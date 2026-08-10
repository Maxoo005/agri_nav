import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:uuid/uuid.dart';

import '../ffi/nav_bridge.dart';
import '../models/history_record.dart';
import '../models/work_task.dart';
import '../services/coverage_service.dart';
import '../services/gps_location_service.dart';
import '../services/history_database.dart';
import '../services/machine_service.dart';
import '../services/material_monitor_service.dart';
import '../services/work_mode_settings_service.dart';
import '../services/work_session_service.dart';
import '../services/work_task_service.dart';
import '../utils/geo_utils.dart';
import 'finish_work_dialog.dart';

// ── Paleta kolorów Work Mode ──────────────────────────────────────────────────
const _kBg = Color(0xFF0A0A0A);
const _kGrid = Color(0x0CFFFFFF);
const _kBoundary = Color(0x55FFFFFF);
const _kHeadland = Color(0x55FF9800);
const _kActiveHeadland = Color(0xFFFF9800); // pomarańcz bez transparentności
const _kSwath = Color(0x55E0E0E0);
const _kActiveSwath = Color(0xFFFFD600);
const _kCoverage = Color(0x5500BCD4);

/// Tryb prowadzenia maszyny.
enum _GuidanceMode { swath, headland }

// ─────────────────────────────────────────────────────────────────────────────
// WorkModeView — minimalistyczny widok prowadzenia geometrycznego
// ─────────────────────────────────────────────────────────────────────────────

/// Pełnoekranowy widok pracy zastępujący mapę satelitarną czystą geometrią pola.
///
/// Przejmuje [GnssSimulatorBridge.onPosition] w [initState] i przywraca
/// poprzedni callback (MapView) w [dispose].
class WorkModeView extends StatefulWidget {
  const WorkModeView({
    super.key,
    required this.swaths,
    required this.headlandRings,
    required this.fieldBoundary,
    required this.initialSnapInfo,
    required this.initialCoveredHa,
    required this.initialPos,
    required this.initialHeading,
    required this.workingWidthM,
    this.fieldId,
    this.fieldName,
    this.activeTask,
    this.machineName,
    this.overlapM = 0.0,
    this.swathAngleDeg = 0.0,
  });

  /// Równoległe ścieżki uprawowe z C++ SwathPlanner.
  final List<Swath> swaths;

  /// Pierścienie uwrociowe — każdy to zamknięty wielokąt.
  final List<List<LatLng>> headlandRings;

  /// Wektorowa granica pola (≥ 3 punkty).
  final List<LatLng> fieldBoundary;

  final SnapInfo initialSnapInfo;
  final double initialCoveredHa;
  final LatLng initialPos;
  final double initialHeading;

  /// Szerokość robocza maszyny [m] — do wizualizacji śladu pokrycia.
  final double workingWidthM;

  /// Identyfikator pola w Hive (null = brak aktywnego pola).
  final String? fieldId;

  /// Nazwa pola — do zapisu historii po zakończeniu pracy.
  final String? fieldName;

  /// Aktywne zadanie robocze — używane do monitorowania zużycia materiału.
  /// Null = monitorowanie wyłączone.
  final WorkTask? activeTask;

  /// Nazwa maszyny (migawka) — do zapisu historii.
  final String? machineName;

  /// Zakładka (overlap) między przejściami [m] — do zapisu historii.
  final double overlapM;

  /// Kierunek ścieżek (azymut) [°] — do zapisu historii.
  final double swathAngleDeg;

  @override
  State<WorkModeView> createState() => _WorkModeViewState();
}

class _WorkModeViewState extends State<WorkModeView> {
  // ── Obrót mapy (Work Mode) ───────────────────────────────────────────────────
  /// Próg prędkości do odblokowania obrotu CAŁEJ MAPY — wyższy niż
  /// [GpsLocationService.kMinHeadingSpeedMs], które bramkuje sam heading
  /// używany przez prowadzenie/cross-track ([_tractorHeading] poniżej).
  /// Obrót pełnego ekranu wzmacnia szum headingu wizualnie dużo bardziej niż
  /// drganie samego wskaźnika (efekt geometryczny — im dalej od środka
  /// obrotu, tym większe przesunięcie piksela przy tym samym błędzie kąta),
  /// więc mapa zamraża się "wcześniej", dopiero przy jednoznacznym ruchu
  /// (~3.6 km/h, żwawy chód) zamiast przy progu prowadzenia (~1.8 km/h).
  static const double kMinMapRotationSpeedMs = 1.0;

  /// Współczynnik EMA (kołowego — na wektorze jednostkowym (cos θ, sin θ),
  /// bo heading zawija się na 0°/360°, co psuje zwykły EMA na stopniach) dla
  /// kąta obrotu mapy. Mocniejsze wygładzanie niż EMA pozycji w
  /// [GpsLocationService] (α=0.3) i nieskończenie mocniejsze niż dzisiejszy
  /// surowy heading (zero wygładzania). Przy ~100 ms tickach strumienia GPS
  /// daje to stałą czasową ~0.8 s — zauważalnie spokojniej niż dziś, ale
  /// realny, trwały skręt maszyny nadal "dogania" mapę w ok. sekundę.
  static const double _kMapRotationEmaAlpha = 0.12;

  // ── Dynamic state ────────────────────────────────────────────────────────────
  late LatLng _tractorPos;
  late double _tractorHeading;

  /// Kąt faktycznie przekazywany do [_FieldCanvasPainter] jako obrót kanwy —
  /// CELOWO osobny od [_tractorHeading] (który zasila prowadzenie/cross-track
  /// i pozostaje nietknięty). Aktualizowany własnym, mocniejszym EMA i własną
  /// (wyższą) bramką prędkości — patrz stałe wyżej.
  double _mapRotationDeg = 0.0;
  double? _mapRotationEmaX;
  double? _mapRotationEmaY;

  /// Tryb orientacji mapy — zapamiętany w Hive przez [WorkModeSettingsService].
  MapOrientationMode _orientationMode = MapOrientationMode.headingUp;
  // Not part of setState — updated directly in _onSimPosition.
  // Used only as the one-time `initial` value for Lightbar; live updates
  // are delivered via _deviationCtrl stream, so no rebuild is needed here.
  double _crossTrack = 0.0;
  bool _guidanceValid = false;
  late StreamController<_DeviationSnapshot> _deviationCtrl;
  late SnapInfo _snapInfo;

  // ── Tryb prowadzenia ─────────────────────────────────────────────────────────
  _GuidanceMode _guidanceMode = _GuidanceMode.swath;

  /// Indeks aktywnego pierścienia uwrocia (−1 = brak). Używany do podświetlenia
  /// na kanwie i jest ustawiany w trybie headland po każdym query().
  int _activeHeadlandRingIndex = -1;

  // ── Wstrzymanie pracy ────────────────────────────────────────────────────────
  /// Pochodzi z [WorkSessionService] — wstrzymanie działa także w tle
  /// (serwis przeżywa opuszczenie tego ekranu).
  bool get _isPaused => WorkSessionService.instance.paused;

  /// Ręczny wyłącznik maszyny (patrz [WorkSessionService.machineOff]) — w
  /// odróżnieniu od pauzy NIE zatrzymuje czasu pracy ani nawigacji, tylko
  /// malowanie śladu i zużycie materiału.
  bool get _machineOff => WorkSessionService.instance.machineOff;

  /// Pozycje GPS zapisane w momencie wstrzymania — wyświetlane jako znaczniki
  /// uzupełnienia materiału na kanwie pola.
  final List<LatLng> _pauseMarkers = [];

  /// Powierzchnia pola [ha] (z geometrii granicy) — do wyświetlania postępu
  /// "zrobione / całe pole".
  late double _fieldAreaHa;

  /// Czas pracy z [WorkSessionService] — odświeżany co sekundę przez strumień.
  Duration _workElapsed = Duration.zero;
  StreamSubscription<Duration>? _sessionSub;

