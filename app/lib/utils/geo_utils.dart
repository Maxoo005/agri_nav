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
}
