import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../ffi/nav_bridge.dart';
import '../services/coverage_service.dart';

// ── Paleta kolorów Work Mode ──────────────────────────────────────────────────
const _kBg = Color(0xFF0A0A0A);
const _kGrid = Color(0x0CFFFFFF);
const _kBoundary = Color(0x55FFFFFF);
const _kHeadland = Color(0x55FF9800);
const _kSwath = Color(0x55E0E0E0);
const _kActiveSwath = Color(0xFFFFD600);
const _kCoverage = Color(0x5500BCD4);

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

  @override
  State<WorkModeView> createState() => _WorkModeViewState();
}

class _WorkModeViewState extends State<WorkModeView> {
  // ── Stan dynamiczny ──────────────────────────────────────────────────────────
  late LatLng _tractorPos;
  late double _tractorHeading;
  double _crossTrack = 0.0;
  bool _guidanceValid = false;
  late SnapInfo _snapInfo;
  late double _coveredHa;
  double _speedKmh = 0.0;
  double _overlapFraction = 0.0;

  LatLng? _prevPos;
  DateTime? _prevTime;

  /// Poprzedni callback symulatora GPS — przywracany w [dispose].
  void Function(SimPosition)? _prevSimCallback;

  /// Skala widoku: pikseli na metr (zarządzana gestem pinch-to-zoom).
  double _pixelsPerMeter = 5.0;

  @override
  void initState() {
    super.initState();
    _tractorPos = widget.initialPos;
    _tractorHeading = widget.initialHeading;
    _snapInfo = widget.initialSnapInfo;
    _coveredHa = widget.initialCoveredHa;

    // Przejęcie callbacku GPS od MapView
    _prevSimCallback = GnssSimulatorBridge.instance.onPosition;
    GnssSimulatorBridge.instance.onPosition = _onSimPosition;
  }

  @override
  void dispose() {
    // Zwróć callback GPS do poprzedniego właściciela (MapView)
    GnssSimulatorBridge.instance.onPosition = _prevSimCallback;
    super.dispose();
  }

