import 'dart:developer' as dev;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:uuid/uuid.dart';

import '../ffi/nav_bridge.dart';
import '../models/lpis_parcel.dart';
import '../models/field_model.dart';
import '../services/lpis_service.dart';
import '../services/field_service.dart';
import '../utils/geo_utils.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Enum kroków importu
// ─────────────────────────────────────────────────────────────────────────────

enum _ImportStep {
  /// Użytkownik konfiguruje obszar i filtry.
  configure,

  /// Trwa pobieranie działek z ULDK (GUGiK).
  fetching,

  /// Podgląd pobranych działek + opcja kasowania.
  preview,

  /// Trwa przetwarzanie geometrii przez C++ (union + simplify).
  processing,

  /// Gotowy do zapisu — user wpisuje nazwę.
  done,
}

// ─────────────────────────────────────────────────────────────────────────────
// LpisImportSheet
// ─────────────────────────────────────────────────────────────────────────────

/// BottomSheet do importu działek LPIS (dane z ULDK GUGiK).
///
/// Przepływ:
///   1. Konfiguracja: wpisz numery ewidencyjne działek (TERYT).
///   2. Fetching: pobieranie działek z ULDK (GetParcelById).
///   3. Preview: lista działek + checkboxy + wyświetlenie minimapy.
///   4. Processing: C++ GeometryProcessor (union + simplify + buffer 2 cm).
///   5. Done: nazwa pola → zapis do Hive → return [FieldModel].
class LpisImportSheet extends StatefulWidget {
  const LpisImportSheet({
    super.key,
    this.mapBounds,
    this.onFieldCreated,
    this.fullScreen = false,
  });

  /// Aktualny widok mapy — używany jako obszar domyślny dla zapytania LPIS.
  /// Opcjonalny: po otwarciu z ekranu głównego (bez mapy) import odbywa się
  /// po numerze TERYT, a granice pola są dopasowywane na mapie po zapisie.
  final LatLngBounds? mapBounds;

  /// Callback wywoływany po zapisaniu pola do Hive.
  final void Function(FieldModel field)? onFieldCreated;

  /// Gdy true — sheet otwiera się jako pełny ekran (bez mapy w tle).
  final bool fullScreen;

  static Future<FieldModel?> show(
    BuildContext context, {
    LatLngBounds? mapBounds,
    bool fullScreen = false,
  }) {
    if (fullScreen) {
      return Navigator.push<FieldModel>(
        context,
        MaterialPageRoute(
          builder: (_) => LpisImportSheet(
            mapBounds: mapBounds,
            fullScreen: true,
          ),
        ),
      );
    }
    return showModalBottomSheet<FieldModel>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => LpisImportSheet(mapBounds: mapBounds),
    );
  }

  @override
  State<LpisImportSheet> createState() => _LpisImportSheetState();
}

class _LpisImportSheetState extends State<LpisImportSheet> {
  // ── Kontrolery ────────────────────────────────────────────────────────────────
  final List<TextEditingController> _terytCtrls = [TextEditingController()];
  final _nameCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();

  // ── Stan ─────────────────────────────────────────────────────────────────────
  _ImportStep _step = _ImportStep.configure;
  List<LpisParcel> _parcels = [];
  final Set<String> _selected = {};
  String? _cropGroupFilter;
  List<String> _availableCropGroups = [];
  bool _loadingGroups = false;
  String? _error;
  MergeFieldResult? _mergeResult;
  bool _fromCache = false;

  /// Epsilon RDP [m]: 0.0 = pełna dokładność (brak uproszczenia), większe = mniej wierzchołków.
  double _simplifyEpsilonM = 0.0;

  @override
  void initState() {
    super.initState();
    _loadCropGroups();
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    for (final c in _terytCtrls) {
      c.dispose();
    }
    _nameCtrl.dispose();
    super.dispose();
  }

  // ── Ładowanie metadanych ─────────────────────────────────────────────────────

  Future<void> _loadCropGroups() async {
    setState(() => _loadingGroups = true);
    try {
      final codes = await LpisService.instance.fetchCropGroupCodes();
      if (mounted) setState(() => _availableCropGroups = codes);
    } catch (_) {
      // Metadane niedostępne offline — pomijamy
    } finally {
      if (mounted) setState(() => _loadingGroups = false);
    }
  }

  // ── Pobieranie działek ───────────────────────────────────────────────────────

