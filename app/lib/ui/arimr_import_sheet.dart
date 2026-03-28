import 'dart:developer' as dev;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:uuid/uuid.dart';

import '../ffi/nav_bridge.dart';
import '../models/arimr_parcel.dart';
import '../models/field_model.dart';
import '../services/arimr_service.dart';
import '../services/field_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Enum kroków importu
// ─────────────────────────────────────────────────────────────────────────────

enum _ImportStep {
  /// Użytkownik konfiguruje obszar i filtry.
  configure,

  /// Trwa pobieranie działek z ARiMR.
  fetching,

  /// Podgląd pobranych działek + opcja kasowania.
  preview,

  /// Trwa przetwarzanie geometrii przez C++ (union + simplify).
  processing,

  /// Gotowy do zapisu — user wpisuje nazwę.
  done,
}

// ─────────────────────────────────────────────────────────────────────────────
// ArimrImportSheet
// ─────────────────────────────────────────────────────────────────────────────

/// BottomSheet do importu obszarowego działek LPIS z rejestru ARiMR.
///
/// Przepływ:
///   1. Konfiguracja: opcjonalny filtr farmId / kodu grupy upraw.
///   2. Fetching: pobieranie działek widocznego obszaru mapy (lub wpisanego farmId).
///   3. Preview: lista działek + checkboxy + wyświetlenie minimapy.
///   4. Processing: C++ GeometryProcessor (union + simplify + buffer 2 cm).
///   5. Done: nazwa pola → zapis do Hive → return [FieldModel].
class ArimrImportSheet extends StatefulWidget {
  const ArimrImportSheet({
    super.key,
    required this.mapBounds,
    this.onFieldCreated,
  });

  /// Aktualny widok mapy — używany jako obszar domyślny dla zapytania LPIS.
  final LatLngBounds mapBounds;

  /// Callback wywoływany po zapisaniu pola do Hive.
  final void Function(FieldModel field)? onFieldCreated;

  static Future<FieldModel?> show(
    BuildContext context, {
    required LatLngBounds mapBounds,
  }) {
    return showModalBottomSheet<FieldModel>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ArimrImportSheet(mapBounds: mapBounds),
    );
  }

  @override
  State<ArimrImportSheet> createState() => _ArimrImportSheetState();
}

class _ArimrImportSheetState extends State<ArimrImportSheet> {
  // ── Kontrolery ────────────────────────────────────────────────────────────────
  final _farmIdCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();

  // ── Stan ─────────────────────────────────────────────────────────────────────
  _ImportStep _step = _ImportStep.configure;
  List<ArimrParcel> _parcels = [];
  final Set<String> _selected = {};
  String? _cropGroupFilter;
  List<String> _availableCropGroups = [];
  bool _loadingGroups = false;
  String? _error;
  MergeFieldResult? _mergeResult;
  bool _fromCache = false;

  @override
  void initState() {
    super.initState();
    _loadCropGroups();
  }

