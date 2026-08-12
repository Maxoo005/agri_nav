import 'dart:convert';
import 'dart:developer' as dev;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:uuid/uuid.dart';

import '../models/field_model.dart';
import '../services/field_service.dart';
import '../utils/geo_utils.dart';
import '../utils/geojson_parser.dart';
import '../utils/kml_parser.dart';
import '../utils/parsed_polygon.dart';
import 'map_view.dart' show kGeoportalWmsUrl;

// ─────────────────────────────────────────────────────────────────────────────
// Enum kroków importu
// ─────────────────────────────────────────────────────────────────────────────

enum _FileImportStep {
  /// Wybór pliku .kml/.geojson/.json z pamięci telefonu.
  pickFile,

  /// Trwa odczyt i parsowanie pliku.
  parsing,

  /// Plik zawierał więcej niż jeden wielokąt — checkboxy do wyboru, które
  /// zaimportować (pomijany, gdy plik ma dokładnie jeden wielokąt).
  select,

  /// Podgląd zaznaczonych granic na żywej mapie z ortofoto GUGiK, przed
  /// ostatecznym zatwierdzeniem.
  preview,

  /// Nazwa (nazwy) pola do zapisu → zapis do Hive.
  confirmNames,
}

// ─────────────────────────────────────────────────────────────────────────────
// FileImportSheet
// ─────────────────────────────────────────────────────────────────────────────

/// Import granicy pola z gotowego pliku KML/GeoJSON — alternatywa dla
/// importu katastralnego (ULDK/LPIS) dla pól, gdzie automatyczna korekta
/// katastru jest niewystarczająca. Granica jest już dokładna (narysowana
/// ręcznie przez rolnika w Google Earth Pro / QGIS na dobrej ortofotomapie),
/// więc zapisywana jest bez żadnej korekty punktami kontrolnymi
/// ([FieldCorrectionMode.none]) i oznaczana jako [FieldSource.file].
///
/// Przepływ:
///   1. pickFile: wybór pliku (file_picker).
///   2. parsing: wykrycie formatu po rozszerzeniu → [KmlParser]/[GeoJsonParser].
///   3. select: gdy plik ma >1 wielokąt — checkboxy, które zaimportować.
///   4. preview: żywa mapa (ortofoto GUGiK) z zaznaczonymi granicami.
///   5. confirmNames: nazwa(-y) pola → zapis do Hive → zwrot [FieldModel]s.
///
/// W przeciwieństwie do importu katastralnego (`LpisImportSheet`) nie ma tu
/// kroku scalania geometrii (C++ union) — każdy wielokąt z pliku staje się
/// osobnym, niezależnym polem. Ekran jest zawsze pełnoekranowy: w
/// odróżnieniu od importu ULDK, import z pliku nie jest powiązany z
/// bieżącym obszarem widocznym na mapie, więc nie ma potrzeby trybu
/// bottom-sheet wpiętego w `map_view.dart`.
class FileImportSheet extends StatefulWidget {
  const FileImportSheet({super.key});

  /// Otwiera ekran importu z pliku i zwraca listę zapisanych pól — pustą
  /// listę, jeśli użytkownik anulował na dowolnym etapie. W przeciwieństwie
  /// do `LpisImportSheet.show` (Future&lt;FieldModel?&gt;) zwraca zawsze
  /// listę, bo jeden plik może dać wiele pól naraz.
  ///
  /// Ekran jest zwykłym `StatefulWidget` tworzonym od nowa przy każdym
  /// wywołaniu — można go otwierać dowolną liczbę razy, bez żadnego stanu
  /// blokującego ponowne użycie ani limitu importów.
  static Future<List<FieldModel>> show(BuildContext context) async {
    final result = await Navigator.push<List<FieldModel>>(
      context,
      MaterialPageRoute(builder: (_) => const FileImportSheet()),
    );
    return result ?? const [];
  }

  @override
  State<FileImportSheet> createState() => _FileImportSheetState();
}

class _FileImportSheetState extends State<FileImportSheet> {
  _FileImportStep _step = _FileImportStep.pickFile;
  String? _error;
  String? _pickedFileName;

  List<ParsedPolygon> _polygons = [];
  final Set<int> _selectedIndices = {};
  List<TextEditingController> _nameCtrls = [];

  bool _saving = false;
  final _previewMapController = MapController();

  @override
  void dispose() {
    for (final c in _nameCtrls) {
      c.dispose();
    }
    _previewMapController.dispose();
    super.dispose();
  }