  // ── GPS callback (~100 ms) ───────────────────────────────────────────────────
  void _onSimPosition(SimPosition pos) {
    if (!mounted) return;

    final newPos = LatLng(pos.latitude, pos.longitude);
    final now = DateTime.now();
    double heading = _tractorHeading;
    double speedKmh = _speedKmh;

    if (_prevPos != null) {
      final dlat = (newPos.latitude - _prevPos!.latitude).abs();
      final dlon = (newPos.longitude - _prevPos!.longitude).abs();
      if (dlat + dlon > 1e-7) heading = _bearing(_prevPos!, newPos);

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

    final guidance = NavBridge.instance.update(
      lat: pos.latitude,
      lon: pos.longitude,
      alt: pos.altitude,
      accuracy: pos.accuracy,
    );

    SnapInfo snapInfo = _snapInfo;
    if (widget.swaths.isNotEmpty) {
      snapInfo = SwathGuidanceBridge.instance
          .query(pos.latitude, pos.longitude, heading);
    }

    double overlapFraction = _overlapFraction;
    double coveredHa = _coveredHa;
    CoverageService.instance.addPoint(newPos);
    if (widget.fieldId != null) {
      overlapFraction = SectionControlBridge.instance.addStrip(
        pos.latitude,
        pos.longitude,
        heading,
        widget.workingWidthM,
      );
      coveredHa = SectionControlBridge.instance.coveredAreaHa();
    }

    setState(() {
      _tractorPos = newPos;
      _tractorHeading = heading;
      _crossTrack = guidance.crossTrack;
      _guidanceValid = guidance.valid;
      _snapInfo = snapInfo;
      _speedKmh = speedKmh;
      _overlapFraction = overlapFraction;
      _coveredHa = coveredHa;
    });

    _prevPos = newPos;
    _prevTime = now;
  }

  static double _bearing(LatLng from, LatLng to) {
    final dLon = (to.longitude - from.longitude) * math.pi / 180.0;
    final lat1 = from.latitude * math.pi / 180.0;
    final lat2 = to.latitude * math.pi / 180.0;
    final y = math.sin(dLon) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
    return (math.atan2(y, x) * 180.0 / math.pi + 360.0) % 360.0;
  }

  void _exitWorkMode() {
    CoverageService.instance.stopTracking();
    Navigator.of(context).pop();
  }

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
                    tractorHeading: _tractorHeading,
                    swaths: widget.swaths,
                    headlandRings: widget.headlandRings,
                    fieldBoundary: widget.fieldBoundary,
                    coverageTrack: coverageTrack,
                    activeSwathIndex: _snapInfo.swathIndex,
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
                crossTrack: _crossTrack,
                valid: _guidanceValid,
              ),
            ),

            // ── 3. Panel statystyk (prawy bok, pod lightbarem) ────────────────
            Positioned(
              right: 12,
              top: padding.top + 8 + 82,
              child: _StatsPanel(
                speedKmh: _speedKmh,
                coveredHa: _coveredHa,
                snapInfo: _snapInfo,
                overlapFraction: _overlapFraction,
              ),
            ),

            // ── 4. Wskaźnik snap-to-swath (lewy bok, pod lightbarem) ──────────
            if (_snapInfo.swathIndex >= 0)
              Positioned(
                left: 12,
                top: padding.top + 8 + 82,
                child: _SwathIndicator(snapInfo: _snapInfo),
              ),

            // ── 5. Przycisk "Zakończ pracę" (dół ekranu) ──────────────────────
            Positioned(
              bottom: padding.bottom + 20,
              left: 20,
              right: 20,
              child: Hero(
                tag: 'workModeHero',
                // Material zapobiega błędom renderowania Hero nad różnymi tłami
                child: Material(
                  color: Colors.transparent,
                  child: _ExitButton(onPressed: _exitWorkMode),
                ),
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
    required this.tractorHeading,
    required this.swaths,
    required this.headlandRings,
    required this.fieldBoundary,
    required this.coverageTrack,
    required this.activeSwathIndex,
    required this.pixelsPerMeter,
    required this.workingWidthM,
  });

  final LatLng tractorPos;
  final double tractorHeading;
  final List<Swath> swaths;
  final List<List<LatLng>> headlandRings;
  final List<LatLng> fieldBoundary;
  final List<LatLng> coverageTrack;
  final int activeSwathIndex;
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
    canvas.rotate(-tractorHeading * math.pi / 180.0);

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
    final headlandPaint = Paint()
      ..color = _kHeadland
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    for (final ring in headlandRings) {
      if (ring.length < 2) continue;
      final path = ui.Path();
      for (int i = 0; i < ring.length; i++) {
        final o = _toLocal(ring[i]);
        i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
      }
      path.close();
      canvas.drawPath(path, headlandPaint);
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
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round);
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

    canvas.restore();

    // ── Kursor ciągnika (ekran, zawsze skierowany w górę = kierunek jazdy) ────
    canvas.save();
    canvas.translate(cx, cy);
    _drawTractorCursor(canvas);
    canvas.restore();
  }

  void _drawTractorCursor(Canvas canvas) {
    const r = 22.0;
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
          ..color = Colors.white.withOpacity(0.07)
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
      old.tractorHeading != tractorHeading ||
      old.activeSwathIndex != activeSwathIndex ||
      old.pixelsPerMeter != pixelsPerMeter ||
      old.coverageTrack != coverageTrack;
}

// ─────────────────────────────────────────────────────────────────────────────
// Lightbar — pasek świetlny prowadzenia
// ─────────────────────────────────────────────────────────────────────────────

class _Lightbar extends StatelessWidget {
  const _Lightbar({required this.crossTrack, required this.valid});

  final double crossTrack;
  final bool valid;

  static Color _ctColor(double ct, bool valid) {
    if (!valid) return const Color(0x88FFFFFF);
    final a = ct.abs();
    if (a < 0.15) return const Color(0xFF00E676);
    if (a < 0.50) return Colors.orange;
    return Colors.redAccent;
  }

