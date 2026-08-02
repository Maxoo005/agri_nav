import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/field_model.dart';

/// Podgląd schematu pola z zaplanowaną trasą swathów.
///
/// Wspólny widget używany przez [MachineSelectorScreen] i kreator nowego
/// zadania. Gdy podano [swathAngleDeg] (azymut 0–179° od północy), ścieżki
/// są rysowane pod tym kątem; w przeciwnym razie używany jest kierunek linii
/// AB zapisanej w polu.
class FieldSchemaPreview extends StatelessWidget {
  const FieldSchemaPreview({
    super.key,
    required this.field,
    required this.workingWidthM,
    this.swathAngleDeg,
    this.height = 140,
  });

  final FieldModel field;
  final double workingWidthM;

  /// Azymut ścieżek [0, 180) w stopniach od północy. Null = kierunek z linii AB.
  final double? swathAngleDeg;

  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: const Color(0xFF1A2A1A),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: CustomPaint(
          painter: _FieldSchemaPainter(
            field: field,
            workingWidthM: workingWidthM,
            swathAngleDeg: swathAngleDeg,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _FieldSchemaPainter extends CustomPainter {
  const _FieldSchemaPainter({
    required this.field,
    required this.workingWidthM,
    this.swathAngleDeg,
  });

  final FieldModel field;
  final double workingWidthM;
  final double? swathAngleDeg;

  @override
  void paint(Canvas canvas, Size size) {
    if (field.boundaryLats.isEmpty) return;

    // ── 1. Znormalizuj współrzędne do przestrzeni ekranu ─────────────────
    final lats = field.boundaryLats;
    final lons = field.boundaryLons;

    double minLat = lats[0], maxLat = lats[0];
    double minLon = lons[0], maxLon = lons[0];
    for (int i = 1; i < lats.length; i++) {
      if (lats[i] < minLat) minLat = lats[i];
      if (lats[i] > maxLat) maxLat = lats[i];
      if (lons[i] < minLon) minLon = lons[i];
      if (lons[i] > maxLon) maxLon = lons[i];
    }

    final dLat = maxLat - minLat;
    final dLon = maxLon - minLon;
    if (dLat < 1e-9 || dLon < 1e-9) return;

    const padding = 16.0;
    final w = size.width - padding * 2;
    final h = size.height - padding * 2;

    // Zachowaj proporcje względem rzeczywistości (Mercator approx)
    final cosLat = math.cos((minLat + maxLat) / 2.0 * math.pi / 180.0);
    final scaleX = w / (dLon * cosLat);
    final scaleY = h / dLat;
    final scale = math.min(scaleX, scaleY);

    final dispW = dLon * cosLat * scale;
    final dispH = dLat * scale;
    final offX = padding + (w - dispW) / 2;
    final offY = padding + (h - dispH) / 2;

    Offset toScreen(double lat, double lon) => Offset(
          offX + (lon - minLon) * cosLat * scale,
          offY + (maxLat - lat) * scale, // flip Y
        );

    // ── 2. Narysuj siatkę ────────────────────────────────────────────────
    final gridPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.04)
      ..strokeWidth = 0.5;
    for (double x = offX; x < offX + dispW; x += 20) {
      canvas.drawLine(Offset(x, offY), Offset(x, offY + dispH), gridPaint);
    }
    for (double y = offY; y < offY + dispH; y += 20) {
      canvas.drawLine(Offset(offX, y), Offset(offX + dispW, y), gridPaint);
    }

    // ── 3. Narysuj swathy ────────────────────────────────────────────────
    // Azymut podany wprost (0 = północ), albo kierunek linii AB.
    double abAngle = 0.0; // kąt względem osi X ekranu (0 = poziomy swath)
    if (swathAngleDeg != null) {
      final rad = swathAngleDeg! * math.pi / 180.0;
      // Bearing → kierunek w przestrzeni ekranu: x = E, y = −N.
      abAngle = math.atan2(-math.cos(rad), math.sin(rad));
    } else if (field.lineA != null && field.lineB != null) {
      final a = toScreen(field.lineALat!, field.lineALon!);
      final b = toScreen(field.lineBLat!, field.lineBLon!);
      final dx = b.dx - a.dx;
      final dy = b.dy - a.dy;
      abAngle = math.atan2(dy, dx);
    }

    // Szerokość swatha w pikselach
    const latPerM = 1.0 / 111320.0;
    final swathPx = workingWidthM * latPerM * scale;
    final swathStep = swathPx.clamp(3.0, 40.0);

    final swathPaint = Paint()
      ..color = Colors.greenAccent.withValues(alpha: 0.35)
      ..strokeWidth = math.max(1.0, swathStep - 1.5)
      ..style = PaintingStyle.stroke;

    // Projekcja prostopadła do AB — rysuj linie równoległe
    final perpAngle = abAngle + math.pi / 2;
    final cosP = math.cos(perpAngle);
    final sinP = math.sin(perpAngle);
    final cosA = math.cos(abAngle);
    final sinA = math.sin(abAngle);

    final cx = offX + dispW / 2;
    final cy = offY + dispH / 2;
    final maxDist = math.sqrt(dispW * dispW + dispH * dispH);

    for (double d = -maxDist; d < maxDist; d += swathStep) {
      final lx = cx + cosP * d;
      final ly = cy + sinP * d;
      canvas.drawLine(
        Offset(lx - cosA * maxDist, ly - sinA * maxDist),
        Offset(lx + cosA * maxDist, ly + sinA * maxDist),
        swathPaint,
      );
    }

    // ── 4. Narysuj granicę pola ──────────────────────────────────────────
    final fillPaint = Paint()
      ..color = Colors.green.withValues(alpha: 0.08)
      ..style = PaintingStyle.fill;
    final borderPaint = Paint()
      ..color = Colors.greenAccent
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

    final path = Path();
    final first = toScreen(lats[0], lons[0]);
    path.moveTo(first.dx, first.dy);
    for (int i = 1; i < lats.length; i++) {
      final p = toScreen(lats[i], lons[i]);
      path.lineTo(p.dx, p.dy);
    }
    path.close();

    canvas.drawPath(path, fillPaint);
    canvas.drawPath(path, borderPaint);

    // ── 5. Linia AB ──────────────────────────────────────────────────────
    if (field.lineA != null && field.lineB != null) {
      final a = toScreen(field.lineALat!, field.lineALon!);
      final b = toScreen(field.lineBLat!, field.lineBLon!);
      final abPaint = Paint()
        ..color = Colors.orangeAccent
        ..strokeWidth = 2.5;
      canvas.drawLine(a, b, abPaint);
      canvas.drawCircle(a, 4, Paint()..color = Colors.orangeAccent);
      // Etykieta A / B
      final tp = TextPainter(textDirection: TextDirection.ltr);
      tp.text = const TextSpan(
          text: 'A',
          style: TextStyle(color: Colors.orangeAccent, fontSize: 10));
      tp.layout();
      tp.paint(canvas, a.translate(5, -12));
      tp.text = const TextSpan(
          text: 'B',
          style: TextStyle(color: Colors.orangeAccent, fontSize: 10));
      tp.layout();
      tp.paint(canvas, b.translate(5, -12));
    }
  }

  @override
  bool shouldRepaint(_FieldSchemaPainter old) =>
      old.field != field ||
      old.workingWidthM != workingWidthM ||
      old.swathAngleDeg != swathAngleDeg;
}
