import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// Punkt w lokalnym układzie ENU (metry), względem pewnego originu WGS-84.
typedef Enu = ({double e, double n});

/// Wynik dopasowania transformacji podobieństwa 2D (obrót + skala + przesunięcie).
typedef SimilarityFit = ({
  double rotationRad,
  double scale,
  double txM,
  double tyM,
});

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

  /// Converts [p] to a local ENU (East/North, metres) frame centred at [origin].
  ///
  /// Equirectangular approximation — same convention (`111320.0`, `cos(lat)`)
  /// already used by [GeoportalService.nudgeField] and [minPassesBearing].
  /// Accurate enough at field scale; consistent with the rest of the codebase.
  static Enu toEnu(LatLng origin, LatLng p) {
    const mPerDeg = 111320.0;
    final cosLat = math.cos(origin.latitude * math.pi / 180.0);
    return (
      e: (p.longitude - origin.longitude) * mPerDeg * cosLat,
      n: (p.latitude - origin.latitude) * mPerDeg,
    );
  }

  /// Inverse of [toEnu] — converts an ENU offset from [origin] back to WGS-84.
  static LatLng fromEnu(LatLng origin, double e, double n) {
    const mPerDeg = 111320.0;
    final cosLat = math.cos(origin.latitude * math.pi / 180.0);
    return LatLng(
      origin.latitude + n / mPerDeg,
      origin.longitude + (cosLat > 0.0 ? e / (mPerDeg * cosLat) : 0.0),
    );
  }

  /// Least-squares fit of a 2D similarity transform (rotation + uniform scale
  /// + translation) mapping [src] onto [tgt], both in ENU metres.
  ///
  /// Closed-form complex-number solution (Kabsch/Procrustes 2D, no
  /// reflection): representing each point as `e + i·n`, the optimal
  /// rotation+scale is `z = Σ(conj(src_i)·tgt_i) / Σ|src_i|²`; `|z|` is the
  /// scale and `arg(z)` the rotation. Translation follows from the centroids.
  ///
  /// Requires `src.length == tgt.length >= 2`.
  static SimilarityFit fitSimilarity2D(List<Enu> src, List<Enu> tgt) {
    assert(src.length == tgt.length && src.length >= 2,
        'fitSimilarity2D wymaga co najmniej 2 par punktów');

    var meanSrcE = 0.0, meanSrcN = 0.0, meanTgtE = 0.0, meanTgtN = 0.0;
    for (var i = 0; i < src.length; i++) {
      meanSrcE += src[i].e;
      meanSrcN += src[i].n;
      meanTgtE += tgt[i].e;
      meanTgtN += tgt[i].n;
    }
    final count = src.length;
    meanSrcE /= count;
    meanSrcN /= count;
    meanTgtE /= count;
    meanTgtN /= count;

    var numRe = 0.0, numIm = 0.0, denom = 0.0;
    for (var i = 0; i < src.length; i++) {
      final sE = src[i].e - meanSrcE;
      final sN = src[i].n - meanSrcN;
      final tE = tgt[i].e - meanTgtE;
      final tN = tgt[i].n - meanTgtN;
      // conj(s)·t = (sE - i·sN)(tE + i·tN)
      numRe += sE * tE + sN * tN;
      numIm += sE * tN - sN * tE;
      denom += sE * sE + sN * sN;
    }

    if (denom < 1e-9) {
      // Zdegenerowany przypadek (wszystkie punkty źródłowe w jednym miejscu)
      // — brak sensownego obrotu/skali, tylko przesunięcie centroidów.
      return (
        rotationRad: 0.0,
        scale: 1.0,
        txM: meanTgtE - meanSrcE,
        tyM: meanTgtN - meanSrcN,
      );
    }

    final zRe = numRe / denom;
    final zIm = numIm / denom;
    final scale = math.sqrt(zRe * zRe + zIm * zIm);
    final rotationRad = math.atan2(zIm, zRe);

    // t = meanTgt − z·meanSrc (mnożenie zespolone: obrót+skala meanSrc)
    final txM = meanTgtE - (zRe * meanSrcE - zIm * meanSrcN);
    final tyM = meanTgtN - (zIm * meanSrcE + zRe * meanSrcN);

    return (rotationRad: rotationRad, scale: scale, txM: txM, tyM: tyM);
  }

  /// Applies a [SimilarityFit] to [point], both in the same ENU frame
  /// (identified by [origin]). Shared by [FieldModel.boundary] (committed
  /// fit) and the live control-points preview (uncommitted fit).
  static LatLng applySimilarity2D(
    LatLng origin,
    LatLng point, {
    required double rotationRad,
    required double scale,
    required double txM,
    required double tyM,
  }) {
    final p = toEnu(origin, point);
    final cosT = math.cos(rotationRad);
    final sinT = math.sin(rotationRad);
    final e2 = scale * (p.e * cosT - p.n * sinT) + txM;
    final n2 = scale * (p.e * sinT + p.n * cosT) + tyM;
    return fromEnu(origin, e2, n2);
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
