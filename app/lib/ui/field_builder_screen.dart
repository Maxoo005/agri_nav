import 'dart:developer' as dev;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:uuid/uuid.dart';

import '../ffi/nav_bridge.dart';
import '../models/field_model.dart';
import '../services/field_service.dart';
import '../services/geoportal_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Model stanu kreatora (immutable step pattern)
// ─────────────────────────────────────────────────────────────────────────────

enum _BuildStep { input, fetching, preview, merging, done }

class _ParcelEntry {
  _ParcelEntry({required this.fullId});
  final String fullId;
  List<LatLng>? geometry; // null = oczekuje na fetch
  String? error; // non-null = błąd pobrania

  bool get ok => geometry != null;
}

// ─────────────────────────────────────────────────────────────────────────────
// FieldBuilderScreen
// ─────────────────────────────────────────────────────────────────────────────

/// Ekran Kreatora Pola Geodezyjnego.
///
/// Przepływ:
///   1. Użytkownik wpisuje prefiks obrębu + numery działek.
///   2. "Sprawdź działki" → concurrent fetch z ULDK.
///   3. Podgląd listy pobranych działek z możliwością usunięcia.
///   4. "Generuj granicę pola" → C++ ParcelMerger (Clipper2 Union).
///   5. Użytkownik wpisuje nazwę → zapis do Hive → powrót z [FieldModel].
class FieldBuilderScreen extends StatefulWidget {
  const FieldBuilderScreen({super.key});

  /// Otwiera kreator i zwraca [FieldModel] lub null gdy użytkownik anulował.
  static Future<FieldModel?> open(BuildContext context) =>
      Navigator.push<FieldModel>(
        context,
        MaterialPageRoute(builder: (_) => const FieldBuilderScreen()),
      );

  @override
  State<FieldBuilderScreen> createState() => _FieldBuilderScreenState();
}

class _FieldBuilderScreenState extends State<FieldBuilderScreen> {
  // ── Kontrolery ───────────────────────────────────────────────────────────────
  final _prefixCtrl = TextEditingController();
  final _parcelsCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();

  // ── Stan ─────────────────────────────────────────────────────────────────────
  _BuildStep _step = _BuildStep.input;
  final List<_ParcelEntry> _entries = [];
  MergeFieldResult? _mergeResult;
  String? _globalError;

  @override
  void dispose() {
    _prefixCtrl.dispose();
    _parcelsCtrl.dispose();
    _nameCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  // ── Logika ───────────────────────────────────────────────────────────────────

  /// Parsuje pole tekstowe na listę pełnych identyfikatorów działek.
  List<String> _parseIds() {
    final raw = _parcelsCtrl.text
        .split(RegExp(r'[,;\n]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final prefix = _prefixCtrl.text.trim();
    return raw
        .map((id) => prefix.isEmpty
            ? id
            : GeoportalService.buildFullParcelId(prefix, id))
        .toList();
  }

  Future<void> _fetchAll() async {
    final ids = _parseIds();
    if (ids.isEmpty) {
      setState(() => _globalError = 'Wpisz co najmniej jeden numer działki.');
      return;
    }

    setState(() {
      _step = _BuildStep.fetching;
      _globalError = null;
      _entries
        ..clear()
        ..addAll(ids.map((id) => _ParcelEntry(fullId: id)));
    });

    try {
      final result = await GeoportalService.instance.fetchMultipleParcels(ids);

      if (!mounted) return;
      setState(() {
        for (final entry in _entries) {
          if (result.geometries.containsKey(entry.fullId)) {
            entry.geometry = result.geometries[entry.fullId];
          } else {
            entry.error = result.errors[entry.fullId] ?? 'Nieznany błąd';
          }
        }
        _step = _BuildStep.preview;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _step = _BuildStep.input;
        _globalError = e.toString();
      });
    }
  }

  Future<void> _mergeAndFinish() async {
    final okEntries = _entries.where((e) => e.ok).toList();
    if (okEntries.isEmpty) {
      setState(() => _globalError = 'Brak prawidłowych geometrii do scalenia.');
      return;
    }

    setState(() {
      _step = _BuildStep.merging;
      _globalError = null;
    });

    try {
      final polygons = okEntries.map((e) => e.geometry!).toList();

      // C++ union — uruchamiamy w Isolate aby nie blokować UI
      final mergeResult = await _runMergeIsolate(polygons);

      if (!mounted) return;

      // Wstępna nazwa pola
      final shortest =
          okEntries.map((e) => e.fullId.split('.').last).join(', ');
      _nameCtrl.text = 'Pole $shortest';

      setState(() {
        _mergeResult = mergeResult;
        _step = _BuildStep.done;
      });

      // Informacja o wieloczęściowym polu
      if (mergeResult.isMultipart) {
        _showMultipartWarning();
      }
    } catch (e) {
      dev.log('Merge error: $e', name: 'FieldBuilderScreen', level: 900);
      if (!mounted) return;
      setState(() {
        _step = _BuildStep.preview;
        _globalError = 'Błąd scalania: $e';
      });
    }
  }

  // Merge może być w tym samym isolate (C-call jest szybki dla kilku działek)
  Future<MergeFieldResult> _runMergeIsolate(List<List<LatLng>> polygons) async {
    return ParcelMergerBridge.instance.merge(polygons);
  }

  Future<void> _saveField() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Wpisz nazwę pola')),
      );
      return;
    }

    final mr = _mergeResult!;
    final boundary = mr.primaryBoundary;
    if (boundary.length < 3) {
      setState(() => _globalError = 'Wynikowa granica jest zbyt mała.');
      return;
    }

    final field = FieldModel(
      id: const Uuid().v4(),
      name: name,
      boundaryLats: boundary.map((p) => p.latitude).toList(),
      boundaryLons: boundary.map((p) => p.longitude).toList(),
      sourceParcelIds:
          _entries.where((e) => e.ok).map((e) => e.fullId).toList(),
      source: FieldSource.uldk,
      lastSyncDate: DateTime.now(),
    );

    await FieldService.instance.save(field);

    if (!mounted) return;
    Navigator.pop(context, field);
  }