  late double _coveredHa;
  double _speedKmh = 0.0;
  double _overlapFraction = 0.0;

  /// Surowa (nie-zdeduplikowana) powierzchnia dla liczenia zużycia materiału —
  /// patrz [GeoUtils.trackSweptAreaHa]. Nakładki liczą się tu ponownie, w
  /// przeciwieństwie do [_coveredHa].
  double _rawMaterialAreaHa = 0.0;
  LatLng? _lastMaterialPos;

  // ── Material monitor ─────────────────────────────────────────────────────────
  MaterialMonitorState _monitorState = MaterialMonitorState.empty;
  StreamSubscription<MaterialMonitorState>? _monitorSub;

  /// Prevent repeated low-level alerts within the same work session.
  bool _lowAlertShown = false;

  LatLng? _prevPos;
  DateTime? _prevTime;

  /// Subscription to the unified GPS stream.
  StreamSubscription<SimPosition>? _gpsSub;

  /// Jakość fixa do kafelka GPS w [_StatsPanel] — aktualizowana niezależnie
  /// od pozycji (patrz [GpsLocationService.fixStatusStream]), więc badge
  /// pokazuje np. "Szukanie…" nawet gdy chwilowo brak nowych współrzędnych.
  GpsFixStatus _fixStatus = GpsLocationService.instance.fixStatus;
  StreamSubscription<GpsFixStatus>? _fixStatusSub;

  /// Skala widoku: pikseli na metr (zarządzana gestem pinch-to-zoom).
  double _pixelsPerMeter = 5.0;

  @override
  void initState() {
    super.initState();
    _tractorPos = widget.initialPos;
    _tractorHeading = widget.initialHeading;
    _mapRotationDeg = widget.initialHeading;
    final initRad = widget.initialHeading * math.pi / 180.0;
    _mapRotationEmaX = math.cos(initRad);
    _mapRotationEmaY = math.sin(initRad);
    _orientationMode = WorkModeSettingsService.instance.orientationMode;
    _snapInfo = widget.initialSnapInfo;
    _coveredHa = widget.initialCoveredHa;
    _fieldAreaHa = GeoUtils.polygonAreaHa(widget.fieldBoundary);
    _deviationCtrl = StreamController<_DeviationSnapshot>.broadcast();

    // CoverageService jest singletonem (współdzielony z MapView) — jego
    // bufor w pamięci jest już wczytany/aktualny w tym momencie (MapView
    // woła startTracking() przed wejściem w Tryb Pracy), więc surową
    // powierzchnię materiału odtwarzamy z niego.
    final liveTrack = CoverageService.instance.currentTrack;
    _rawMaterialAreaHa =
        GeoUtils.trackSweptAreaHa(liveTrack, widget.workingWidthM);
    _lastMaterialPos = liveTrack.isNotEmpty ? liveTrack.last : null;

    // Sesja pracy działa w tle: wznawia/przypina istniejącą albo startuje
    // nową. Timer biegnie w serwisie niezależnie od tego ekranu.
    if (widget.fieldId != null) {
      WorkSessionService.instance.start(
        fieldId: widget.fieldId!,
        task: widget.activeTask,
      );
      _workElapsed = WorkSessionService.instance.elapsed;
      _sessionSub = WorkSessionService.instance.stream.listen((d) {
        if (mounted) setState(() => _workElapsed = d);
      });
    }

    // Start material monitor if task has rate/tank data
    if (widget.activeTask != null) {
      MaterialMonitorService.instance
          .start(widget.activeTask!, currentAreaHa: _rawMaterialAreaHa);
      _monitorState = MaterialMonitorService.instance.state;
      _monitorSub = MaterialMonitorService.instance.stream.listen((s) {
        if (!mounted) return;
        setState(() => _monitorState = s);
        // Low-level alert: below 10%
        if (!_lowAlertShown && s.fillFraction < 0.10 && s.fillFraction > 0) {
          _lowAlertShown = true;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Row(
                children: [
                  Icon(Icons.warning_amber_rounded,
                      color: Colors.white, size: 20),
                  SizedBox(width: 8),
                  Text('Uwaga: Niski poziom w zbiorniku!'),
                ],
              ),
              backgroundColor: Colors.red[800],
              duration: const Duration(seconds: 5),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      });
      // Dawka ustawiona, ale nie wiadomo jeszcze ile jest zatankowane (nowe
      // podejście: poziom zbiornika ustawia się na starcie Trybu Pracy, nie
      // przy tworzeniu zadania) — zapytaj operatora zanim ruszy.
      if (widget.activeTask!.targetRate != null &&
          widget.activeTask!.initialTankVolume == null) {
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _showInitialFillDialog());
      }
    }

    // Subskrypcja do zunifikowanego strumienia GPS (real lub symulator)
    _gpsSub = GpsLocationService.instance.positionStream.listen(_onGpsPosition);
    _fixStatusSub =
        GpsLocationService.instance.fixStatusStream.listen((status) {
      if (mounted) setState(() => _fixStatus = status);
    });
  }

  @override
  void dispose() {
    _monitorSub?.cancel();
    _sessionSub?.cancel();
    // Gdy praca trwa w tle (nie zakończona), monitor materiału działa dalej —
    // zużycie nalicza MapView po powrocie na mapę.
    if (!WorkSessionService.instance.isActive) {
      MaterialMonitorService.instance.stop();
    }
    _gpsSub?.cancel();
    _fixStatusSub?.cancel();
    _deviationCtrl.close();
    super.dispose();
  }

