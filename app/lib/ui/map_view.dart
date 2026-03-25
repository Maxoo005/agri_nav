import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import 'package:latlong2/latlong.dart';
import 'package:uuid/uuid.dart';

import '../ffi/nav_bridge.dart';
import '../models/field_model.dart';
import '../offline/download_region_sheet.dart';
import '../offline/offline_map_manager.dart';
import '../services/coverage_service.dart';
import '../services/field_service.dart';
import 'field_manager_screen.dart';
import 'work_mode_view.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// MapView — główny ekran nawigacji rolniczej
// ═══════════════════════════════════════════════════════════════════════════════

class MapView extends StatefulWidget {
  const MapView({super.key});

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
  bool _recordingBoundary = false;

  // ── Wygenerowane ścieżki uprawowe ────────────────────────────────────
  List<Swath> _swaths = [];
  List<List<LatLng>> _headlandRings = [];

  // ── Snapowanie do ścieżki ────────────────────────────────────────────────────
  SnapInfo _snapInfo = SnapInfo.none;

  // ── Nagrywanie pokrycia ──────────────────────────────────────────────────────
  bool _trackingCoverage = false;
  double _coveredHa = 0.0;
  double _speedKmh = 0.0;
  double _overlapFraction = 0.0;
  List<LatLng> _savedTrack = [];
  DateTime? _prevTime;

  // ── Parametry generowania ścieżek ───────────────────────────────────────────
  double _overlapM = 0.0; // zakładka [m]
  int _headlandLaps = 0; // liczba objazdów uwrociowych
  double _swathAngleDeg = 0.0; // kierunek ścieżek [°], auto z granicy

  // ── Tryb śledzenia ciągnika ─────────────────────────────────────────────────
  bool _followTractor = true;
  // ── Rysowanie granicy (DrawingMode) ───────────────────────────────
  /// Czy użytkownik aktywnie rysuje granicę palcem.
  bool _drawingMode = false;

  // ── Zapisane pola (Hive) ────────────────────────────────────────────
  List<FieldModel> _savedFields = [];

  /// Aktywnie załadowane pole (granica + linia AB z pamięci).
  FieldModel? _activeField;
  LatLng? _prevPos;

  // ── Cykl życia ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    // Uruchom symulator C++ — callback co ~100 ms z wątku natywnego Dart
    final sim = GnssSimulatorBridge.instance;
    sim.onPosition = _onSimPosition;
    sim.start(startLat: 51.930428, startLon: 17.726242);