  void _showMultipartWarning() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.orange),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Działki nie stykają się – zapisano jako pole wieloczęściowe. '
                'Używana będzie tylko główna granica zewnętrzna.',
                style: TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
        backgroundColor: const Color(0xFF2C2C2C),
        duration: const Duration(seconds: 6),
      ),
    );
  }

  // ── Widżety ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1C1C1C),
        foregroundColor: Colors.white,
        title: const Text(
          'Kreator Pola Geodezyjnego',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        actions: [
          if (_step == _BuildStep.input || _step == _BuildStep.preview)
            TextButton(
              onPressed: () => Navigator.pop(context),
              child:
                  const Text('Anuluj', style: TextStyle(color: Colors.white54)),
            ),
        ],
      ),
      body: Column(
        children: [
          // ── Pasek kroków ──────────────────────────────────────────────────
          _StepBar(step: _step),

          Expanded(
            child: SingleChildScrollView(
              controller: _scrollCtrl,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_globalError != null)
                    _ErrorBanner(message: _globalError!),

                  // ── Krok 1: Dane wejściowe ──────────────────────────────
                  if (_step == _BuildStep.input) ...[
                    _SectionHeader(
                      icon: Icons.link,
                      title: 'Prefiks obrębu ewidencyjnego',
                      subtitle: 'Opcjonalnie. Przykład: 141201_2.0001',
                    ),
                    _DarkTextField(
                      controller: _prefixCtrl,
                      hint: 'np. 141201_2.0001',
                      keyboardType: TextInputType.text,
                    ),
                    const SizedBox(height: 20),
                    _SectionHeader(
                      icon: Icons.list_alt_rounded,
                      title: 'Numery działek',
                      subtitle: 'Wpisz pełne np. 141201_2.0001.1234/2\n'
                          'lub, z prefiksem powyżej, tylko: 1234/2, 1235/1',
                    ),
                    _DarkTextField(
                      controller: _parcelsCtrl,
                      hint:
                          '1234/2, 1235/1, 1236\n(każda w nowej linii lub po przecinku)',
                      maxLines: 5,
                      keyboardType: TextInputType.multiline,
                    ),
                    const SizedBox(height: 8),
                    _PreviewChips(parseIds: _parseIds),
                    const SizedBox(height: 24),
                    _PrimaryButton(
                      label: 'Sprawdź działki w ULDK',
                      icon: Icons.cloud_download_rounded,
                      onPressed: _fetchAll,
                      color: Colors.blue[700]!,
                    ),
                  ],

                  // ── Krok 2: Ładowanie ───────────────────────────────────
                  if (_step == _BuildStep.fetching) ...[
                    const SizedBox(height: 40),
                    const Center(
                      child: Column(
                        children: [
                          CircularProgressIndicator(color: Colors.greenAccent),
                          SizedBox(height: 16),
                          Text('Pobieranie geometrii z ULDK GUGiK…',
                              style: TextStyle(color: Colors.white70)),
                        ],
                      ),
                    ),
                  ],

                  // ── Krok 3: Podgląd działek ─────────────────────────────
                  if (_step == _BuildStep.preview) ...[
                    _SectionHeader(
                      icon: Icons.checklist_rounded,
                      title: 'Pobrane działki',
                      subtitle: '${_entries.where((e) => e.ok).length}'
                          ' z ${_entries.length} pobranych pomyślnie',
                    ),
                    ..._entries.map((e) => _ParcelTile(
                          entry: e,
                          onRemove: () => setState(() => _entries.remove(e)),
                        )),
                    const SizedBox(height: 16),
                    if (_entries.any((e) => e.ok)) ...[
                      _PrimaryButton(
                        label: 'Generuj granicę pola',
                        icon: Icons.merge_type_rounded,
                        onPressed: _mergeAndFinish,
                        color: Colors.green[700]!,
                      ),
                    ],
                    const SizedBox(height: 8),
                    _SecondaryButton(
                      label: 'Wróć i popraw',
                      onPressed: () => setState(() {
                        _step = _BuildStep.input;
                        _globalError = null;
                      }),
                    ),
                  ],

                  // ── Krok 4: Scalanie ────────────────────────────────────
                  if (_step == _BuildStep.merging) ...[
                    const SizedBox(height: 40),
                    const Center(
                      child: Column(
                        children: [
                          CircularProgressIndicator(color: Colors.greenAccent),
                          SizedBox(height: 16),
                          Text('Scalanie geometrii (Clipper2 Union)…',
                              style: TextStyle(color: Colors.white70)),
                        ],
                      ),
                    ),
                  ],

                  // ── Krok 5: Wynik + zapis ───────────────────────────────
                  if (_step == _BuildStep.done && _mergeResult != null) ...[
                    _SectionHeader(
                      icon: Icons.check_circle_rounded,
                      title: 'Granica wygenerowana',
                      subtitle: _mergeResult!.isMultipart
                          ? '⚠ Pole wieloczęściowe — działki nie stykają się'
                          : '${_mergeResult!.primaryBoundary.length} wierzchołków',
                    ),
                    _MergeResultCard(result: _mergeResult!),
                    const SizedBox(height: 20),
                    _SectionHeader(
                      icon: Icons.drive_file_rename_outline_rounded,
                      title: 'Nazwa pola',
                      subtitle: 'Zostanie zapisana w bazie lokalnej',
                    ),
                    _DarkTextField(
                      controller: _nameCtrl,
                      hint: 'np. Pole za stodołą',
                    ),
                    const SizedBox(height: 24),
                    _PrimaryButton(
                      label: 'Zapisz pole',
                      icon: Icons.save_rounded,
                      onPressed: _saveField,
                      color: const Color(0xFF2E7D32),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Widżety pomocnicze
// ─────────────────────────────────────────────────────────────────────────────

class _StepBar extends StatelessWidget {
  const _StepBar({required this.step});
  final _BuildStep step;

  static const _labels = ['Dane', 'Pobierz', 'Podgląd', 'Scal', 'Zapisz'];

  @override
  Widget build(BuildContext context) {
    final idx = step.index;
    return Container(
      color: const Color(0xFF1C1C1C),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: List.generate(_labels.length, (i) {
          final active = i == idx;
          final done = i < idx;
          return Expanded(
            child: Row(
              children: [
                if (i > 0)
                  Expanded(
                    child: Container(
                      height: 2,
                      color: done ? Colors.greenAccent : Colors.white12,
                    ),
                  ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: done
                            ? Colors.greenAccent
                            : active
                                ? Colors.blue[700]
                                : Colors.white12,
                      ),
                      child: Center(
                        child: done
                            ? const Icon(Icons.check,
                                size: 14, color: Colors.black)
                            : Text(
                                '${i + 1}',
                                style: TextStyle(
                                  color: active ? Colors.white : Colors.white38,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _labels[i],
                      style: TextStyle(
                        color: active ? Colors.white : Colors.white38,
                        fontSize: 9,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        }),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.icon,
    required this.title,
    required this.subtitle,
  });
  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Colors.greenAccent, size: 18),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  )),
              Text(subtitle,
                  style: const TextStyle(color: Colors.white38, fontSize: 12)),
            ],
          ),
        ],
      ),
    );
  }
}

class _DarkTextField extends StatelessWidget {
  const _DarkTextField({
    required this.controller,
    required this.hint,
    this.maxLines = 1,
    this.keyboardType,
  });
  final TextEditingController controller;
  final String hint;
  final int maxLines;
  final TextInputType? keyboardType;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      keyboardType: keyboardType,
      style: const TextStyle(color: Colors.white, fontSize: 14),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.white24, fontSize: 13),
        filled: true,
        fillColor: const Color(0xFF2A2A2A),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
    );
  }
}