  // ── GPS callback (real device or simulator, ~100 ms) ───────────────────────
  void _onGpsPosition(SimPosition pos) {
    if (!mounted) return;

    final newPos = LatLng(pos.latitude, pos.longitude);
    final now = DateTime.now();

    // ── Accuracy gate ─────────────────────────────────────────────────────────
    // Poor-fix positions (accuracy > kMaxAccuracyM) must not contaminate:
    //   • SectionControlBridge strips (→ false hectare counts)
    //   • HeadlandGuidanceBridge / SwathGuidanceBridge queries
    //   • NavigationBridge.update (→ phantom cross-track errors)
    // We still update the visual tractor position so the operator sees that
    // the machine has moved, but all guidance and coverage logic is skipped.
    if (!pos.isAccurate) {
      setState(() => _tractorPos = newPos);
      return;
    }

    double heading = pos.heading >= 0 ? pos.heading : _tractorHeading;
    // Gdy brak sprzętowego kursu, licz z przyrostu pozycji.
    if (pos.heading < 0 && _prevPos != null) {
      final dlat = (newPos.latitude - _prevPos!.latitude).abs();
      final dlon = (newPos.longitude - _prevPos!.longitude).abs();
      if (dlat + dlon > 1e-7) {
        heading = _bearing(_prevPos!, newPos);
      }
    }
    // Prędkość: preferuj sprzętowy odczyt (m/s → km/h). Gdy niedostępny LUB
    // zgłasza 0 mimo ruchu (znany problem części telefonów), licz z przyrostu
    // pozycji z wygładzaniem EMA i martwą strefą na szum pozycji.
    double speedKmh = _speedKmh;
    if (pos.speed > 0) {
      speedKmh = pos.speed * 3.6;
    } else if (_prevPos != null && _prevTime != null) {
      final dt = now.difference(_prevTime!).inMilliseconds / 1000.0;
      if (dt > 0.01) {
        final cosLat = math.cos(newPos.latitude * math.pi / 180.0);
        final de = (newPos.longitude - _prevPos!.longitude) * 111320.0 * cosLat;
        final dn = (newPos.latitude - _prevPos!.latitude) * 111320.0;
        final raw = math.sqrt(de * de + dn * dn) / dt * 3.6;
        speedKmh = _speedKmh + (raw - _speedKmh) * 0.45;
        if (speedKmh < 0.8) speedKmh = 0.0;
      }
    }

    // ── Obrót mapy: OSOBNA bramka prędkości + OSOBNY EMA (patrz stałe u góry
    // klasy) — nie modyfikuje `heading`/`_tractorHeading` powyżej, więc
    // prowadzenie i cross-track pozostają dokładnie tak wygładzone/bramkowane
    // jak dotychczas. Poniżej progu kąt po prostu zamraża się na ostatniej
    // wartości (bez dryfu), więc wznowienie ruchu nie daje skoku mapy.
    final double speedMsForRotation =
        pos.speed > 0 ? pos.speed : speedKmh / 3.6;
    if (speedMsForRotation >= kMinMapRotationSpeedMs) {
      final rad = heading * math.pi / 180.0;
      final x = math.cos(rad);
      final y = math.sin(rad);
      if (_mapRotationEmaX == null || _mapRotationEmaY == null) {
        _mapRotationEmaX = x;
        _mapRotationEmaY = y;
      } else {
        _mapRotationEmaX = _kMapRotationEmaAlpha * x +
            (1.0 - _kMapRotationEmaAlpha) * _mapRotationEmaX!;
        _mapRotationEmaY = _kMapRotationEmaAlpha * y +
            (1.0 - _kMapRotationEmaAlpha) * _mapRotationEmaY!;
      }
      _mapRotationDeg =
          math.atan2(_mapRotationEmaY!, _mapRotationEmaX!) * 180.0 / math.pi;
    }

    final guidance = NavBridge.instance.update(
      lat: pos.latitude,
      lon: pos.longitude,
      alt: pos.altitude,
      accuracy: pos.accuracy,
    );

    // ── 1. Snap do najbliższego pasa (zawsze aktualny — używany przez Lightbar
    //    w trybie swath i przez panel statystyk)
    SnapInfo snapInfo = _snapInfo;
    if (widget.swaths.isNotEmpty) {
      snapInfo = SwathGuidanceBridge.instance
          .query(pos.latitude, pos.longitude, heading);
    }

    // ── 2. Pick deviation source for Lightbar ────────────────────────────────
    // Swath mode: signed distance from the nearest pass.
    // Headland mode: cross-track from the nearest headland ring segment.
    int newHeadlandRingIndex = _activeHeadlandRingIndex;
    if (_guidanceMode == _GuidanceMode.swath || widget.headlandRings.isEmpty) {
      if (snapInfo.swathIndex >= 0) {
        _deviationCtrl.add(_DeviationSnapshot(
          crossTrack: snapInfo.distanceM * snapInfo.side.toDouble(),
          valid: true,
        ));
      } else {
        _deviationCtrl.add(_DeviationSnapshot(
          crossTrack: guidance.crossTrack,
          valid: guidance.valid,
        ));
      }
    } else {
      final hs = HeadlandGuidanceBridge.instance
          .query(pos.latitude, pos.longitude, heading);
      _deviationCtrl.add(_DeviationSnapshot(
        crossTrack: hs.crossTrackM,
        valid: hs.ringIndex >= 0,
      ));
      newHeadlandRingIndex = hs.ringIndex;
    }

    double overlapFraction = _overlapFraction;
    double coveredHa = _coveredHa;

    // ── 3. Ślad pokrycia: rejestruj tylko gdy praca AKTYWNA (nie wstrzymana),
    //    maszyna WŁĄCZONA i pojazd jest w obrysie pola — poza granicą
    //    (uwrocie, dojazd) albo z wyłączoną maszyną nie malujemy śladu ani
    //    nie liczymy hektarów/materiału.
    final insideBoundary = widget.fieldBoundary.length < 3 ||
        GeoUtils.pointInPolygon(newPos, widget.fieldBoundary);
    if (!_isPaused && !_machineOff && insideBoundary) {
      CoverageService.instance.addPoint(newPos);
      // Surowa powierzchnia (nakładki liczą się ponownie) — podstawa
      // zużycia materiału, osobna od zdeduplikowanych hektarów poniżej.
      if (_lastMaterialPos != null) {
        final enu = GeoUtils.toEnu(_lastMaterialPos!, newPos);
        final segM = math.sqrt(enu.e * enu.e + enu.n * enu.n);
        _rawMaterialAreaHa += segM * widget.workingWidthM / 10000.0;
      }
      _lastMaterialPos = newPos;
      if (widget.fieldId != null) {
        overlapFraction = SectionControlBridge.instance.addStrip(
          pos.latitude,
          pos.longitude,
          heading,
          widget.workingWidthM,
        );
        coveredHa = SectionControlBridge.instance.coveredAreaHa();
      }
      MaterialMonitorService.instance.updateArea(_rawMaterialAreaHa);
    } else {
      // Przerwa w naliczaniu — następny punkt nie może doliczyć fantomowego
      // odcinka przez przerwę (pauza / maszyna wyłączona / poza obrysem).
      _lastMaterialPos = null;
    }

    // Update guidance fields directly (no setState) — used only as the
    // one-time Lightbar initial value on the next rebuild; live updates
    // flow through _deviationCtrl stream, so no full rebuild needed.
    _crossTrack = guidance.crossTrack;
    _guidanceValid = guidance.valid;

    setState(() {
      _tractorPos = newPos;
      _tractorHeading = heading;
      _snapInfo = snapInfo;
      _speedKmh = speedKmh;
      _overlapFraction = overlapFraction;
      _coveredHa = coveredHa;
      _activeHeadlandRingIndex = newHeadlandRingIndex;
    });

    _prevPos = newPos;
    _prevTime = now;
  }

  static double _bearing(LatLng from, LatLng to) => GeoUtils.bearing(from, to);

  /// Przełącza stan wstrzymania pracy.
  /// Przy wstrzymaniu: zatrzymuje rejestrację pokrycia i licznik czasu
  /// (stan trzyma [WorkSessionService] — działa też po opuszczeniu ekranu)
  /// oraz zapisuje pozycję GPS jako znacznik miejsca uzupełnienia materiału.
  void _togglePause() {
    final service = WorkSessionService.instance;
    if (service.paused) {
      service.resume();
    } else {
      service.pause();
      setState(() {
        // Cap pause-marker list at 50 to prevent unbounded memory growth
        if (_pauseMarkers.length < 50) {
          _pauseMarkers.add(_tractorPos);
        }
      });
    }
  }