  @override
  Widget build(BuildContext context) {
    final color = _ctColor(crossTrack, valid);
    final absStr = valid ? '${crossTrack.abs().toStringAsFixed(2)} m' : '---';
    final sideStr = valid
        ? (crossTrack > 0.05
            ? '  ▶'
            : crossTrack < -0.05
                ? '◀  '
                : ' ✓ ')
        : '';

    return Container(
      height: 66,
      decoration: BoxDecoration(
        color: const Color(0xFF111111),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white12),
        boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 10)],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Komórki LED
            SizedBox.expand(
              child: CustomPaint(
                painter: _LightbarPainter(
                  crossTrack: crossTrack,
                  valid: valid,
                ),
              ),
            ),
            // Wartość liczbowa na środku
            Text(
              '$absStr$sideStr',
              style: TextStyle(
                color: color,
                fontSize: 26,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.8,
                shadows: const [Shadow(color: Colors.black, blurRadius: 8)],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LightbarPainter extends CustomPainter {
  const _LightbarPainter({required this.crossTrack, required this.valid});

  final double crossTrack;
  final bool valid;

  // 31 komórek; środek = indeks 15 (0-based); zakres ±1.5 m → 0.1 m/komórkę
  static const int _n = 31;
  static const int _center = 15;
  static const double _range = 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    final cellW = size.width / _n;
    const vPad = 7.0;

    // Przesunięcie od środka w komórkach (clamp do ±_center)
    final deviation = valid
        ? ((crossTrack / _range) * _center).round().clamp(-_center, _center)
        : 0;
    final lo = math.min(_center, _center + deviation);
    final hi = math.max(_center, _center + deviation);

    for (int i = 0; i < _n; i++) {
      final lit = valid && i >= lo && i <= hi;
      final dist = (i - _center).abs();
      final color = _cellColor(dist, lit);

      canvas.drawRRect(
        RRect.fromLTRBR(
          i * cellW + 2.0,
          vPad,
          (i + 1) * cellW - 2.0,
          size.height - vPad,
          Radius.circular(cellW * 0.3),
        ),
        Paint()..color = color,
      );
    }
  }

  Color _cellColor(int dist, bool lit) {
    if (!lit) return const Color(0xFF181818);
    if (dist == 0) return const Color(0xFF00E676); // środek: jasna zieleń
    if (dist <= 1) return const Color(0xFF69F0AE); // ±0.1 m: zieleń
    if (dist <= 3) return Colors.yellow; // ±0.2–0.3 m: żółty
    if (dist <= 7) return Colors.orange; // ±0.4–0.7 m: pomarańcz
    return Colors.redAccent; // > 0.8 m: czerwony
  }

  @override
  bool shouldRepaint(_LightbarPainter old) =>
      old.crossTrack != crossTrack || old.valid != valid;
}

// ─────────────────────────────────────────────────────────────────────────────
// Panel statystyk
// ─────────────────────────────────────────────────────────────────────────────

class _StatsPanel extends StatelessWidget {
  const _StatsPanel({
    required this.speedKmh,
    required this.coveredHa,
    required this.snapInfo,
    required this.overlapFraction,
  });

  final double speedKmh;
  final double coveredHa;
  final SnapInfo snapInfo;
  final double overlapFraction;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 152,
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
          _StatTile(
            icon: Icons.crop_square_rounded,
            color: Colors.greenAccent,
            label: 'Zrobione',
            value: '${coveredHa.toStringAsFixed(2)} ha',
          ),
          const _TileDivider(),
          _StatTile(
            icon: Icons.gps_fixed_rounded,
            color: Colors.lightBlueAccent,
            label: 'GPS',
            value: 'RTK Fix',
            dot: Colors.greenAccent,
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
                    Text(
                      value,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
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
// Wskaźnik snap-to-swath (lewy bok)
// ─────────────────────────────────────────────────────────────────────────────

class _SwathIndicator extends StatelessWidget {
  const _SwathIndicator({required this.snapInfo});

  final SnapInfo snapInfo;

  @override
  Widget build(BuildContext context) {
    final dist = snapInfo.distanceM;
    final Color indicatorColor;
    if (dist < 0.15) {
      indicatorColor = Colors.greenAccent;
    } else if (dist < 0.5) {
      indicatorColor = Colors.orange;
    } else {
      indicatorColor = Colors.redAccent;
    }

    final IconData sideIcon = snapInfo.side > 0
        ? Icons.arrow_forward_rounded
        : snapInfo.side < 0
            ? Icons.arrow_back_rounded
            : Icons.check_circle_rounded;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: const Color(0xCC0D0D0D),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(sideIcon, color: indicatorColor, size: 22),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'odl. od pasa',
                style: TextStyle(
                  color: Colors.white38,
                  fontSize: 9,
                  letterSpacing: 0.6,
                ),
              ),
              Text(
                '${dist.toStringAsFixed(2)} m',
                style: TextStyle(
                  color: indicatorColor,
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
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
