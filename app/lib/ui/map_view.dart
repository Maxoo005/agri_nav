import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import 'package:latlong2/latlong.dart';

import '../ffi/nav_bridge.dart';
import '../offline/download_region_sheet.dart';
import '../offline/offline_map_manager.dart';

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
  LatLng _tractorPos = const LatLng(52.2297, 21.0122);
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
  // ── Tryb śledzenia ciągnika ─────────────────────────────────────────────────
  bool _followTractor = true;

  LatLng? _prevPos;

  // ── Cykl życia ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    // Uruchom symulator C++ — callback co ~100 ms z wątku natywnego Dart
    final sim = GnssSimulatorBridge.instance;
    sim.onPosition = _onSimPosition;
    sim.start(startLat: 52.2297, startLon: 21.0122);
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

    // Kurs obliczany z kolejnych pozycji GPS
    double heading = _tractorHeading;
    if (_prevPos != null) {
      final dlat = (newPos.latitude - _prevPos!.latitude).abs();
      final dlon = (newPos.longitude - _prevPos!.longitude).abs();
      if (dlat + dlon > 1e-7) {
        heading = _bearing(_prevPos!, newPos);
      }
    }

    // Wyślij do silnika C++ i odbierz wynik prowadzenia
    final result = NavBridge.instance.update(
      lat: pos.latitude,
      lon: pos.longitude,
      alt: pos.altitude,
      accuracy: pos.accuracy,
    );

    setState(() {
      _tractorPos = newPos;
      _tractorHeading = heading;
      _crossTrack = result.crossTrack;
      _guidanceValid = result.valid;
    });

    _prevPos = newPos;

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
    });
    NavBridge.instance.resetAbLine();
  }

  // ── Granica pola ───────────────────────────────────────────────────────

  /// Przełącza tryb nagrywania granicy pola.
  /// Każdy krok: dodaje bieżącą pozycję do listy wierzchołków.
  void _toggleBoundaryRecording() {
    if (!_recordingBoundary) {
      // Rozpocznij nagrywanie — wyczyść stary
      setState(() {
        _fieldBoundary.clear();
        _swaths = [];
        _recordingBoundary = true;
      });
    } else {
      // Zatrzymaj nagrywanie
      setState(() => _recordingBoundary = false);
    }
  }

  /// Dodaje punkt do granicy pola (wywoływane z długiego naciśnięcia mapy).
  void _addBoundaryPoint(LatLng pt) {
    if (!_recordingBoundary) return;
    setState(() => _fieldBoundary.add(pt));
  }

  // ── Generowanie ścieżek ───────────────────────────────────────────────────

  void _generateSwaths({double workingWidthM = 3.0}) {
    if (_fieldBoundary.length < 3 || _pointA == null || _pointB == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Ustaw granicę pola (≥ 3 pkt) oraz linię AB'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final polygon =
        _fieldBoundary.map((ll) => (ll.latitude, ll.longitude)).toList();

    final swaths = SwathPlannerBridge.instance.plan(
      polygon: polygon,
      ax: _pointA!.latitude,
      ay: _pointA!.longitude,
      bx: _pointB!.latitude,
      by: _pointB!.longitude,
      workingWidthM: workingWidthM,
    );

    setState(() => _swaths = swaths);
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
              // Krótkie naciśnięcie: wyłącza śledzenie
              onTap: (_, __) => setState(() => _followTractor = false),
              // Długie naciśnięcie: dodaje wierzchołek granicy pola
              onLongPress: (_, latLng) => _addBoundaryPoint(latLng),
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
                // Brak zasięgu = pusta kafelka, aplikacja nie crashuje
              ),

              // ── Granice pola (PolygonLayer) ───────────────────────────────────
              if (_fieldBoundary.length >= 3)
                PolygonLayer(
                  polygons: [
                    Polygon(
                      points: _fieldBoundary,
                      color: Colors.yellow.withOpacity(0.12),
                      borderColor: _recordingBoundary
                          ? Colors.orange
                          : Colors.yellowAccent,
                      borderStrokeWidth: 2.0,
                    ),
                  ],
                ),

              // ── Ścieżki uprawowe (swaths) ──────────────────────────────────
              if (_swaths.isNotEmpty)
                PolylineLayer(
                  polylines: _swaths
                      .map(
                        (s) => Polyline(
                          points: [
                            LatLng(s.startLat, s.startLon),
                            LatLng(s.endLat, s.endLon),
                          ],
                          color: Colors.greenAccent.withOpacity(0.7),
                          strokeWidth: 1.4,
                        ),
                      )
                      .toList(),
                ),

              // ── Linia AB ────────────────────────────────────────────────────
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

              // ── Markery A, B + ikona ciągnika ───────────────────────────────
              MarkerLayer(
                markers: [
                  if (_pointA != null) _abMarker(_pointA!, 'A'),
                  if (_pointB != null) _abMarker(_pointB!, 'B'),
                  // Ikona ciągnika — obraca się zgodnie z kursem GPS
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

          // ── Przyciski top-right: follow + offline ───────────────────────────
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
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
                    // ── Nagrywanie granicy pola ───────────────────────
                    FloatingActionButton.small(
                      heroTag: 'boundary',
                      tooltip: _recordingBoundary
                          ? 'Zakończ nagrywanie granicy'
                          : 'Nagraj granicę pola',
                      backgroundColor: _recordingBoundary
                          ? Colors.orange[800]
                          : const Color(0xAA000000),
                      onPressed: _toggleBoundaryRecording,
                      child: Icon(
                        _recordingBoundary ? Icons.stop : Icons.crop_free,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                    const SizedBox(height: 8),
                    // ── Generowanie ścieżek ────────────────────────────
                    FloatingActionButton.small(
                      heroTag: 'swaths',
                      tooltip: 'Generuj ścieżki (3 m)',
                      backgroundColor: _swaths.isNotEmpty
                          ? Colors.green[700]
                          : const Color(0xAA000000),
                      onPressed: () => _generateSwaths(workingWidthM: 3.0),
                      child: Icon(
                        _swaths.isNotEmpty ? Icons.grid_on : Icons.grid_off,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // ── Panel dolny: odchylenie + przyciski AB ──────────────────────────
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
  });

  final double crossTrack;
  final bool valid;
  final bool hasA;
  final bool hasB;
  final VoidCallback onSetA;
  final VoidCallback onSetB;
  final VoidCallback onReset;

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