  /// Zatrzymuje pracę: zapisuje zadanie w historii, zamraża licznik czasu,
  /// kończy monitor materiału i rejestrację pokrycia, po czym wraca na mapę.
  Future<void> _finishWorkMode() async {
    final session = WorkSessionService.instance;
    // Odczytaj PRZED MaterialMonitorService.stop() (zeruje stan).
    final monitor = MaterialMonitorService.instance;
    final materialConsumed = monitor.isActive ? monitor.totalConsumed : null;
    final materialUnit = monitor.isActive ? monitor.state.unit : null;
    final info = FinishWorkInfo(
      fieldName: widget.fieldName ?? '',
      machineName: widget.machineName ?? '',
      taskTypeLabel: widget.activeTask?.taskType.label ?? 'Inne',
      workingWidthM: widget.workingWidthM,
      overlapM: widget.overlapM,
      swathAngleDeg: widget.swathAngleDeg,
      workDuration: session.elapsed,
      coveredHa: _coveredHa,
      speedKmh: _speedKmh,
      materialConsumed: materialConsumed,
      materialUnit: materialUnit,
    );
    final note = await showFinishWorkDialog(context, info);
    if (note == null || !mounted) return;

    // Zapis do bazy historii (każde zakończenie pracy = jeden rekord).
    try {
      await HistoryDatabase.instance.save(HistoryRecord(
        id: const Uuid().v4(),
        fieldId: widget.fieldId ?? '',
        fieldName: widget.fieldName ?? '',
        machineName: widget.machineName,
        taskType: widget.activeTask?.taskType ?? TaskType.other,
        workingWidthM: widget.workingWidthM,
        overlapM: widget.overlapM,
        swathAngleDeg: widget.swathAngleDeg,
        workDuration: session.elapsed,
        coveredHa: _coveredHa,
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
    if (mounted) Navigator.of(context).pop();
  }

  /// Pojemność zbiornika z profilu maszyny — prawdziwy fizyczny limit, w
  /// odróżnieniu od [WorkTask.initialTankVolume] (ile faktycznie wlano na
  /// starcie, może być mniej niż pełny zbiornik). Fallback na
  /// `initialTankVolume`, gdyby maszyna nie miała ustawionej pojemności.
  double? get _machineTankCapacity {
    final task = widget.activeTask;
    if (task == null) return null;
    return MachineService.instance.getById(task.machineId)?.tankCapacity ??
        task.initialTankVolume;
  }

  /// Pyta operatora ile jest zatankowane na starcie Trybu Pracy — poziom
  /// zbiornika nie jest już ustalany przy tworzeniu zadania, tylko tutaj
  /// (patrz [WorkTask.initialTankVolume]). Wpisz dokładną ilość albo kafelek
  /// "Pełny zbiornik" (pojemność wzięta z profilu maszyny).
  Future<void> _showInitialFillDialog() async {
    final task = widget.activeTask;
    if (task == null || !mounted) return;
    final unit = (task.unit ?? 'l/ha').split('/').first;
    final capacity = _machineTankCapacity;

    double? amount;
    final choice = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          title: const Row(
            children: [
              Icon(Icons.local_gas_station_rounded, color: Colors.greenAccent),
              SizedBox(width: 10),
              Text('Ile jest zatankowane?',
                  style: TextStyle(color: Colors.white)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                autofocus: true,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'Ilość ($unit)',
                  labelStyle: const TextStyle(color: Colors.white54),
                  enabledBorder: const UnderlineInputBorder(
                      borderSide: BorderSide(color: Colors.white30)),
                  focusedBorder: const UnderlineInputBorder(
                      borderSide: BorderSide(color: Colors.greenAccent)),
                ),
                onChanged: (v) {
                  final d = double.tryParse(v.replaceAll(',', '.'));
                  setDlg(() => amount = d);
                },
              ),
              if (capacity != null) ...[
                const SizedBox(height: 14),
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => Navigator.pop(ctx, 'full'),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        vertical: 12, horizontal: 14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A3A1A),
                      borderRadius: BorderRadius.circular(8),
                      border:
                          Border.all(color: Colors.greenAccent, width: 0.5),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.water_drop_rounded,
                            color: Colors.greenAccent, size: 18),
                        const SizedBox(width: 8),
                        Text(
                          'Pełny zbiornik (${capacity.toStringAsFixed(0)} $unit)',
                          style: const TextStyle(
                              color: Colors.greenAccent,
                              fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'skip'),
              child: const Text('Pomiń (bez monitorowania)',
                  style: TextStyle(color: Colors.white54)),
            ),
            if (amount != null && amount! > 0)
              FilledButton(
                style:
                    FilledButton.styleFrom(backgroundColor: Colors.green[700]),
                onPressed: () => Navigator.pop(ctx, 'amount'),
                child: const Text('Zatwierdź'),
              ),
          ],
        ),
      ),
    );