  @override
  void dispose() {
    _farmIdCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  // ── Ładowanie metadanych ─────────────────────────────────────────────────────

  Future<void> _loadCropGroups() async {
    setState(() => _loadingGroups = true);
    try {
      final codes = await ArimrService.instance.fetchCropGroupCodes();
      if (mounted) setState(() => _availableCropGroups = codes);
    } catch (_) {
      // Metadane niedostępne offline — pomijamy
    } finally {
      if (mounted) setState(() => _loadingGroups = false);
    }
  }

  // ── Pobieranie działek ───────────────────────────────────────────────────────

  Future<void> _fetchParcels() async {
    setState(() {
      _step = _ImportStep.fetching;
      _error = null;
      _parcels = [];
      _selected.clear();
    });

    try {
      LpisFetchResult result;
      final farmId = _farmIdCtrl.text.trim();

      if (farmId.isNotEmpty) {
        result = await ArimrService.instance.fetchByFarmId(farmId);
      } else {
        result = await ArimrService.instance.fetchAgriculturalParcels(
          widget.mapBounds,
          cropGroupCode: _cropGroupFilter,
        );
      }

      if (!mounted) return;
      setState(() {
        _parcels = result.parcels;
        _selected.addAll(result.parcels.map((p) => p.objectId));
        _fromCache = result.fromCache;
        _step = _ImportStep.preview;
      });
    } on ArimrNoNetworkException {
      if (!mounted) return;
      setState(() {
        _error = 'Brak połączenia. Sprawdź Wi-Fi lub użyj danych z cache.';
        _step = _ImportStep.configure;
      });
    } on ArimrServiceException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _step = _ImportStep.configure;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Nieoczekiwany błąd: $e';
        _step = _ImportStep.configure;
      });
    }
  }

  // ── Przetwarzanie geometrii ───────────────────────────────────────────────────

  Future<void> _processParcels() async {
    final toProcess =
        _parcels.where((p) => _selected.contains(p.objectId)).toList();

    if (toProcess.isEmpty) {
      setState(() => _error = 'Zaznacz co najmniej jedną działkę.');
      return;
    }

    setState(() {
      _step = _ImportStep.processing;
      _error = null;
    });

    try {
      final polygons =
          toProcess.map((p) => p.boundary).where((b) => b.length >= 3).toList();

      final result = await LpisProcessorBridge.instance.processAsync(
        polygons,
        bufferM: 0.02,
        simplifyEpsilonM: 0.3,
      );

      if (!mounted) return;

      if (result.primaryBoundary.isEmpty) {
        setState(() {
          _error =
              'Przetwarzanie geometrii nie zwróciło granicy. Spróbuj z innym filtrem.';
          _step = _ImportStep.preview;
        });
        return;
      }

      _mergeResult = result;
      _nameCtrl.text =
          'Pole ARiMR ${FieldService.instance.getAll().length + 1}';

      setState(() => _step = _ImportStep.done);
    } catch (e, st) {
      dev.log('LpisProcessor error: $e', stackTrace: st, name: 'ArimrImport');
      if (!mounted) return;
      setState(() {
        _error = 'Błąd przetwarzania geometrii: $e';
        _step = _ImportStep.preview;
      });
    }
  }

  // ── Zapis pola ────────────────────────────────────────────────────────────────

  Future<void> _saveField() async {
    final boundary = _mergeResult?.primaryBoundary ?? [];
    if (boundary.isEmpty) return;

    final name =
        _nameCtrl.text.trim().isEmpty ? 'Pole ARiMR' : _nameCtrl.text.trim();

    final selectedParcels =
        _parcels.where((p) => _selected.contains(p.objectId)).toList();

    final field = FieldModel(
      id: const Uuid().v4(),
      name: name,
      boundaryLats: boundary.map((e) => e.latitude).toList(),
      boundaryLons: boundary.map((e) => e.longitude).toList(),
      source: FieldSource.arimr,
      arimrParcelIds: selectedParcels.map((p) => p.objectId).toList(),
    );

    await FieldService.instance.save(field);

    widget.onFieldCreated?.call(field);
    if (mounted) Navigator.pop(context, field);
  }

  // ── Budowanie UI ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (ctx, scrollCtrl) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF1E1E1E),
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: Column(
          children: [
            // ── Uchwyt ────────────────────────────────────────────────────────
            Center(
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            _buildHeader(),
            const Divider(color: Colors.white12, height: 1),
            Expanded(child: _buildBody(scrollCtrl)),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final titles = {
      _ImportStep.configure: 'Import LPIS (ARiMR)',
      _ImportStep.fetching: 'Pobieranie działek…',
      _ImportStep.preview: 'Wybierz działki (${_parcels.length})',
      _ImportStep.processing: 'Przetwarzanie geometrii…',
      _ImportStep.done: 'Nazwa pola',
    };

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          if (_step == _ImportStep.preview || _step == _ImportStep.done)
            IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white70),
              onPressed: () => setState(() {
                _step = _step == _ImportStep.done
                    ? _ImportStep.preview
                    : _ImportStep.configure;
              }),
            ),
          Expanded(
            child: Text(
              titles[_step] ?? 'ARiMR',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (_fromCache && _step == _ImportStep.preview)
            const Chip(
              label: Text('CACHE', style: TextStyle(fontSize: 11)),
              backgroundColor: Color(0xFF3A3A00),
              labelStyle: TextStyle(color: Colors.yellowAccent),
            ),
        ],
      ),
    );
  }

  Widget _buildBody(ScrollController scrollCtrl) {
    switch (_step) {
      case _ImportStep.configure:
        return _buildConfigure(scrollCtrl);
      case _ImportStep.fetching:
      case _ImportStep.processing:
        return _buildLoading();
      case _ImportStep.preview:
        return _buildPreview(scrollCtrl);
      case _ImportStep.done:
        return _buildDone(scrollCtrl);
    }
  }

  // ── Krok 1: Konfiguracja ──────────────────────────────────────────────────────

  Widget _buildConfigure(ScrollController scrollCtrl) {
    return ListView(
      controller: scrollCtrl,
      padding: const EdgeInsets.all(16),
      children: [
        // Opis obszaru
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF2A2A2A),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              const Icon(Icons.crop_free, color: Colors.greenAccent, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Obszar: ${widget.mapBounds.south.toStringAsFixed(4)}°N, '
                  '${widget.mapBounds.west.toStringAsFixed(4)}°E → '
                  '${widget.mapBounds.north.toStringAsFixed(4)}°N, '
                  '${widget.mapBounds.east.toStringAsFixed(4)}°E',
                  style: const TextStyle(color: Colors.white60, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // Filtr: numer ewidencyjny działki (TERYT / ULDK)
        TextField(
          controller: _farmIdCtrl,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            labelText: 'Nr ewidencyjny działki (TERYT) — opcjonalnie',
            labelStyle: TextStyle(color: Colors.white54),
            hintText: 'np. 141201_1.0001.AR_1.1',
            hintStyle: TextStyle(color: Colors.white24),
            enabledBorder: OutlineInputBorder(
              borderSide: BorderSide(color: Colors.white24),
            ),
            focusedBorder: OutlineInputBorder(
              borderSide: BorderSide(color: Colors.greenAccent),
            ),
            prefixIcon: Icon(Icons.pin_drop, color: Colors.white38),
          ),
        ),
        const SizedBox(height: 12),

        // Filtr: kod grupy upraw
        _buildCropGroupDropdown(),
        const SizedBox(height: 8),

        // Błąd
        if (_error != null) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.red.shade900.withOpacity(0.3),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                const Icon(Icons.error_outline,
                    color: Colors.redAccent, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_error!,
                      style: const TextStyle(
                          color: Colors.redAccent, fontSize: 13)),
                ),
              ],
            ),
          ),
        ],

        const SizedBox(height: 20),

        // Przycisk Pobierz
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.green[700],
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            icon: const Icon(Icons.download),
            label: const Text('Pobierz działki LPIS'),
            onPressed: _fetchParcels,
          ),
        ),
        const SizedBox(height: 8),

        // Przycisk: użyj cache
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Colors.white24),
              foregroundColor: Colors.white60,
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            icon: const Icon(Icons.storage, size: 18),
            label: const Text('Użyj danych z cache (offline)'),
            onPressed: () {
              final cached =
                  ArimrService.instance.getCachedParcels(widget.mapBounds);
              if (cached.isEmpty) {
                setState(
                    () => _error = 'Brak danych w cache dla tego obszaru.');
                return;
              }
              setState(() {
                _parcels = cached;
                _selected.addAll(cached.map((p) => p.objectId));
                _fromCache = true;
                _step = _ImportStep.preview;
              });
            },
          ),
        ),
      ],
    );
  }

  Widget _buildCropGroupDropdown() {
    if (_loadingGroups) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: LinearProgressIndicator(color: Colors.greenAccent),
      );
    }
    if (_availableCropGroups.isEmpty) return const SizedBox.shrink();

    return DropdownButtonFormField<String>(
      value: _cropGroupFilter,
      dropdownColor: const Color(0xFF2A2A2A),
      style: const TextStyle(color: Colors.white),
      decoration: const InputDecoration(
        labelText: 'Filtr: kod grupy upraw — opcjonalnie',
        labelStyle: TextStyle(color: Colors.white54),
        enabledBorder:
            OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
        focusedBorder: OutlineInputBorder(
            borderSide: BorderSide(color: Colors.greenAccent)),
        prefixIcon: Icon(Icons.grass, color: Colors.white38),
      ),
      items: [
        const DropdownMenuItem(value: null, child: Text('— Wszystkie —')),
        ..._availableCropGroups.map((code) => DropdownMenuItem(
              value: code,
              child: Text(code),
            )),
      ],
      onChanged: (v) => setState(() => _cropGroupFilter = v),
    );
  }

  // ── Krok 2/4: Loading ─────────────────────────────────────────────────────────

  Widget _buildLoading() {
    final msg = _step == _ImportStep.fetching
        ? 'Pobieranie działek z geoportal.arimr.gov.pl…'
        : 'Przetwarzanie geometrii (C++ Clipper2)…';
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(color: Colors.greenAccent),
          const SizedBox(height: 16),
          Text(msg,
              style: const TextStyle(color: Colors.white60, fontSize: 14)),
        ],
      ),
    );
  }

  // ── Krok 3: Podgląd ───────────────────────────────────────────────────────────

  Widget _buildPreview(ScrollController scrollCtrl) {
    if (_parcels.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search_off, color: Colors.white38, size: 48),
            const SizedBox(height: 12),
            const Text('Brak działek rolnych w tym obszarze.',
                style: TextStyle(color: Colors.white54)),
            const SizedBox(height: 16),
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white60,
                  side: const BorderSide(color: Colors.white24)),
              onPressed: () => setState(() => _step = _ImportStep.configure),
              child: const Text('Zmień obszar / filtry'),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            controller: scrollCtrl,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            itemCount: _parcels.length,
            itemBuilder: (ctx, i) => _buildParcelTile(_parcels[i]),
          ),
        ),
        _buildPreviewActions(),
      ],
    );
  }

  Widget _buildParcelTile(ArimrParcel parcel) {
    final isSelected = _selected.contains(parcel.objectId);
    return CheckboxListTile(
      value: isSelected,
      onChanged: (v) => setState(() {
        if (v == true) {
          _selected.add(parcel.objectId);
        } else {
          _selected.remove(parcel.objectId);
        }
      }),
      activeColor: Colors.greenAccent,
      checkColor: Colors.black,
      title: Row(
        children: [
          if (parcel.cropGroupCode != null)
            Container(
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: _cropGroupColor(parcel.cropGroupCode!),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                parcel.cropGroupCode!,
                style: const TextStyle(fontSize: 11, color: Colors.white),
              ),
            ),
          Expanded(
            child: Text(
              parcel.farmId != null
                  ? 'Gosp. ${parcel.farmId}'
                  : 'ID: ${parcel.objectId}',
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
        ],
      ),
      subtitle: Text(
        [
          if (parcel.cropGroupLabel != null) parcel.cropGroupLabel,
          if (parcel.areaHa != null) '${parcel.areaHa!.toStringAsFixed(2)} ha',
          if (parcel.campaignYear != null) '${parcel.campaignYear}',
        ].join(' · '),
        style: const TextStyle(color: Colors.white54, fontSize: 12),
      ),
    );
  }

  Color _cropGroupColor(String code) {
    switch (code.toUpperCase()) {
      case 'R':
        return Colors.brown.shade700;
      case 'TR':
        return Colors.green.shade800;
      case 'TUZ':
        return Colors.teal.shade700;
      case 'S':
        return Colors.deepPurple.shade700;
      default:
        return Colors.blueGrey.shade700;
    }
  }

  Widget _buildPreviewActions() {
    final selCount = _selected.length;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: const BoxDecoration(
        color: Color(0xFF2A2A2A),
        border: Border(top: BorderSide(color: Colors.white12)),
      ),
      child: Row(
        children: [
          TextButton.icon(
            icon: Icon(
              selCount == _parcels.length ? Icons.deselect : Icons.select_all,
              size: 18,
            ),
            label: Text(
              selCount == _parcels.length
                  ? 'Odznacz wszystkie'
                  : 'Zaznacz wszystkie',
            ),
            style: TextButton.styleFrom(foregroundColor: Colors.white60),
            onPressed: () => setState(() {
              if (selCount == _parcels.length) {
                _selected.clear();
              } else {
                _selected.addAll(_parcels.map((p) => p.objectId));
              }
            }),
          ),
          const Spacer(),
          if (_error != null)
            Flexible(
              child: Text(_error!,
                  style:
                      const TextStyle(color: Colors.redAccent, fontSize: 12)),
            ),
          const SizedBox(width: 8),
          FilledButton.icon(
            style: FilledButton.styleFrom(
                backgroundColor:
                    selCount > 0 ? Colors.green[700] : Colors.grey[700]),
            icon: const Icon(Icons.merge_type, size: 18),
            label: Text('Scal ($selCount)'),
            onPressed: selCount > 0 ? _processParcels : null,
          ),
        ],
      ),
    );
  }

  // ── Krok 5: Nazwa pola ────────────────────────────────────────────────────────

  Widget _buildDone(ScrollController scrollCtrl) {
    final boundary = _mergeResult?.primaryBoundary ?? [];
    final holes = _mergeResult?.holes ?? [];
    final selCount = _selected.length;

    return ListView(
      controller: scrollCtrl,
      padding: const EdgeInsets.all(16),
      children: [
        // Podsumowanie
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.green.shade900.withOpacity(0.3),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.green.shade700),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: const [
                  Icon(Icons.check_circle, color: Colors.greenAccent, size: 20),
                  SizedBox(width: 8),
                  Text('Granica gotowa',
                      style: TextStyle(
                          color: Colors.greenAccent,
                          fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(height: 6),
              Text('Działki LPIS: $selCount',
                  style: const TextStyle(color: Colors.white70, fontSize: 13)),
              Text('Wierzchołki granicy: ${boundary.length}',
                  style: const TextStyle(color: Colors.white70, fontSize: 13)),
              if (holes.isNotEmpty)
                Text('Otwory (dziury): ${holes.length}',
                    style:
                        const TextStyle(color: Colors.white54, fontSize: 13)),
              if (_mergeResult?.isMultipart == true)
                const Text(
                  'Uwaga: pole wieloczęściowe (działki się nie stykają)',
                  style: TextStyle(color: Colors.orangeAccent, fontSize: 12),
                ),
            ],
          ),
        ),
        const SizedBox(height: 20),

        // Nazwa pola
        TextField(
          controller: _nameCtrl,
          style: const TextStyle(color: Colors.white),
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Nazwa pola',
            labelStyle: TextStyle(color: Colors.white54),
            enabledBorder: OutlineInputBorder(
                borderSide: BorderSide(color: Colors.white24)),
            focusedBorder: OutlineInputBorder(
                borderSide: BorderSide(color: Colors.greenAccent)),
            prefixIcon: Icon(Icons.label_outline, color: Colors.white38),
          ),
        ),
        const SizedBox(height: 24),

        // Zapisz
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.green[700],
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            icon: const Icon(Icons.save),
            label: const Text('Zapisz pole'),
            onPressed: _saveField,
          ),
        ),
      ],
    );
  }
}
