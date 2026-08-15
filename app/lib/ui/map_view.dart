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
import '../services/machine_service.dart';
import '../models/task_plan.dart';
import '../models/work_task.dart';
import '../services/coverage_service.dart';
import '../services/field_service.dart';
import '../services/gps_location_service.dart';
import '../services/history_database.dart';
import '../services/material_monitor_service.dart';
import '../services/task_database.dart';
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
import '../utils/elastic_warp.dart';
import 'widgets/degree_angle_input.dart';

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

  /// Gdy true, nagrywanie granicy przez obejście/przejazd RTK startuje
  /// automatycznie zaraz po uruchomieniu GPS — używane przez kafelek
  /// "Obejdź granicę (RTK)" na ekranie głównym, żeby użytkownik nie musiał
  /// szukać przycisku po wejściu na mapę.
  final bool startBoundaryWalk;

  const MapView({
    super.key,
    this.initialField,
    this.initialTask,
    this.startBoundaryWalk = false,
  });

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

  // ── Wyznaczanie AB: tryb "2 punkty" (stuknięcia na mapie) ───────────────────
  bool _abTapMode = false;

  /// Pierwsze stuknięcie (kandydat na A), dopóki drugie nie zatwierdzi linii.
  /// Osobne od [_pointA], żeby anulowanie w trakcie wyznaczania nie
  /// nadpisywało już zatwierdzonej, poprzedniej linii AB.
  LatLng? _abTapPending;

  // ── Wyznaczanie AB: tryb "przejazd" (nagrywanie RTK + dopasowanie) ──────────
  bool _abRecording = false;
  final List<LatLng> _abRecordedPoints = [];

  // ── Tworzenie granicy przez obejście/przejazd RTK ───────────────────────────
  bool _boundaryRecording = false;
  final List<LatLng> _boundaryRecordedPoints = [];
  int _boundaryFixedCount = 0;
  int _boundaryFloatCount = 0;

  static const int _kMinBoundaryRecordedPoints = 10;
  static const double _kMinBoundaryAreaHa = 0.01; // 100 m²
  static const double _kBoundaryMinPointDistanceM = 0.2; // decymacja wejścia
  static const double _kBoundaryCloseWarnM = 25.0; // próg ostrzeżenia domknięcia
  static const double _kBoundarySimplifyEpsilonM = 0.15; // RDP (patrz processLpis)

  // ── Granice pola (PolygonLayer — gotowe do podpięcia) ───────────────────────
  final List<LatLng> _fieldBoundary = [];

  // ── Wygenerowane ścieżki uprawowe ────────────────────────────────────
  /// Ścieżki gotowe do wyświetlenia/prowadzenia — surowy wynik plannera
  /// (patrz [_rawSwaths]) przesunięty o [_manualOffsetM]. To pole (nie
  /// [_rawSwaths]) jest tym, co czyta reszta ekranu (rendering, guidance,
  /// Tryb Pracy).
  List<Swath> _swaths = [];
  List<List<LatLng>> _headlandRings = [];

  /// Surowy wynik SwathPlannera (ręcznego generowania lub optymalizatora),
  /// PRZED zastosowaniem [_manualOffsetM]. Trzymany osobno, żeby ręczna
  /// korekta przesunięcia nie kumulowała się przy każdym ponownym
  /// wygenerowaniu/optymalizacji — zawsze liczona od tego surowego wyniku.
  List<Swath> _rawSwaths = [];

  /// Punkt A użyty jako ENU-origin przy ostatnim (re)generowaniu ścieżek —
  /// potrzebny do ponownego nakarmienia [SwathGuidanceBridge] po zmianie
  /// [_manualOffsetM] bez konieczności ponownego wywołania plannera.
  LatLng? _swathOrigin;

  /// Ręczna korekta wygenerowanych ścieżek [m], prostopadle do kierunku
  /// jazdy (+ = w prawo). Patrz [TaskPlan.manualOffsetM].
  double _manualOffsetM = 0.0;
  bool _swathOffsetPanelVisible = false;

  // ── Snapowanie do ścieżki ────────────────────────────────────────────────────
  SnapInfo _snapInfo = SnapInfo.none;

  // ── Nagrywanie pokrycia ──────────────────────────────────────────────────────
  bool _trackingCoverage = false;
  double _coveredHa = 0.0;
  List<LatLng> _savedTrack = [];

  /// Surowa (nie-zdeduplikowana) powierzchnia dla liczenia zużycia materiału —
  /// patrz [GeoUtils.trackSweptAreaHa]. Osobna od [_coveredHa]: nakładki mają
  /// się liczyć ponownie tutaj, w przeciwieństwie do liczenia hektarów.
  double _rawMaterialAreaHa = 0.0;
  LatLng? _lastMaterialPos;

  // ── Parametry generowania ścieżek ───────────────────────────────────────────
  double _overlapM = 0.0; // zakładka [m]
  int _headlandLaps = 0; // liczba objazdów uwrociowych
  double _swathAngleDeg = 0.0; // kierunek ścieżek [°], auto z granicy
  bool _optimizingAngle = false; // trwa SwathPlanner::optimizeAngle() w tle

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

  /// Zapisany plan (SQLite) zadania załadowanego na start tego ekranu —
  /// null gdy pole otwarto bez zadania (tryb legacy). Trzymany, żeby móc
  /// wykryć rozjazd między jego zamrożoną migawką granicy a aktualną
  /// korektą pola (patrz [_taskBoundaryStale]) i ewentualnie ją nadpisać.
  TaskPlan? _loadedTaskPlan;

  /// Czy granica zapisana w [_loadedTaskPlan] różni się od aktualnej,
  /// skorygowanej granicy pola (rolnik dodał/zmienił punkty kontrolne po
  /// utworzeniu zadania). Gdy true, pokazywany jest baner z jawnym wyborem
  /// aktualizacji — bez cichej, automatycznej zmiany geometrii zadania
  /// w trakcie pracy.
  bool _taskBoundaryStale = false;

  /// Aktualna, skorygowana wersja pola dla [_loadedTaskPlan] — źródło dla
  /// przycisku "Aktualizuj" w banerze nieaktualności. Ustawiane razem z
  /// [_taskBoundaryStale].
  FieldModel? _staleLiveField;

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
      // Kafelek "Obejdź granicę (RTK)" na ekranie głównym wchodzi wprost tu
      // z tą flagą — po starcie GPS od razu włącz nagrywanie, żeby
      // użytkownik nie musiał szukać przycisku w panelu POLE.
      if (widget.startBoundaryWalk && mounted) {
        _toggleBoundaryWalk();
      }
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

    // ── Nagrywanie linii AB przez przejazd ──────────────────────────────────
    // Filtr jakości fixa MUSI być na fixStatus (rtkFixed), nie na
    // pos.isAccurate — to drugie przepuszcza też zwykły GPS telefonu i DGPS
    // (patrz GpsLocationService._fromGnss), a błąd kąta z takich punktów
    // zaprzepaściłby cały sens tego trybu.
    if (_abRecording &&
        GpsLocationService.instance.fixStatus == GpsFixStatus.rtkFixed) {
      _abRecordedPoints.add(newPos); // rebuild via setState() poniżej
    }

    // ── Nagrywanie granicy przez obejście/przejazd RTK ──────────────────────
    // Szerszy filtr niż AB (Fixed LUB Float) — pojedynczy wierzchołek
    // obrysu nie musi mieć precyzji nagłówka AB, dokładność Float
    // (dm-level) wystarcza dla granicy pola. Dodatkowa decymacja
    // odległościowa, żeby nie gromadzić tysięcy niemal identycznych
    // punktów przy wolnym chodzie/postoju (RDP i tak by je usunął przy
    // zapisie — to tylko oszczędność pamięci w trakcie nagrywania).
    if (_boundaryRecording) {
      final fs = GpsLocationService.instance.fixStatus;
      if (fs == GpsFixStatus.rtkFixed || fs == GpsFixStatus.rtkFloat) {
        final last = _boundaryRecordedPoints.isEmpty
            ? null
            : _boundaryRecordedPoints.last;
        final moved = last == null ||
            _enuDistanceM(last, newPos) >= _kBoundaryMinPointDistanceM;
        if (moved) {
          _boundaryRecordedPoints.add(newPos); // rebuild via setState() poniżej
          if (fs == GpsFixStatus.rtkFixed) {
            _boundaryFixedCount++;
          } else {
            _boundaryFloatCount++;
          }
        }
      }
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

    // Cofanie: kurs GPS to kierunek ruchu po ziemi, więc przy jeździe tyłem
    // "odwraca się" o ~180° względem przodu pojazdu. Taki skok traktujemy
    // jako cofanie i nie obracamy wskaźnika — zostaje przy ostatnim kursie
    // jazdy do przodu, zamiast wykonywać nagły obrót o pół obrotu.
    if (_headingDiff(heading, _tractorHeading) > 135.0) {
      heading = _tractorHeading;
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
      // Poza obrysem pola nie malujemy śladu ani nie liczymy hektarów —
      // przejazd po uwrociu/drodze dojazdowej nie ma się wliczać.
      final insideBoundary = _activeField == null ||
          GeoUtils.pointInPolygon(newPos, _activeField!.boundary);
      if (!sessionPaused && !session.machineOff && insideBoundary) {
        CoverageService.instance.addPoint(newPos);
        // Surowa powierzchnia (nakładki liczą się ponownie) — podstawa
        // zużycia materiału, osobna od zdeduplikowanych hektarów poniżej.
        if (_lastMaterialPos != null) {
          final enu = GeoUtils.toEnu(_lastMaterialPos!, newPos);
          final segM = math.sqrt(enu.e * enu.e + enu.n * enu.n);
          _rawMaterialAreaHa += segM * _activeWorkingWidth / 10000.0;
        }
        _lastMaterialPos = newPos;
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
            MaterialMonitorService.instance.updateArea(_rawMaterialAreaHa);
          }
        }
      } else {
        // Przerwa w naliczaniu (pauza / maszyna wyłączona / poza obrysem) —
        // następny punkt nie może doliczyć fantomowego odcinka przez przerwę.
        _lastMaterialPos = null;
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

  Future<void> _toggleDrawingMode() async {
    if (!_drawingMode && (_abRecording || _boundaryRecording)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_abRecording
              ? 'Zatrzymaj nagrywanie linii AB przed rysowaniem granicy'
              : 'Zakończ obejście granicy przed rysowaniem'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    final finishingBoundary = _drawingMode && _fieldBoundary.length >= 3;
    setState(() {
      _drawingMode = !_drawingMode;
      if (_drawingMode) {
        _clearControlPointsState();
        _abTapMode = false;
        // Nowo rysowana granica nie powinna dziedziczyć linii AB z
        // poprzednio wczytanego/aktywnego pola.
        _pointA = null;
        _pointB = null;
        NavBridge.instance.resetAbLine();
        _fieldBoundary.clear();
        _swaths = [];
        _rawSwaths = [];
        _swathOrigin = null;
        // Ta sama zasada co przy AB powyżej — nowo rysowana granica nie
        // powinna dziedziczyć korekty przesunięcia z poprzedniego pola.
        _manualOffsetM = 0.0;
        _headlandRings = [];
        _snapInfo = SnapInfo.none;
        _activeField = null;
      }
    });
    if (finishingBoundary) {
      await _autoSetSwathAngle(_fieldBoundary);
      if (!mounted) return;
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _showSaveFieldDialog());
    }
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
      // Zadanie już w toku (potwierdzony poziom zbiornika / zmieniona dawka
      // w trakcie pracy) ma pierwszeństwo przed świeżą migawką z planu —
      // inaczej powrót na ten ekran zgubiłby te ustawienia i zapytałby o
      // zbiornik od nowa.
      _activeTask = WorkTaskService.instance.getById(plan.id) ??
          WorkTask(
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
      // Odczytaj prawdziwy profil maszyny (pojemność/jednostka zbiornika) —
      // migawka w TaskPlan nie przechowuje tych pól. Gdy maszyna została
      // usunięta z bazy, wróć do migawki jako fallback.
      _activeMachine = MachineService.instance.getById(plan.machineId) ??
          MachineModel(
            id: plan.machineId ?? '',
            name: plan.machineName ?? '—',
            type: MachineType.fromJson(plan.machineType),
            workingWidthM: plan.workingWidthM,
          );
    } else {
      // Pole ładowane bez planu (np. świeży import LPIS) — kontekst
      // poprzednio otwartego zadania (jeśli był) już nie dotyczy tego pola,
      // inaczej baner nieaktualności zostałby "zawieszony" nad niepowiązanym
      // polem. _loadTaskPlan ustawi te pola ponownie, jeśli trzeba.
      _loadedTaskPlan = null;
      _taskBoundaryStale = false;
      _staleLiveField = null;
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
      _rawSwaths = [];
      _swathOrigin = null;
      _headlandRings = [];
      _snapInfo = SnapInfo.none;
      if (plan?.swathAngleDeg != null) _swathAngleDeg = plan!.swathAngleDeg;
      _overlapM = plan?.overlapM ?? 0.0;
      _headlandLaps = plan?.headlandLaps ?? 0;
      // Zawsze przypisz (również gdy plan==null/pole bez zadania) — inaczej
      // korekta przesunięcia poprzednio wczytanego zadania "przecieka" do
      // pola, które żadnej korekty nie ma (ten sam wzorzec co _pointA/_pointB
      // poniżej).
      _manualOffsetM = plan?.manualOffsetM ?? 0.0;
      _savedTrack = savedTrack;
      _coveredHa = coveredHa;
      _rawMaterialAreaHa =
          GeoUtils.trackSweptAreaHa(savedTrack, replayWidth);
      _lastMaterialPos = savedTrack.isNotEmpty ? savedTrack.last : null;
      // Zawsze przypisz (również gdy null) — inaczej linia AB poprzednio
      // wczytanego pola "przecieka" do pola, które żadnej linii nie ma.
      _pointA = field.lineA;
      _pointB = field.lineB;
    });
    if (_pointA != null && _pointB != null) {
      NavBridge.instance.setAbLine(
        _pointA!.latitude,
        _pointA!.longitude,
        _pointB!.latitude,
        _pointB!.longitude,
      );
    } else {
      NavBridge.instance.resetAbLine();
    }
    // Plan bez zapisanego kąta (świeże pole) -> dolicz precyzyjny domyślny
    // kierunek, zanim wygenerujemy ścieżki poniżej.
    if (plan?.swathAngleDeg == null) {
      await _autoSetSwathAngle(_fieldBoundary);
    }
    // Ścieżki od razu gotowe (z zapisanej linii AB, jeśli jest, inaczej z
    // autokąta) — bez tego Tryb Pracy startowałby z pustą siatką, dopóki
    // użytkownik ręcznie nie tapnie "Generuj".
    if (_fieldBoundary.length >= 3) {
      await _planSwaths(workingWidthM: _activeWorkingWidth);
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
    // _loadField już wygenerowało ścieżki (patrz komentarz tam) — z tą samą
    // szerokością, bo _activeMachine (ustawione z planu) determinuje
    // _activeWorkingWidth == plan.workingWidthM. Drugie wywołanie tu
    // powtórzyłoby ten sam koszt (~20-200 ms) bez żadnej korzyści.

    _loadedTaskPlan = plan;
    _checkTaskBoundaryStaleness();
  }

  // ── Nieaktualność granicy zadania (korekta zmieniona po jego utworzeniu) ───

  /// Odległość [m] między dwoma punktami WGS-84 — lokalna aproksymacja ENU,
  /// wystarczająca przy porównywaniu wierzchołków tej samej granicy.
  double _vertexDistanceM(double lat1, double lon1, LatLng p2) {
    final enu = GeoUtils.toEnu(LatLng(lat1, lon1), p2);
    return math.sqrt(enu.e * enu.e + enu.n * enu.n);
  }

  /// Czy zamrożona granica zapisana w [plan] różni się od [liveBoundary]
  /// (aktualna korekta pola) o więcej niż drobny szum numeryczny.
  ///
  /// Różna liczba wierzchołków (np. przejście na korektę elastyczną, która
  /// zagęszcza krawędzie) liczy się od razu jako rozjazd — bez próby
  /// dopasowania punkt-do-punktu.
  bool _boundaryDiffers(TaskPlan plan, List<LatLng> liveBoundary) {
    const thresholdM = 0.3;
    final lats = plan.boundaryLats;
    final lons = plan.boundaryLons;
    if (lats.length != liveBoundary.length) return true;
    for (var i = 0; i < lats.length; i++) {
      if (_vertexDistanceM(lats[i], lons[i], liveBoundary[i]) > thresholdM) {
        return true;
      }
    }
    return false;
  }

  /// Porównuje [_loadedTaskPlan] z aktualnym, zapisanym stanem pola
  /// (odczytanym świeżo z [FieldService], nie z [_activeField] — dla zadań
  /// otwartych z planu [_activeField] to sama zamrożona migawka, więc
  /// porównanie sam-do-siebie zawsze wyszłoby "aktualne"). Wywoływać po
  /// każdej zmianie korekty pola w trakcie tej sesji ekranu.
  void _checkTaskBoundaryStaleness() {
    final plan = _loadedTaskPlan;
    if (plan == null) return;
    final liveField = FieldService.instance.getById(plan.fieldId);
    final stale =
        liveField != null && _boundaryDiffers(plan, liveField.boundary);
    setState(() {
      _taskBoundaryStale = stale;
      _staleLiveField = stale ? liveField : null;
    });
  }

  /// Nadpisuje granicę [_loadedTaskPlan] aktualną, skorygowaną granicą pola
  /// i przeładowuje ścieżki/pokrycie — jedyna droga do zmiany granicy
  /// istniejącego zadania: zawsze jawna akcja rolnika z banera, nigdy cicho.
  Future<void> _updateTaskBoundaryFromField() async {
    final plan = _loadedTaskPlan;
    final liveField = _staleLiveField;
    if (plan == null || liveField == null) return;

    final boundary = liveField.boundary;
    final updatedPlan = TaskPlan(
      id: plan.id,
      name: plan.name,
      fieldId: plan.fieldId,
      fieldName: plan.fieldName,
      boundaryLats: boundary.map((p) => p.latitude).toList(),
      boundaryLons: boundary.map((p) => p.longitude).toList(),
      lineALat: plan.lineALat,
      lineALon: plan.lineALon,
      lineBLat: plan.lineBLat,
      lineBLon: plan.lineBLon,
      machineId: plan.machineId,
      machineName: plan.machineName,
      machineType: plan.machineType,
      taskType: plan.taskType,
      workingWidthM: plan.workingWidthM,
      overlapM: plan.overlapM,
      headlandLaps: plan.headlandLaps,
      swathAngleDeg: plan.swathAngleDeg,
      targetRate: plan.targetRate,
      tankVolume: plan.tankVolume,
      unit: plan.unit,
      createdAt: plan.createdAt,
    );
    await TaskDatabase.instance.save(updatedPlan);

    setState(() {
      _loadedTaskPlan = updatedPlan;
      _taskBoundaryStale = false;
      _staleLiveField = null;
    });

    // Przeładuj pole/ścieżki/pokrycie na bazie nowej granicy — ta sama
    // ścieżka co przy pierwszym otwarciu zadania z planu.
    await _loadField(liveField, plan: updatedPlan);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: const Text(
          'Zadanie zaktualizowane do nowej granicy pola'),
      backgroundColor: Colors.green[700],
      duration: const Duration(seconds: 3),
    ));
  }

  /// Ukrywa baner nieaktualności bez zmiany zapisanej granicy zadania —
  /// zadanie nadal pracuje na starej migawce do jawnej aktualizacji albo
  /// ponownego otwarcia ekranu.
  void _dismissTaskBoundaryWarning() {
    setState(() => _taskBoundaryStale = false);
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
    // Gdy linia AB jest wyznaczona (stuknięciami lub przejazdem), kierunek
    // pochodzi z niej — suwak staje się tylko podglądem, żeby przypadkowe
    // przeciągnięcie nie zgubiło precyzyjnie wyznaczonego kąta po cichu.
    final hasAbLine = _pointA != null && _pointB != null;

    final action = await showDialog<String>(
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
                hasAbLine
                    ? 'Kierunek ścieżek '
                        '(z linii AB — użyj "Wyczyść AB", aby ustawić ręcznie)'
                    : 'Kierunek ścieżek',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              DegreeAngleInput(
                value: angle,
                enabled: !hasAbLine,
                color: Colors.tealAccent,
                onChanged: (v) => setDlg(() => angle = v),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, null),
                child: const Text('Anuluj')),
            TextButton(
              onPressed:
                  hasAbLine ? null : () => Navigator.pop(ctx, 'optimize'),
              child: const Text('Kierunek wg granicy',
                  style: TextStyle(color: Colors.tealAccent)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.green[700]),
              onPressed: () => Navigator.pop(ctx, 'generate'),
              child: const Text('Generuj'),
            ),
          ],
        ),
      ),
    );

    if (action == null || !mounted) return;

    if (action == 'optimize') {
      setState(() {
        _overlapM = overlap;
        _headlandLaps = laps;
      });
      await _optimizeAndApplySwaths(
        workingWidthM: width,
        overlapM: overlap,
        headlandLaps: laps,
      );
      return;
    }

    setState(() {
      _overlapM = overlap;
      _headlandLaps = laps;
      _swathAngleDeg = angle;
    });
    await _planSwaths(workingWidthM: width);
  }

  /// Uruchamia SwathPlanner::optimizeAngle() (deterministyczny kierunek wg
  /// najdłuższej krawędzi granicy, w tle przez Isolate.run) i od razu
  /// aplikuje gotowy wynik do stanu mapy — identycznie jak [_planSwaths], ale
  /// bez drugiego wywołania FFI (wynik już zawiera gotowy plan).
  Future<void> _optimizeAndApplySwaths({
    required double workingWidthM,
    required double overlapM,
    required int headlandLaps,
  }) async {
    if (_fieldBoundary.length < 3) return;

    setState(() => _optimizingAngle = true);

    final polygon =
        _fieldBoundary.map((ll) => (ll.latitude, ll.longitude)).toList();

    OptimizeAngleResult result;
    try {
      result = await OptimizeAngleBridge.optimizeAsync(
        polygon: polygon,
        workingWidthM: workingWidthM,
        overlapM: overlapM,
        headlandLaps: headlandLaps,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _optimizingAngle = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Błąd optymalizacji kierunku: $e'),
        backgroundColor: Colors.red[800],
        duration: const Duration(seconds: 4),
      ));
      return;
    }

    if (!mounted) return;

    if (result.swaths.isEmpty) {
      setState(() => _optimizingAngle = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Nie znaleziono poprawnego układu ścieżek dla tego pola'),
        backgroundColor: Colors.orange,
      ));
      return;
    }

    final (a, _) = _abFromAngle(result.bestAngleDeg);

    setState(() {
      _rawSwaths = result.swaths;
      _swathOrigin = a;
      _swaths = GeoUtils.offsetSwaths(_rawSwaths, _manualOffsetM);
      _headlandRings = result.headlandRings
          .map((ring) => ring.map((p) => LatLng(p.$1, p.$2)).toList())
          .toList();
      _swathAngleDeg = result.bestAngleDeg;
      _snapInfo = SnapInfo.none;
      _optimizingAngle = false;
    });

    SwathGuidanceBridge.instance.setSwaths(_swaths, a.latitude, a.longitude);
    if (_headlandRings.isNotEmpty) {
      HeadlandGuidanceBridge.instance
          .setRings(_headlandRings, a.latitude, a.longitude);
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
          'Znaleziono: ${result.swathCount} przejazdów (kierunek ${result.bestAngleDeg.toStringAsFixed(2)}°)'),
      backgroundColor: Colors.green[700],
      duration: const Duration(seconds: 4),
    ));
  }

  /// Ustawia [_swathAngleDeg] na precyzyjny wynik SwathPlanner::optimizeAngle()
  /// (C++, kierunek wg najdłuższej krawędzi granicy, dokładność 0.01°) dla
  /// [boundary], z bieżącymi parametrami szerokości/zakładki/uwrocia. Używane
  /// we wszystkich miejscach, gdzie kąt jest ustawiany automatycznie (bez
  /// jawnego kliknięcia "Kierunek wg granicy"). Po niepowodzeniu/pustym
  /// wyniku zostawia poprzednią wartość [_swathAngleDeg] — tak samo jak
  /// przycisk.
  Future<void> _autoSetSwathAngle(List<LatLng> boundary) async {
    if (boundary.length < 3) return;
    final polygon = boundary.map((ll) => (ll.latitude, ll.longitude)).toList();

    OptimizeAngleResult result;
    try {
      result = await OptimizeAngleBridge.optimizeAsync(
        polygon: polygon,
        workingWidthM: _activeWorkingWidth,
        overlapM: _overlapM,
        headlandLaps: _headlandLaps,
      );
    } catch (_) {
      return;
    }
    if (!mounted || result.swaths.isEmpty) return;
    setState(() => _swathAngleDeg = result.bestAngleDeg);
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

    // Preferuj rzeczywistą linię AB (stuknięcia / przejazd) — dostarcza
    // dokładny kierunek. Bez niej, dotychczasowy syntetyczny punkt A/B
    // wokół centroidu granicy, tylko z kąta suwaka.
    final (a, b) = (_pointA != null && _pointB != null)
        ? (_pointA!, _pointB!)
        : _abFromAngle(_swathAngleDeg);
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
      _rawSwaths = result.swaths;
      _swathOrigin = a;
      _swaths = GeoUtils.offsetSwaths(_rawSwaths, _manualOffsetM);
      _headlandRings = result.headlandRings
          .map((ring) => ring.map((p) => LatLng(p.$1, p.$2)).toList())
          .toList();
      _snapInfo = SnapInfo.none;
    });

    // Feed new swaths into the guidance engine
    if (_swaths.isNotEmpty) {
      SwathGuidanceBridge.instance.setSwaths(_swaths, ax, ay);
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

  // ── Ręczne przesunięcie wygenerowanych ścieżek ────────────────────────────

  /// Zmienia [_manualOffsetM] o [deltaCm] (w prawo dodatnie), przelicza
  /// [_swaths] od [_rawSwaths] (planner nigdy nie jest wołany ponownie),
  /// od razu karmi nim [SwathGuidanceBridge] (tak samo jak przy zwykłym
  /// generowaniu) i zapisuje korektę do [_loadedTaskPlan], jeśli zadanie jest
  /// zapisane w SQLite. Wywoływane zarówno z panelu na mapie, jak i (przez
  /// [WorkModeView]'s onOffsetChanged) na żywo w Trybie Pracy.
  void _adjustSwathOffset(int deltaCm) => _setSwathOffsetM(
      double.parse((_manualOffsetM + deltaCm / 100.0).toStringAsFixed(2)));

  void _resetSwathOffset() => _setSwathOffsetM(0.0);

  void _setSwathOffsetM(double newOffsetM) {
    setState(() {
      _manualOffsetM = newOffsetM;
      _swaths = GeoUtils.offsetSwaths(_rawSwaths, _manualOffsetM);
    });
    final origin = _swathOrigin;
    if (origin != null && _swaths.isNotEmpty) {
      SwathGuidanceBridge.instance
          .setSwaths(_swaths, origin.latitude, origin.longitude);
    }
    unawaited(_persistManualOffset());
  }

  /// Zapisuje bieżący [_manualOffsetM] do zadania w SQLite — no-op, gdy
  /// ścieżki zostały wygenerowane bez zapisanego [TaskPlan] (np. pole
  /// ad-hoc bez przejścia przez kreator zadania); wtedy korekta obowiązuje
  /// tylko do zamknięcia ekranu, tak samo jak np. [_overlapM] w tym samym
  /// scenariuszu.
  Future<void> _persistManualOffset() async {
    final plan = _loadedTaskPlan;
    if (plan == null) return;
    final updated = TaskPlan(
      id: plan.id,
      name: plan.name,
      fieldId: plan.fieldId,
      fieldName: plan.fieldName,
      boundaryLats: plan.boundaryLats,
      boundaryLons: plan.boundaryLons,
      lineALat: plan.lineALat,
      lineALon: plan.lineALon,
      lineBLat: plan.lineBLat,
      lineBLon: plan.lineBLon,
      machineId: plan.machineId,
      machineName: plan.machineName,
      machineType: plan.machineType,
      taskType: plan.taskType,
      workingWidthM: plan.workingWidthM,
      overlapM: plan.overlapM,
      headlandLaps: plan.headlandLaps,
      swathAngleDeg: plan.swathAngleDeg,
      manualOffsetM: _manualOffsetM,
      targetRate: plan.targetRate,
      tankVolume: plan.tankVolume,
      unit: plan.unit,
      createdAt: plan.createdAt,
    );
    _loadedTaskPlan = updated;
    await TaskDatabase.instance.save(updated);
  }

  // ── Coverage tracking ────────────────────────────────────────────────────────

  // ── Widok Pracy (WorkMode) ──────────────────────────────────────────────────

  Future<void> _launchWorkMode() async {
    if (_abRecording) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Zakończ nagrywanie linii AB przed wejściem w Tryb Pracy'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

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
            onOffsetStep: _adjustSwathOffset,
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
    // CoverageService jest singletonem współdzielonym z WorkModeView — jego
    // bufor w pamięci jest już aktualny, więc surową powierzchnię materiału
    // odtwarzamy z niego zamiast próbować przekazywać stan między ekranami.
    final liveTrack = CoverageService.instance.currentTrack;
    setState(() {
      _savedTrack = saved;
      _coveredHa = SectionControlBridge.instance.coveredAreaHa();
      _rawMaterialAreaHa =
          GeoUtils.trackSweptAreaHa(liveTrack, _activeWorkingWidth);
      _lastMaterialPos = liveTrack.isNotEmpty ? liveTrack.last : null;
      _trackingCoverage = sessionActive;
    });
  }

  /// Zakończenie aktywnej sesji z bannera "Praca w toku" (mapa).
  /// Tak samo jak "Zakończ pracę" w Trybie Pracy — zapisuje zadanie w
  /// historii (z notatką), zamraża czas i kończy rejestrację pokrycia.
  Future<void> _finishActiveSession() async {
    final session = WorkSessionService.instance;
    // Odczytaj PRZED MaterialMonitorService.stop() (zeruje stan).
    final monitor = MaterialMonitorService.instance;
    final materialConsumed = monitor.isActive ? monitor.totalConsumed : null;
    final materialUnit = monitor.isActive ? monitor.state.unit : null;
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
      materialConsumed: materialConsumed,
      materialUnit: materialUnit,
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
        productivityHaPerHour: info.hectaresPerHour,
        materialConsumed: materialConsumed,
        materialUnit: materialUnit,
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
    _checkTaskBoundaryStaleness();
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
    _checkTaskBoundaryStaleness();
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
    if (!_controlPointsMode && (_abRecording || _boundaryRecording)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_abRecording
              ? 'Zatrzymaj nagrywanie linii AB przed korektą punktami kontrolnymi'
              : 'Zakończ obejście granicy przed korektą punktami kontrolnymi'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    setState(() {
      final turningOn = !_controlPointsMode;
      _clearControlPointsState();
      if (turningOn) {
        _controlPointsMode = true;
        _drawingMode = false;
        _nudgePanelVisible = false;
        _abTapMode = false;
        _abTapPending = null;
      }
    });
  }

  /// Najbliższy punkt na surowej granicy katastralnej (przed CP i offsetem)
  /// w promieniu ~40px ekranu od [tapped], albo `null` gdy brak trafienia.
  ///
  /// Szuka wzdłuż CAŁEJ granicy (każdej krawędzi między kolejnymi
  /// wierzchołkami), nie tylko w samych wierzchołkach — dla korekty
  /// elastycznej (4+ par) punkty kontrolne trzeba móc rozłożyć równomiernie
  /// po całym obwodzie, nie tylko w narożnikach (patrz
  /// [ElasticWarp.densifyRing], który odkształca właśnie te
  /// "międzywierzchołkowe" odcinki). Zwraca punkt
  /// interpolowany liniowo między dwoma najbliższymi wierzchołkami — przy
  /// trafieniu dokładnie w narożnik to po prostu ten wierzchołek (zachowanie
  /// jak dawniej).
  LatLng? _nearestBoundaryPoint(LatLng tapped) {
    final field = _activeField;
    if (field == null || field.boundaryLats.length < 2) return null;
    const thresholdPx = 40.0;
    final tappedPt = _mapController.camera.latLngToScreenPoint(tapped);
    LatLng? best;
    var bestDist = thresholdPx;
    final n = field.boundaryLats.length;
    for (var i = 0; i < n; i++) {
      final a = LatLng(field.boundaryLats[i], field.boundaryLons[i]);
      final b = LatLng(
        field.boundaryLats[(i + 1) % n],
        field.boundaryLons[(i + 1) % n],
      );
      final aPt = _mapController.camera.latLngToScreenPoint(a);
      final bPt = _mapController.camera.latLngToScreenPoint(b);
      final abx = bPt.x - aPt.x;
      final aby = bPt.y - aPt.y;
      final abLenSq = abx * abx + aby * aby;
      var t = 0.0;
      if (abLenSq > 1e-9) {
        t = ((tappedPt.x - aPt.x) * abx + (tappedPt.y - aPt.y) * aby) /
            abLenSq;
        t = t.clamp(0.0, 1.0);
      }
      final projX = aPt.x + t * abx;
      final projY = aPt.y + t * aby;
      final dx = tappedPt.x - projX;
      final dy = tappedPt.y - projY;
      final dist = math.sqrt(dx * dx + dy * dy);
      if (dist < bestDist) {
        bestDist = dist;
        best = LatLng(
          a.latitude + t * (b.latitude - a.latitude),
          a.longitude + t * (b.longitude - a.longitude),
        );
      }
    }
    return best;
  }

  void _handleControlPointTap(LatLng latLng) {
    if (_activeField == null) return;
    if (_cpPendingSource == null) {
      final snapped = _nearestBoundaryPoint(latLng);
      if (snapped == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Stuknij bliżej granicy pola (przerywana pomarańczowa linia)'),
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
  /// Metoda dopasowania jest funkcją samej liczby par — bez ręcznego wyboru
  /// trybu: 2-3 pary → transformacja podobieństwa (jak dotychczas), od
  /// [ElasticWarp.minControlPoints] par → automatyczne przejście na
  /// dopasowanie elastyczne (patrz [ControlPointsPanel] — etykieta metody
  /// aktualizuje się na żywo). Wymaga wywołania wewnątrz `setState`.
  void _updateCpPreview() {
    final field = _activeField;
    if (field == null || _cpPairs.length < 2) {
      _cpPreviewBoundary = [];
      return;
    }
    final origin = field.center;
    if (_cpPairs.length < ElasticWarp.minControlPoints) {
      final src =
          _cpPairs.map((p) => GeoUtils.toEnu(origin, p.source)).toList();
      final tgt =
          _cpPairs.map((p) => GeoUtils.toEnu(origin, p.target)).toList();
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
      return;
    }
    final src =
        _cpPairs.map((p) => GeoUtils.toEnu(origin, p.source)).toList();
    final tgt =
        _cpPairs.map((p) => GeoUtils.toEnu(origin, p.target)).toList();
    final warp = ElasticWarp.fit(src, tgt);
    // Zagęść surowe krawędzie przed transformacją, tak samo jak
    // FieldModel.boundary — inaczej podgląd (proste odcinki między
    // narożnikami) wyglądałby inaczej niż zapisany wynik.
    final rawEnu = ElasticWarp.densifyRing(List.generate(
        field.boundaryLats.length,
        (i) => GeoUtils.toEnu(
            origin, LatLng(field.boundaryLats[i], field.boundaryLons[i]))));
    _cpPreviewBoundary = rawEnu.map((p) {
      final t = warp.transform(p);
      final corrected = GeoUtils.fromEnu(origin, t.e, t.n);
      return LatLng(
        corrected.latitude + field.offsetLat,
        corrected.longitude + field.offsetLon,
      );
    }).toList();
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

  /// Usuwa pojedynczą parę o indeksie [index] — pozwala poprawić jedną
  /// konkretną parę (np. przy korekcie elastycznej z wieloma parami) bez
  /// cofania wszystkich dodanych po niej.
  void _removeCpPair(int index) {
    setState(() {
      _cpPairs.removeAt(index);
      _updateCpPreview();
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
    final updated = _cpPairs.length >= ElasticWarp.minControlPoints
        ? await GeoportalService.instance
            .applyControlPointsElastic(_activeField!, _cpPairs)
        : await GeoportalService.instance
            .applyControlPoints(_activeField!, _cpPairs);
    setState(() {
      _activeField = updated;
      _fieldBoundary
        ..clear()
        ..addAll(updated.boundary);
      _clearControlPointsState();
    });
    _checkTaskBoundaryStaleness();
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
    _checkTaskBoundaryStaleness();
  }

  // ── Wyznaczanie linii AB ─────────────────────────────────────────────────────

  static const double _kMinAbTapDistanceM = 2.0;
  static const int _kMinAbRecordedPoints = 5;
  static const double _kMinAbLineLengthM = 20.0;

  // ── Tryb "2 punkty" ──────────────────────────────────────────────────────────

  void _toggleAbTapMode() {
    if (!_abTapMode) {
      if (_abRecording) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Zatrzymaj nagrywanie linii AB przed wyznaczaniem stuknięciami'),
            backgroundColor: Colors.orange,
          ),
        );
        return;
      }
      setState(() {
        _abTapMode = true;
        _abTapPending = null;
        _controlPointsMode = false;
        _clearControlPointsState();
        _drawingMode = false;
        _nudgePanelVisible = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Dotknij mapy: punkt A (początek linii)')),
      );
    } else {
      setState(() {
        _abTapMode = false;
        _abTapPending = null;
      });
    }
  }

  void _handleAbTap(LatLng latLng) {
    final pending = _abTapPending;
    if (pending == null) {
      setState(() => _abTapPending = latLng);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Dotknij mapy: punkt B (koniec linii)')),
      );
      return;
    }

    final enu = GeoUtils.toEnu(pending, latLng);
    final distanceM = math.sqrt(enu.e * enu.e + enu.n * enu.n);
    if (distanceM < _kMinAbTapDistanceM) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Punkty zbyt blisko siebie — dotknij dalszego miejsca dla punktu B'),
          backgroundColor: Colors.orange,
        ),
      );
      return; // zostań w oczekiwaniu na punkt B
    }

    final headingDeg = GeoUtils.bearing(pending, latLng) % 180.0;
    setState(() {
      _abTapMode = false;
      _abTapPending = null;
    });
    _commitAbLine(pending, latLng, headingDeg, AbSource.manual2Points);
  }

  // ── Tryb "przejazd" ──────────────────────────────────────────────────────────

  void _toggleAbRecording() {
    if (_abRecording) {
      _finalizeAbRecording();
      return;
    }
    if (_drawingMode || _controlPointsMode || _boundaryRecording) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_boundaryRecording
              ? 'Zakończ obejście granicy przed nagrywaniem linii AB'
              : 'Zakończ rysowanie/korektę granicy przed nagrywaniem linii AB'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    setState(() {
      _abRecording = true;
      _abTapMode = false;
      _abTapPending = null;
      _abRecordedPoints.clear();
      _nudgePanelVisible = false;
    });
  }

  /// Wywoływane przez [PopScope], gdy użytkownik próbuje zejść z ekranu w
  /// trakcie nagrywania linii AB (np. gestem "wstecz") — pyta, czy odrzucić
  /// zebrane punkty, zamiast po cichu je tracić.
  Future<void> _handleAbRecordingPopAttempt() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: const Text('Nagrywanie w toku',
            style: TextStyle(color: Colors.white)),
        content: const Text(
          'Trwa nagrywanie linii AB. Wyjście teraz odrzuci zebrane punkty.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Zostań'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red[800]),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Odrzuć i wyjdź'),
          ),
        ],
      ),
    );
    if (discard != true) return;
    _cancelAbRecording();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  void _cancelAbRecording() {
    setState(() {
      _abRecording = false;
      _abRecordedPoints.clear();
    });
  }

  /// Zatrzymuje zbieranie i liczy dopasowanie. Gdy przejazd jest za krótki
  /// albo ma za mało punktów RTK Fixed, NIE przerywa nagrywania — bufor
  /// zostaje, użytkownik może jechać dalej i nacisnąć "Zakończ" ponownie,
  /// zamiast tracić dotychczasowy przejazd.
  Future<void> _finalizeAbRecording() async {
    final points = List<LatLng>.from(_abRecordedPoints);
    final fit = GeoUtils.fitLineThroughPoints(points);

    if (fit == null || points.length < _kMinAbRecordedPoints) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            'Za mało punktów o jakości RTK Fixed (zebrano: ${points.length}, '
            'wymagane min. $_kMinAbRecordedPoints). Sprawdź połączenie z '
            'odbiornikiem RTK i jedź dalej — nagrywanie trwa.'),
        backgroundColor: Colors.red[800],
        duration: const Duration(seconds: 4),
      ));
      return;
    }
    if (fit.lengthM < _kMinAbLineLengthM) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            'Przejazd zbyt krótki (${fit.lengthM.toStringAsFixed(1)} m, '
            'wymagane min. ${_kMinAbLineLengthM.toStringAsFixed(0)} m) — jedź '
            'dalej i spróbuj ponownie.'),
        backgroundColor: Colors.orange,
        duration: const Duration(seconds: 4),
      ));
      return;
    }

    setState(() => _abRecording = false);
    await _showAbRecordingConfirmDialog(fit, pointCount: points.length);
  }

  Future<void> _showAbRecordingConfirmDialog(
    AbLineFit fit, {
    required int pointCount,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: const Text('Linia AB z przejazdu',
            style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Długość odcinka: ${fit.lengthM.toStringAsFixed(1)} m',
                style: const TextStyle(color: Colors.white70, fontSize: 13)),
            const SizedBox(height: 4),
            Text('Kierunek: ${fit.headingDeg.toStringAsFixed(2)}°',
                style: const TextStyle(color: Colors.white70, fontSize: 13)),
            const SizedBox(height: 4),
            Text('Punkty (RTK Fixed): $pointCount',
                style: const TextStyle(color: Colors.white70, fontSize: 13)),
            const SizedBox(height: 4),
            Text(
                'Rozrzut od prostej (RMS): '
                '${(fit.rmsM * 100).toStringAsFixed(1)} cm',
                style: const TextStyle(color: Colors.white70, fontSize: 13)),
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
    );

    if (ok != true || !mounted) return;
    _abRecordedPoints.clear();
    await _commitAbLine(
        fit.pointA, fit.pointB, fit.headingDeg, AbSource.drivenRecording);
  }

  /// Tekst statusu AB pokazywany w panelu "POLE" — jasno mówi, z czego
  /// aktualnie korzysta SwathGuidance, zamiast zmuszać do zgadywania.
  String _abStatusLabel(FieldModel field) {
    if (_pointA == null || _pointB == null) {
      return 'Linia AB: nie ustawiona (używam domyślnej)';
    }
    return switch (field.abSource) {
      AbSource.manual2Points => 'Linia AB: ustawiona (ręcznie)',
      AbSource.drivenRecording => 'Linia AB: ustawiona (przejazd)',
      AbSource.unknown => 'Linia AB: ustawiona (nieznana metoda)',
      AbSource.none => 'Linia AB: ustawiona (nieznana metoda)',
    };
  }

  // ── Wspólny zapis / czyszczenie ──────────────────────────────────────────────

  /// Zapisuje linię AB do tego samego miejsca, gdzie dziś przechowywany jest
  /// kierunek ścieżek dla SwathGuidance — [FieldModel.lineALat]/[lineALon]/
  /// [lineBLat]/[lineBLon] — niezależnie od tego, czy pochodzi ze stuknięć,
  /// czy z dopasowania po przejeździe.
  Future<void> _commitAbLine(
    LatLng a,
    LatLng b,
    double headingDeg,
    AbSource source,
  ) async {
    setState(() {
      _pointA = a;
      _pointB = b;
      _swathAngleDeg = headingDeg;
    });
    NavBridge.instance
        .setAbLine(a.latitude, a.longitude, b.latitude, b.longitude);

    final field = _activeField;
    if (field != null) {
      field
        ..lineALat = a.latitude
        ..lineALon = a.longitude
        ..lineBLat = b.latitude
        ..lineBLon = b.longitude
        ..abSource = source;
      await FieldService.instance.save(field);
      if (!mounted) return;
      setState(() => _savedFields = FieldService.instance.getAll());
    }

    // Od razu pokaż efekt na mapie — bez dodatkowego "Generuj".
    if (_fieldBoundary.length >= 3) {
      await _planSwaths(workingWidthM: _activeWorkingWidth);
    }
  }

  Future<void> _clearAbLine() async {
    final field = _activeField;
    setState(() {
      _pointA = null;
      _pointB = null;
      _abTapMode = false;
      _abTapPending = null;
      _abRecording = false;
      _abRecordedPoints.clear();
    });
    NavBridge.instance.resetAbLine();
    await _autoSetSwathAngle(_fieldBoundary);
    if (!mounted) return;

    if (field != null) {
      field
        ..lineALat = null
        ..lineALon = null
        ..lineBLat = null
        ..lineBLon = null
        ..abSource = AbSource.none;
      await FieldService.instance.save(field);
      if (!mounted) return;
      setState(() => _savedFields = FieldService.instance.getAll());
    }

    if (_fieldBoundary.length >= 3) {
      await _planSwaths(workingWidthM: _activeWorkingWidth);
    }
  }

  // ── Tworzenie granicy przez obejście/przejazd RTK ───────────────────────────

  /// Odległość [m] między dwoma punktami w lokalnym ENU — używana tylko do
  /// decymacji wejścia podczas nagrywania obejścia (patrz [_onGpsPosition]).
  double _enuDistanceM(LatLng a, LatLng b) {
    final d = GeoUtils.toEnu(a, b);
    return math.sqrt(d.e * d.e + d.n * d.n);
  }

  /// Tekst statusu pokazywany w panelu "POLE" podczas nagrywania obejścia —
  /// analogiczny do [_abStatusLabel], aktualizowany na każdą klatkę GPS.
  String _boundaryWalkStatusLabel() {
    final n = _boundaryRecordedPoints.length;
    final areaHa =
        n >= 3 ? GeoUtils.polygonAreaHa(_boundaryRecordedPoints) : 0.0;
    final areaPart =
        areaHa > 0 ? ' • ok. ${areaHa.toStringAsFixed(2)} ha' : '';
    return 'Obejście: $n pkt (Fixed $_boundaryFixedCount, '
        'Float $_boundaryFloatCount)$areaPart';
  }

  void _toggleBoundaryWalk() {
    if (_boundaryRecording) {
      _finalizeBoundaryWalk();
      return;
    }
    if (_drawingMode || _abRecording || _controlPointsMode) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('Zakończ rysowanie/korektę granicy przed obejściem pola'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    setState(() {
      _boundaryRecording = true;
      _boundaryRecordedPoints.clear();
      _boundaryFixedCount = 0;
      _boundaryFloatCount = 0;
      // Ten tryb zawsze tworzy NOWE pole — ta sama zasada co przy "Rysuj":
      // nie powinien dziedziczyć aktywnego pola/AB/ścieżek z poprzedniego.
      _clearControlPointsState();
      _abTapMode = false;
      _abTapPending = null;
      _pointA = null;
      _pointB = null;
      NavBridge.instance.resetAbLine();
      _fieldBoundary.clear();
      _swaths = [];
      _rawSwaths = [];
      _swathOrigin = null;
      _manualOffsetM = 0.0;
      _headlandRings = [];
      _snapInfo = SnapInfo.none;
      _activeField = null;
      _nudgePanelVisible = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
            'Nagrywanie granicy rozpoczęte — obejdź/objedź pole i wróć '
            'blisko punktu startowego, potem naciśnij "Zakończ".'),
        backgroundColor: Colors.blueGrey,
        duration: Duration(seconds: 4),
      ),
    );
  }

  /// Wywoływane przez [PopScope], gdy użytkownik próbuje zejść z ekranu w
  /// trakcie obejścia granicy (np. gestem "wstecz") — pyta, czy odrzucić
  /// zebrane punkty, zamiast po cichu je tracić (patrz
  /// [_handleAbRecordingPopAttempt]).
  Future<void> _handleBoundaryWalkPopAttempt() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title:
            const Text('Obejście w toku', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Trwa nagrywanie granicy pola. Wyjście teraz odrzuci zebrane punkty.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Zostań'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red[800]),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Odrzuć i wyjdź'),
          ),
        ],
      ),
    );
    if (discard != true) return;
    _cancelBoundaryWalk();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  void _cancelBoundaryWalk() {
    setState(() {
      _boundaryRecording = false;
      _boundaryRecordedPoints.clear();
      _boundaryFixedCount = 0;
      _boundaryFloatCount = 0;
    });
  }

  /// Zatrzymuje zbieranie i waliduje trasę. Gdy punktów jest za mało albo
  /// zamknięta pętla ma zbyt mały obszar, NIE przerywa nagrywania — bufor
  /// zostaje, użytkownik idzie/jedzie dalej i naciska "Zakończ" ponownie
  /// (ten sam wzorzec co [_finalizeAbRecording]).
  Future<void> _finalizeBoundaryWalk() async {
    final points = List<LatLng>.from(_boundaryRecordedPoints);

    if (points.length < _kMinBoundaryRecordedPoints) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            'Za mało punktów o jakości RTK Fixed/Float (zebrano: '
            '${points.length}, wymagane min. $_kMinBoundaryRecordedPoints). '
            'Sprawdź połączenie z odbiornikiem RTK i idź dalej — '
            'nagrywanie trwa.'),
        backgroundColor: Colors.red[800],
        duration: const Duration(seconds: 4),
      ));
      return;
    }

    final rawAreaHa = GeoUtils.polygonAreaHa(points);
    if (rawAreaHa < _kMinBoundaryAreaHa) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            'Trasa nie tworzy jeszcze zamkniętej pętli o sensownym '
            'obszarze (${(rawAreaHa * 10000).toStringAsFixed(0)} m²) — '
            'obejdź dalej granicę pola i spróbuj ponownie.'),
        backgroundColor: Colors.orange,
        duration: const Duration(seconds: 4),
      ));
      return;
    }

    final closeGapM = _enuDistanceM(points.first, points.last);

    setState(() => _boundaryRecording = false);
    await _showBoundaryWalkConfirmDialog(points, closeGapM);
  }

  /// Upraszcza surową trasę przez [LpisProcessorBridge] (union + RDP —
  /// ten sam natywny procesor geometrii co import LPIS, wywołany z jednym
  /// wielokątem i `bufferM: 0.0`, bez buforowania) i pyta o nazwę pola przed
  /// zapisem. Odrzucenie NIE czyści bufora nagrania — spójnie z
  /// [_showAbRecordingConfirmDialog].
  Future<void> _showBoundaryWalkConfirmDialog(
    List<LatLng> rawPoints,
    double closeGapM,
  ) async {
    MergeFieldResult result;
    try {
      result = await LpisProcessorBridge.instance.processAsync(
        [rawPoints],
        bufferM: 0.0,
        simplifyEpsilonM: _kBoundarySimplifyEpsilonM,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Błąd przetwarzania granicy: $e'),
        backgroundColor: Colors.red[800],
      ));
      return;
    }
    if (!mounted) return;

    final boundary = result.primaryBoundary;
    if (boundary.length < 3) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Przetwarzanie geometrii nie zwróciło poprawnej granicy — '
              'spróbuj obejść pole ponownie.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final nameCtrl = TextEditingController(
        text: 'Pole (obejście) ${FieldService.instance.getAll().length + 1}');
    final areaHa = GeoUtils.polygonAreaHa(boundary);

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: const Text('Granica z obejścia RTK',
            style: TextStyle(color: Colors.white)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: nameCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Nazwa pola',
                  labelStyle: TextStyle(color: Colors.white54),
                  enabledBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Colors.white38)),
                  focusedBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Colors.greenAccent)),
                ),
              ),
              const SizedBox(height: 14),
              Text('Powierzchnia: ${areaHa.toStringAsFixed(2)} ha',
                  style: const TextStyle(color: Colors.white70, fontSize: 13)),
              const SizedBox(height: 4),
              Text(
                  'Punkty RTK: ${rawPoints.length} '
                  '(Fixed: $_boundaryFixedCount, Float: $_boundaryFloatCount)',
                  style: const TextStyle(color: Colors.white70, fontSize: 13)),
              const SizedBox(height: 4),
              Text(
                  'Wierzchołki: ${rawPoints.length} → ${boundary.length} '
                  '(uproszczenie RDP, ε=${_kBoundarySimplifyEpsilonM.toStringAsFixed(2)} m)',
                  style: const TextStyle(color: Colors.white70, fontSize: 13)),
              if (closeGapM > _kBoundaryCloseWarnM) ...[
                const SizedBox(height: 8),
                Text(
                    '⚠ Pętla nie została w pełni domknięta (rozstaw '
                    '${closeGapM.toStringAsFixed(0)} m) — granica zostanie '
                    'automatycznie domknięta linią prostą między punktem '
                    'startowym i końcowym.',
                    style: const TextStyle(
                        color: Colors.orangeAccent, fontSize: 12)),
              ],
              if (result.isMultipart) ...[
                const SizedBox(height: 8),
                const Text(
                    '⚠ Trasa się przecięła — użyto największego wykrytego '
                    'obszaru. Sprawdź podgląd przed zapisem.',
                    style:
                        TextStyle(color: Colors.orangeAccent, fontSize: 12)),
              ],
            ],
          ),
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
    );

    if (ok != true || !mounted) {
      nameCtrl.dispose();
      return;
    }
    final rawName = nameCtrl.text.trim();
    nameCtrl.dispose();

    _boundaryRecordedPoints.clear();
    _boundaryFixedCount = 0;
    _boundaryFloatCount = 0;

    final field = FieldModel(
      id: const Uuid().v4(),
      name: rawName.isEmpty ? 'Pole (obejście)' : rawName,
      boundaryLats: boundary.map((p) => p.latitude).toList(),
      boundaryLons: boundary.map((p) => p.longitude).toList(),
      source: FieldSource.walked,
      areaHa: areaHa,
    );
    await FieldService.instance.save(field);
    if (!mounted) return;

    await _loadField(field);
    if (!mounted) return;
    setState(() => _savedFields = FieldService.instance.getAll());
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
          if (_activeField != null) ...[
            Text(
              _abStatusLabel(_activeField!),
              style: TextStyle(
                color: _pointA != null ? Colors.greenAccent : Colors.white54,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
          ],
          if (_boundaryRecording) ...[
            Text(
              _boundaryWalkStatusLabel(),
              style: const TextStyle(
                color: Colors.greenAccent,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
          ],
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
                  _activeField!.correctionMode != FieldCorrectionMode.none)
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
                icon: _boundaryRecording
                    ? Icons.flag_circle_outlined
                    : Icons.directions_walk,
                label: _boundaryRecording ? 'Zakończ' : 'Obejdź pole',
                tooltip: _boundaryRecording
                    ? 'Zakończ obejście i zapisz granicę'
                    : 'Najdokładniejsza metoda — obejdź granicę pola pieszo '
                        'lub maszyną z aktywnym modułem RTK',
                isActive: _boundaryRecording,
                onPressed: _toggleBoundaryWalk,
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
              if (_rawSwaths.isNotEmpty)
                _ActionTile(
                  icon: Icons.swap_horiz,
                  label: 'Przesuń',
                  tooltip: 'Przesuń wygenerowane ścieżki w bok (cm)',
                  isActive: _swathOffsetPanelVisible || _manualOffsetM != 0.0,
                  onPressed: () => setState(
                      () => _swathOffsetPanelVisible = !_swathOffsetPanelVisible),
                ),
              if (_activeField != null)
                _ActionTile(
                  icon: Icons.touch_app_outlined,
                  label: 'AB: 2 punkty',
                  tooltip: 'Wyznacz linię AB stuknięciami na mapie (szybkie, '
                      'dla wąskich maszyn)',
                  isActive: _abTapMode,
                  onPressed: _toggleAbTapMode,
                ),
              if (_activeField != null)
                _ActionTile(
                  icon: Icons.route_outlined,
                  label: 'AB: przejazd',
                  tooltip: 'Wyznacz linię AB z rzeczywistego przejazdu RTK '
                      '(precyzyjne, dla szerokich maszyn)',
                  isActive: _abRecording,
                  onPressed: _toggleAbRecording,
                ),
              if (_pointA != null)
                _ActionTile(
                  icon: Icons.clear,
                  label: 'Wyczyść AB',
                  tooltip: 'Usuń wyznaczoną linię AB (wróć do kąta auto)',
                  onPressed: _clearAbLine,
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
                    const Padding(
                      padding: EdgeInsets.only(top: 10),
                      child: Text(
                        'Ile jest zatankowane, ustawisz na starcie Trybu Pracy.',
                        style: TextStyle(color: Colors.white38, fontSize: 12),
                      ),
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
        // JPEG zamiast PNG — warstwa jest nieprzezroczysta (transparent: false),
        // więc kompresja bezstratna PNG nie ma tu żadnej zalety, a kafelki
        // zdjęć lotniczych w JPEG są kilkukrotnie mniejsze (potwierdzone
        // wsparcie w GetCapabilities serwera ORTO/WMS/HighResolution).
        format: 'image/jpeg',
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

  /// Najmniejsza różnica kątowa między dwoma kursami (0–360°), wynik w [0, 180].
  static double _headingDiff(double a, double b) {
    final d = (a - b).abs() % 360.0;
    return d > 180.0 ? 360.0 - d : d;
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Nagrywanie linii AB / obejścia granicy trwa zwykle kilka minut
      // fizycznego przejazdu — przypadkowe zejście z ekranu (gest "wstecz")
      // nie powinno po cichu gubić zebranych punktów.
      canPop: !_abRecording && !_boundaryRecording,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_abRecording) {
          _handleAbRecordingPopAttempt();
        } else if (_boundaryRecording) {
          _handleBoundaryWalkPopAttempt();
        }
      },
      child: Scaffold(
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
                if (_abTapMode) {
                  _handleAbTap(latLng);
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

              // ── Linia AB — nagrywanie na żywo (tryb "przejazd") ─────────────
              if (_abRecording && _abRecordedPoints.length >= 2)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _abRecordedPoints,
                      color: Colors.pinkAccent.withValues(alpha: 0.55),
                      strokeWidth: 3.0,
                    ),
                  ],
                ),

              // ── Granica pola — obejście RTK, nagrywanie na żywo ─────────────
              if (_boundaryRecording && _boundaryRecordedPoints.length >= 2)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _boundaryRecordedPoints,
                      color: Colors.greenAccent,
                      strokeWidth: 3.5,
                    ),
                    // Podgląd domknięcia pętli — pokazuje, jaki kształt
                    // przyjmie granica, gdyby użytkownik zakończył teraz.
                    if (_boundaryRecordedPoints.length >= 3)
                      Polyline(
                        points: [
                          _boundaryRecordedPoints.last,
                          _boundaryRecordedPoints.first,
                        ],
                        color: Colors.greenAccent.withValues(alpha: 0.45),
                        strokeWidth: 2.0,
                        pattern:
                            StrokePattern.dashed(segments: const [6, 6]),
                      ),
                  ],
                ),

              // ── Linia AB — zatwierdzona (stuknięcia lub przejazd) ───────────
              if (_pointA != null && _pointB != null)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: [_pointA!, _pointB!],
                      color: Colors.pinkAccent,
                      strokeWidth: 2.5,
                    ),
                  ],
                ),
              if ((_pointA != null && _pointB != null) ||
                  _abTapPending != null)
                CircleLayer(
                  circles: [
                    if (_pointA != null)
                      CircleMarker(
                        point: _pointA!,
                        radius: 6,
                        color: Colors.pinkAccent,
                        borderColor: Colors.white,
                        borderStrokeWidth: 1.5,
                      ),
                    if (_pointB != null)
                      CircleMarker(
                        point: _pointB!,
                        radius: 6,
                        color: Colors.purpleAccent,
                        borderColor: Colors.white,
                        borderStrokeWidth: 1.5,
                      ),
                    if (_abTapPending != null)
                      CircleMarker(
                        point: _abTapPending!,
                        radius: 7,
                        color: Colors.pinkAccent,
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

          // ── Wskaźnik trwającej optymalizacji kierunku ścieżek ─────────────────
          if (_optimizingAngle)
            Positioned(
              top: 80,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2A2A2A),
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: const [
                      BoxShadow(color: Colors.black45, blurRadius: 8),
                    ],
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.tealAccent),
                      ),
                      SizedBox(width: 10),
                      Text('Szukam optymalnego kierunku…',
                          style: TextStyle(color: Colors.white)),
                    ],
                  ),
                ),
              ),
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

          // ── Panel ręcznego przesunięcia wygenerowanych ścieżek ───────────────
          if (_swathOffsetPanelVisible && _rawSwaths.isNotEmpty)
            Positioned(
              left: 12,
              bottom: 200,
              child: _SwathOffsetPanel(
                offsetCm: (_manualOffsetM * 100).round(),
                onStep: _adjustSwathOffset,
                onReset: _resetSwathOffset,
                onClose: () =>
                    setState(() => _swathOffsetPanelVisible = false),
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
                onRemovePair: _removeCpPair,
                onCancel: _cancelControlPoints,
                onConfirm: _confirmControlPoints,
              ),
            ),

          // ── Panel nagrywania linii AB (tryb "przejazd") ───────────────────────
          if (_abRecording)
            Positioned(
              left: 12,
              bottom: 200,
              child: AbRecordingPanel(
                pointCount: _abRecordedPoints.length,
                lengthM: _abRecordedPoints.length >= 2
                    ? GeoUtils.fitLineThroughPoints(_abRecordedPoints)
                        ?.lengthM
                    : null,
                fixStatus: GpsLocationService.instance.fixStatus,
                onStop: _finalizeAbRecording,
                onCancel: _cancelAbRecording,
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

          // ── Nieaktualna granica zadania + Praca w toku (banery w tle) ───────
          if (_taskBoundaryStale ||
              (_activeField != null &&
                  _activeField!.id == WorkSessionService.instance.fieldId))
            Positioned(
              left: 16,
              right: 16,
              bottom: 24,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_taskBoundaryStale) ...[
                    _StaleTaskBoundaryBanner(
                      onUpdate: _updateTaskBoundaryFromField,
                      onDismiss: _dismissTaskBoundaryWarning,
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (_activeField != null &&
                      _activeField!.id == WorkSessionService.instance.fieldId)
                    _ActiveWorkBanner(
                      fieldName: _activeField!.name,
                      onResume: _launchWorkMode,
                      onFinish: _finishActiveSession,
                    ),
                ],
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
// Banner nieaktualności granicy zadania — korekta zmieniona po jego utworzeniu
// ═══════════════════════════════════════════════════════════════════════════════

/// Ostrzega, że zapisana w zadaniu granica (migawka z chwili utworzenia)
/// różni się od aktualnej, skorygowanej granicy pola — rolnik dodał/zmienił
/// punkty kontrolne już PO utworzeniu tego zadania. Aktualizacja jest zawsze
/// jawną akcją ("Aktualizuj") — nigdy cichą, żeby nie przesunąć geometrii
/// zadania (i już zebranego pokrycia terenu) w trakcie pracy bez wiedzy
/// operatora.
class _StaleTaskBoundaryBanner extends StatelessWidget {
  const _StaleTaskBoundaryBanner({
    required this.onUpdate,
    required this.onDismiss,
  });

  final VoidCallback onUpdate;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xEE3A2A00),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.orangeAccent.withValues(alpha: 0.7)),
        boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 10)],
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded,
              color: Colors.orangeAccent, size: 22),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'Granica pola zmieniła się od utworzenia tego zadania '
              '(korekta punktami kontrolnymi). Prowadzenie i ścieżki wciąż '
              'bazują na starej granicy.',
              style: TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: onUpdate,
            style: TextButton.styleFrom(
              foregroundColor: Colors.orangeAccent,
              padding: const EdgeInsets.symmetric(horizontal: 10),
            ),
            child: const Text('Aktualizuj',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          IconButton(
            tooltip: 'Zamknij',
            visualDensity: VisualDensity.compact,
            color: Colors.white54,
            onPressed: onDismiss,
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
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

// ── Panel ręcznego przesunięcia wygenerowanych ścieżek (offset boczny) ────────
//
// W przeciwieństwie do _ManualOffsetPanel powyżej: przesuwa SAME wygenerowane
// ścieżki (prostopadle do kierunku jazdy), nie warstwę LPIS. Wartość jest
// zapisywana do TaskPlan.manualOffsetM (patrz _persistManualOffset) — ma
// przetrwać zamknięcie/otwarcie zadania, w odróżnieniu od kalibracji LPIS.
class _SwathOffsetPanel extends StatelessWidget {
  const _SwathOffsetPanel({
    required this.offsetCm,
    required this.onStep,
    required this.onReset,
    required this.onClose,
  });

  /// Bieżące przesunięcie w cm (+ = w prawo względem kierunku jazdy).
  final int offsetCm;
  final void Function(int deltaCm) onStep;
  final VoidCallback onReset;
  final VoidCallback onClose;

  static const _stepCm = 5;

  @override
  Widget build(BuildContext context) {
    final hasOffset = offsetCm != 0;
    final label = offsetCm == 0
        ? '0 cm'
        : offsetCm > 0
            ? '$offsetCm cm →'
            : '${-offsetCm} cm ←';
    return Container(
      width: 150,
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
          Row(
            children: [
              const Icon(Icons.swap_horiz, color: Colors.tealAccent, size: 13),
              const SizedBox(width: 4),
              const Expanded(
                child: Text(
                  'Przesuń ścieżki',
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
          Text(
            label,
            style: TextStyle(
              color: hasOffset ? Colors.orangeAccent : Colors.white38,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _ArrowButton(
                icon: Icons.keyboard_arrow_left_rounded,
                tooltip: 'Przesuń w lewo o $_stepCm cm',
                onTap: () => onStep(-_stepCm),
              ),
              const SizedBox(width: 4),
              _ArrowButton(
                icon: Icons.restart_alt,
                tooltip: 'Wyzeruj przesunięcie',
                onTap: onReset,
                color: hasOffset ? Colors.orangeAccent : Colors.white24,
              ),
              const SizedBox(width: 4),
              _ArrowButton(
                icon: Icons.keyboard_arrow_right_rounded,
                tooltip: 'Przesuń w prawo o $_stepCm cm',
                onTap: () => onStep(_stepCm),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            '1 krok = $_stepCm cm',
            style: TextStyle(color: Colors.white24, fontSize: 8.5),
          ),
        ],
      ),
    );
  }
}

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