    // Załaduj zapisane pola z Hive
    _savedFields = FieldService.instance.getAll();
  }

  @override
  void dispose() {
    GnssSimulatorBridge.instance.stop();
    super.dispose();
  }

  // ── Callback z GnssSimulatorBridge (Dart main thread, ~100 ms) ─────────────

  void _onSimPosition(SimPosition pos) {
    if (!mounted) return;

    final newPos = LatLng(pos.latitude, pos.longitude);
    final now = DateTime.now();

    // Kurs obliczany z kolejnych pozycji GPS
    double heading = _tractorHeading;
    double speedKmh = _speedKmh;
    if (_prevPos != null) {
      final dlat = (newPos.latitude - _prevPos!.latitude).abs();
      final dlon = (newPos.longitude - _prevPos!.longitude).abs();
      if (dlat + dlon > 1e-7) {
        heading = _bearing(_prevPos!, newPos);
      }
      // Prędkość z delty pozycji i czasu
      if (_prevTime != null) {
        final dt = now.difference(_prevTime!).inMilliseconds / 1000.0;
        if (dt > 0.01) {
          final cosLat = math.cos(newPos.latitude * math.pi / 180.0);
          final de =
              (newPos.longitude - _prevPos!.longitude) * 111320.0 * cosLat;
          final dn = (newPos.latitude - _prevPos!.latitude) * 111320.0;
          speedKmh = math.sqrt(de * de + dn * dn) / dt * 3.6;
        }
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
    double overlapFraction = _overlapFraction;
    double coveredHa = _coveredHa;
    if (_trackingCoverage) {
      CoverageService.instance.addPoint(newPos);
      if (_activeField != null) {
        overlapFraction = SectionControlBridge.instance.addStrip(
          pos.latitude,
          pos.longitude,
          heading,
          _activeField!.workingWidthM,
        );
        coveredHa = SectionControlBridge.instance.coveredAreaHa();
      }
    }

    setState(() {
      _tractorPos = newPos;
      _tractorHeading = heading;
      _crossTrack = result.crossTrack;
      _guidanceValid = result.valid;
      _snapInfo = snapInfo;
      _speedKmh = speedKmh;
      _overlapFraction = overlapFraction;
      _coveredHa = coveredHa;
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

  // ── Obsługa linii AB ─────────────────────────────────────────────────────────

  void _setPointA() {
    setState(() => _pointA = _tractorPos);
    _trySendAbLine();
  }

  void _setPointB() {
    setState(() => _pointB = _tractorPos);
    _trySendAbLine();
  }

  void _trySendAbLine() {
    if (_pointA != null && _pointB != null) {
      // Przekaż WGS-84 do C++ — NavEngine przeliczy na ENU
      NavBridge.instance.setAbLine(
        _pointA!.latitude,
        _pointA!.longitude,
        _pointB!.latitude,
        _pointB!.longitude,
      );
    }
  }

  void _resetAbLine() {
    setState(() {
      _pointA = null;
      _pointB = null;
      _crossTrack = 0;
      _guidanceValid = false;
      _swaths = [];
      _headlandRings = [];
      _snapInfo = SnapInfo.none;
    });
    NavBridge.instance.resetAbLine();
  }

  // ── Granica pola (DrawingMode) ────────────────────────────────────────────

  void _toggleDrawingMode() {
    setState(() {
      _drawingMode = !_drawingMode;
      if (_drawingMode) {
        _fieldBoundary.clear();
        _swaths = [];
        _headlandRings = [];
        _snapInfo = SnapInfo.none;
        _activeField = null;
        _recordingBoundary = true;
      } else {
        _recordingBoundary = false;
        if (_fieldBoundary.length >= 3) {
          _swathAngleDeg = _minPassesAngle(_fieldBoundary);
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

  void _loadField(FieldModel field) {
    final savedTrack = CoverageService.instance.loadForField(field.id);

    // Reset SectionControl to new field origin and replay saved track
    SectionControlBridge.instance
      ..clear()
      ..setOrigin(field.center.latitude, field.center.longitude);

    var coveredHa = 0.0;
    if (savedTrack.isNotEmpty) {
      SectionControlBridge.instance
          .replayTrack(savedTrack, field.workingWidthM);
      coveredHa = SectionControlBridge.instance.coveredAreaHa();
    }

    setState(() {
      _fieldBoundary
        ..clear()
        ..addAll(field.boundary);
      _activeField = field;
      _swaths = [];
      _headlandRings = [];
      _snapInfo = SnapInfo.none;
      _swathAngleDeg = _minPassesAngle(field.boundary);
      _savedTrack = savedTrack;
      _coveredHa = coveredHa;
      _overlapFraction = 0.0;
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
    _mapController.move(field.center, 16);
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

    double width = _activeField?.workingWidthM ?? 3.0;
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
              Slider(
                min: 1.0,
                max: 36.0,
                divisions: 70,
                value: width,
                activeColor: Colors.greenAccent,
                onChanged: (v) => setDlg(() => width = v),
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
    _planSwaths(workingWidthM: width);
  }

  /// Wywołuje C++ SwathPlanner z aktualnymi parametrami i aktualizuje stan.
  /// Kierunek ścieżek pochodzi z [_swathAngleDeg] — wyznaczanego automatycznie
  /// z najdłuższego boku granicy lub ręcznie przez suwak w dialogu.
  void _planSwaths({double workingWidthM = 3.0}) {
    final polygon =
        _fieldBoundary.map((ll) => (ll.latitude, ll.longitude)).toList();

    final (a, b) = _abFromAngle(_swathAngleDeg);

    final result = SwathPlannerFullBridge.instance.planFull(
      polygon: polygon,
      ax: a.latitude,
      ay: a.longitude,
      bx: b.latitude,
      by: b.longitude,
      workingWidthM: workingWidthM,
      overlapM: _overlapM,
      headlandLaps: _headlandLaps,
    );

    setState(() {
      _swaths = result.swaths;
      _headlandRings = result.headlandRings
          .map((ring) => ring.map((p) => LatLng(p.$1, p.$2)).toList())
          .toList();
      _snapInfo = SnapInfo.none;
    });

    // Feed new swaths into the guidance engine
    if (result.swaths.isNotEmpty) {
      SwathGuidanceBridge.instance
          .setSwaths(result.swaths, a.latitude, a.longitude);
    }
  }

  // ── Helpers: kierunek ścieżek ─────────────────────────────────────────────

  /// Finds the swath bearing [0, 180) that minimises the number of passes.
  ///
  /// Strategy: sweep every 1° in [0°, 179°] and for each candidate angle
  /// measure the field extent along the perpendicular axis (= sweep width).
  /// The angle with the smallest perpendicular extent needs fewest passes.
  static double _minPassesAngle(List<LatLng> pts) {
    if (pts.length < 2) return 0.0;

    // Convert all vertices to a local ENU frame (first vertex as origin)
    // to work in metres rather than degrees.
    final originLat = pts[0].latitude;
    final originLon = pts[0].longitude;
    final cosLat = math.cos(originLat * math.pi / 180.0);
    final enu = pts
        .map((p) => (
              (p.longitude - originLon) * 111320.0 * cosLat, // E
              (p.latitude - originLat) * 111320.0, // N
            ))
        .toList();

    double bestAngle = 0.0;
    double minWidth = double.infinity;

    for (int deg = 0; deg < 180; deg++) {
      final rad = deg * math.pi / 180.0;
      // Swath direction (bearing): unit vector = (sinθ, cosθ) in (E, N).
      // Perpendicular axis (90° CW):  unit vector = (cosθ, -sinθ) in (E, N).
      // Projection of (e, n) onto perpendicular: e·cosθ − n·sinθ.
      double minP = double.infinity;
      double maxP = double.negativeInfinity;
      for (final (e, n) in enu) {
        final p = e * math.cos(rad) - n * math.sin(rad);
        if (p < minP) minP = p;
        if (p > maxP) maxP = p;
      }
      final width = maxP - minP;
      if (width < minWidth) {
        minWidth = width;
        bestAngle = deg.toDouble();
      }
    }
    return bestAngle;
  }

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
      CoverageService.instance.startTracking(_activeField!.id);
      SectionControlBridge.instance
        ..setOrigin(
            _activeField!.center.latitude, _activeField!.center.longitude)
        ..clear();
      setState(() => _trackingCoverage = true);
    }

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
          workingWidthM: _activeField?.workingWidthM ?? 3.0,
          fieldId: _activeField?.id,
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

    // Przywróć callback GPS (WorkModeView.dispose już to robi, ale dla pewności)
    if (!mounted) return;
    GnssSimulatorBridge.instance.onPosition = _onSimPosition;

    // Odśwież statystyki pokrycia po powrocie z trybu pracy
    final saved = CoverageService.instance.loadForField(_activeField?.id ?? '');
    setState(() {
      _savedTrack = saved;
      _coveredHa = SectionControlBridge.instance.coveredAreaHa();
      _trackingCoverage = false; // WorkModeView wywołał stopTracking
    });
  }

  void _toggleCoverage() {
    if (_trackingCoverage) {
      CoverageService.instance.stopTracking();
      final saved =
          CoverageService.instance.loadForField(_activeField?.id ?? '');
      setState(() {
        _trackingCoverage = false;
        _savedTrack = saved;
      });
    } else {
      if (_activeField != null) {
        CoverageService.instance.startTracking(_activeField!.id);
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
    await CoverageService.instance.clearForField(_activeField?.id ?? '');
    SectionControlBridge.instance.clear();
    setState(() {
      _savedTrack = [];
      _coveredHa = 0.0;
      _overlapFraction = 0.0;
    });
  }

  /// Coverage strip width in screen pixels, proportional to implement width.
  double _coverageStrokeWidth() {
    try {
      final zoom = _mapController.camera.zoom;
      final lat = _tractorPos.latitude;
      final mpp =
          156543.03392 * math.cos(lat * math.pi / 180) / math.pow(2, zoom);
      return ((_activeField?.workingWidthM ?? 3.0) / mpp).clamp(2.0, 60.0);
    } catch (_) {
      return 10.0;
    }
  }

  // ── Azymuty ──────────────────────────────────────────────────────────────────

  /// Kurs (stopnie od północy, 0–360) z [from] do [to].
  static double _bearing(LatLng from, LatLng to) {
    final dLon = (to.longitude - from.longitude) * math.pi / 180.0;
    final lat1 = from.latitude * math.pi / 180.0;
    final lat2 = to.latitude * math.pi / 180.0;
    final y = math.sin(dLon) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
    return (math.atan2(y, x) * 180.0 / math.pi + 360.0) % 360.0;
  }

  // ── Budowniczy znacznika A/B ─────────────────────────────────────────────────

  Marker _abMarker(LatLng pos, String label) => Marker(
        point: pos,
        width: 30,
        height: 30,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.blue[800],
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      );

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ── FlutterMap ──────────────────────────────────────────────────────
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _tractorPos,
              initialZoom: 17,
              onTap: (_, __) {
                if (!_drawingMode) setState(() => _followTractor = false);
              },
              onLongPress: (_, latLng) {
                if (!_drawingMode && _recordingBoundary) {
                  setState(() => _fieldBoundary.add(latLng));
                }
              },
            ),
            children: [
              // ── Podkład satelitarny Esri (offline-first przez FMTC) ─────────
              TileLayer(
                urlTemplate: kSatUrl,
                userAgentPackageName: 'com.example.agri_nav',
                tileProvider: const FMTCStore(kTileStore).getTileProvider(
                  settings: FMTCTileProviderSettings(
                    behavior: CacheBehavior.cacheFirst,
                  ),
                ),
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
                            color: Colors.white.withOpacity(0.06),
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
                      color: Colors.yellow.withOpacity(0.12),
                      borderColor:
                          _drawingMode ? Colors.orange : Colors.yellowAccent,
                      borderStrokeWidth: 2.0,
                    ),
                  ],
                ),

              // ── Pierścienie uwrociowe ────────────────────────────────────────
              if (_headlandRings.isNotEmpty)
                PolylineLayer(
                  polylines: _headlandRings
                      .map((ring) => Polyline(
                            points: [...ring, ring.first], // zamknij pierścień
                            color: Colors.orangeAccent.withOpacity(0.75),
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
                      color: Colors.blue.withOpacity(0.50),
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
                          ? Colors.yellow.withOpacity(0.95)
                          : Colors.greenAccent.withOpacity(0.7),
                      strokeWidth: isNearest ? 3.2 : 1.4,
                    );
                  }).toList(),
                ),

              // ── Linia AB ─────────────────────────────────────────────────────
              if (_pointA != null && _pointB != null)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: [_pointA!, _pointB!],
                      color: Colors.lightBlueAccent,
                      strokeWidth: 2.5,
                    ),
                  ],
                ),

              // ── Markery A, B + ikona ciągnika ────────────────────────────────
              MarkerLayer(
                markers: [
                  if (_pointA != null) _abMarker(_pointA!, 'A'),
                  if (_pointB != null) _abMarker(_pointB!, 'B'),
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
                  if (_shouldAddPoint(pt))
                    setState(() => _fieldBoundary.add(pt));
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
                    FloatingActionButton.small(
                      heroTag: 'offline',
                      tooltip: 'Mapy offline',
                      backgroundColor: const Color(0xAA000000),
                      onPressed: () => DownloadRegionSheet.show(
                        context,
                        center: _mapController.camera.center,
                      ),
                      child: const Icon(
                        Icons.download_for_offline_outlined,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                    const SizedBox(height: 8),
                    // ── Lista zapisanych pól ──────────────────────────────────
                    FloatingActionButton.small(
                      heroTag: 'fields',
                      tooltip: 'Zapisane pola',
                      backgroundColor: _activeField != null
                          ? const Color(0xFF1B5E20)
                          : const Color(0xAA000000),
                      onPressed: () async {
                        final selected = await FieldManagerScreen.open(context);
                        if (selected != null && mounted) _loadField(selected);
                        if (mounted) {
                          setState(() =>
                              _savedFields = FieldService.instance.getAll());
                        }
                      },
                      child: Badge(
                        isLabelVisible: _savedFields.isNotEmpty,
                        label: Text('${_savedFields.length}'),
                        backgroundColor: Colors.greenAccent,
                        textColor: Colors.black,
                        child: const Icon(Icons.agriculture,
                            color: Colors.white, size: 20),
                      ),
                    ),
                    const SizedBox(height: 8),
                    // ── Rysowanie granicy palcem ──────────────────────────────
                    FloatingActionButton.small(
                      heroTag: 'draw',
                      tooltip: _drawingMode
                          ? 'Anuluj rysowanie'
                          : 'Rysuj granicę pola',
                      backgroundColor: _drawingMode
                          ? Colors.orange[800]
                          : const Color(0xAA000000),
                      onPressed: _toggleDrawingMode,
                      child: Icon(
                        _drawingMode ? Icons.cancel_outlined : Icons.edit,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                    const SizedBox(height: 8),
                    // ── Nagrywanie pokrycia ───────────────────────────────────
                    FloatingActionButton.small(
                      heroTag: 'coverage',
                      tooltip: _trackingCoverage
                          ? 'Zatrzymaj nagrywanie pokrycia'
                          : 'Nagraj pokrycie pola',
                      backgroundColor: _trackingCoverage
                          ? Colors.blue[700]
                          : const Color(0xAA000000),
                      onPressed: _toggleCoverage,
                      child: Icon(
                        _trackingCoverage
                            ? Icons.stop_circle_outlined
                            : Icons.radio_button_checked,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                    const SizedBox(height: 8),
                    // ── Wyczyść ślad ──────────────────────────────────────────
                    if (_savedTrack.isNotEmpty || _coveredHa > 0)
                      FloatingActionButton.small(
                        heroTag: 'clearTrack',
                        tooltip: 'Wyczyść ślad',
                        backgroundColor: Colors.red[900],
                        onPressed: _clearTrackWithConfirm,
                        child: const Icon(
                          Icons.layers_clear,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                    if (_savedTrack.isNotEmpty || _coveredHa > 0)
                      const SizedBox(height: 8),
                    // ── Generowanie ścieżek ────────────────────────────────────
                    FloatingActionButton.small(
                      heroTag: 'swaths',
                      tooltip: _swaths.isNotEmpty || _headlandRings.isNotEmpty
                          ? 'Parametry ścieżek (aktywne)'
                          : 'Generuj ścieżki',
                      backgroundColor:
                          _swaths.isNotEmpty || _headlandRings.isNotEmpty
                              ? Colors.green[700]
                              : const Color(0xAA000000),
                      onPressed: _showSwathParamsDialog,
                      child: Icon(
                        _swaths.isNotEmpty || _headlandRings.isNotEmpty
                            ? Icons.grid_on
                            : Icons.grid_off,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // ── Panel dolny: odchylenie + przyciski AB ────────────────────────────
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: _NavPanel(
              crossTrack: _crossTrack,
              valid: _guidanceValid,
              hasA: _pointA != null,
              hasB: _pointB != null,
              onSetA: _setPointA,
              onSetB: _setPointB,
              onReset: _resetAbLine,
              snapInfo: _snapInfo.swathIndex >= 0 ? _snapInfo : null,
              coveredHa: _coveredHa,
              speedKmh: _speedKmh,
              overlapFraction: _overlapFraction,
              onClearTrack: _clearTrackWithConfirm,
            ),
          ),
        ],
      ),
    );
  }
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
// Panel nawigacyjny (dolny pasek)
// ═══════════════════════════════════════════════════════════════════════════════

class _NavPanel extends StatelessWidget {
  const _NavPanel({
    required this.crossTrack,
    required this.valid,
    required this.hasA,
    required this.hasB,
    required this.onSetA,
    required this.onSetB,
    required this.onReset,
    required this.coveredHa,
    required this.speedKmh,
    required this.overlapFraction,
    required this.onClearTrack,
    this.snapInfo,
  });

  final double crossTrack;
  final bool valid;
  final bool hasA;
  final bool hasB;
  final VoidCallback onSetA;
  final VoidCallback onSetB;
  final VoidCallback onReset;
  final double coveredHa;
  final double speedKmh;
  final double overlapFraction;
  final VoidCallback onClearTrack;
  final SnapInfo? snapInfo;

  Color get _ctColor {
    if (!valid) return Colors.grey;
    final abs = crossTrack.abs();
    if (abs < 0.15) return const Color(0xFF00E676);
    if (abs < 0.50) return Colors.orange;
    return Colors.redAccent;
  }

  @override
  Widget build(BuildContext context) {
    final abs = crossTrack.abs();
    final side = crossTrack >= 0 ? 'prawo' : 'lewo';

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xEE000000),
        border: Border(top: BorderSide(color: Colors.white12, width: 0.5)),
      ),
      padding: EdgeInsets.fromLTRB(
        12,
        10,
        12,
        12 + MediaQuery.of(context).padding.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Snap-to-swath info (gdy ścieżki są wygenerowane) ────────────────
          if (snapInfo != null) ...[
            _SnapInfoRow(snapInfo: snapInfo!),
            const SizedBox(height: 6)
          ],

          // ── Pasek wskaźnika odchylenia (zakres ±1.5 m) ─────────────────────
          Row(
            children: [
              const Text('L',
                  style: TextStyle(color: Colors.white38, fontSize: 10)),
              const SizedBox(width: 4),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value:
                        valid ? (crossTrack.clamp(-1.5, 1.5) + 1.5) / 3.0 : 0.5,
                    minHeight: 8,
                    backgroundColor: Colors.white10,
                    valueColor: AlwaysStoppedAnimation(_ctColor),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              const Text('P',
                  style: TextStyle(color: Colors.white38, fontSize: 10)),
            ],
          ),

          const SizedBox(height: 4),

          // ── Wartość odchylenia (numeryczna) ────────────────────────────────
          Text(
            valid
                ? '${abs.toStringAsFixed(2)} m  $side'
                : 'Linia AB nie ustawiona',
            style: TextStyle(
              color: _ctColor,
              fontSize: 22,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),

          const SizedBox(height: 10),

          // ── Statystyki pokrycia ──────────────────────────────────────────────
          Row(
            children: [
              const Icon(Icons.crop_square_rounded,
                  color: Colors.greenAccent, size: 14),
              const SizedBox(width: 4),
              Text(
                '${coveredHa.toStringAsFixed(2)} ha',
                style: const TextStyle(color: Colors.greenAccent, fontSize: 13),
              ),
              const SizedBox(width: 16),
              const Icon(Icons.speed, color: Colors.white54, size: 14),
              const SizedBox(width: 4),
              Text(
                '${speedKmh.toStringAsFixed(1)} km/h',
                style: const TextStyle(color: Colors.white54, fontSize: 13),
              ),
              const Spacer(),
              _OverlapAlertBanner(overlapFraction: overlapFraction),
            ],
          ),

          const SizedBox(height: 10),

          // ── Przyciski Punkt A / Punkt B / Reset ─────────────────────────────
          Row(
            children: [
              Expanded(
                  child:
                      _AbButton(label: 'Punkt A', isSet: hasA, onTap: onSetA)),
              const SizedBox(width: 8),
              Expanded(
                  child:
                      _AbButton(label: 'Punkt B', isSet: hasB, onTap: onSetB)),
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.clear, color: Colors.white38),
                tooltip: 'Resetuj linię AB',
                onPressed: onReset,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Wiersz informacji o snap-to-swath ────────────────────────────────────────

class _SnapInfoRow extends StatelessWidget {
  const _SnapInfoRow({required this.snapInfo});

  final SnapInfo snapInfo;

  @override
  Widget build(BuildContext context) {
    final sideStr = snapInfo.side > 0
        ? 'prawo'
        : snapInfo.side < 0
            ? 'lewo'
            : 'środek';
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.linear_scale, color: Colors.yellowAccent, size: 14),
        const SizedBox(width: 6),
        Text(
          'Pas ${snapInfo.swathIndex + 1}: '
          '${snapInfo.distanceM.toStringAsFixed(2)} m  $sideStr',
          style: const TextStyle(
            color: Colors.yellowAccent,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

// ── Przycisk Punkt A/B ────────────────────────────────────────────────────────

class _AbButton extends StatelessWidget {
  const _AbButton(
      {required this.label, required this.isSet, required this.onTap});

  final String label;
  final bool isSet;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(vertical: 11),
        decoration: BoxDecoration(
          color: isSet ? Colors.blue[800] : Colors.white10,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSet ? Colors.lightBlueAccent : Colors.white24,
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          isSet ? '✓  $label' : label,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}

// ── Baner ostrzeżenia o nakładaniu (pulsujący czerwony) ──────────────────────

class _OverlapAlertBanner extends StatefulWidget {
  const _OverlapAlertBanner({required this.overlapFraction});

  final double overlapFraction;

  @override
  State<_OverlapAlertBanner> createState() => _OverlapAlertBannerState();
}

class _OverlapAlertBannerState extends State<_OverlapAlertBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    )..repeat(reverse: true);
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.overlapFraction < 0.10) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, __) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.red.withOpacity(0.50 + _anim.value * 0.40),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.warning_amber_rounded,
                color: Colors.white, size: 14),
            const SizedBox(width: 4),
            Text(
              'Nakł. ${(widget.overlapFraction * 100).toStringAsFixed(0)}%',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