/// Podgląd chipów z parsowanych ID (aktualizuje się w czasie wpisywania).
class _PreviewChips extends StatefulWidget {
  const _PreviewChips({required this.parseIds});
  final List<String> Function() parseIds;

  @override
  State<_PreviewChips> createState() => _PreviewChipsState();
}

class _PreviewChipsState extends State<_PreviewChips> {
  List<String> _ids = [];

  @override
  Widget build(BuildContext context) {
    final ids = widget.parseIds();
    if (ids.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: ids
          .map((id) => Chip(
                label: Text(id,
                    style: const TextStyle(fontSize: 11, color: Colors.white)),
                backgroundColor: const Color(0xFF2A4A2A),
                side: const BorderSide(color: Colors.greenAccent, width: 0.5),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                visualDensity: VisualDensity.compact,
              ))
          .toList(),
    );
  }
}

class _ParcelTile extends StatelessWidget {
  const _ParcelTile({required this.entry, required this.onRemove});
  final _ParcelEntry entry;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: entry.ok
              ? Colors.greenAccent.withAlpha(80)
              : Colors.red.withAlpha(80),
        ),
      ),
      child: Row(
        children: [
          Icon(
            entry.ok ? Icons.check_circle_rounded : Icons.error_rounded,
            color: entry.ok ? Colors.greenAccent : Colors.redAccent,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(entry.fullId,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w500)),
                if (entry.ok)
                  Text(
                    '${entry.geometry!.length} wierzchołków',
                    style: const TextStyle(
                        color: Colors.greenAccent, fontSize: 11),
                  )
                else
                  Text(
                    entry.error ?? 'Nieznany błąd',
                    style:
                        const TextStyle(color: Colors.redAccent, fontSize: 11),
                  ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline,
                color: Colors.white38, size: 18),
            onPressed: onRemove,
            tooltip: 'Usuń działkę',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }
}