  Future<void> _fetchParcels() async {
    final ids = _terytCtrls
        .map((c) => c.text.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    if (ids.isEmpty) {
      setState(() => _error =
          'Podaj co najmniej jeden numer ewidencyjny działki (TERYT).');
      return;
    }

    setState(() {
      _step = _ImportStep.fetching;
      _error = null;
      _parcels = [];
      _selected.clear();
    });

    final allParcels = <LpisParcel>[];
    final errors = <String>[];

    for (final id in ids) {
      try {
        final result = await LpisService.instance.fetchByFarmId(id);
        allParcels.addAll(result.parcels);
      } on LpisNoNetworkException {
        if (!mounted) return;
        setState(() {
          _error = 'Brak połączenia. Sprawdź Wi-Fi lub użyj danych z cache.';
          _step = _ImportStep.configure;
        });
        return;
      } on LpisServiceException catch (e) {
        errors.add('[$id]: ${e.message}');
      } catch (e) {
        errors.add('[$id]: $e');
      }
    }

    if (!mounted) return;

    if (allParcels.isEmpty) {
      setState(() {
        _error = 'Nie znaleziono żadnych działek.'
            '${errors.isNotEmpty ? '\n${errors.join('\n')}' : ''}';
        _step = _ImportStep.configure;
      });
      return;
    }

    setState(() {
      _parcels = allParcels;
      _selected.addAll(allParcels.map((p) => p.objectId));
      _fromCache = false;
      _step = _ImportStep.preview;
      if (errors.isNotEmpty) {
        _error = 'Części działek nie znaleziono:\n${errors.join('\n')}';
      }
    });
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
        simplifyEpsilonM: _simplifyEpsilonM,
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
          'Pole LPIS ${FieldService.instance.getAll().length + 1}';

      setState(() => _step = _ImportStep.done);
    } catch (e, st) {
      dev.log('LpisProcessor error: $e', stackTrace: st, name: 'LpisImport');
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
        _nameCtrl.text.trim().isEmpty ? 'Pole LPIS' : _nameCtrl.text.trim();

    final selectedParcels =
        _parcels.where((p) => _selected.contains(p.objectId)).toList();

    final field = FieldModel(
      id: const Uuid().v4(),
      name: name,
      boundaryLats: boundary.map((e) => e.latitude).toList(),
      boundaryLons: boundary.map((e) => e.longitude).toList(),
      source: FieldSource.lpis,
      lpisParcelIds: selectedParcels.map((p) => p.objectId).toList(),
      areaHa: GeoUtils.polygonAreaHa(boundary),
    );

    await FieldService.instance.save(field);

    widget.onFieldCreated?.call(field);
    if (mounted) Navigator.pop(context, field);
  }

  // ── Budowanie UI ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (widget.fullScreen) {
      return Scaffold(
        backgroundColor: const Color(0xFF1E1E1E),
        body: SafeArea(child: _buildContent(_scrollCtrl)),
      );
    }
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (ctx, scrollCtrl) => _buildContent(scrollCtrl),
    );
  }

  Widget _buildContent(ScrollController scrollCtrl) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: widget.fullScreen
            ? BorderRadius.zero
            : const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        children: [
          // ── Uchwyt (tylko tryb bottom sheet) ────────────────────────────────
          if (!widget.fullScreen)
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
    );
  }

  Widget _buildHeader() {
    final titles = {
      _ImportStep.configure: 'Import działek LPIS (ULDK GUGiK)',
      _ImportStep.fetching: 'Pobieranie działek…',
      _ImportStep.preview: 'Wybierz działki (${_parcels.length})',
      _ImportStep.processing: 'Przetwarzanie geometrii…',
      _ImportStep.done: 'Nazwa pola',
    };

    final canGoBack =
        _step == _ImportStep.preview || _step == _ImportStep.done;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          if (widget.fullScreen)
            IconButton(
              icon: Icon(
                canGoBack ? Icons.arrow_back : Icons.close,
                color: Colors.white70,
              ),
              tooltip: canGoBack ? 'Wstecz' : 'Zamknij',
              onPressed: () {
                if (canGoBack) {
                  setState(() {
                    _step = _step == _ImportStep.done
                        ? _ImportStep.preview
                        : _ImportStep.configure;
                  });
                } else {
                  Navigator.pop(context);
                }
              },
            )
          else if (canGoBack)
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
              titles[_step] ?? 'LPIS',
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
        // Opis obszaru (lub wskazówka, gdy brak mapy — import po TERYT)
        if (widget.mapBounds != null)
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
                    'Obszar: ${widget.mapBounds!.south.toStringAsFixed(4)}°N, '
                    '${widget.mapBounds!.west.toStringAsFixed(4)}°E → '
                    '${widget.mapBounds!.north.toStringAsFixed(4)}°N, '
                    '${widget.mapBounds!.east.toStringAsFixed(4)}°E',
                    style:
                        const TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                ),
              ],
            ),
          )
        else
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF2A2A2A),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Row(
              children: [
                Icon(Icons.pin_drop, color: Colors.greenAccent, size: 20),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Wpisz numery ewidencyjne działek (TERYT), aby pobrać '
                    'granice z rejestru LPIS (ULDK GUGiK). Pole zostanie '
                    'pokazane na mapie po zapisaniu.',
                    style: TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 16),

        // Numery ewidencyjne działek (TERYT) — wiele pól
        _buildTerytRows(),
        const SizedBox(height: 12),

        // Filtr: kod grupy upraw
        _buildCropGroupDropdown(),
        const SizedBox(height: 12),

        // Dokładność granicy
        _buildAccuracySelector(),
        const SizedBox(height: 8),

        // Błąd
        if (_error != null) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.red.shade900.withValues(alpha: 0.3),
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
                  LpisService.instance.getCachedParcels(widget.mapBounds);
              if (cached.isEmpty) {
                setState(() => _error = widget.mapBounds != null
                    ? 'Brak danych w cache dla tego obszaru.'
                    : 'Brak zapisanych działek w cache.');
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

  // ── Wiele pól TERYT ─────────────────────────────────────────────────────────

  Widget _buildTerytRows() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...List.generate(_terytCtrls.length, (i) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: TextField(
                    controller: _terytCtrls[i],
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: i == 0
                          ? 'Nr ewidencyjny działki (TERYT)'
                          : 'Działka ${i + 1}',
                      labelStyle: const TextStyle(color: Colors.white54),
                      hintText: 'np. 141201_1.0001.AR_1.1',
                      hintStyle: const TextStyle(color: Colors.white24),
                      enabledBorder: const OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.white24),
                      ),
                      focusedBorder: const OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.greenAccent),
                      ),
                      prefixIcon: const Icon(
                        Icons.pin_drop,
                        color: Colors.white38,
                      ),
                    ),
                  ),
                ),
                if (i > 0) ...[
                  const SizedBox(width: 4),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white38),
                    tooltip: 'Usuń',
                    onPressed: () => setState(() {
                      _terytCtrls[i].dispose();
                      _terytCtrls.removeAt(i);
                    }),
                  ),
                ],
              ],
            ),
          );
        }),
        TextButton.icon(
          icon: const Icon(Icons.add, size: 18, color: Colors.greenAccent),
          label: const Text(
            'Dodaj +',
            style: TextStyle(color: Colors.greenAccent),
          ),
          onPressed: () =>
              setState(() => _terytCtrls.add(TextEditingController())),
        ),
      ],
    );
  }

  // ── Selektor dokładności granicy ─────────────────────────────────────────────

  static const _accuracyPresets = <(String, double)>[
    ('Pełna (kataster)', 0.0),
    ('Wysoka  5 cm', 0.05),
    ('Standardowa  30 cm', 0.30),
    ('Uproszczona  1 m', 1.0),
  ];

  Widget _buildAccuracySelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 6),
          child: Text(
            'Dokładność granicy',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ),
        Wrap(
          spacing: 8,
          children: _accuracyPresets.map((preset) {
            final (label, eps) = preset;
            final selected = (_simplifyEpsilonM - eps).abs() < 1e-9;
            return ChoiceChip(
              label: Text(label,
                  style: TextStyle(
                    fontSize: 12,
                    color: selected ? Colors.black : Colors.white70,
                  )),
              selected: selected,
              selectedColor: Colors.greenAccent,
              backgroundColor: const Color(0xFF2A2A2A),
              side: BorderSide(
                color: selected ? Colors.greenAccent : Colors.white24,
              ),
              onSelected: (_) => setState(() => _simplifyEpsilonM = eps),
            );
          }).toList(),
        ),
        if (_simplifyEpsilonM == 0.0)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text(
              'Wszystkie wierzchołki z katastru (zalecane)',
              style: TextStyle(color: Colors.greenAccent, fontSize: 11),
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
        ? 'Pobieranie działek z ULDK GUGiK…'
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

  Widget _buildParcelTile(LpisParcel parcel) {
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
            color: Colors.green.shade900.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.green.shade700),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
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
