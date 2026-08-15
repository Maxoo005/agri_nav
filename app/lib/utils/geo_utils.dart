import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../ffi/guidance_bridge.dart' show Swath;

/// Punkt w lokalnym układzie ENU (metry), względem pewnego originu WGS-84.
typedef Enu = ({double e, double n});

/// Wynik dopasowania transformacji podobieństwa 2D (obrót + skala + przesunięcie).
typedef SimilarityFit = ({
  double rotationRad,
  double scale,
  double txM,
  double tyM,
});

/// Wynik dopasowania linii AB metodą najmniejszych kwadratów (patrz
/// [GeoUtils.fitLineThroughPoints]).
typedef AbLineFit = ({
  LatLng pointA,
  LatLng pointB,
  double headingDeg,
  double lengthM,
  double rmsM,
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

  /// Shifts every swath in [swaths] by [offsetM] metres, perpendicular to its
  /// own start→end bearing. Positive = right of travel direction (same sign
  /// convention as [SnapInfo.side] == +1). Pure transform over the planner's
  /// output — never mutates the SwathPlanner result itself, so it composes
  /// cleanly with re-generation/re-optimization.
  static List<Swath> offsetSwaths(List<Swath> swaths, double offsetM) {
    if (offsetM == 0.0 || swaths.isEmpty) return swaths;
    return [for (final s in swaths) _offsetSwath(s, offsetM)];
  }

  static Swath _offsetSwath(Swath s, double offsetM) {
    final start = LatLng(s.startLat, s.startLon);
    final end = LatLng(s.endLat, s.endLon);
    final endEnu = toEnu(start, end);
    final len = math.sqrt(endEnu.e * endEnu.e + endEnu.n * endEnu.n);
    if (len < 1e-6) return s;
    final dE = endEnu.e / len, dN = endEnu.n / len;
    // Perpendicular, rotated 90° clockwise from travel direction = "right".
    final offE = dN * offsetM, offN = -dE * offsetM;
    final newStart = fromEnu(start, offE, offN);
    final newEnd = fromEnu(start, endEnu.e + offE, endEnu.n + offN);
    return Swath(
      startLat: newStart.latitude,
      startLon: newStart.longitude,
      endLat: newEnd.latitude,
      endLon: newEnd.longitude,
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

  /// Total-least-squares (orthogonal regression / PCA) best-fit line through
  /// [points], for deriving a precise AB heading from a recorded RTK track.
  ///
  /// Unlike ordinary "y on x" regression, this does not break down for a
  /// near-vertical (north-south) path — it minimises the sum of squared
  /// PERPENDICULAR distances from every point to the line, via the closed-form
  /// principal-axis angle of the points' 2×2 covariance matrix (same family of
  /// method as [fitSimilarity2D], applied to a line instead of a similarity
  /// transform).
  ///
  /// Returns `null` when fewer than 2 points are given, or all points are
  /// (numerically) coincident.
  ///
  /// The returned heading is folded into `[0, 180)` — same convention as
  /// [bearing] mod 180 and the existing `_swathAngleDeg`/`_abFromAngle` in
  /// map_view.dart, since an AB line has a direction but no "arrow": a swath
  /// running north-south is the same line whether recorded driving north or
  /// south. [pointA]/[pointB] are the extreme projections of the recorded
  /// points onto the fitted line (not the raw, noisy first/last samples),
  /// ordered so [pointA] is nearest the start of the recording and [pointB]
  /// nearest the end — purely cosmetic, so "A" matches where the driver
  /// actually started. [lengthM] is the resulting line's extent; [rmsM] is
  /// the RMS perpendicular residual (how tightly the points hugged the fitted
  /// line) — both are left for the caller to apply as UX/acceptance
  /// thresholds (e.g. minimum length, minimum straightness).
  static AbLineFit? fitLineThroughPoints(List<LatLng> points) {
    if (points.length < 2) return null;

    final origin = points.first;
    final enu = points.map((p) => toEnu(origin, p)).toList();

    var eBar = 0.0, nBar = 0.0;
    for (final p in enu) {
      eBar += p.e;
      nBar += p.n;
    }
    eBar /= enu.length;
    nBar /= enu.length;

    var sEE = 0.0, sNN = 0.0, sEN = 0.0;
    for (final p in enu) {
      final de = p.e - eBar;
      final dn = p.n - nBar;
      sEE += de * de;
      sNN += dn * dn;
      sEN += de * dn;
    }
    if (sEE + sNN < 1e-6) return null; // wszystkie punkty w jednym miejscu

    // Kąt głównej osi chmury punktów względem osi E (matematyczna konwencja,
    // przeciwnie do wskazówek zegara) — standardowy wzór zamknięty PCA/TLS.
    final thetaStd = 0.5 * math.atan2(2 * sEN, sEE - sNN);
    // Konwersja na namiar używany w reszcie kodu (0°=N, 90°=E, zgodnie z
    // ruchem wskazówek zegara — patrz [bearing]/`_abFromAngle`), zwinięty do
    // [0,180) tym samym idiomem co [bearing] (dodanie pełnego obrotu przed
    // modulo dla bezpieczeństwa przy wartościach ujemnych).
    final headingDeg =
        ((math.pi / 2 - thetaStd) * 180.0 / math.pi + 360.0) % 180.0;
    final headingRad = headingDeg * math.pi / 180.0;
    final dirE = math.sin(headingRad), dirN = math.cos(headingRad);
    final perpE = math.cos(headingRad), perpN = -math.sin(headingRad);

    var tMin = double.infinity, tMax = double.negativeInfinity;
    var tFirst = 0.0, tLast = 0.0;
    var sumPerp2 = 0.0;
    for (var i = 0; i < enu.length; i++) {
      final de = enu[i].e - eBar;
      final dn = enu[i].n - nBar;
      final t = de * dirE + dn * dirN;
      final perp = de * perpE + dn * perpN;
      sumPerp2 += perp * perp;
      if (t < tMin) tMin = t;
      if (t > tMax) tMax = t;
      if (i == 0) tFirst = t;
      if (i == enu.length - 1) tLast = t;
    }

    LatLng atT(double t) => fromEnu(origin, eBar + t * dirE, nBar + t * dirN);
    final endMin = atT(tMin);
    final endMax = atT(tMax);
    final startFirst = tFirst <= tLast; // A ≈ początek jazdy, B ≈ koniec

    return (
      pointA: startFirst ? endMin : endMax,
      pointB: startFirst ? endMax : endMin,
      headingDeg: headingDeg,
      lengthM: tMax - tMin,
      rmsM: math.sqrt(sumPerp2 / enu.length),
    );
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

  /// Czy [pt] leży wewnątrz wielokąta [polygon] (WGS-84, niekoniecznie
  /// zamknięty — ostatni wierzchołek nie musi powtarzać pierwszego).
  ///
  /// Klasyczny ray-casting (parzysto-nieparzysty), operujący bezpośrednio na
  /// stopniach lat/lon — wystarczająco dokładny dla topologii "wewnątrz
  /// pola", bo pola są na tyle małe, że lokalne zniekształcenie rzutu nie
  /// zmienia wyniku testu.
  static bool pointInPolygon(LatLng pt, List<LatLng> polygon) {
    if (polygon.length < 3) return false;
    var inside = false;
    for (int i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
      final xi = polygon[i].longitude, yi = polygon[i].latitude;
      final xj = polygon[j].longitude, yj = polygon[j].latitude;
      final crosses = (yi > pt.latitude) != (yj > pt.latitude);
      if (crosses &&
          pt.longitude <
              (xj - xi) * (pt.latitude - yi) / (yj - yi) + xi) {
        inside = !inside;
      }
    }
    return inside;
  }

  /// Surowa (NIE zdeduplikowana) powierzchnia pokryta narzędziem o szerokości
  /// [widthM] wzdłuż śladu [track]: suma długości kolejnych odcinków × szerokość.
  ///
  /// W odróżnieniu od powierzchni liczonej przez [SectionControl] (unikalne
  /// komórki siatki — nakładki liczą się raz), to jest podstawa do liczenia
  /// zużycia materiału: dawka/ha leci przez całą szerokość narzędzia przy
  /// każdym przejeździe, niezależnie od tego, czy dany pas się nakłada z
  /// poprzednim (zakładka) czy nie — więc nakładki MUSZĄ liczyć się ponownie.
  ///
  /// [track] bywa nieciągły (przerwy z pauzy / wyjścia poza obrys / wyłączonej
  /// maszyny — te punkty w ogóle nie trafiają do śladu). Odcinki dłuższe niż
  /// [maxSegmentM] traktujemy jako taki "przeskok" i pomijamy, żeby nie
  /// doliczyć fantomowego przejazdu przez przerwę.
  static double trackSweptAreaHa(
    List<LatLng> track,
    double widthM, {
    double maxSegmentM = 15.0,
  }) {
    if (track.length < 2 || widthM <= 0) return 0.0;
    var totalM = 0.0;
    for (int i = 1; i < track.length; i++) {
      final enu = toEnu(track[i - 1], track[i]);
      final segM = math.sqrt(enu.e * enu.e + enu.n * enu.n);
      if (segM <= maxSegmentM) totalM += segM;
    }
    return totalM * widthM / 10000.0;
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
