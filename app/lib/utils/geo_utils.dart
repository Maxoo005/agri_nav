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
