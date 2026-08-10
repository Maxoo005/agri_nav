import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:uuid/uuid.dart';

import '../ffi/nav_bridge.dart';
import 'app_theme.dart';
import '../models/field_model.dart';
import '../models/history_record.dart';
import '../models/machine_model.dart';
import '../models/task_plan.dart';
import '../models/work_task.dart';
import '../services/coverage_service.dart';
import '../services/field_service.dart';
import '../services/gps_location_service.dart';
import '../services/history_database.dart';
import '../services/material_monitor_service.dart';
import '../services/work_session_service.dart';
import '../services/work_task_service.dart';
import '../models/lpis_parcel.dart';
import '../services/lpis_service.dart';
import '../services/geoportal_service.dart';
import 'lpis_import_sheet.dart';
import 'cadastral_widgets.dart';

import 'finish_work_dialog.dart';
import 'machine_selector_screen.dart';
import 'work_mode_view.dart';
import '../utils/geo_utils.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// MapView — główny ekran nawigacji rolniczej
// ═══════════════════════════════════════════════════════════════════════════════

/// URL bazowy serwisu WMS — Ortofotomapa HighResolution GUGiK (Polska).
///
/// GetCapabilities:
///   $kGeoportalWmsUrl?SERVICE=WMS&REQUEST=GetCapabilities
/// Pokrycie: obszar Polski (≈ lat 49–55, lon 14–24.5).
/// GetCapabilities deklaruje tylko EPSG:4326/EPSG:2180, ale serwer w
/// praktyce poprawnie obsługuje też EPSG:3857 (zweryfikowane realnym
/// zapytaniem GetMap — patrz historia zmian). Używamy EPSG:3857, bo to
/// natywna siatka kafelków flutter_map (MapOptions.crs domyślnie
/// Epsg3857()) — patrz przestroga przy [Epsg4326] w [_WmsGeographicCrs].
///
/// WAŻNE: bazowy adres musi kończyć się '?' — WMSTileLayerOptions dokleja
/// własne parametry ('&service=WMS&request=GetMap...') bezpośrednio po nim.
const String kGeoportalWmsUrl =
    'https://mapy.geoportal.gov.pl/wss/service/PZGIK/ORTO/WMS/HighResolution?';

/// URL bazowy serwisu WMS — LPIS ARiMR (referencyjne działki rolne, GUGiK).
///
/// GetCapabilities: $kArimrLpisWmsUrl?SERVICE=WMS&REQUEST=GetCapabilities
/// Wyłącznie warstwa wizualna — WFS wyłączony, GetFeatureInfo nie zwraca
/// geometrii, więc NIE nadaje się do importu granic (tylko podgląd/nakładka).
/// Warstwy podzielone wg województwa (nazwa = kod TERYT województwa);
/// '30' = wielkopolskie (zweryfikowane przez GetCapabilities).
/// Serwer odrzuca EPSG:3857 (ServiceException code="InvalidSRS") —
/// akceptuje wyłącznie EPSG:4326/2176-2180 → patrz [_WmsGeographicCrs].
/// MaxScaleDenominator ograniczone przez serwer — warstwa renderuje się
/// (nie jest pusta) dopiero po przybliżeniu do poziomu pojedynczego pola.
const String kArimrLpisWmsUrl = 'https://mapy.geoportal.gov.pl/wss/ext/arimr_lpis?';

/// Nazwa warstwy LPIS ARiMR dla województwa wielkopolskiego.
const String kArimrLpisLayerWielkopolska = '30';

/// CRS pomocnicza dla warstw WMS wymagających SRS=EPSG:4326 (np. LPIS ARiMR),
/// gdy siatka kafelków mapy pozostaje standardową Web Mercator — czyli
/// zawsze w flutter_map, bo [MapOptions.crs] domyślnie to [Epsg3857] i
/// niczego innego flutter_map nie obsługuje dla właściwego przesuwania/
/// zoomowania mapy.
///
/// PUŁAPKA: wbudowana klasa [Epsg4326] zakłada LINIOWĄ siatkę stopni przy
/// odwracaniu współrzędnych piksela kafelka na LatLng
/// ([WMSTileLayerOptions.getUrl] wywołuje `crs.pointToLatLng` na pikselach
/// policzonych w NIELINIOWEJ przestrzeni Merkatora kamery mapy) — daje to
/// przesunięcie rzędu tysięcy km (zweryfikowane: kafelek z okolic Czermina
/// przy zoom 17 przeliczał się na bbox w okolicach Florydy, USA), a serwer
/// LPIS w odpowiedzi na bbox poza zasięgiem danych zwraca puste białe tło
/// (HTTP 200, prawidłowy PNG, brak treści).
///
/// Ta klasa poprawnie odwraca projekcję Merkatora (deleguje do [Epsg3857]
/// dla przeliczeń piksel↔LatLng — to ta sama siatka, którą realnie
/// generuje kamera mapy), ale zwraca bbox w stopniach (tożsamość lon/lat,
/// jak [Epsg4326]) — dokładnie to, czego oczekuje serwer WMS z SRS=EPSG:4326.
class _WmsGeographicCrs extends Crs {
  const _WmsGeographicCrs()
      : super(code: 'EPSG:4326', infinite: false, wrapLng: const (-180, 180));

  static const _tileGrid = Epsg3857();
  static const _degrees = Epsg4326();

  @override
  Projection get projection => _degrees.projection;

  @override
  (double, double) transform(double x, double y, double scale) =>
      _tileGrid.transform(x, y, scale);

  @override
  (double, double) untransform(double x, double y, double scale) =>
      _tileGrid.untransform(x, y, scale);

  @override
  (double, double) latLngToXY(LatLng latlng, double scale) =>
      _tileGrid.latLngToXY(latlng, scale);

  @override
  LatLng pointToLatLng(math.Point point, double zoom) =>
      _tileGrid.pointToLatLng(point, zoom);

  @override
  getProjectedBounds(double zoom) => _tileGrid.getProjectedBounds(zoom);
}

/// Tryby podkładu mapowego dostępne w MapView.
enum MapLayerMode {
  /// Tryb konfiguracji — warstwy rastrowe (ortofoto / LPIS ARiMR) włączane
  /// niezależnie przełącznikami w panelu "Warstwy mapy". Umożliwia
  /// weryfikację granic działek względem rzeczywistości.
  geoportal,

  /// Tryb pracy — brak kafelków mapowych, ciemne tło #1A1A1A + siatka pomocnicza.
  /// Oszczędza transfer danych i zasoby GPU podczas rzeczywistej pracy w polu.
  work,
}

class MapView extends StatefulWidget {
  final FieldModel? initialField;

  /// Zapisany plan zadania (z bazy SQLite) — gdy podany, pole, maszyna,
  /// parametry ścieżek i śledzenie pokrycia są konfigurowane z planu.
  final TaskPlan? initialTask;

  const MapView({super.key, this.initialField, this.initialTask});

  @override
  State<MapView> createState() => _MapViewState();
}

class _MapViewState extends State<MapView> {
  final _mapController = MapController();

  // ── Stan pozycji i nawigacji ────────────────────────────────────────────────
  LatLng _tractorPos = const LatLng(51.930428, 17.726242);
  double _tractorHeading = 0.0; // stopnie od północy (0=N, 90=E)
  double _crossTrack = 0.0; // [m] + prawo, − lewo
  bool _guidanceValid = false;

  // ── Linia AB ────────────────────────────────────────────────────────────────
  LatLng? _pointA;
  LatLng? _pointB;

  // ── Granice pola (PolygonLayer — gotowe do podpięcia) ───────────────────────
  final List<LatLng> _fieldBoundary = [];

  // ── Wygenerowane ścieżki uprawowe ────────────────────────────────────
  List<Swath> _swaths = [];
  List<List<LatLng>> _headlandRings = [];

  // ── Snapowanie do ścieżki ────────────────────────────────────────────────────
  SnapInfo _snapInfo = SnapInfo.none;

  // ── Nagrywanie pokrycia ──────────────────────────────────────────────────────
  bool _trackingCoverage = false;
  double _coveredHa = 0.0;
  List<LatLng> _savedTrack = [];

  // ── Parametry generowania ścieżek ───────────────────────────────────────────
  double _overlapM = 0.0; // zakładka [m]
  int _headlandLaps = 0; // liczba objazdów uwrociowych
  double _swathAngleDeg = 0.0; // kierunek ścieżek [°], auto z granicy

  // ── Tryb śledzenia ciągnika ─────────────────────────────────────────────────
  bool _followTractor = true;
  // ── Rysowanie granicy (DrawingMode) ───────────────────────────────
  /// Czy użytkownik aktywnie rysuje granicę palcem.
  bool _drawingMode = false;

  // ── Warstwa LPIS (dane z ULDK GUGiK, wektor — do importu granic) ─────────────
  bool _lpisLayerVisible = false;
  List<LpisParcel> _lpisParcels = [];

  // ── Warstwy rastrowe WMS (niezależnie przełączalne, patrz "Warstwy mapy") ───
  /// Ortofotomapa GUGiK jako tło.
  bool _orthophotoVisible = true;

  /// LPIS ARiMR (referencyjny obrys działek rolnych) jako nakładka.
  /// Wyłącznie wizualna — serwer nie eksportuje wektora (WFS wyłączony).
  bool _arimrLpisVisible = false;

  // ── Korekta przesunięcia (Nudge) ─────────────────────────────────────────────
  bool _nudgePanelVisible = false;

  // ── Korekta punktami kontrolnymi (obrót + skala + przesunięcie) ─────────────
  bool _controlPointsMode = false;
  LatLng? _cpPendingSource;
  final List<({LatLng source, LatLng target})> _cpPairs = [];
  List<LatLng> _cpPreviewBoundary = [];

  // ── Manual Offset — kalibracja warstwy LPIS względem satelity (stopnie) ─────
  double _parcelLatOffset = 0;
  double _parcelLonOffset = 0;
  bool _offsetPanelVisible = false;