  // ── Krok 1: wybór i parsowanie pliku ─────────────────────────────────────────

  Future<void> _pickAndParseFile() async {
    setState(() => _error = null);

    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['kml', 'geojson', 'json'],
        withData: true,
      );
    } catch (e) {
      dev.log('Błąd otwierania selektora plików: $e',
          name: 'FileImportSheet', level: 900);
      if (!mounted) return;
      setState(() => _error = 'Nie udało się otworzyć selektora plików: $e');
      return;
    }
    if (!mounted || result == null || result.files.isEmpty) {
      return; // Użytkownik anulował — cichy powrót, to nie błąd.
    }

    final file = result.files.single;
    final bytes = file.bytes;
    if (bytes == null) {
      setState(() => _error = 'Nie udało się odczytać zawartości pliku.');
      return;
    }

    setState(() {
      _step = _FileImportStep.parsing;
      _pickedFileName = file.name;
    });

    try {
      final content = utf8.decode(bytes, allowMalformed: true);
      final polygons = _parseByFormat(file.extension, file.name, content);

      for (final c in _nameCtrls) {
        c.dispose();
      }
      _nameCtrls = [
        for (final p in polygons)
          TextEditingController(text: p.suggestedName ?? ''),
      ];

      if (!mounted) return;
      _polygons = polygons;
      _selectedIndices.clear();
      if (polygons.length == 1) {
        _selectedIndices.add(0);
        setState(() => _step = _FileImportStep.preview);
      } else {
        setState(() => _step = _FileImportStep.select);
      }
    } on FormatException catch (e) {
      dev.log('Błąd parsowania pliku importu "${file.name}": ${e.message}',
          name: 'FileImportSheet', level: 900);
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _step = _FileImportStep.pickFile;
      });
    } catch (e) {
      dev.log('Nieoczekiwany błąd importu z pliku "${file.name}": $e',
          name: 'FileImportSheet', level: 1000);
      if (!mounted) return;
      setState(() {
        _error = 'Nieoczekiwany błąd podczas wczytywania pliku: $e';
        _step = _FileImportStep.pickFile;
      });
    }
  }

  /// Wybiera parser wg rozszerzenia pliku. SAF (selektor plików Androida)
  /// nie zawsze poprawnie zwraca/respektuje rozszerzenie, więc przy braku
  /// rozpoznanego rozszerzenia dobieramy parser po zawartości pliku
  /// (KML zaczyna się od '<', GeoJSON od '{').
  List<ParsedPolygon> _parseByFormat(
      String? extension, String fileName, String content) {
    final ext = (extension ?? '').toLowerCase();
    if (ext == 'kml') return KmlParser.parse(content);
    if (ext == 'geojson' || ext == 'json') return GeoJsonParser.parse(content);

    final trimmed = content.trimLeft();
    if (trimmed.startsWith('<')) return KmlParser.parse(content);
    if (trimmed.startsWith('{')) return GeoJsonParser.parse(content);

    throw FormatException(
        'Nierozpoznany format pliku "$fileName" — obsługiwane są .kml, '
        '.geojson, .json.');
  }

  // ── Nawigacja wstecz ──────────────────────────────────────────────────────────

  bool get _canGoBack => _step != _FileImportStep.pickFile;

  void _goBack() {
    setState(() {
      switch (_step) {
        case _FileImportStep.select:
          _error = null;
          _step = _FileImportStep.pickFile;
        case _FileImportStep.preview:
          _step = _polygons.length > 1
              ? _FileImportStep.select
              : _FileImportStep.pickFile;
        case _FileImportStep.confirmNames:
          _step = _FileImportStep.preview;
        case _FileImportStep.pickFile:
        case _FileImportStep.parsing:
          break; // brak przycisku "wstecz" na tych krokach
      }
    });
  }

  // ── Krok: wybór wielokątów (gdy plik ma ich więcej niż jeden) ────────────────

  void _toggleSelectAll() {
    setState(() {
      if (_selectedIndices.length == _polygons.length) {
        _selectedIndices.clear();
      } else {
        _selectedIndices
          ..clear()
          ..addAll(List.generate(_polygons.length, (i) => i));
      }
    });
  }

  // ── Zapis pól ─────────────────────────────────────────────────────────────────

  Future<void> _saveFields() async {
    if (_selectedIndices.isEmpty) return;
    setState(() => _saving = true);

    final saved = <FieldModel>[];
    final selected = _selectedIndices.toList()..sort();
    for (final i in selected) {
      final poly = _polygons[i];
      final rawName = _nameCtrls[i].text.trim();
      final name = rawName.isEmpty ? 'Pole ${saved.length + 1}' : rawName;
      final field = FieldModel(
        id: const Uuid().v4(),
        name: name,
        boundaryLats: poly.points.map((p) => p.latitude).toList(),
        boundaryLons: poly.points.map((p) => p.longitude).toList(),
        source: FieldSource.file,
        areaHa: GeoUtils.polygonAreaHa(poly.points),
      );
      await FieldService.instance.save(field);
      saved.add(field);
    }

    dev.log('Zaimportowano ${saved.length} pól z pliku "$_pickedFileName"',
        name: 'FileImportSheet');
    if (!mounted) return;
    Navigator.pop(context, saved);
  }

  // ── Budowanie UI ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1E1E),
        foregroundColor: Colors.white,
        title: Text(_titleFor(_step)),
        leading: _canGoBack
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: _goBack,
              )
            : null,
      ),
      body: SafeArea(child: _buildBody()),
    );
  }

  String _titleFor(_FileImportStep step) => switch (step) {
        _FileImportStep.pickFile => 'Importuj z pliku (KML/GeoJSON)',
        _FileImportStep.parsing => 'Wczytywanie pliku…',
        _FileImportStep.select => 'Wybierz pola (${_polygons.length})',
        _FileImportStep.preview => 'Podgląd granicy na mapie',
        _FileImportStep.confirmNames =>
          _selectedIndices.length > 1 ? 'Nazwy pól' : 'Nazwa pola',
      };

  Widget _buildBody() {
    switch (_step) {
      case _FileImportStep.pickFile:
        return _buildPickFile();
      case _FileImportStep.parsing:
        return _buildLoading();
      case _FileImportStep.select:
        return _buildSelect();
      case _FileImportStep.preview:
        return _buildPreview();
      case _FileImportStep.confirmNames:
        return _buildConfirmNames();
    }
  }

  // ── Krok 1: wybór pliku ──────────────────────────────────────────────────────

  Widget _buildPickFile() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.upload_file, size: 64, color: Colors.white38),
            const SizedBox(height: 16),
            const Text(
              'Wczytaj gotową granicę pola z pliku .kml lub .geojson\n'
              '(np. narysowaną w Google Earth Pro albo QGIS).\n'
              'Granica zostanie zapisana bez dodatkowej korekty.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54, fontSize: 13),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
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
            const SizedBox(height: 24),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.green[700],
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              ),
              icon: const Icon(Icons.folder_open),
              label: const Text('Wybierz plik'),
              onPressed: _pickAndParseFile,
            ),
          ],
        ),
      ),
    );
  }

  // ── Krok: ładowanie ──────────────────────────────────────────────────────────

  Widget _buildLoading() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: Colors.greenAccent),
          SizedBox(height: 16),
          Text('Wczytywanie i parsowanie pliku…',
              style: TextStyle(color: Colors.white60, fontSize: 14)),
        ],
      ),
    );
  }

  // ── Krok: wybór wielokątów ───────────────────────────────────────────────────

  Widget _buildSelect() {
    return Column(
      children: [
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            itemCount: _polygons.length,
            separatorBuilder: (_, __) =>
                const Divider(height: 1, color: Colors.white10),
            itemBuilder: (_, i) => _buildSelectTile(i),
          ),
        ),
        _buildSelectActions(),
      ],
    );
  }

  Widget _buildSelectTile(int i) {
    final poly = _polygons[i];
    final isSelected = _selectedIndices.contains(i);
    return CheckboxListTile(
      value: isSelected,
      onChanged: (v) => setState(() {
        if (v == true) {
          _selectedIndices.add(i);
        } else {
          _selectedIndices.remove(i);
        }
      }),
      activeColor: Colors.greenAccent,
      checkColor: Colors.black,
      title: Text(
        poly.suggestedName ?? 'Wielokąt ${i + 1}',
        style: const TextStyle(color: Colors.white, fontSize: 14),
      ),
      subtitle: Text(
        '${poly.points.length} wierzchołków  •  '
        '${GeoUtils.polygonAreaHa(poly.points).toStringAsFixed(2)} ha',
        style: const TextStyle(color: Colors.white54, fontSize: 12),
      ),
    );
  }

  Widget _buildSelectActions() {
    final selCount = _selectedIndices.length;
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
              selCount == _polygons.length ? Icons.deselect : Icons.select_all,
              size: 18,
            ),
            label: Text(selCount == _polygons.length
                ? 'Odznacz wszystkie'
                : 'Zaznacz wszystkie'),
            style: TextButton.styleFrom(foregroundColor: Colors.white60),
            onPressed: _toggleSelectAll,
          ),
          const Spacer(),
          FilledButton.icon(
            style: FilledButton.styleFrom(
                backgroundColor:
                    selCount > 0 ? Colors.green[700] : Colors.grey[700]),
            icon: const Icon(Icons.map_outlined, size: 18),
            label: Text('Podgląd ($selCount)'),
            onPressed: selCount > 0
                ? () => setState(() => _step = _FileImportStep.preview)
                : null,
          ),
        ],
      ),
    );
  }

  // ── Krok: podgląd na mapie ───────────────────────────────────────────────────

  Widget _buildPreview() {
    final selected = _selectedIndices.toList()..sort();
    final allPoints = [
      for (final i in selected) ..._polygons[i].points,
    ];

    return Column(
      children: [
        Expanded(
          child: FlutterMap(
            mapController: _previewMapController,
            options: MapOptions(
              initialCameraFit: CameraFit.bounds(
                bounds: LatLngBounds.fromPoints(allPoints),
                padding: const EdgeInsets.all(40),
              ),
            ),
            children: [
              // Ortofoto GUGiK — ta sama warstwa WMS co w MapView, żeby
              // podgląd realnie pokazywał to samo zdjęcie lotnicze, na
              // którym granica została narysowana w Google Earth/QGIS.
              TileLayer(
                wmsOptions: WMSTileLayerOptions(
                  baseUrl: kGeoportalWmsUrl,
                  layers: const ['Raster'],
                  format: 'image/jpeg',
                  transparent: false,
                  version: '1.1.1',
                  crs: const Epsg3857(),
                ),
                userAgentPackageName: 'com.example.agri_nav',
                keepBuffer: 4,
                maxNativeZoom: 18,
                evictErrorTileStrategy:
                    EvictErrorTileStrategy.notVisibleRespectMargin,
              ),
              PolygonLayer(
                polygons: [
                  for (final i in selected)
                    Polygon(
                      points: _polygons[i].points,
                      color: Colors.yellow.withValues(alpha: 0.22),
                      borderColor: Colors.yellow,
                      borderStrokeWidth: 3.0,
                    ),
                ],
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: const BoxDecoration(
            color: Color(0xFF2A2A2A),
            border: Border(top: BorderSide(color: Colors.white12)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  selected.length > 1
                      ? '${selected.length} granic do zapisania'
                      : '1 granica do zapisania',
                  style: const TextStyle(color: Colors.white60, fontSize: 13),
                ),
              ),
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: Colors.green[700]),
                icon: const Icon(Icons.arrow_forward, size: 18),
                label: const Text('Dalej'),
                onPressed: () =>
                    setState(() => _step = _FileImportStep.confirmNames),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Krok: nazwy pól + zapis ──────────────────────────────────────────────────

  Widget _buildConfirmNames() {
    final selected = _selectedIndices.toList()..sort();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (var n = 0; n < selected.length; n++) ...[
          _buildNameField(selected[n], n + 1),
          const SizedBox(height: 12),
        ],
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.green[700],
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            icon: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.save),
            label: Text(_saving
                ? 'Zapisywanie…'
                : (selected.length > 1
                    ? 'Zapisz ${selected.length} pól'
                    : 'Zapisz pole')),
            onPressed: _saving ? null : _saveFields,
          ),
        ),
      ],
    );
  }

  Widget _buildNameField(int i, int displayIndex) {
    final poly = _polygons[i];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _nameCtrls[i],
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            labelText: 'Nazwa pola $displayIndex',
            labelStyle: const TextStyle(color: Colors.white54),
            enabledBorder: const OutlineInputBorder(
                borderSide: BorderSide(color: Colors.white24)),
            focusedBorder: const OutlineInputBorder(
                borderSide: BorderSide(color: Colors.greenAccent)),
            prefixIcon: const Icon(Icons.label_outline, color: Colors.white38),
          ),
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Text(
            '${poly.points.length} wierzchołków  •  '
            '${GeoUtils.polygonAreaHa(poly.points).toStringAsFixed(2)} ha',
            style: const TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ),
      ],
    );
  }
}