    if (!mounted || choice == null || choice == 'skip') return;
    final fill = choice == 'full' ? capacity : amount;
    if (fill == null || fill <= 0) return;
    MaterialMonitorService.instance
        .confirmInitialFill(fill, currentAreaHa: _rawMaterialAreaHa);
    await WorkTaskService.instance.save(task);
    if (mounted) {
      setState(() => _monitorState = MaterialMonitorService.instance.state);
    }
  }

  Future<void> _showRefillDialog() async {
    final task = widget.activeTask;
    if (task == null) return;
    final maxVol = _machineTankCapacity ?? 0.0;
    final unit = MaterialMonitorService.instance.state.unit;

    // Option A: full refill (one tap)
    // Option B: partial — user enters amount
    double? partialAmount;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          title: const Row(
            children: [
              Icon(Icons.local_gas_station_rounded, color: Colors.greenAccent),
              SizedBox(width: 10),
              Text('Tankowanie', style: TextStyle(color: Colors.white)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Zbiornik: ${_monitorState.remainingVolume.toStringAsFixed(1)} / '
                '${maxVol.toStringAsFixed(0)} $unit',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 16),
              TextField(
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'Uzupełnienie ($unit) — zostaw puste = pełny',
                  labelStyle: const TextStyle(color: Colors.white54),
                  enabledBorder: const UnderlineInputBorder(
                      borderSide: BorderSide(color: Colors.white30)),
                  focusedBorder: const UnderlineInputBorder(
                      borderSide: BorderSide(color: Colors.greenAccent)),
                ),
                onChanged: (v) {
                  final d = double.tryParse(v.replaceAll(',', '.'));
                  setDlg(() => partialAmount = d);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Anuluj')),
            FilledButton.icon(
              icon: const Icon(Icons.water_drop_rounded, size: 18),
              label: const Text('Pełny zbiornik'),
              style: FilledButton.styleFrom(backgroundColor: Colors.green[700]),
              onPressed: () => Navigator.pop(ctx, 'full'),
            ),
            if (partialAmount != null && partialAmount! > 0)
              FilledButton.icon(
                icon: const Icon(Icons.add_rounded, size: 18),
                label: Text('+${partialAmount!.toStringAsFixed(1)} $unit'),
                style:
                    FilledButton.styleFrom(backgroundColor: Colors.teal[700]),
                onPressed: () => Navigator.pop(ctx, 'partial'),
              ),
          ],
        ),
      ),
    );

    if (choice == null || !mounted) return;
    if (choice == 'full') {
      MaterialMonitorService.instance.fullRefill(
          currentAreaHa: _rawMaterialAreaHa, maxCapacity: maxVol);
    } else if (choice == 'partial' && partialAmount != null) {
      MaterialMonitorService.instance.refill(
        addedVolume: partialAmount!,
        currentAreaHa: _rawMaterialAreaHa,
        maxCapacity: maxVol,
      );
    }
    // Allow low alert to fire again after refill
    setState(() {
      _monitorState = MaterialMonitorService.instance.state;
      _lowAlertShown = false;
    });
  }

  /// Pozwala zmienić dawkę (l/ha lub kg/ha) w trakcie pracy — np. gdy operator
  /// koryguje ustawienia oprysku/siewnika w polu. Zużycie policzone dotychczas
  /// (przy starej dawce) zostaje zachowane; nowa dawka liczy się dopiero od
  /// tego momentu (patrz [MaterialMonitorService.setRate]).
  Future<void> _showChangeRateDialog() async {
    final task = widget.activeTask;
    if (task == null || task.targetRate == null) return;
    final unit = MaterialMonitorService.instance.state.unit;

    double? newRate = task.targetRate;
    final rateCtrl =
        TextEditingController(text: _formatRate(task.targetRate!));

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Row(
          children: [
            Icon(Icons.tune_rounded, color: Colors.tealAccent),
            SizedBox(width: 10),
            Text('Zmień dawkę', style: TextStyle(color: Colors.white)),
          ],
        ),
        content: TextField(
          controller: rateCtrl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            labelText: 'Dawka ($unit/ha)',
            labelStyle: const TextStyle(color: Colors.white54),
            enabledBorder: const UnderlineInputBorder(
                borderSide: BorderSide(color: Colors.white30)),
            focusedBorder: const UnderlineInputBorder(
                borderSide: BorderSide(color: Colors.tealAccent)),
          ),
          onChanged: (v) => newRate = double.tryParse(v.replaceAll(',', '.')),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Anuluj')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.teal[700]),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Zapisz'),
          ),
        ],
      ),
    );
    rateCtrl.dispose();

    if (confirmed != true || newRate == null || newRate! <= 0 || !mounted) {
      return;
    }
    MaterialMonitorService.instance
        .setRate(newRate!, currentAreaHa: _rawMaterialAreaHa);
    await WorkTaskService.instance.save(task);
    setState(() => _monitorState = MaterialMonitorService.instance.state);
  }

  static String _formatRate(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  // ── Build ─────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.of(context).padding;
    final coverageTrack = CoverageService.instance.currentTrack;

    return Scaffold(
      backgroundColor: _kBg,
      body: GestureDetector(
        // Pinch-to-zoom zmienia skalę kanwy
        onScaleUpdate: (d) {
          if (d.pointerCount >= 2) {
            setState(() {
              _pixelsPerMeter = (_pixelsPerMeter * d.scale).clamp(1.0, 25.0);
            });
          }
        },
        child: Stack(
          children: [
            // ── 1. Geometryczna kanwa pola (cała powierzchnia ekranu) ─────────
            Positioned.fill(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: _FieldCanvasPainter(
                    tractorPos: _tractorPos,
                    mapRotationDeg:
                        _orientationMode == MapOrientationMode.headingUp
                            ? _mapRotationDeg
                            : 0.0,
                    swaths: widget.swaths,
                    headlandRings: widget.headlandRings,
                    fieldBoundary: widget.fieldBoundary,
                    coverageTrack: coverageTrack,
                    activeSwathIndex: _snapInfo.swathIndex,
                    activeHeadlandRingIndex: _activeHeadlandRingIndex,
                    pauseMarkers: _pauseMarkers,
                    pixelsPerMeter: _pixelsPerMeter,
                    workingWidthM: widget.workingWidthM,
                  ),
                ),
              ),
            ),

            // ── 2. Lightbar — pasek świetlny (pełna szerokość, pod safe area) ─
            Positioned(
              top: padding.top + 8,
              left: 12,
              right: 12,
              child: _Lightbar(
                deviationStream: _deviationCtrl.stream,
                initial: _DeviationSnapshot(
                  crossTrack: _crossTrack,
                  valid: _guidanceValid,
                ),
              ),
            ),

            // ── 3. Panel statystyk (prawy bok, pod lightbarem) ────────────────
            Positioned(
              right: 12,
              top: padding.top + 8 + 82,
              child: _StatsPanel(
                speedKmh: _speedKmh,
                coveredHa: _coveredHa,
                fieldAreaHa: _fieldAreaHa,
                workElapsed: _workElapsed,
                snapInfo: _snapInfo,
                overlapFraction: _overlapFraction,
                fixStatus: _fixStatus,
              ),
            ),

            // ── 4b. Przełączniki: tryb prowadzenia (jeśli są uwrocia) +
            //       orientacja mapy (lewy bok, pod lightbarem)
            Positioned(
              left: 12,
              top: padding.top + 8 + 82,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.headlandRings.isNotEmpty) ...[
                    _GuidanceModeButton(
                      mode: _guidanceMode,
                      onToggle: () => setState(() {
                        _guidanceMode = _guidanceMode == _GuidanceMode.swath
                            ? _GuidanceMode.headland
                            : _GuidanceMode.swath;
                        // Reset active ring highlight when switching modes
                        if (_guidanceMode == _GuidanceMode.swath) {
                          _activeHeadlandRingIndex = -1;
                        }
                      }),
                    ),
                    const SizedBox(height: 8),
                  ],
                  _OrientationModeButton(
                    mode: _orientationMode,
                    onToggle: () => setState(() {
                      _orientationMode =
                          _orientationMode == MapOrientationMode.headingUp
                              ? MapOrientationMode.northUp
                              : MapOrientationMode.headingUp;
                      WorkModeSettingsService.instance.orientationMode =
                          _orientationMode;
                    }),
                  ),
                ],
              ),
            ),

            // ── 5. Przyciski dołu: Wstrzymaj / Zakończ pracę ─────────────────
            Positioned(
              bottom: padding.bottom + 20,
              left: 20,
              right: 20,
              child: Row(
                children: [
                  _MachineOffButton(
                    isOff: _machineOff,
                    onPressed: () => setState(() => WorkSessionService.instance
                        .setMachineOff(!_machineOff)),
                  ),
                  const SizedBox(width: 8),
                  _PauseButton(
                    isPaused: _isPaused,
                    onPressed: _togglePause,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Hero(
                      tag: 'workModeHero',
                      child: Material(
                        color: Colors.transparent,
                        child: _ExitButton(onPressed: _finishWorkMode),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // ── 6. Wskaźnik zbiornika (lewy dół, widoczny tylko gdy monitorowanie aktywne)
            if (MaterialMonitorService.instance.isActive)
              Positioned(
                left: 12,
                bottom: padding.bottom + 86,
                child: _TankIndicator(
                  state: _monitorState,
                  rate: widget.activeTask?.targetRate ?? 0.0,
                  onRefill: _showRefillDialog,
                  onChangeRate: _showChangeRateDialog,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Geometryczna kanwa pola — CustomPainter
// ─────────────────────────────────────────────────────────────────────────────

/// Rysuje siatkę pola w trybie "track-up": kierunek jazdy wskazuje zawsze górę
/// ekranu. Traktor jest wyśrodkowany, a cały układ ENU obraca się względem niego.
class _FieldCanvasPainter extends CustomPainter {
  const _FieldCanvasPainter({
    required this.tractorPos,
    required this.mapRotationDeg,
    required this.swaths,
    required this.headlandRings,
    required this.fieldBoundary,
    required this.coverageTrack,
    required this.activeSwathIndex,
    required this.activeHeadlandRingIndex,
    required this.pauseMarkers,
    required this.pixelsPerMeter,
    required this.workingWidthM,
  });

  final LatLng tractorPos;

  /// Kąt obrotu kanwy (mode-dependent: kąt jazdy wygładzony EMA w trybie
  /// "kierunek jazdy do góry", zawsze 0 w trybie "północ do góry" — patrz
  /// [MapOrientationMode]). NIE jest to bezpośrednio heading GPS.
  final double mapRotationDeg;
  final List<Swath> swaths;
  final List<List<LatLng>> headlandRings;
  final List<LatLng> fieldBoundary;
  final List<LatLng> coverageTrack;
  final int activeSwathIndex;
  final int activeHeadlandRingIndex;
  final List<LatLng> pauseMarkers;
  final double pixelsPerMeter;
  final double workingWidthM;

  /// Przelicza WGS-84 na lokalne piksele ENU względem [tractorPos].
  /// +X = wschód, +Y = południe (Y odwrócone w stosunku do geograficznego N).
  Offset _toLocal(LatLng pt) {
    final cosLat = math.cos(tractorPos.latitude * math.pi / 180.0);
    final dE = (pt.longitude - tractorPos.longitude) * 111320.0 * cosLat;
    final dN = (pt.latitude - tractorPos.latitude) * 111320.0;
    return Offset(dE * pixelsPerMeter, -dN * pixelsPerMeter);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;

    // ── Cały świat obrócony tak, by kierunek jazdy = góra ekranu ─────────────
    canvas.save();
    canvas.translate(cx, cy);
    canvas.rotate(-mapRotationDeg * math.pi / 180.0);

    // ── Siatka pomocnicza co 10 m ─────────────────────────────────────────────
    final gridStep = 10.0 * pixelsPerMeter;
    if (gridStep >= 8.0) {
      final gridPaint = Paint()
        ..color = _kGrid
        ..strokeWidth = 0.5;
      // Rozszerz siatkę za widoczny obszar
      final ext = math.max(size.width, size.height) * 2;
      final start = -(ext / gridStep).ceil() * gridStep;
      for (double x = start; x <= ext * 2; x += gridStep) {
        canvas.drawLine(Offset(x, -ext), Offset(x, ext), gridPaint);
      }
      for (double y = start; y <= ext * 2; y += gridStep) {
        canvas.drawLine(Offset(-ext, y), Offset(ext, y), gridPaint);
      }
    }

    // ── Granica pola ──────────────────────────────────────────────────────────
    if (fieldBoundary.length >= 3) {
      final path = ui.Path();
      for (int i = 0; i < fieldBoundary.length; i++) {
        final o = _toLocal(fieldBoundary[i]);
        i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
      }
      path.close();
      canvas
        ..drawPath(
            path,
            Paint()
              ..color = const Color(0x18FFFFFF)
              ..style = PaintingStyle.fill)
        ..drawPath(
            path,
            Paint()
              ..color = _kBoundary
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5
              ..strokeJoin = StrokeJoin.round);
    }

    // ── Pierścienie uwrociowe ─────────────────────────────────────────────────
    for (int ri = 0; ri < headlandRings.length; ri++) {
      final ring = headlandRings[ri];
      if (ring.length < 2) continue;
      final isActive = ri == activeHeadlandRingIndex;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..color = isActive ? _kActiveHeadland : _kHeadland
        ..strokeWidth = isActive ? 3.0 : 1.2;
      final path = ui.Path();
      for (int i = 0; i < ring.length; i++) {
        final o = _toLocal(ring[i]);
        i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
      }
      path.close();
      canvas.drawPath(path, paint);
    }

    // ── Ślad pokrycia ─────────────────────────────────────────────────────────
    if (coverageTrack.length >= 2) {
      final path = ui.Path();
      var first = true;
      for (final pt in coverageTrack) {
        final o = _toLocal(pt);
        if (first) {
          path.moveTo(o.dx, o.dy);
          first = false;
        } else {
          path.lineTo(o.dx, o.dy);
        }
      }
      final sw = (workingWidthM * pixelsPerMeter).clamp(2.0, 120.0);
      canvas.drawPath(
          path,
          Paint()
            ..color = _kCoverage
            ..style = PaintingStyle.stroke
            ..strokeWidth = sw
            ..strokeCap = StrokeCap.butt
            ..strokeJoin = StrokeJoin.miter
            ..strokeMiterLimit = 4.0);
    }

    // ── Ścieżki uprawowe ──────────────────────────────────────────────────────
    final swathPaint = Paint()
      ..color = _kSwath
      ..strokeWidth = 1.0;
    final activeSwathPaint = Paint()
      ..color = _kActiveSwath
      ..strokeWidth = 3.2;
    for (int i = 0; i < swaths.length; i++) {
      final s = swaths[i];
      final s0 = _toLocal(LatLng(s.startLat, s.startLon));
      final s1 = _toLocal(LatLng(s.endLat, s.endLon));
      canvas.drawLine(
          s0, s1, i == activeSwathIndex ? activeSwathPaint : swathPaint);
    }

    // ── Znaczniki wstrzymania (miejsca uzupełnienia materiału) ───────────────
    for (final marker in pauseMarkers) {
      final o = _toLocal(marker);
      // Poświata zewnętrzna
      canvas.drawCircle(
        o,
        20,
        Paint()
          ..color = const Color(0x44FFD600)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
      );
      // Żółte wypełnione kółko
      canvas.drawCircle(o, 11, Paint()..color = const Color(0xFFFFD600));
      canvas.drawCircle(
        o,
        11,
        Paint()
          ..color = Colors.black45
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
      // Kształt kropli (ikona uzupełnienia) wewnątrz kółka
      final dropPath = ui.Path()
        ..moveTo(o.dx, o.dy - 6)
        ..lineTo(o.dx + 4, o.dy + 3)
        ..arcToPoint(Offset(o.dx - 4, o.dy + 3),
            radius: const Radius.circular(4), clockwise: false)
        ..close();
      canvas.drawPath(dropPath, Paint()..color = Colors.black87);
    }

    canvas.restore();

    // ── Kursor ciągnika (ekran, zawsze skierowany w górę = kierunek jazdy) ────
    canvas.save();
    canvas.translate(cx, cy);
    _drawTractorCursor(canvas);
    canvas.restore();
  }

  void _drawTractorCursor(Canvas canvas) {
    // Scale the cursor so its widest points (±r*0.6) exactly match the
    // coverage-strip half-width (workingWidthM * pixelsPerMeter / 2).
    // This satisfies the UX requirement: cursor always fills the strip.
    final r = (workingWidthM * pixelsPerMeter / 1.2).clamp(14.0, 80.0);
    // Strzałka z wcięciem: czubek na górze = kierunek jazdy
    final path = ui.Path()
      ..moveTo(0, -r)
      ..lineTo(r * 0.6, r * 0.72)
      ..lineTo(0, r * 0.25)
      ..lineTo(-r * 0.6, r * 0.72)
      ..close();

    // Subtelna poświata (aura)
    canvas.drawCircle(
        Offset.zero,
        r * 1.8,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.07)
          ..style = PaintingStyle.fill);

    canvas
      ..drawPath(
          path,
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.fill)
      ..drawPath(
          path,
          Paint()
            ..color = Colors.black54
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.8);
  }

  @override
  bool shouldRepaint(_FieldCanvasPainter old) =>
      old.tractorPos != tractorPos ||
      old.mapRotationDeg != mapRotationDeg ||
      old.activeSwathIndex != activeSwathIndex ||
      old.activeHeadlandRingIndex != activeHeadlandRingIndex ||
      old.pixelsPerMeter != pixelsPerMeter ||
      old.coverageTrack != coverageTrack ||
      old.pauseMarkers.length != pauseMarkers.length;
}

// ─────────────────────────────────────────────────────────────────────────────
// Lightbar — pasek świetlny prowadzenia
// ─────────────────────────────────────────────────────────────────────────────

/// Migawka danych odchylenia emitowana przez [StreamController] w stanie
/// [_WorkModeViewState]. Lightbar subskrybuje własny strumień i przebudowuje
/// się niezależnie od cyklu setState widoku mapy.
class _DeviationSnapshot {
  const _DeviationSnapshot({required this.crossTrack, required this.valid});
  final double crossTrack;
  final bool valid;
}

/// Stany semantyczne lightbara.
enum _LbState { invalid, neutral, warnLeft, warnRight, errLeft, errRight }

/// Dynamiczny pasek świetlny z trójfazową logiką kolorów i animowanymi
/// strzałkami kierunkowymi. Subskrybuje [deviationStream] bez powodowania
/// przebudowy całego widoku mapy.
class _Lightbar extends StatefulWidget {
  const _Lightbar({
    required this.deviationStream,
    required this.initial,
  });

  final Stream<_DeviationSnapshot> deviationStream;
  final _DeviationSnapshot initial;

  @override
  State<_Lightbar> createState() => _LightbarWidgetState();
}

class _LightbarWidgetState extends State<_Lightbar>
    with TickerProviderStateMixin {
  // Wolne pulsowanie — faza ostrzeżenia (żółty, ~1 500 ms)
  late AnimationController _slowCtrl;
  // Szybkie pulsowanie — faza błędu (czerwony, ~500 ms)
  late AnimationController _fastCtrl;
  late Animation<double> _slowAnim;
  late Animation<double> _fastAnim;

  @override
  void initState() {
    super.initState();
    _slowCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    _fastCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..repeat(reverse: true);
    _slowAnim = Tween<double>(begin: 0.35, end: 1.0).animate(
      CurvedAnimation(parent: _slowCtrl, curve: Curves.easeInOut),
    );
    _fastAnim = Tween<double>(begin: 0.20, end: 1.0).animate(
      CurvedAnimation(parent: _fastCtrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _slowCtrl.dispose();
    _fastCtrl.dispose();
    super.dispose();
  }

  // ── Klasyfikacja odchylenia ───────────────────────────────────────────────
  //  ct < 0  →  lewa strzałka (maszyna za daleko w lewo, koryguj w lewo)
  //  ct > 0  →  prawa strzałka (maszyna za daleko w prawo, koryguj w prawo)
  static _LbState _classify(double ct, bool valid) {
    if (!valid) return _LbState.invalid;
    final a = ct.abs();
    if (a < 0.10) return _LbState.neutral;
    if (a <= 0.30) return ct < 0 ? _LbState.warnLeft : _LbState.warnRight;
    return ct < 0 ? _LbState.errLeft : _LbState.errRight;
  }

  static Color _stateColor(_LbState s) => switch (s) {
        _LbState.neutral => const Color(0xFF00E676),
        _LbState.warnLeft || _LbState.warnRight => const Color(0xFFFFD600),
        _LbState.errLeft || _LbState.errRight => const Color(0xFFFF1744),
        _LbState.invalid => const Color(0x88FFFFFF),
      };

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<_DeviationSnapshot>(
      stream: widget.deviationStream,
      initialData: widget.initial,
      builder: (context, snap) {
        final data = snap.data!;
        final state = _classify(data.crossTrack, data.valid);
        final color = _stateColor(state);

        final isError = state == _LbState.errLeft || state == _LbState.errRight;
        final isWarn =
            state == _LbState.warnLeft || state == _LbState.warnRight;
        final isLeftActive =
            state == _LbState.warnLeft || state == _LbState.errLeft;
        final isRightActive =
            state == _LbState.warnRight || state == _LbState.errRight;
        final isNeutral = state == _LbState.neutral;

        // Subskrybuj wyłącznie potrzebną animację — neutralne tło nie pulsuje.
        final Animation<double> tickAnim = isError
            ? _fastAnim
            : isWarn
                ? _slowAnim
                : const AlwaysStoppedAnimation<double>(1.0);

        final absStr = data.valid
            ? '${data.crossTrack.abs().toStringAsFixed(2)} m'
            : '---';

        return AnimatedBuilder(
          animation: tickAnim,
          builder: (context, _) {
            final pulse = tickAnim.value;

            // Tło: w fazie ERROR subtelnie pulsuje ku ciemnej czerwieni
            final bgRed = isError ? (pulse * 30).round() : 0;
            final bgColor = Color.fromARGB(
              255,
              (0x11 + bgRed).clamp(0, 255),
              0x11,
              0x11,
            );

            // Obramowanie: subtelna poświata w aktywnym kolorze
            final borderColor = state == _LbState.invalid
                ? Colors.white12
                : color.withValues(alpha: isNeutral ? 0.28 : 0.45);

            // Cień zewnętrzny: w fazie ERROR rozszerza się rytmicznie
            final List<BoxShadow> shadows = isError
                ? [
                    BoxShadow(
                      color: color.withValues(alpha: pulse * 0.40),
                      blurRadius: 14,
                      spreadRadius: 2,
                    ),
                  ]
                : const [BoxShadow(color: Colors.black54, blurRadius: 10)];

            // Krycie strzałek
            final double leftOpacity;
            final double rightOpacity;
            if (isNeutral) {
              // Obie strzałki widoczne statycznie, w kolorze zielonym
              leftOpacity = 0.40;
              rightOpacity = 0.40;
            } else if (isLeftActive) {
              leftOpacity = pulse; // pulsuje
              rightOpacity = 0.07; // prawie niewidoczna
            } else if (isRightActive) {
              leftOpacity = 0.07;
              rightOpacity = pulse;
            } else {
              // invalid
              leftOpacity = 0.07;
              rightOpacity = 0.07;
            }

            final leftColor =
                (isNeutral || isLeftActive) ? color : Colors.white;
            final rightColor =
                (isNeutral || isRightActive) ? color : Colors.white;

            return Container(
              height: 66,
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: borderColor),
                boxShadow: shadows,
              ),
              child: Row(
                children: [
                  // ← Strzałka
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14.0),
                    child: Opacity(
                      opacity: leftOpacity,
                      child: Icon(
                        Icons.arrow_back_ios_rounded,
                        color: leftColor,
                        size: 30,
                      ),
                    ),
                  ),
                  // Tekst odchylenia — centrum paska
                  Expanded(
                    child: Center(
                      child: Text(
                        absStr,
                        style: TextStyle(
                          color: color,
                          fontSize: 26,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.8,
                          shadows: const [
                            Shadow(color: Colors.black87, blurRadius: 8),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // → Strzałka
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14.0),
                    child: Opacity(
                      opacity: rightOpacity,
                      child: Icon(
                        Icons.arrow_forward_ios_rounded,
                        color: rightColor,
                        size: 30,
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Panel statystyk
// ─────────────────────────────────────────────────────────────────────────────

class _StatsPanel extends StatelessWidget {
  const _StatsPanel({
    required this.speedKmh,
    required this.coveredHa,
    required this.fieldAreaHa,
    required this.workElapsed,
    required this.snapInfo,
    required this.overlapFraction,
    required this.fixStatus,
  });

  final double speedKmh;
  final double coveredHa;
  final double fieldAreaHa;
  final Duration workElapsed;
  final SnapInfo snapInfo;
  final double overlapFraction;
  final GpsFixStatus fixStatus;

  /// Etykieta + kolor kropki dla kafelka GPS — czerwony/szary = za mało
  /// dokładne do prowadzenia, żółty = RTK Float, zielony = RTK Fixed.
  static (String, Color) _fixVisual(GpsFixStatus status) => switch (status) {
        GpsFixStatus.inactive => ('Nieaktywny', Colors.grey),
        GpsFixStatus.searching => ('Szukanie…', Colors.grey),
        GpsFixStatus.gps => ('GPS', Colors.redAccent),
        GpsFixStatus.dgps => ('DGPS', Colors.orangeAccent),
        GpsFixStatus.rtkFloat => ('RTK Float', Colors.amber),
        GpsFixStatus.rtkFixed => ('RTK Fixed', Colors.greenAccent),
      };

  @override
  Widget build(BuildContext context) {
    final (fixValue, fixDot) = _fixVisual(fixStatus);
    // "Zrobione / całe pole" — gdy znana powierzchnia pola.
    final coveredValue = fieldAreaHa > 0
        ? '${coveredHa.toStringAsFixed(2)} / '
            '${fieldAreaHa.toStringAsFixed(2)} ha'
        : '${coveredHa.toStringAsFixed(2)} ha';

    return Container(
      width: 168,
      decoration: BoxDecoration(
        color: const Color(0xCC0D0D0D),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _StatTile(
            icon: Icons.speed_rounded,
            color: Colors.white70,
            label: 'Prędkość',
            value: '${speedKmh.toStringAsFixed(1)} km/h',
          ),
          const _TileDivider(),
          // Wydajność [ha/h] — liczona ze zrobionych hektarów i czasu pracy
          // (nie z prędkości × szerokości).
          _StatTile(
            icon: Icons.speed_outlined,
            color: Colors.tealAccent,
            label: 'Wydajność',
            value:
                '${hectaresPerHourOf(coveredHa, workElapsed).toStringAsFixed(2)} ha/h',
          ),
          const _TileDivider(),
          _StatTile(
            icon: Icons.crop_square_rounded,
            color: Colors.greenAccent,
            label: 'Zrobione',
            value: coveredValue,
          ),
          const _TileDivider(),
          _StatTile(
            icon: Icons.timer_outlined,
            color: Colors.purpleAccent,
            label: 'Czas pracy',
            value: formatWorkDuration(workElapsed),
          ),
          const _TileDivider(),
          _StatTile(
            icon: Icons.gps_fixed_rounded,
            color: Colors.lightBlueAccent,
            label: 'GPS',
            value: fixValue,
            dot: fixDot,
          ),
          if (snapInfo.swathIndex >= 0) ...[
            const _TileDivider(),
            _StatTile(
              icon: Icons.linear_scale_rounded,
              color: Colors.yellowAccent,
              label: 'Pas',
              value: '${snapInfo.swathIndex + 1}',
            ),
          ],
          if (overlapFraction >= 0.10) ...[
            const _TileDivider(),
            _StatTile(
              icon: Icons.warning_amber_rounded,
              color: Colors.redAccent,
              label: 'Nakładka',
              value: '${(overlapFraction * 100).round()}%',
            ),
          ],
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
    this.dot,
  });

  final IconData icon;
  final Color color;
  final String label;
  final String value;
  final Color? dot;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      child: Row(
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 9,
                    letterSpacing: 0.6,
                  ),
                ),
                Row(
                  children: [
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          value,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    if (dot != null) ...[
                      const SizedBox(width: 5),
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: dot,
                          boxShadow: [BoxShadow(color: dot!, blurRadius: 4)],
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TileDivider extends StatelessWidget {
  const _TileDivider();

  @override
  Widget build(BuildContext context) =>
      const Divider(height: 1, thickness: 0.5, color: Colors.white12);
}

// ─────────────────────────────────────────────────────────────────────────────
// Wskaźnik zbiornika
// ─────────────────────────────────────────────────────────────────────────────

class _TankIndicator extends StatelessWidget {
  const _TankIndicator({
    required this.state,
    required this.rate,
    required this.onRefill,
    required this.onChangeRate,
  });

  final MaterialMonitorState state;
  final double rate;
  final VoidCallback onRefill;
  final VoidCallback onChangeRate;

  static Color _fillColor(double fraction) {
    if (fraction > 0.25) return Colors.greenAccent;
    if (fraction > 0.10) return Colors.orangeAccent;
    return Colors.redAccent;
  }

  @override
  Widget build(BuildContext context) {
    final color = _fillColor(state.fillFraction);
    final pct = (state.fillFraction * 100).round();

    return Container(
      width: 140,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xCC0D0D0D),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title row
          Row(
            children: [
              Icon(Icons.water_drop_rounded, color: color, size: 14),
              const SizedBox(width: 5),
              const Text(
                'ZBIORNIK',
                style: TextStyle(
                  color: Colors.white38,
                  fontSize: 9,
                  letterSpacing: 0.8,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                '$pct%',
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),

          // Progress bar
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: state.fillFraction.clamp(0.0, 1.0),
              backgroundColor: Colors.white12,
              valueColor: AlwaysStoppedAnimation<Color>(color),
              minHeight: 8,
            ),
          ),
          const SizedBox(height: 7),

          // Remaining volume
          Text(
            'Pozostało: ${state.remainingVolume.toStringAsFixed(1)} ${state.unit}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),

          // Range
          Text(
            'Zasięg: ${state.rangeHa.toStringAsFixed(2)} ha',
            style: const TextStyle(color: Colors.white54, fontSize: 11),
          ),
          const SizedBox(height: 2),

          // Dawka (edytowalna w trakcie pracy)
          InkWell(
            onTap: onChangeRate,
            borderRadius: BorderRadius.circular(4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Dawka: ${rate.toStringAsFixed(1)} ${state.unit}/ha',
                    style:
                        const TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                ),
                const Icon(Icons.edit_rounded,
                    color: Colors.tealAccent, size: 13),
              ],
            ),
          ),
          const SizedBox(height: 8),

          // Refill button
          SizedBox(
            width: double.infinity,
            height: 30,
            child: FilledButton.icon(
              icon: const Icon(Icons.local_gas_station_rounded, size: 14),
              label: const Text('Tankowanie', style: TextStyle(fontSize: 11)),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF1A3A1A),
                foregroundColor: Colors.greenAccent,
                padding: EdgeInsets.zero,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(7),
                  side: const BorderSide(color: Colors.greenAccent, width: 0.5),
                ),
              ),
              onPressed: onRefill,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Przycisk wyjścia z widoku pracy
// ─────────────────────────────────────────────────────────────────────────────

class _ExitButton extends StatelessWidget {
  const _ExitButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      style: FilledButton.styleFrom(
        backgroundColor: const Color(0xAA7F0000),
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(54),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: Colors.white24),
        ),
        textStyle: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
      onPressed: onPressed,
      icon: const Icon(Icons.stop_circle_outlined),
      label: const Text('Zakończ pracę'),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Przycisk Wstrzymaj / Wznów
// ─────────────────────────────────────────────────────────────────────────────

/// Ręczny wyłącznik maszyny — narzędzie jest fizycznie wyłączone (np. jazda
/// na uwrociu/drogą dojazdową): nie maluje śladu i nie zużywa materiału, ale
/// w odróżnieniu od [_PauseButton] NIE zatrzymuje czasu pracy ani nawigacji.
class _MachineOffButton extends StatelessWidget {
  const _MachineOffButton({required this.isOff, required this.onPressed});

  final bool isOff;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final Color bg =
        isOff ? const Color(0xAA4A0000) : const Color(0xAA1A1A1A);
    final Color fg = isOff ? Colors.redAccent : Colors.white54;

    return FilledButton.icon(
      style: FilledButton.styleFrom(
        backgroundColor: bg,
        foregroundColor: fg,
        minimumSize: const Size(88, 54),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: fg.withValues(alpha: 0.45)),
        ),
        textStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
      onPressed: onPressed,
      icon: Icon(isOff
          ? Icons.power_off_rounded
          : Icons.power_settings_new_rounded),
      label: Text(isOff ? 'Wyłączona' : 'Maszyna'),
    );
  }
}

class _PauseButton extends StatelessWidget {
  const _PauseButton({required this.isPaused, required this.onPressed});

  final bool isPaused;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final Color bg = isPaused
        ? const Color(0xAA004D26) // ciemnozielony gdy "Wznów"
        : const Color(0xAA4A2800); // ciemnopomarańczowy gdy "Wstrzymaj"
    final Color fg = isPaused ? Colors.greenAccent : const Color(0xFFFFB74D);

    return FilledButton.icon(
      style: FilledButton.styleFrom(
        backgroundColor: bg,
        foregroundColor: fg,
        minimumSize: const Size(88, 54),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: fg.withValues(alpha: 0.45)),
        ),
        textStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
      onPressed: onPressed,
      icon: Icon(
        isPaused
            ? Icons.play_arrow_rounded
            : Icons.pause_circle_outline_rounded,
      ),
      label: Text(isPaused ? 'Wznów' : 'Wstrzymaj'),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Przełącznik trybu prowadzenia: linie AB ↔ uwrocie
// ─────────────────────────────────────────────────────────────────────────────

class _GuidanceModeButton extends StatelessWidget {
  const _GuidanceModeButton({
    required this.mode,
    required this.onToggle,
  });

  final _GuidanceMode mode;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final isHeadland = mode == _GuidanceMode.headland;
    final label = isHeadland ? 'Uwrocie' : 'Linie AB';
    final icon = isHeadland ? Icons.loop_rounded : Icons.linear_scale_rounded;
    final borderColor = isHeadland ? _kActiveHeadland : Colors.white24;
    final fgColor = isHeadland ? _kActiveHeadland : Colors.white70;

    return GestureDetector(
      onTap: onToggle,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          color: const Color(0xCC0D0D0D),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: borderColor, width: isHeadland ? 1.5 : 0.8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: fgColor, size: 15),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: fgColor,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Przełącznik orientacji mapy: kierunek jazdy do góry ↔ północ do góry
// ─────────────────────────────────────────────────────────────────────────────

class _OrientationModeButton extends StatelessWidget {
  const _OrientationModeButton({
    required this.mode,
    required this.onToggle,
  });

  final MapOrientationMode mode;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final isNorthUp = mode == MapOrientationMode.northUp;
    final label = isNorthUp ? 'Północ' : 'Jazda';
    final icon = isNorthUp ? Icons.explore_rounded : Icons.navigation_rounded;
    final fgColor = isNorthUp ? Colors.lightBlueAccent : Colors.white70;
    final borderColor = isNorthUp ? Colors.lightBlueAccent : Colors.white24;

    return GestureDetector(
      onTap: onToggle,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          color: const Color(0xCC0D0D0D),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: borderColor, width: isNorthUp ? 1.5 : 0.8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: fgColor, size: 15),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: fgColor,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