  // ── Tryb podkładu mapowego ────────────────────────────────────────────────────
  MapLayerMode _mapMode = MapLayerMode.geoportal;

  // ── Odporność warstwy WMS na zimny start aplikacji ──────────────────────────
  /// Zwiększany, by wymusić przebudowę [TileLayer] (nowy klucz → nowy cache
  /// kafelków). flutter_map domyślnie NIE ponawia kafelków, które zawiodły
  /// (evictErrorTileStrategy.none) — jeśli sieć/DNS jeszcze się "rozgrzewa"
  /// tuż po starcie programu, ortofotomapa zostaje pusta na stałe aż do
  /// ręcznej interakcji. Jedno opóźnione odświeżenie naprawia ten przypadek.
  int _tileReloadKey = 0;

  // ── Zapisane pola (Hive) ────────────────────────────────────────────
  List<FieldModel> _savedFields = [];

  /// Aktywnie załadowane pole (granica + linia AB z pamięci).
  FieldModel? _activeField;

  /// Aktywnie wybrana maszyna (null = brak).
  MachineModel? _activeMachine;

  /// Aktywne zadanie robocze (null = brak / tryb legacy).
  WorkTask? _activeTask;

  /// Efektywna szerokość robocza: maszyna → pole → domyślna 3 m.
  double get _activeWorkingWidth =>
      _activeMachine?.workingWidthM ?? _activeField?.workingWidthM ?? 3.0;

  LatLng? _prevPos;
  DateTime? _prevTime;

  /// Ostatnia obliczona prędkość [km/h] — używana w podsumowaniu
  /// "Zakończ pracę" z bannera (wydajność ha/h).
  double _speedKmh = 0.0;

  /// GPS stream subscription — drives position updates from real or simulated GPS.
  StreamSubscription<SimPosition>? _gpsSub;

  // ── Cykl życia ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();