class _MergeResultCard extends StatelessWidget {
  const _MergeResultCard({required this.result});
  final MergeFieldResult result;

  @override
  Widget build(BuildContext context) {
    final outerCount = result.rings.where((r) => r.isOuter).length;
    final holeCount = result.rings.where((r) => !r.isOuter).length;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1A2A1A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: result.isMultipart
                ? Colors.orange.withAlpha(120)
                : Colors.greenAccent.withAlpha(80)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ResultRow(
              Icons.crop_square_rounded, 'Zewnętrzne granice:', '$outerCount'),
          if (holeCount > 0)
            _ResultRow(Icons.donut_large_rounded, 'Otwory (dziury w polu):',
                '$holeCount'),
          _ResultRow(Icons.straighten_rounded, 'Wierzchołki głównej granicy:',
              '${result.primaryBoundary.length}'),
          if (result.isMultipart)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded,
                      color: Colors.orange, size: 16),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Pole wieloczęściowe: działki nie stykają się.',
                      style: TextStyle(color: Colors.orange, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow(this.icon, this.label, this.value);
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(icon, color: Colors.greenAccent, size: 15),
          const SizedBox(width: 8),
          Text(label,
              style: const TextStyle(color: Colors.white54, fontSize: 12)),
          const Spacer(),
          Text(value,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    required this.color,
  });
  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 50,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: color,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        icon: Icon(icon, size: 20),
        label: Text(label,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        onPressed: onPressed,
      ),
    );
  }
}

class _SecondaryButton extends StatelessWidget {
  const _SecondaryButton({required this.label, required this.onPressed});
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 44,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white54,
          side: const BorderSide(color: Colors.white12),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        onPressed: onPressed,
        child: Text(label),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.withAlpha(30),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.red.withAlpha(80)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Colors.redAccent, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message,
                style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
          ),
        ],
      ),
    );
  }
}
