import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// Geometry helpers shared across the application.
///
/// All helpers are pure functions — no state, no side effects.
abstract final class GeoUtils {
  /// Calculates the forward azimuth (bearing) from [from] to [to].
  ///
  /// Returns degrees from North, clockwise, in the range [0, 360).
  static double bearing(LatLng from, LatLng to) {
    const toRad = math.pi / 180.0;
    final dLon = (to.longitude - from.longitude) * toRad;
    final lat1 = from.latitude * toRad;
    final lat2 = to.latitude * toRad;
    final y = math.sin(dLon) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
    return (math.atan2(y, x) * 180.0 / math.pi + 360.0) % 360.0;
  }

  /// Computes the area of a closed polygon [pts] in hectares (1 ha = 10 000 m²).
  ///
  /// Uses a local equirectangular projection centred at the polygon's mean
  /// latitude, then the shoelace formula. Accurate for field-scale polygons.
  /// Returns 0.0 when there are fewer than 3 vertices.
  static double polygonAreaHa(List<LatLng> pts) {
    if (pts.length < 3) return 0.0;
    var latSum = 0.0;
    for (final p in pts) {
      latSum += p.latitude;
    }
    final lat0 = latSum / pts.length * math.pi / 180.0;
    const earthRadiusM = 6371008.8; // średni promień Ziemi
    const k = earthRadiusM * math.pi / 180.0; // metry na stopień
    final cosLat = math.cos(lat0);

    var sum2 = 0.0;
    for (int i = 0; i < pts.length; i++) {
      final a = pts[i];
      final b = pts[(i + 1) % pts.length];
      final xA = a.longitude * k * cosLat;
      final yA = a.latitude * k;
      final xB = b.longitude * k * cosLat;
      final yB = b.latitude * k;
      sum2 += xA * yB - xB * yA;
    }
    return sum2.abs() / 20000.0;
  }

  /// Finds the swath bearing [0, 180) that minimises the number of passes.
  ///
  /// Strategy: sweep every 1° in [0°, 179°] and for each candidate angle
  /// measure the field extent along the perpendicular axis (= sweep width).
  /// The angle with the smallest perpendicular extent needs fewest passes.
  static double minPassesBearing(List<LatLng> pts) {
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
}