    // Poproś o uprawnienia i uruchom GPS po załadowaniu drzewa widgetów
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await GpsLocationService.instance.start(context);
    });

    _gpsSub = GpsLocationService.instance.positionStream.listen(_onGpsPosition);

    // Ponów kafelki WMS raz, gdy sieć zdąży się "rozgrzać" po zimnym starcie
    // — bez tego kafelki, które zawiodły w pierwszej chwili po uruchomieniu
    // programu, zostają puste do końca życia tego ekranu (patrz _tileReloadKey).
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) setState(() => _tileReloadKey++);
    });

    // Załaduj zapisane pola z Hive
    _savedFields = FieldService.instance.getAll();

    if (widget.initialField != null) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _loadField(widget.initialField!));
    } else if (widget.initialTask != null) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _loadTaskPlan(widget.initialTask!));
    }
  }

  @override
  void dispose() {
    _gpsSub?.cancel();
    GpsLocationService.instance.stop();
    super.dispose();
  }

  // ── Callback GPS (realny lub symulator, Dart main thread) ───────────────────

  void _onGpsPosition(SimPosition pos) {
    if (!mounted) return;

    final newPos = LatLng(pos.latitude, pos.longitude);

    // ── Accuracy gate ─────────────────────────────────────────────────────────
    // When GPS fix is poor (accuracy > kMaxAccuracyM), move the visual marker
    // to the raw position so the user sees they are moving, but skip all
    // navigation computation (NavBridge, coverage, swath snap).
    // GpsLocationService.fixStatus is already set to GpsFixStatus.searching
    // and the GPS FAB turns orange — no extra UI action needed here.
    if (!pos.isAccurate) {
      setState(() => _tractorPos = newPos);
      return;
    }

    // Kurs: używaj heading z GPS jeśli dostępny (speed-gated by service),
    // inaczej oblicz z kolejnych pozycji
    double heading = _tractorHeading;
    if (pos.heading >= 0) {
      heading = pos.heading;
    } else if (_prevPos != null) {
      final dlat = (newPos.latitude - _prevPos!.latitude).abs();
      final dlon = (newPos.longitude - _prevPos!.longitude).abs();
      if (dlat + dlon > 1e-7) {
        heading = _bearing(_prevPos!, newPos);
      }
    }

    // Prędkość: preferuj sprzętowy odczyt (m/s → km/h), inaczej licz z
    // przyrostu pozycji z wygładzaniem EMA i martwą strefą na szum.
    final now = DateTime.now();
    double speedKmh = _speedKmh;
    if (pos.speed > 0) {
      speedKmh = pos.speed * 3.6;
    } else if (_prevPos != null && _prevTime != null) {
      final dt = now.difference(_prevTime!).inMilliseconds / 1000.0;
      if (dt > 0.01) {
        final cosLat = math.cos(newPos.latitude * math.pi / 180.0);
        final de =
            (newPos.longitude - _prevPos!.longitude) * 111320.0 * cosLat;
        final dn = (newPos.latitude - _prevPos!.latitude) * 111320.0;
        final raw = math.sqrt(de * de + dn * dn) / dt * 3.6;
        speedKmh = _speedKmh + (raw - _speedKmh) * 0.45;
        if (speedKmh < 0.8) speedKmh = 0.0;
      }
    }

    // Wyślij do silnika C++ i odbierz wynik prowadzenia
    final result = NavBridge.instance.update(
      lat: pos.latitude,
      lon: pos.longitude,
      alt: pos.altitude,
      accuracy: pos.accuracy,
    );

    // Snap-to-swath guidance
    SnapInfo snapInfo = _snapInfo;
    if (_swaths.isNotEmpty) {
      snapInfo = SwathGuidanceBridge.instance
          .query(pos.latitude, pos.longitude, heading);
    }

    // Coverage tracking + section control
    double coveredHa = _coveredHa;
    if (_trackingCoverage) {
      // Praca aktywna ale WSTRZYMANA (np. uzupełnianie zbiornika) → pokrycie
      // i zużycie materiału stoją, dopóki operator nie wznowi.
      final session = WorkSessionService.instance;
      final sessionPaused = session.isActive && session.paused;
      if (!sessionPaused) {
        CoverageService.instance.addPoint(newPos);
        if (_activeField != null) {
          SectionControlBridge.instance.addStrip(
            pos.latitude,
            pos.longitude,
            heading,
            _activeWorkingWidth,
          );
          coveredHa = SectionControlBridge.instance.coveredAreaHa();
          // Praca w tle: zużycie materiału naliczane także po wyjściu z
          // Trybu Pracy, dopóki sesja nie jest zakończona.
          if (session.isActive) {
            MaterialMonitorService.instance.updateArea(coveredHa);
          }
        }
      }
    }

    setState(() {
      _tractorPos = newPos;
      _tractorHeading = heading;
      _crossTrack = result.crossTrack;
      _guidanceValid = result.valid;
      _snapInfo = snapInfo;
      _coveredHa = coveredHa;
      _speedKmh = speedKmh;
    });

    _prevPos = newPos;
    _prevTime = now;

    // Przesuń mapę za ciągnikiem (jeśli tryb follow aktywny)
    if (_followTractor) {
      try {
        _mapController.move(newPos, _mapController.camera.zoom);
      } catch (_) {
        // MapController może nie być jeszcze gotowy
      }
    }
  }

  // ── Granica pola (DrawingMode) ────────────────────────────────────────────

  void _toggleDrawingMode() {
    setState(() {
      _drawingMode = !_drawingMode;
      if (_drawingMode) {
        _clearControlPointsState();
        _fieldBoundary.clear();
        _swaths = [];
        _headlandRings = [];
        _snapInfo = SnapInfo.none;
        _activeField = null;
      } else {
        if (_fieldBoundary.length >= 3) {
          _swathAngleDeg = GeoUtils.minPassesBearing(_fieldBoundary);
          WidgetsBinding.instance
              .addPostFrameCallback((_) => _showSaveFieldDialog());
        }
      }
    });
  }

  LatLng _screenToLatLng(Offset offset) => _mapController.camera.pointToLatLng(
        math.Point(offset.dx, offset.dy),
      );

  bool _shouldAddPoint(LatLng candidate) {
    if (_fieldBoundary.isEmpty) return true;
    final last = _fieldBoundary.last;
    return (candidate.latitude - last.latitude).abs() +
            (candidate.longitude - last.longitude).abs() >
        0.00003;
  }

  // ── Zapis pola (dialog) ────────────────────────────────────────────────────

  Future<void> _showSaveFieldDialog() async {
    final ctrl = TextEditingController(
        text: 'Pole ${FieldService.instance.getAll().length + 1}');
    double workingWidth = _activeField?.workingWidthM ?? 3.0;

    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          backgroundColor: const Color(0xFF2A2A2A),
          title:
              const Text('Zapisz pole', style: TextStyle(color: Colors.white)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: ctrl,
                style: const TextStyle(color: Colors.white),
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Nazwa pola',
                  labelStyle: TextStyle(color: Colors.white54),
                  enabledBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Colors.white38)),
                  focusedBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Colors.greenAccent)),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Szerokość robocza: ${workingWidth.toStringAsFixed(1)} m',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              Slider(
                min: 1.0,
                max: 12.0,
                divisions: 22,
                value: workingWidth,
                activeColor: Colors.greenAccent,
                onChanged: (v) => setDlg(() => workingWidth = v),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Odrzuć')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.green[700]),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Zapisz'),
            ),
          ],
        ),
      ),
    );

    if (saved != true || !mounted) return;
    final name = ctrl.text.trim().isEmpty ? 'Pole' : ctrl.text.trim();

    final field = FieldModel(
      id: const Uuid().v4(),
      name: name,
      boundaryLats: _fieldBoundary.map((e) => e.latitude).toList(),
      boundaryLons: _fieldBoundary.map((e) => e.longitude).toList(),
      workingWidthM: workingWidth,
      lineALat: _pointA?.latitude,
      lineALon: _pointA?.longitude,
      lineBLat: _pointB?.latitude,
      lineBLon: _pointB?.longitude,
      areaHa: GeoUtils.polygonAreaHa(_fieldBoundary),
    );

    await FieldService.instance.save(field);
    setState(() {
      _savedFields = FieldService.instance.getAll();
      _activeField = field;
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Zapisano: $name'),
        backgroundColor: Colors.green[700],
        duration: const Duration(seconds: 2),
      ));
    }
  }

  // ── Ładowanie pola z listy ─────────────────────────────────────────────────

  /// Ładuje pole; przy podanym [plan] (zapisany plan zadania w SQLite)
  /// dodatkowo konfiguruje aktywne zadanie/maszynę oraz parametry ścieżek
  /// zgodnie z migawką zapisaną w planie.
  Future<void> _loadField(FieldModel field, {TaskPlan? plan}) async {
    if (plan != null) {
      _activeTask = WorkTask(
        id: plan.id,
        fieldId: plan.fieldId,
        machineId: plan.machineId,
        taskType: plan.taskType,
        effectiveWidthM: plan.workingWidthM,
        targetRate: plan.targetRate,
        initialTankVolume: plan.tankVolume,
        unit: plan.unit,
        createdAt: plan.createdAt,
        name: plan.name,
      );
      _activeMachine = MachineModel(
        id: plan.machineId ?? '',
        name: plan.machineName ?? '—',
        type: MachineType.fromJson(plan.machineType),
        workingWidthM: plan.workingWidthM,
      );
    }

    final savedTrack = plan != null
        ? CoverageService.instance.loadForTask(field.id, plan.id)
        : (_activeTask != null
            ? CoverageService.instance.loadForTask(field.id, _activeTask!.id)
            : CoverageService.instance.loadForField(field.id));

    // Reset SectionControl to new field origin and replay saved track
    SectionControlBridge.instance
      ..clear()
      ..setOrigin(field.center.latitude, field.center.longitude);

    var coveredHa = 0.0;
    final replayWidth = plan?.workingWidthM ??
        _activeTask?.effectiveWidthM ??
        field.workingWidthM;
    if (savedTrack.isNotEmpty) {
      coveredHa = await SectionControlBridge.instance
          .replayTrack(savedTrack, replayWidth);
    }

    setState(() {
      _fieldBoundary
        ..clear()
        ..addAll(field.boundary);
      _activeField = field;
      _swaths = [];
      _headlandRings = [];
      _snapInfo = SnapInfo.none;
      _swathAngleDeg =
          plan?.swathAngleDeg ?? GeoUtils.minPassesBearing(field.boundary);
      _overlapM = plan?.overlapM ?? 0.0;
      _headlandLaps = plan?.headlandLaps ?? 0;
      _savedTrack = savedTrack;
      _coveredHa = coveredHa;
      if (field.lineA != null) _pointA = field.lineA;
      if (field.lineB != null) _pointB = field.lineB;
    });
    if (_pointA != null && _pointB != null) {
      NavBridge.instance.setAbLine(
        _pointA!.latitude,
        _pointA!.longitude,
        _pointB!.latitude,
        _pointB!.longitude,
      );
    }
    // Dopasuj kamerę do granic pola z marginesem 40px
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (field.boundary.length >= 2) {
        final bounds = LatLngBounds.fromPoints(field.boundary);
        _mapController.fitCamera(
          CameraFit.bounds(
            bounds: bounds,
            padding: const EdgeInsets.all(40),
          ),
        );
      }
    });
  }

  /// Ładuje pole i konfigurację z zapisanego planu zadania (SQLite),
  /// a następnie od razu uruchamia śledzenie pokrycia dla tego zadania.
  Future<void> _loadTaskPlan(TaskPlan plan) async {
    final field = FieldModel(
      id: plan.fieldId,
      name: plan.fieldName,
      boundaryLats: plan.boundaryLats,
      boundaryLons: plan.boundaryLons,
      workingWidthM: plan.workingWidthM,
      lineALat: plan.lineALat,
      lineALon: plan.lineALon,
      lineBLat: plan.lineBLat,
      lineBLon: plan.lineBLon,
    );
    await _loadField(field, plan: plan);
    if (_activeField != null) {
      CoverageService.instance.startTracking(_activeField!.id, taskId: plan.id);
      SectionControlBridge.instance
        ..setOrigin(
            _activeField!.center.latitude, _activeField!.center.longitude)
        ..clear();
      setState(() => _trackingCoverage = true);
    }
    await _planSwaths(workingWidthM: plan.workingWidthM);
  }

  // ── Generowanie ścieżek ───────────────────────────────────────────────────

  /// Otwiera dialog parametrów, a następnie generuje ścieżki i uwrocia.
  Future<void> _showSwathParamsDialog() async {
    if (_fieldBoundary.length < 3) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Najpierw wyznacz granicę pola (≥ 3 pkt)'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    double width = _activeWorkingWidth;
    double overlap = _overlapM;
    int laps = _headlandLaps;
    double angle = _swathAngleDeg;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          backgroundColor: const Color(0xFF2A2A2A),
          title: const Text('Parametry ścieżek',
              style: TextStyle(color: Colors.white)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Szerokość robocza: ${width.toStringAsFixed(1)} m',
                  style: const TextStyle(color: Colors.white70, fontSize: 13)),
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline,
                        color: Colors.white70),
                    onPressed: () => setDlg(() {
                      width = double.parse(
                          ((width - 0.1).clamp(1.0, 36.0)).toStringAsFixed(1));
                    }),
                  ),
                  Expanded(
                    child: Slider(
                      min: 1.0,
                      max: 36.0,
                      divisions: 350,
                      value: width,
                      activeColor: Colors.greenAccent,
                      onChanged: (v) => setDlg(() {
                        width = double.parse(v.toStringAsFixed(1));
                      }),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline,
                        color: Colors.white70),
                    onPressed: () => setDlg(() {
                      width = double.parse(
                          ((width + 0.1).clamp(1.0, 36.0)).toStringAsFixed(1));
                    }),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text('Zakładka (overlap): ${overlap.toStringAsFixed(2)} m',
                  style: const TextStyle(color: Colors.white70, fontSize: 13)),
              Slider(
                min: 0.0,
                max: 1.0,
                divisions: 20,
                value: overlap,
                activeColor: Colors.orangeAccent,
                onChanged: (v) => setDlg(() => overlap = v),
              ),
              const SizedBox(height: 4),
              Text('Uwrocie (objazdy): $laps',
                  style: const TextStyle(color: Colors.white70, fontSize: 13)),
              Slider(
                min: 0,
                max: 5,
                divisions: 5,
                value: laps.toDouble(),
                activeColor: Colors.blueAccent,
                onChanged: (v) => setDlg(() => laps = v.round()),
              ),
              const SizedBox(height: 4),
              Text(
                'Kierunek ścieżek: ${angle.toStringAsFixed(0)}°',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              Slider(
                min: 0,
                max: 179,
                divisions: 179,
                value: angle,
                activeColor: Colors.tealAccent,
                onChanged: (v) => setDlg(() => angle = v),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Anuluj')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.green[700]),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Generuj'),
            ),
          ],
        ),
      ),
    );

    if (ok != true || !mounted) return;

    setState(() {
      _overlapM = overlap;
      _headlandLaps = laps;
      _swathAngleDeg = angle;
    });
    await _planSwaths(workingWidthM: width);
  }

  /// Generates swaths via SwathPlannerFullBridge.planFull().
  ///
  /// Runs synchronously on the main thread — the native C++ plan_full()
  /// typically completes in 20–200 ms which is acceptable for a button press.
  /// Previous [Isolate.run] approach was removed because FFI singletons
  /// (DynamicLibrary / calloc) are not reliably transferable across Dart
  /// isolates on Android, causing silent failures.
  Future<void> _planSwaths({double workingWidthM = 3.0}) async {
    if (_fieldBoundary.length < 3) return;

    final polygon =
        _fieldBoundary.map((ll) => (ll.latitude, ll.longitude)).toList();

    final (a, b) = _abFromAngle(_swathAngleDeg);
    final ax = a.latitude, ay = a.longitude;
    final bx = b.latitude, by = b.longitude;
    final overlapM = _overlapM;
    final headlandLaps = _headlandLaps;

    PlanResult result;
    try {
      result = SwathPlannerFullBridge.instance.planFull(
        polygon: polygon,
        ax: ax,
        ay: ay,
        bx: bx,
        by: by,
        workingWidthM: workingWidthM,
        overlapM: overlapM,
        headlandLaps: headlandLaps,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Błąd generowania ścieżek: $e'),
        backgroundColor: Colors.red[800],
        duration: const Duration(seconds: 4),
      ));
      return;
    }

    if (!mounted) return;

    setState(() {
      _swaths = result.swaths;
      _headlandRings = result.headlandRings
          .map((ring) => ring.map((p) => LatLng(p.$1, p.$2)).toList())
          .toList();
      _snapInfo = SnapInfo.none;
    });

    // Feed new swaths into the guidance engine
    if (result.swaths.isNotEmpty) {
      SwathGuidanceBridge.instance.setSwaths(result.swaths, ax, ay);
    }

    // Feed headland rings into the headland guidance engine
    if (_headlandRings.isNotEmpty) {
      HeadlandGuidanceBridge.instance.setRings(_headlandRings, ax, ay);
    }
  }

  // ── Helpers: kierunek ścieżek ─────────────────────────────────────────────

  /// Synthetic AB pair from boundary centroid + azimuth [deg].
  /// Returns (A, B) 2 km apart — well outside any realistic field.
  (LatLng, LatLng) _abFromAngle(double angleDeg) {
    final lat = _fieldBoundary.map((p) => p.latitude).reduce((a, b) => a + b) /
        _fieldBoundary.length;
    final lon = _fieldBoundary.map((p) => p.longitude).reduce((a, b) => a + b) /
        _fieldBoundary.length;
    const arm = 2000.0; // metres
    final rad = angleDeg * math.pi / 180.0;
    final dN = math.cos(rad) * arm;
    final dE = math.sin(rad) * arm;
    final dLat = dN / 111320.0;
    final dLon = dE / (111320.0 * math.cos(lat * math.pi / 180.0));
    return (
      LatLng(lat - dLat, lon - dLon), // A
      LatLng(lat + dLat, lon + dLon), // B
    );
  }

  // ── Coverage tracking ────────────────────────────────────────────────────────

  // ── Widok Pracy (WorkMode) ──────────────────────────────────────────────────

  Future<void> _launchWorkMode() async {
    // Upewnij się, że coverage jest aktywne przed wejściem w tryb pracy
    if (!_trackingCoverage && _activeField != null) {
      CoverageService.instance
          .startTracking(_activeField!.id, taskId: _activeTask?.id);
      SectionControlBridge.instance
        ..setOrigin(
            _activeField!.center.latitude, _activeField!.center.longitude)
        ..clear();
      setState(() => _trackingCoverage = true);
    }

    // ── BUG FIX: pause MapView GPS subscription during WorkModeView ────────────
    // Without this pause, both MapView._onGpsPosition AND
    // WorkModeView._onGpsPosition receive every GPS event simultaneously,
    // causing SectionControlBridge.addStrip() to be called twice per tick →
    // hectare counts double. The broadcast stream still flows to WorkModeView;
    // MapView's callback simply does not fire while paused.
    _gpsSub?.pause();
    try {
      await Navigator.push<void>(
        context,
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => WorkModeView(
            swaths: _swaths,
            headlandRings: _headlandRings,
            fieldBoundary: _fieldBoundary,
            initialSnapInfo: _snapInfo,
            initialCoveredHa: _coveredHa,
            initialPos: _tractorPos,
            initialHeading: _tractorHeading,
            workingWidthM: _activeWorkingWidth,
            fieldId: _activeField?.id,
            fieldName: _activeField?.name,
            activeTask: _activeTask,
            machineName: _activeMachine?.name,
            overlapM: _overlapM,
            swathAngleDeg: _swathAngleDeg,
          ),
          transitionsBuilder: (_, anim, __, child) => SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 1),
              end: Offset.zero,
            ).animate(CurvedAnimation(parent: anim, curve: Curves.easeInOut)),
            child: FadeTransition(opacity: anim, child: child),
          ),
          transitionDuration: const Duration(milliseconds: 380),
        ),
      );
    } finally {
      // Always resume — even if WorkModeView throws or is popped via OS back
      _gpsSub?.resume();
    }

    if (!mounted) return;

    // Odśwież statystyki pokrycia po powrocie z trybu pracy.
    final saved = _activeTask != null
        ? CoverageService.instance
            .loadForTask(_activeField?.id ?? '', _activeTask!.id)
        : CoverageService.instance.loadForField(_activeField?.id ?? '');
    // Praca działa W TLE: dopóki sesja nie została zakończona, pokrycie
    // rejestruje się dalej na mapie (użytkownik może wrócić do Trybu Pracy).
    final sessionActive = WorkSessionService.instance.isActive;
    setState(() {
      _savedTrack = saved;
      _coveredHa = SectionControlBridge.instance.coveredAreaHa();
      _trackingCoverage = sessionActive;
    });
  }

  /// Zakończenie aktywnej sesji z bannera "Praca w toku" (mapa).
  /// Tak samo jak "Zakończ pracę" w Trybie Pracy — zapisuje zadanie w
  /// historii (z notatką), zamraża czas i kończy rejestrację pokrycia.
  Future<void> _finishActiveSession() async {
    final session = WorkSessionService.instance;
    final info = FinishWorkInfo(
      fieldName: _activeField?.name ?? '',
      machineName: _activeMachine?.name ?? '',
      taskTypeLabel: _activeTask?.taskType.label ?? 'Inne',
      workingWidthM: _activeWorkingWidth,
      overlapM: _overlapM,
      swathAngleDeg: _swathAngleDeg,
      workDuration: session.elapsed,
      coveredHa: SectionControlBridge.instance.coveredAreaHa(),
      speedKmh: _speedKmh,
    );
    final note = await showFinishWorkDialog(context, info);
    if (note == null || !mounted) return;

    try {
      await HistoryDatabase.instance.save(HistoryRecord(
        id: const Uuid().v4(),
        fieldId: _activeField?.id ?? '',
        fieldName: _activeField?.name ?? '',
        machineName: _activeMachine?.name,
        taskType: _activeTask?.taskType ?? TaskType.other,
        workingWidthM: _activeWorkingWidth,
        overlapM: _overlapM,
        swathAngleDeg: _swathAngleDeg,
        workDuration: session.elapsed,
        coveredHa: SectionControlBridge.instance.coveredAreaHa(),
        note: note,
        completedAt: DateTime.now(),
      ));
    } catch (e) {
      debugPrint('HistoryDatabase save error: $e');
    }

    session.finish();
    MaterialMonitorService.instance.stop();
    CoverageService.instance.stopTracking();
    setState(() => _trackingCoverage = false);
  }

  // ── Nudge — korekta przesunięcia granicy ───────────────────────────────────────────

  Future<void> _nudgeActive(double dx, double dy) async {
    if (_activeField == null) return;
    final updated = await GeoportalService.instance
        .nudgeField(_activeField!, dxM: dx, dyM: dy);
    setState(() {
      _activeField = updated;
      _fieldBoundary
        ..clear()
        ..addAll(updated.boundary);
    });
  }

  Future<void> _resetActiveNudge() async {
    if (_activeField == null) return;
    final updated = await GeoportalService.instance.resetNudge(_activeField!);
    setState(() {
      _activeField = updated;
      _fieldBoundary
        ..clear()
        ..addAll(updated.boundary);
    });
  }

  // ── Punkty kontrolne — korekta obrotem+skalą+przesunięciem ──────────────────

  /// Zeruje stan trybu punktów kontrolnych (bez `setState` — do złożenia
  /// z innymi blokami `setState`, np. przy wejściu w tryb rysowania).
  void _clearControlPointsState() {
    _controlPointsMode = false;
    _cpPendingSource = null;
    _cpPairs.clear();
    _cpPreviewBoundary.clear();
  }

  void _toggleControlPointsMode() {
    setState(() {
      final turningOn = !_controlPointsMode;
      _clearControlPointsState();
      if (turningOn) {
        _controlPointsMode = true;
        _drawingMode = false;
        _nudgePanelVisible = false;
      }
    });
  }

  /// Najbliższy surowy wierzchołek granicy katastralnej (przed CP i offsetem)
  /// w promieniu ~40px ekranu od [tapped], albo `null` gdy brak trafienia.
  LatLng? _nearestRawVertex(LatLng tapped) {
    final field = _activeField;
    if (field == null) return null;
    const thresholdPx = 40.0;
    final tappedPt = _mapController.camera.latLngToScreenPoint(tapped);
    LatLng? best;
    var bestDist = thresholdPx;
    for (var i = 0; i < field.boundaryLats.length; i++) {
      final vertex = LatLng(field.boundaryLats[i], field.boundaryLons[i]);
      final vertexPt = _mapController.camera.latLngToScreenPoint(vertex);
      final dx = vertexPt.x - tappedPt.x;
      final dy = vertexPt.y - tappedPt.y;
      final dist = math.sqrt(dx * dx + dy * dy);
      if (dist < bestDist) {
        bestDist = dist;
        best = vertex;
      }
    }
    return best;
  }

  void _handleControlPointTap(LatLng latLng) {
    if (_activeField == null) return;
    if (_cpPendingSource == null) {
      final snapped = _nearestRawVertex(latLng);
      if (snapped == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content:
                Text('Stuknij bliżej wierzchołka granicy (czerwony punkt)'),
          ),
        );
        return;
      }
      setState(() => _cpPendingSource = snapped);
    } else {
      setState(() {
        _cpPairs.add((source: _cpPendingSource!, target: latLng));
        _cpPendingSource = null;
        _updateCpPreview();
      });
    }
  }

  /// Przelicza podgląd na żywo (niezatwierdzony fit) z aktualnych par.
  /// Wymaga wywołania wewnątrz `setState`.
  void _updateCpPreview() {
    final field = _activeField;
    if (field == null || _cpPairs.length < 2) {
      _cpPreviewBoundary = [];
      return;
    }
    final origin = field.center;
    final src = _cpPairs.map((p) => GeoUtils.toEnu(origin, p.source)).toList();
    final tgt = _cpPairs.map((p) => GeoUtils.toEnu(origin, p.target)).toList();
    final fit = GeoUtils.fitSimilarity2D(src, tgt);
    _cpPreviewBoundary = List.generate(field.boundaryLats.length, (i) {
      final raw = LatLng(field.boundaryLats[i], field.boundaryLons[i]);
      final corrected = GeoUtils.applySimilarity2D(
        origin,
        raw,
        rotationRad: fit.rotationRad,
        scale: fit.scale,
        txM: fit.txM,
        tyM: fit.tyM,
      );
      return LatLng(
        corrected.latitude + field.offsetLat,
        corrected.longitude + field.offsetLon,
      );
    });
  }

  void _undoLastCpPair() {
    setState(() {
      if (_cpPendingSource != null) {
        _cpPendingSource = null;
      } else if (_cpPairs.isNotEmpty) {
        _cpPairs.removeLast();
      }
      _updateCpPreview();
    });
  }

  void _resetCpPairs() {
    setState(() {
      _cpPendingSource = null;
      _cpPairs.clear();
      _cpPreviewBoundary = [];
    });
  }

  void _cancelControlPoints() {
    setState(_clearControlPointsState);
  }

  Future<void> _confirmControlPoints() async {
    if (_activeField == null) return;
    if (_cpPairs.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Potrzeba co najmniej 2 par punktów (masz: ${_cpPairs.length})',
          ),
        ),
      );
      return;
    }
    final updated = await GeoportalService.instance
        .applyControlPoints(_activeField!, _cpPairs);
    setState(() {
      _activeField = updated;
      _fieldBoundary
        ..clear()
        ..addAll(updated.boundary);
      _clearControlPointsState();
    });
  }

  Future<void> _resetControlPoints() async {
    if (_activeField == null) return;
    final updated =
        await GeoportalService.instance.resetControlPoints(_activeField!);
    setState(() {
      _activeField = updated;
      _fieldBoundary
        ..clear()
        ..addAll(updated.boundary);
    });
  }

  void _toggleCoverage() {
    if (_trackingCoverage) {
      CoverageService.instance.stopTracking();
      final saved = _activeTask != null
          ? CoverageService.instance
              .loadForTask(_activeField?.id ?? '', _activeTask!.id)
          : CoverageService.instance.loadForField(_activeField?.id ?? '');
      setState(() {
        _trackingCoverage = false;
        _savedTrack = saved;
      });
    } else {
      if (_activeField != null) {
        CoverageService.instance
            .startTracking(_activeField!.id, taskId: _activeTask?.id);
        SectionControlBridge.instance.setOrigin(
          _activeField!.center.latitude,
          _activeField!.center.longitude,
        );
      }
      setState(() => _trackingCoverage = true);
    }
  }

  Future<void> _clearTrackWithConfirm() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title:
            const Text('Wyczyść ślad', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Usunąć nagrany ślad dla tego pola? Operacja jest nieodwracalna.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Anuluj'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red[700]),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Wyczyść'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    if (_activeTask != null) {
      await CoverageService.instance
          .clearForTask(_activeField?.id ?? '', _activeTask!.id);
    } else {
      await CoverageService.instance.clearForField(_activeField?.id ?? '');
    }
    SectionControlBridge.instance.clear();
    setState(() {
      _savedTrack = [];
      _coveredHa = 0.0;
    });
  }

  // ── Akcje panelu ──────────────────────────────────────────────────────────

  void _toggleLpisLayer() {
    final show = !_lpisLayerVisible;
    if (show && _lpisParcels.isEmpty) {
      final cached = LpisService.instance.getCachedParcels();
      if (cached.isNotEmpty) {
        setState(() {
          _lpisParcels = cached;
          _lpisLayerVisible = true;
        });
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Brak danych LPIS — użyj przycisku importu działek ▼'),
          backgroundColor: Colors.orange,
          duration: Duration(seconds: 3),
        ),
      );
      return;
    }
    setState(() => _lpisLayerVisible = show);
  }

  Future<void> _importLpis() async {
    final bounds = _mapController.camera.visibleBounds;
    final field = await LpisImportSheet.show(
      context,
      mapBounds: bounds,
    );
    if (field != null && mounted) {
      _loadField(field);
      setState(() {
        _savedFields = FieldService.instance.getAll();
        _lpisParcels = LpisService.instance.getCachedParcels();
        _lpisLayerVisible = true;
      });
    }
  }

  void _showActionsPanel() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.50,
        minChildSize: 0.30,
        maxChildSize: 0.75,
        expand: false,
        builder: (_, controller) => _buildPanelContent(controller),
      ),
    );
  }

  Widget _buildPanelContent(ScrollController controller) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1E1E1E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Center(
            child: Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: AppColors.textFaint,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),

          _buildSectionHeader('WARSTWY MAPY'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8, runSpacing: 8,
            children: [
              _ActionTile(
                icon: Icons.satellite_alt,
                label: 'Ortofotomapa',
                tooltip: 'Pokaż/ukryj zdjęcie lotnicze GUGiK (tło)',
                isActive: _orthophotoVisible,
                onPressed: () => setState(
                    () => _orthophotoVisible = !_orthophotoVisible),
              ),
              _ActionTile(
                icon: Icons.layers,
                label: 'LPIS ARiMR',
                tooltip:
                    'Pokaż/ukryj referencyjny obrys działek ARiMR (nakładka, tylko podgląd)',
                isActive: _arimrLpisVisible,
                onPressed: () => setState(
                    () => _arimrLpisVisible = !_arimrLpisVisible),
              ),
              _ActionTile(
                icon: Icons.grass,
                label: 'Działki LPIS',
                tooltip: 'Pokaż/ukryj działki LPIS (dane z ULDK GUGiK)',
                isActive: _lpisLayerVisible,
                onPressed: _toggleLpisLayer,
              ),
              if (_lpisLayerVisible)
                _ActionTile(
                  icon: Icons.tune,
                  label: 'Manual Offset',
                  tooltip: 'Kalibracja warstwy LPIS względem satelity',
                  isActive: _offsetPanelVisible,
                  onPressed: () => setState(
                      () => _offsetPanelVisible = !_offsetPanelVisible),
                ),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(color: AppColors.textFaint),
          const SizedBox(height: 8),

          _buildSectionHeader('POLE'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8, runSpacing: 8,
            children: [
              if (_activeField != null)
                _ActionTile(
                  icon: Icons.open_with_rounded,
                  label: 'Korekta',
                  tooltip: 'Koryguj położenie granicy',
                  isActive: _nudgePanelVisible,
                  onPressed: () => setState(
                      () => _nudgePanelVisible = !_nudgePanelVisible),
                ),
              if (_activeField != null)
                _ActionTile(
                  icon: Icons.control_camera_rounded,
                  label: 'Punkty kontrolne',
                  tooltip:
                      'Dopasuj granicę do ortofotomapy punktami kontrolnymi',
                  isActive: _controlPointsMode,
                  onPressed: _toggleControlPointsMode,
                ),
              if (_activeField != null &&
                  (_activeField!.cpRotationRad != 0.0 ||
                      _activeField!.cpScale != 1.0 ||
                      _activeField!.cpTxM != 0.0 ||
                      _activeField!.cpTyM != 0.0))
                _ActionTile(
                  icon: Icons.restart_alt,
                  label: 'Resetuj CP',
                  tooltip: 'Wyzeruj korektę punktami kontrolnymi',
                  onPressed: _resetControlPoints,
                ),
              _ActionTile(
                icon: _drawingMode ? Icons.cancel_outlined : Icons.edit,
                label: _drawingMode ? 'Anuluj' : 'Rysuj',
                tooltip: _drawingMode
                    ? 'Anuluj rysowanie'
                    : 'Rysuj granicę pola',
                isActive: _drawingMode,
                onPressed: _toggleDrawingMode,
              ),
              _ActionTile(
                icon: _swaths.isNotEmpty || _headlandRings.isNotEmpty
                    ? Icons.grid_on
                    : Icons.grid_off,
                label: 'Ścieżki',
                tooltip: _swaths.isNotEmpty || _headlandRings.isNotEmpty
                    ? 'Parametry ścieżek (aktywne)'
                    : 'Generuj ścieżki',
                isActive: _swaths.isNotEmpty || _headlandRings.isNotEmpty,
                onPressed: _showSwathParamsDialog,
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(color: AppColors.textFaint),
          const SizedBox(height: 8),

          _buildSectionHeader('POKRYCIE'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8, runSpacing: 8,
            children: [
              _ActionTile(
                icon: _trackingCoverage
                    ? Icons.stop_circle_outlined
                    : Icons.radio_button_checked,
                label: _trackingCoverage ? 'Zatrzymaj' : 'Nagraj',
                tooltip: _trackingCoverage
                    ? 'Zatrzymaj nagrywanie pokrycia'
                    : 'Nagraj pokrycie pola',
                isActive: _trackingCoverage,
                onPressed: _toggleCoverage,
              ),
              if (_savedTrack.isNotEmpty || _coveredHa > 0)
                _ActionTile(
                  icon: Icons.layers_clear,
                  label: 'Wyczyść ślad',
                  tooltip: 'Usuń nagrany ślad',
                  isActive: false,
                  onPressed: _clearTrackWithConfirm,
                ),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(color: AppColors.textFaint),
          const SizedBox(height: 8),

          _buildSectionHeader('WIĘCEJ'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8, runSpacing: 8,
            children: [
              _ActionTile(
                icon: Icons.agriculture,
                label: 'Import działek',
                tooltip: 'Importuj działki LPIS z ULDK GUGiK',
                isActive: false,
                onPressed: _importLpis,
              ),
              _ActionTile(
                icon: Icons.assignment_add,
                label: _activeTask != null ? 'Zmień zadanie' : 'Nowe zadanie',
                tooltip: _activeTask != null
                    ? 'Zadanie aktywne — zmień'
                    : 'Nowe zadanie',
                isActive: _activeTask != null,
                onPressed: _showNewTaskDialog,
              ),
            ],
          ),
        ],
      ),
    );
  }

  static Widget _buildSectionHeader(String title) {
    return Text(
      title,
      style: const TextStyle(
        color: AppColors.textMuted,
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.0,
      ),
    );
  }

  // ── Nowe Zadanie ────────────────────────────────────────────────────────────

  /// Multi-step workflow: Field → Machine → TaskType → generate swaths in RAM.
  Future<void> _showNewTaskDialog() async {
    // Step 1: ensure a field is active
    if (_activeField == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Najpierw wybierz pole z listy zapisanych pól'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    final field = _activeField!;

    // Step 2: pick a machine
    if (!mounted) return;
    final result = await MachineSelectorScreen.open(context, field: field);
    if (result == null || !mounted) return;
    final machine = result.machine;

    // Step 3: pick task type + optional material params
    TaskType? selectedType;
    double? targetRate;
    double? tankVolume;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) {
          final unit = selectedType?.defaultUnit;
          final usesMaterial = selectedType?.usesMaterial ?? false;
          return AlertDialog(
            backgroundColor: const Color(0xFF2A2A2A),
            title: const Text('Rodzaj zadania',
                style: TextStyle(color: Colors.white)),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: TaskType.values
                        .map(
                          (tt) => ChoiceChip(
                            label: Text(tt.label),
                            selected: selectedType == tt,
                            onSelected: (_) => setDlg(() => selectedType = tt),
                            selectedColor: Colors.green[700],
                            labelStyle: TextStyle(
                              color: selectedType == tt
                                  ? Colors.white
                                  : Colors.white70,
                            ),
                            backgroundColor: const Color(0xFF3A3A3A),
                          ),
                        )
                        .toList(),
                  ),
                  if (usesMaterial) ...[
                    const SizedBox(height: 18),
                    Text(
                      'Parametry materiału ($unit)',
                      style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 11,
                          letterSpacing: 0.5),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: 'Dawka ($unit)',
                        labelStyle: const TextStyle(color: Colors.white54),
                        enabledBorder: const UnderlineInputBorder(
                            borderSide: BorderSide(color: Colors.white30)),
                        focusedBorder: const UnderlineInputBorder(
                            borderSide: BorderSide(color: Colors.greenAccent)),
                      ),
                      onChanged: (v) {
                        final d = double.tryParse(v.replaceAll(',', '.'));
                        setDlg(() => targetRate = d);
                      },
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText:
                            'Napełnienie zbiornika (${unit?.split('/').first ?? 'l'})',
                        labelStyle: const TextStyle(color: Colors.white54),
                        enabledBorder: const UnderlineInputBorder(
                            borderSide: BorderSide(color: Colors.white30)),
                        focusedBorder: const UnderlineInputBorder(
                            borderSide: BorderSide(color: Colors.greenAccent)),
                      ),
                      onChanged: (v) {
                        final d = double.tryParse(v.replaceAll(',', '.'));
                        setDlg(() => tankVolume = d);
                      },
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Anuluj'),
              ),
              FilledButton(
                style:
                    FilledButton.styleFrom(backgroundColor: Colors.green[700]),
                onPressed: selectedType == null
                    ? null
                    : () => Navigator.pop(ctx, true),
                child: const Text('Rozpocznij'),
              ),
            ],
          );
        },
      ),
    );
    if (confirmed != true || selectedType == null || !mounted) return;

    // Step 4: create and persist the task
    final task = WorkTask(
      id: const Uuid().v4(),
      fieldId: field.id,
      machineId: machine.id,
      taskType: selectedType!,
      effectiveWidthM: machine.workingWidthM,
      targetRate: targetRate,
      initialTankVolume: tankVolume,
      unit: selectedType!.defaultUnit,
      createdAt: DateTime.now(),
    );
    await WorkTaskService.instance.save(task);

    // Step 5: activate machine + task and generate swaths in RAM
    setState(() {
      _activeMachine = machine;
      _activeTask = task;
    });

    await _planSwaths(workingWidthM: _activeWorkingWidth);

    // Step 6: start coverage tracking keyed by this task
    CoverageService.instance.startTracking(field.id, taskId: task.id);
    SectionControlBridge.instance
      ..setOrigin(field.center.latitude, field.center.longitude)
      ..clear();
    setState(() => _trackingCoverage = true);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Zadanie: ${selectedType!.label} — ${machine.name} '
            '(${machine.workingWidthM?.toStringAsFixed(1) ?? '?'} m)',
          ),
          backgroundColor: Colors.green[700],
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  /// Coverage strip width in screen pixels, proportional to implement width.
  double _coverageStrokeWidth() {
    try {
      final zoom = _mapController.camera.zoom;
      final lat = _tractorPos.latitude;
      // mpp: real-world metres per logical pixel at current zoom and latitude.
      final mpp =
          156543.03392 * math.cos(lat * math.pi / 180) / math.pow(2, zoom);
      return (_activeWorkingWidth / mpp).clamp(2.0, 120.0);
    } catch (_) {
      return 10.0;
    }
  }

  // ── Warstwy podkładowe / rastrowe WMS ──────────────────────────────────────────

  /// Buduje warstwy rastrowe na podstawie [_mapMode] oraz niezależnych
  /// przełączników [_orthophotoVisible] / [_arimrLpisVisible] (panel
  /// "Warstwy mapy") — obie mogą być włączone naraz, ortofoto jako tło,
  /// LPIS ARiMR jako półprzezroczysta nakładka nad nim.
  ///
  /// Optymalizacje płynności:
  ///   • [keepBuffer] = 4   — buforuje kafelki otaczające viewport;
  ///                          eliminuje migotanie przy szybkim pan/zoom.
  ///   • [maxNativeZoom]     — zatrzymuje fetch powyżej natywnej rozdzielczości;
  ///                          przy wyższych zoomach kafelki są skalowane lokalnie.
  List<Widget> _buildRasterLayers() {
    if (_mapMode == MapLayerMode.work) {
      // Tryb Pracy — brak kafelków, ciemne tło + subtelna siatka 10 m.
      return const [_WorkModeGridLayer()];
    }
    return [
      if (_orthophotoVisible) _buildOrthophotoLayer(),
      if (_arimrLpisVisible) _buildArimrLpisLayer(),
    ];
  }

  /// WMS Geoportal GUGiK — Ortofotomapa HighResolution, jako tło.
  /// SRS=EPSG:3857 — natywna siatka kafelków flutter_map (patrz [kGeoportalWmsUrl]),
  /// więc bbox każdego kafelka wychodzi geograficznie poprawny bez żadnych
  /// przeliczeń pośrednich. Urządzenie ma stały dostęp do internetu —
  /// kafelki streamowane na żywo (bez cache offline).
  Widget _buildOrthophotoLayer() {
    return TileLayer(
      // Klucz zmienia się po opóźnionym odświeżeniu (patrz initState) —
      // wymusza nowy TileImageManager i ponowienie kafelków, które
      // zawiodły przy zimnym starcie programu.
      key: ValueKey('geoportal-wms-$_tileReloadKey'),
      wmsOptions: WMSTileLayerOptions(
        baseUrl: kGeoportalWmsUrl,
        layers: const ['Raster'],
        format: 'image/png',
        transparent: false,
        version: '1.1.1',
        crs: const Epsg3857(),
      ),
      userAgentPackageName: 'com.example.agri_nav',
      keepBuffer: 4,
      maxNativeZoom: 18,
      // Kafelki, które zawiodły, są ponawiane gdy wypadną poza widoczny
      // obszar (pan/zoom) zamiast zostać puste na stałe (domyślnie
      // flutter_map nigdy ich nie ponawia — EvictErrorTileStrategy.none).
      evictErrorTileStrategy: EvictErrorTileStrategy.notVisibleRespectMargin,
    );
  }

  /// WMS LPIS ARiMR — referencyjny obrys działek rolnych, jako nakładka
  /// (transparent=true) nad tłem. Wyłącznie warstwa wizualna — WFS
  /// wyłączony na serwerze, brak eksportu wektora (patrz [kArimrLpisWmsUrl]).
  /// SRS=EPSG:4326 wymagany przez serwer → [_WmsGeographicCrs] (patrz
  /// dokumentacja tej klasy — wbudowany [Epsg4326] tu nie zadziała).
  Widget _buildArimrLpisLayer() {
    return TileLayer(
      key: ValueKey('arimr-lpis-wms-$_tileReloadKey'),
      wmsOptions: WMSTileLayerOptions(
        baseUrl: kArimrLpisWmsUrl,
        layers: const [kArimrLpisLayerWielkopolska],
        format: 'image/png',
        transparent: true,
        version: '1.1.1',
        crs: const _WmsGeographicCrs(),
      ),
      userAgentPackageName: 'com.example.agri_nav',
      keepBuffer: 4,
      evictErrorTileStrategy: EvictErrorTileStrategy.notVisibleRespectMargin,
    );
  }

  // ── Azymuty ──────────────────────────────────────────────────────────────────

  /// Delegates to [GeoUtils.bearing].
  static double _bearing(LatLng from, LatLng to) => GeoUtils.bearing(from, to);

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _mapMode == MapLayerMode.work
          ? const Color(0xFF1A1A1A)
          : Colors.black,
      body: Stack(
        children: [
          // ── FlutterMap ──────────────────────────────────────────────────────
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _tractorPos,
              initialZoom: 17,
              onTap: (_, latLng) {
                if (_controlPointsMode) {
                  _handleControlPointTap(latLng);
                  return;
                }
                if (!_drawingMode) setState(() => _followTractor = false);
              },
            ),
            children: [
              // ── Warstwy rastrowe (tło + nakładki, patrz "Warstwy mapy") ────
              ..._buildRasterLayers(),

              // ── Warstwa LPIS (zielone półprzezroczyste) ─────────────────────
              // Wyświetlaj parcele które NIE są aktywnym polem (brak duplikatu warstw)
              if (_lpisLayerVisible && _lpisParcels.isNotEmpty)
                PolygonLayer(
                  polygons: _lpisParcels
                      .where((p) =>
                          p.boundary.length >= 3 &&
                          (_activeField == null ||
                              !_activeField!.lpisParcelIds
                                  .contains(p.objectId)))
                      .map((p) => Polygon(
                            points: p.boundary
                                .map((ll) => LatLng(
                                      ll.latitude + _parcelLatOffset,
                                      ll.longitude + _parcelLonOffset,
                                    ))
                                .toList(),
                            color: Colors.green.withValues(alpha: 0.18),
                            borderColor: Colors.greenAccent,
                            borderStrokeWidth: 1.5,
                          ))
                      .toList(),
                ),

              // ── Wszystkie zapisane pola (szare) ─────────────────────────────
              if (_savedFields.isNotEmpty)
                PolygonLayer(
                  polygons: _savedFields
                      .where((f) =>
                          f.id != _activeField?.id &&
                          f.boundaryLats.length >= 3)
                      .map((f) => Polygon(
                            points: f.boundary,
                            color: Colors.white.withValues(alpha: 0.06),
                            borderColor: Colors.white38,
                            borderStrokeWidth: 1.0,
                          ))
                      .toList(),
                ),

              // ── Aktywna granica pola (PolygonLayer) ─────────────────────────
              if (_fieldBoundary.length >= 3)
                PolygonLayer(
                  polygons: [
                    Polygon(
                      points: _fieldBoundary,
                      color: Colors.yellow.withValues(alpha: 0.22),
                      borderColor: _drawingMode ? Colors.orange : Colors.yellow,
                      borderStrokeWidth: 3.0,
                    ),
                  ],
                ),

              // ── Pierścienie uwrociowe ────────────────────────────────────────
              if (_headlandRings.isNotEmpty)
                PolylineLayer(
                  polylines: _headlandRings
                      .map((ring) => Polyline(
                            points: [...ring, ring.first], // zamknij pierścień
                            color: Colors.orangeAccent.withValues(alpha: 0.75),
                            strokeWidth: 1.8,
                          ))
                      .toList(),
                ),

              // ── Pokrycie pola (coverage track) ───────────────────────────────
              if (_trackingCoverage &&
                  CoverageService.instance.currentTrack.length >= 2)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: CoverageService.instance.currentTrack,
                      color: Colors.blue.withValues(alpha: 0.50),
                      strokeWidth: _coverageStrokeWidth(),
                    ),
                  ],
                ),

              // ── Ścieżki uprawowe (swaths) — aktywna podświetlona żółtym ─────
              if (_swaths.isNotEmpty)
                PolylineLayer(
                  polylines: _swaths.asMap().entries.map((e) {
                    final isNearest = e.key == _snapInfo.swathIndex;
                    final s = e.value;
                    return Polyline(
                      points: [
                        LatLng(s.startLat, s.startLon),
                        LatLng(s.endLat, s.endLon),
                      ],
                      color: isNearest
                          ? Colors.yellow.withValues(alpha: 0.95)
                          : Colors.greenAccent.withValues(alpha: 0.7),
                      strokeWidth: isNearest ? 3.2 : 1.4,
                    );
                  }).toList(),
                ),

              // ── Punkty kontrolne — granica surowa (referencja Krok 1) ───────
              if (_controlPointsMode &&
                  _activeField != null &&
                  _activeField!.boundaryLats.length >= 2)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: [
                        for (var i = 0;
                            i < _activeField!.boundaryLats.length;
                            i++)
                          LatLng(_activeField!.boundaryLats[i],
                              _activeField!.boundaryLons[i]),
                        LatLng(_activeField!.boundaryLats.first,
                            _activeField!.boundaryLons.first),
                      ],
                      color: Colors.deepOrangeAccent,
                      strokeWidth: 1.5,
                      pattern: StrokePattern.dashed(segments: const [6, 4]),
                    ),
                  ],
                ),

              // ── Punkty kontrolne — podgląd na żywo (niezatwierdzony fit) ────
              if (_cpPreviewBoundary.length >= 3)
                PolygonLayer(
                  polygons: [
                    Polygon(
                      points: _cpPreviewBoundary,
                      color: Colors.cyan.withValues(alpha: 0.12),
                      borderColor: Colors.cyanAccent,
                      borderStrokeWidth: 2.5,
                      pattern: StrokePattern.dashed(segments: const [8, 5]),
                    ),
                  ],
                ),

              // ── Punkty kontrolne — pary (łączniki + kropki) ──────────────────
              if (_controlPointsMode && _cpPairs.isNotEmpty)
                PolylineLayer(
                  polylines: _cpPairs
                      .map((p) => Polyline(
                            points: [p.source, p.target],
                            color: Colors.white54,
                            strokeWidth: 1.0,
                            pattern:
                                StrokePattern.dashed(segments: const [4, 4]),
                          ))
                      .toList(),
                ),
              if (_controlPointsMode &&
                  (_cpPairs.isNotEmpty || _cpPendingSource != null))
                CircleLayer(
                  circles: [
                    for (final p in _cpPairs) ...[
                      CircleMarker(
                        point: p.source,
                        radius: 6,
                        color: Colors.red,
                        borderColor: Colors.white,
                        borderStrokeWidth: 1.5,
                      ),
                      CircleMarker(
                        point: p.target,
                        radius: 6,
                        color: Colors.green,
                        borderColor: Colors.white,
                        borderStrokeWidth: 1.5,
                      ),
                    ],
                    if (_cpPendingSource != null)
                      CircleMarker(
                        point: _cpPendingSource!,
                        radius: 7,
                        color: Colors.red,
                        borderColor: Colors.yellow,
                        borderStrokeWidth: 2,
                      ),
                  ],
                ),

              // ── Ikona ciągnika ────────────────────────────────────────────────
              MarkerLayer(
                markers: [
                  Marker(
                    point: _tractorPos,
                    width: 52,
                    height: 52,
                    child: Transform.rotate(
                      angle: _tractorHeading * math.pi / 180.0,
                      child: CustomPaint(
                        painter: _TractorArrow(
                          valid: _guidanceValid,
                          crossTrack: _crossTrack,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),

          // ── Panel korekty przesunięcia (Nudge) ──────────────────────────────
          if (_nudgePanelVisible && _activeField != null)
            Positioned(
              left: 12,
              bottom: 200,
              child: NudgePanel(
                field: _activeField!,
                onNudge: (dx, dy) => _nudgeActive(dx, dy),
                onReset: _resetActiveNudge,
                onClose: () => setState(() => _nudgePanelVisible = false),
              ),
            ),

          // ── Panel korekty punktami kontrolnymi ────────────────────────────────
          if (_controlPointsMode && _activeField != null)
            Positioned(
              left: 12,
              bottom: 200,
              child: ControlPointsPanel(
                pairCount: _cpPairs.length,
                hasPendingSource: _cpPendingSource != null,
                onUndo: _undoLastCpPair,
                onReset: _resetCpPairs,
                onCancel: _cancelControlPoints,
                onConfirm: _confirmControlPoints,
              ),
            ),

          // ── Manual Offset — kalibracja warstwy LPIS względem satelity ────────
          if (_offsetPanelVisible && _lpisLayerVisible)
            Positioned(
              left: 12,
              bottom: 220,
              child: _ManualOffsetPanel(
                latOffset: _parcelLatOffset,
                lonOffset: _parcelLonOffset,
                onNudge: (dLat, dLon) => setState(() {
                  _parcelLatOffset += dLat;
                  _parcelLonOffset += dLon;
                }),
                onReset: () => setState(() {
                  _parcelLatOffset = 0;
                  _parcelLonOffset = 0;
                }),
                onClose: () => setState(() => _offsetPanelVisible = false),
              ),
            ),

          // ── DrawingMode overlay ──────────────────────────────────────────────
          if (_drawingMode)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (d) {
                  final pt = _screenToLatLng(d.localPosition);
                  setState(() => _fieldBoundary
                    ..clear()
                    ..add(pt));
                },
                onPanUpdate: (d) {
                  final pt = _screenToLatLng(d.localPosition);
                  if (_shouldAddPoint(pt)) {
                    setState(() => _fieldBoundary.add(pt));
                  }
                },
                onPanEnd: (_) {
                  setState(() => _drawingMode = false);
                  if (_fieldBoundary.length >= 3) _showSaveFieldDialog();
                },
                child: Container(
                  color: Colors.transparent,
                  alignment: Alignment.topCenter,
                  padding: const EdgeInsets.only(top: 48),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text(
                      '✍  Rysuj granicę — przeciągnij palcem',
                      style: TextStyle(
                          color: Colors.orange, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ),
            ),

          // ── Praca w toku (banner w tle) ─────────────────────────────────────
          if (_activeField != null &&
              _activeField!.id == WorkSessionService.instance.fieldId)
            Positioned(
              left: 16,
              right: 16,
              bottom: 24,
              child: _ActiveWorkBanner(
                fieldName: _activeField!.name,
                onResume: _launchWorkMode,
                onFinish: _finishActiveSession,
              ),
            ),

          // ── Przyciski top-right ──────────────────────────────────────────────
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // ── Tryb pracy (widoczny gdy pole + ścieżki są gotowe) ─────
                    if (_activeField != null && _swaths.isNotEmpty) ...[
                      Hero(
                        tag: 'workModeHero',
                        child: FloatingActionButton.small(
                          heroTag: null,
                          tooltip: 'Rozpocznij pracę',
                          backgroundColor: const Color(0xFF1B5E20),
                          onPressed: _launchWorkMode,
                          child: const Icon(
                            Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 22,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],

                    // ── Śledź ciągnik ─────────────────────────────────────────
                    FloatingActionButton.small(
                      heroTag: 'follow',
                      tooltip: _followTractor
                          ? 'Zatrzymaj śledzenie'
                          : 'Śledź ciągnik',
                      backgroundColor: _followTractor
                          ? Colors.green[700]
                          : const Color(0xAA000000),
                      onPressed: () =>
                          setState(() => _followTractor = !_followTractor),
                      child: Icon(
                        _followTractor ? Icons.gps_fixed : Icons.gps_not_fixed,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                    const SizedBox(height: 8),

                    // ── Przełącznik trybu mapy ─────────────────────────────────
                    FloatingActionButton.small(
                      heroTag: 'mapMode',
                      tooltip: _mapMode == MapLayerMode.geoportal
                          ? 'Przełącz na Tryb Pracy (brak kafelków)'
                          : 'Przełącz na Tryb Konfiguracji (warstwy mapy)',
                      backgroundColor: _mapMode == MapLayerMode.work
                          ? const Color(0xFF1B5E20)
                          : Colors.teal[700],
                      onPressed: () => setState(() {
                        _mapMode = _mapMode == MapLayerMode.geoportal
                            ? MapLayerMode.work
                            : MapLayerMode.geoportal;
                      }),
                      child: Icon(
                        _mapMode == MapLayerMode.work
                            ? Icons.agriculture
                            : Icons.satellite_alt,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                    const SizedBox(height: 8),

                    // ── Menu — panel z pozostałymi opcjami ─────────────────────
                    FloatingActionButton.small(
                      heroTag: 'menu',
                      tooltip: 'Więcej opcji',
                      backgroundColor: const Color(0xAA000000),
                      onPressed: _showActionsPanel,
                      child: const Icon(
                        Icons.tune,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Kafelek akcji w panelu bocznym
// ═══════════════════════════════════════════════════════════════════════════════

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onPressed,
    this.isActive = false,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback onPressed;
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    final color = isActive ? AppColors.success : AppColors.textSecondary;
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 96,
        child: Card(
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          color: Colors.transparent,
          elevation: 0,
          child: InkWell(
            onTap: onPressed,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, color: color, size: 24),
                  const SizedBox(height: 4),
                  Text(
                    label,
                    style: TextStyle(color: color, fontSize: 11),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Banner "Praca w toku" — praca działa w tle aż do jawnego zakończenia
// ═══════════════════════════════════════════════════════════════════════════════

/// Dolny banner widoczny na mapie, dopóki sesja [WorkSessionService] nie jest
/// zakończona. Pozwala wrócić do Trybu Pracy albo zakończyć pracę bez
/// wchodzenia na ekran prowadzenia.
class _ActiveWorkBanner extends StatelessWidget {
  const _ActiveWorkBanner({
    required this.fieldName,
    required this.onResume,
    required this.onFinish,
  });

  final String fieldName;
  final VoidCallback onResume;
  final VoidCallback onFinish;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: WorkSessionService.instance.stream,
      initialData: WorkSessionService.instance.elapsed,
      builder: (context, snap) {
        final service = WorkSessionService.instance;
        if (!service.isActive) return const SizedBox.shrink();
        final paused = service.paused;
        final elapsed = snap.data ?? service.elapsed;

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: paused
                ? const Color(0xEE3A2A00)
                : const Color(0xEE0A3A1E),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: paused
                  ? Colors.orangeAccent.withValues(alpha: 0.7)
                  : Colors.greenAccent.withValues(alpha: 0.7),
            ),
            boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 10)],
          ),
          child: Row(
            children: [
              Icon(
                paused
                    ? Icons.pause_circle_filled_rounded
                    : Icons.play_circle_fill_rounded,
                color: paused ? Colors.orangeAccent : Colors.greenAccent,
                size: 22,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'PRACA W TOKU',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 9,
                        letterSpacing: 1.0,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            fieldName,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          formatWorkDuration(elapsed),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            fontFeatures: [
                              ui.FontFeature.tabularFigures()
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Wróć do pracy',
                visualDensity: VisualDensity.compact,
                color: Colors.greenAccent,
                onPressed: onResume,
                icon: const Icon(Icons.open_in_full_rounded, size: 20),
              ),
              IconButton(
                tooltip: 'Zakończ pracę',
                visualDensity: VisualDensity.compact,
                color: Colors.redAccent,
                onPressed: onFinish,
                icon: const Icon(Icons.stop_circle_outlined, size: 20),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Siatka Trybu Pracy — CustomPainter renderowany zamiast warstwy kafelkowej
// ═══════════════════════════════════════════════════════════════════════════════
/// Ciemne tło z delikatną ortogonalną siatką pomocniczą (co ~80 px w ekranie).
/// Nie wymaga danych geograficznych — jest czysto "ekranowa" i niezmiennicza.
class _WorkModeGridLayer extends StatelessWidget {
  const _WorkModeGridLayer();

  @override
  Widget build(BuildContext context) {
    return const Positioned.fill(
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _GridPainter(),
        ),
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  const _GridPainter();

  @override
  void paint(Canvas canvas, Size size) {
    // Tło
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF1A1A1A),
    );

    // Siatka linii pomocniczych
    final paint = Paint()
      ..color = const Color(0x18FFFFFF)
      ..strokeWidth = 0.5;

    const step = 60.0; // pikseli na ekranie
    for (double x = 0; x <= size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y <= size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }

    // Grubsze linie co 5 kroków (co ~300 px)
    final boldPaint = Paint()
      ..color = const Color(0x28FFFFFF)
      ..strokeWidth = 1.0;
    for (double x = 0; x <= size.width; x += step * 5) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), boldPaint);
    }
    for (double y = 0; y <= size.height; y += step * 5) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), boldPaint);
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) => false;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Ikona ciągnika — CustomPainter (strzałka obracana przez Transform)
// ═══════════════════════════════════════════════════════════════════════════════

class _TractorArrow extends CustomPainter {
  const _TractorArrow({required this.valid, required this.crossTrack});

  final bool valid;
  final double crossTrack; // [m]

  Color get _color {
    if (!valid) return Colors.white54;
    final abs = crossTrack.abs();
    if (abs < 0.15) return const Color(0xFF00E676); // zielony < 15 cm
    if (abs < 0.50) return Colors.orange;
    return Colors.redAccent;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = size.width * 0.42;

    // Trójkąt z wcięciem — czubek wskazuje kierunek jazdy (góra = północ)
    final path = ui.Path()
      ..moveTo(cx, cy - r)
      ..lineTo(cx + r * 0.55, cy + r * 0.72)
      ..lineTo(cx, cy + r * 0.28)
      ..lineTo(cx - r * 0.55, cy + r * 0.72)
      ..close();

    canvas
      ..drawPath(
          path,
          Paint()
            ..color = _color
            ..style = PaintingStyle.fill)
      ..drawPath(
          path,
          Paint()
            ..color = Colors.black87
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5);
  }

  @override
  bool shouldRepaint(_TractorArrow old) =>
      old.valid != valid || old.crossTrack != crossTrack;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Manual Offset Panel — kalibracja warstwy LPIS względem zdjęcia satelitarnego
//
// Przesuwa WSZYSTKIE działki LPIS o stały delta w stopniach (0.00001° ≈ 1.1 m).
// Offset jest czysto wizualny i nie jest zapisywany do bazy.
// ═══════════════════════════════════════════════════════════════════════════════

class _ManualOffsetPanel extends StatelessWidget {
  const _ManualOffsetPanel({
    required this.latOffset,
    required this.lonOffset,
    required this.onNudge,
    required this.onReset,
    required this.onClose,
  });

  final double latOffset;
  final double lonOffset;
  final void Function(double dLat, double dLon) onNudge;
  final VoidCallback onReset;
  final VoidCallback onClose;

  static const _step = 0.00001; // ≈ 1.1 m w kierunku N/S, ≈ 0.7 m E/W @ 52°N

  String _fmt(double v) {
    final steps = (v / _step).round();
    return steps >= 0 ? '+$steps' : '$steps';
  }

  @override
  Widget build(BuildContext context) {
    final hasOffset = latOffset != 0 || lonOffset != 0;
    return Container(
      width: 130,
      decoration: BoxDecoration(
        color: const Color(0xEE0D1B2A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: hasOffset
              ? Colors.orangeAccent.withValues(alpha: 0.8)
              : Colors.tealAccent.withValues(alpha: 0.5),
          width: 1,
        ),
        boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 8)],
      ),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Nagłówek ──────────────────────────────────────────────────────
          Row(
            children: [
              const Icon(Icons.tune, color: Colors.tealAccent, size: 13),
              const SizedBox(width: 4),
              const Expanded(
                child: Text(
                  'Manual Offset',
                  style: TextStyle(
                    color: Colors.tealAccent,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
              GestureDetector(
                onTap: onClose,
                child: const Icon(Icons.close, color: Colors.white38, size: 15),
              ),
            ],
          ),
          const SizedBox(height: 4),

          // ── Wyświetlanie bieżącego offsetu ────────────────────────────────
          Text(
            'N/S: ${_fmt(latOffset)}  E/W: ${_fmt(lonOffset)}',
            style: TextStyle(
              color: hasOffset ? Colors.orangeAccent : Colors.white38,
              fontSize: 9.5,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),

          // ── Strzałka Góra ─────────────────────────────────────────────────
          _ArrowButton(
            icon: Icons.keyboard_arrow_up_rounded,
            tooltip: 'Przesuń N (+lat)',
            onTap: () => onNudge(_step, 0),
          ),
          const SizedBox(height: 2),

          // ── Rząd: Lewo | Reset | Prawo ────────────────────────────────────
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _ArrowButton(
                icon: Icons.keyboard_arrow_left_rounded,
                tooltip: 'Przesuń W (−lon)',
                onTap: () => onNudge(0, -_step),
              ),
              const SizedBox(width: 2),
              _ArrowButton(
                icon: Icons.gps_fixed,
                tooltip: 'Resetuj offset',
                onTap: onReset,
                color: hasOffset ? Colors.orangeAccent : Colors.white24,
              ),
              const SizedBox(width: 2),
              _ArrowButton(
                icon: Icons.keyboard_arrow_right_rounded,
                tooltip: 'Przesuń E (+lon)',
                onTap: () => onNudge(0, _step),
              ),
            ],
          ),
          const SizedBox(height: 2),

          // ── Strzałka Dół ──────────────────────────────────────────────────
          _ArrowButton(
            icon: Icons.keyboard_arrow_down_rounded,
            tooltip: 'Przesuń S (−lat)',
            onTap: () => onNudge(-_step, 0),
          ),

          const SizedBox(height: 4),
          const Text(
            '1 krok ≈ 1.1 m',
            style: TextStyle(color: Colors.white24, fontSize: 8.5),
          ),
        ],
      ),
    );
  }
}

// ── Przycisk kierunkowy dla ManualOffsetPanel ─────────────────────────────────

class _ArrowButton extends StatelessWidget {
  const _ArrowButton({
    required this.icon,
    required this.onTap,
    this.tooltip = '',
    this.color,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              border: Border.all(color: color ?? Colors.white24),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(
              icon,
              color: color ?? Colors.white70,
              size: 20,
            ),
          ),
        ),
      ),
    );
  }
}
