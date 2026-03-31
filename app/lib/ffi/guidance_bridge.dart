import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:latlong2/latlong.dart';

import 'native_lib.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// SwathPlanner — bindings for agrinav_plan_full / agrinav_free_plan
// ═══════════════════════════════════════════════════════════════════════════════

/// One cultivated pass (a start → end segment).
class Swath {
  const Swath({
    required this.startLat,
    required this.startLon,
    required this.endLat,
    required this.endLon,
  });

  final double startLat;
  final double startLon;
  final double endLat;
  final double endLon;
}

/// Native struct FfiPlanResult (64-bit layout, 32 bytes):
///   +0   Pointer<Double>  swathData
///   +8   Pointer<Double>  ringPointData
///   +16  Pointer<Int32>   ringPointCounts
///   +24  Int32            swathCount
///   +28  Int32            ringCount
final class FfiPlanResult extends Struct {
  external Pointer<Double> swathData;
  external Pointer<Double> ringPointData;
  external Pointer<Int32> ringPointCounts;
  @Int32()
  external int swathCount;
  @Int32()
  external int ringCount;
}

typedef _PlanFullNative = Pointer<FfiPlanResult> Function(Pointer<Double>,
    Int32, Double, Double, Double, Double, Double, Double, Int32);
typedef _FreePlanNative = Void Function(Pointer<FfiPlanResult>);

/// Result of full planning: internal swaths + headland rings.
class PlanResult {
  const PlanResult({required this.swaths, required this.headlandRings});

  /// Parallel cultivated passes inside the field.
  final List<Swath> swaths;

  /// Headland rings as lists of points.
  /// Index 0 = outermost (first pass), last = innermost (adjacent to field).
  final List<List<(double lat, double lon)>> headlandRings;

  static const PlanResult empty = PlanResult(swaths: [], headlandRings: []);
}

/// Singleton wrapping agrinav_plan_full — returns swaths + headland rings.
class SwathPlannerFullBridge {
  SwathPlannerFullBridge._() {
    final lib = nativeLib;

    _planFull = lib.lookupFunction<
        _PlanFullNative,
        Pointer<FfiPlanResult> Function(Pointer<Double>, int, double, double,
            double, double, double, double, int)>('agrinav_plan_full');

    _freePlan = lib.lookupFunction<_FreePlanNative,
        void Function(Pointer<FfiPlanResult>)>('agrinav_free_plan');
  }

  static final instance = SwathPlannerFullBridge._();
  late final Pointer<FfiPlanResult> Function(Pointer<Double>, int, double,
      double, double, double, double, double, int) _planFull;
  late final void Function(Pointer<FfiPlanResult>) _freePlan;

  /// Generates internal swaths AND headland rings.
  ///
  /// [polygon]       — field boundary (lat/lon, ≥ 3 points).
  /// [overlapM]      — strip overlap [m] (0 = no overlap).
  /// [headlandLaps]  — number of headland passes (0 = inner swaths only).
  ///
  /// BUG#1 FIX: polygon buffer wrapped in try/finally.
  /// BUG#2 FIX: nullptr check on the planFull return value.
  PlanResult planFull({
    required List<(double lat, double lon)> polygon,
    required double ax,
    required double ay,
    required double bx,
    required double by,
    required double workingWidthM,
    double overlapM = 0.0,
    int headlandLaps = 0,
  }) {
    if (polygon.length < 3) return PlanResult.empty;

    final buf = calloc<Double>(polygon.length * 2);
    try {
      for (int i = 0; i < polygon.length; i++) {
        buf[i * 2] = polygon[i].$1;
        buf[i * 2 + 1] = polygon[i].$2;
      }

      final r = _planFull(buf, polygon.length, ax, ay, bx, by, workingWidthM,
          overlapM, headlandLaps);

      // BUG#2 FIX: null-check before dereferencing the result pointer
      if (r == nullptr) return PlanResult.empty;

      // ── Internal swaths ────────────────────────────────────────────────────
      final swathCount = r.ref.swathCount;
      final List<Swath> swaths = List.generate(swathCount, (i) {
        final d = r.ref.swathData;
        return Swath(
          startLat: d[i * 4 + 0],
          startLon: d[i * 4 + 1],
          endLat: d[i * 4 + 2],
          endLon: d[i * 4 + 3],
        );
      });

      // ── Headland rings ─────────────────────────────────────────────────────
      final ringCount = r.ref.ringCount;
      final List<List<(double, double)>> rings = [];
      if (ringCount > 0) {
        int offset = 0;
        for (int k = 0; k < ringCount; k++) {
          final pts = r.ref.ringPointCounts[k];
          final List<(double, double)> ring = List.generate(pts, (j) {
            final idx = (offset + j) * 2;
            return (r.ref.ringPointData[idx], r.ref.ringPointData[idx + 1]);
          });
          rings.add(ring);
          offset += pts;
        }
      }

      _freePlan(r);
      return PlanResult(swaths: swaths, headlandRings: rings);
    } finally {
      calloc.free(buf);
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// SwathGuidance — snap-to-nearest-swath FFI bridge
// ═══════════════════════════════════════════════════════════════════════════════

/// Mirrors the C struct FfiSnapResult (16 bytes: float, int32, int32, float).
final class FfiSnapResult extends Struct {
  @Float()
  external double distanceM;
  @Int32()
  external int swathIndex;
  @Int32()
  external int side;
  @Float()
  external double headingErrorDeg;
}

/// Dart-friendly result of a snap-to-nearest-swath query.
class SnapInfo {
  const SnapInfo({
    required this.distanceM,
    required this.swathIndex,
    required this.side,
    required this.headingErrorDeg,
  });

  /// Unsigned perpendicular distance to the nearest swath [m].
  final double distanceM;

  /// Index into the current swath list (−1 = no swaths loaded).
  final int swathIndex;

  /// +1 = right of swath direction, −1 = left, 0 = on-line.
  final int side;

  /// Signed heading error [deg]: machine heading − swath direction.
  final double headingErrorDeg;

  static const SnapInfo none =
      SnapInfo(distanceM: 0, swathIndex: -1, side: 0, headingErrorDeg: 0);
}

typedef _GuidanceCreateNative = Pointer<Void> Function();
typedef _GuidanceDestroyNative = Void Function(Pointer<Void>);
typedef _GuidanceSetSwathsNative = Void Function(
    Pointer<Void>, Pointer<Double>, Int32, Double, Double);
typedef _GuidanceQueryNative = FfiSnapResult Function(
    Pointer<Void>, Double, Double, Float);

/// Singleton wrapping the C++ SwathGuidance engine via dart:ffi.
class SwathGuidanceBridge {
  SwathGuidanceBridge._() {
    final lib = nativeLib;
    _create =
        lib.lookupFunction<_GuidanceCreateNative, Pointer<Void> Function()>(
            'agrinav_guidance_create');
    _destroy = lib.lookupFunction<_GuidanceDestroyNative,
        void Function(Pointer<Void>)>('agrinav_guidance_destroy');
    _setSwaths = lib.lookupFunction<_GuidanceSetSwathsNative,
        void Function(Pointer<Void>, Pointer<Double>, int, double, double)>(
      'agrinav_guidance_set_swaths',
    );
    _query = lib.lookupFunction<_GuidanceQueryNative,
        FfiSnapResult Function(Pointer<Void>, double, double, double)>(
      'agrinav_guidance_query',
    );
    _handle = _create();
  }

  static final instance = SwathGuidanceBridge._();

  late final Pointer<Void> _handle;
  late final Pointer<Void> Function() _create;
  late final void Function(Pointer<Void>) _destroy;
  late final void Function(Pointer<Void>, Pointer<Double>, int, double, double)
      _setSwaths;
  late final FfiSnapResult Function(Pointer<Void>, double, double, double)
      _query;

  /// Loads (or replaces) the swath list used for snap-to-path queries.
  ///
  /// Call after [SwathPlannerFullBridge.planFull] succeeds.
  /// [originLat] / [originLon] should be AB-line point A coordinates.
  ///
  /// BUG#1 FIX: calloc wrapped in try/finally.
  void setSwaths(List<Swath> swaths, double originLat, double originLon) {
    if (swaths.isEmpty) return;
    final buf = calloc<Double>(swaths.length * 4);
    try {
      for (int i = 0; i < swaths.length; i++) {
        buf[i * 4 + 0] = swaths[i].startLat;
        buf[i * 4 + 1] = swaths[i].startLon;
        buf[i * 4 + 2] = swaths[i].endLat;
        buf[i * 4 + 3] = swaths[i].endLon;
      }
      _setSwaths(_handle, buf, swaths.length, originLat, originLon);
    } finally {
      calloc.free(buf);
    }
  }

  /// Queries the nearest swath for the given position and machine heading.
  SnapInfo query(double lat, double lon, double headingDeg) {
    final r = _query(_handle, lat, lon, headingDeg);
    return SnapInfo(
      distanceM: r.distanceM.toDouble(),
      swathIndex: r.swathIndex,
      side: r.side,
      headingErrorDeg: r.headingErrorDeg.toDouble(),
    );
  }

  void dispose() => _destroy(_handle);
}

// ═══════════════════════════════════════════════════════════════════════════════
// HeadlandGuidance — snap-to-nearest-headland-ring FFI bridge
// ═══════════════════════════════════════════════════════════════════════════════

/// Mirrors the C struct FfiHeadlandResult (16 bytes: float, float, int32, int32).
final class FfiHeadlandResult extends Struct {
  @Float()
  external double crossTrackM;
  @Float()
  external double headingErrorDeg;
  @Int32()
  external int ringIndex;
  @Int32()
  external int segmentIndex;
}

/// Dart-friendly result of a snap-to-nearest-headland-ring query.
class HeadlandSnapInfo {
  const HeadlandSnapInfo({
    required this.crossTrackM,
    required this.headingErrorDeg,
    required this.ringIndex,
    required this.segmentIndex,
  });

  /// Signed cross-track distance [m]: + = right of ring travel direction.
  final double crossTrackM;

  /// Signed heading error [deg]: machine heading minus ring local tangent.
  final double headingErrorDeg;

  /// Index of the nearest ring (−1 = no rings loaded).
  final int ringIndex;

  /// Index of the nearest segment within the ring.
  final int segmentIndex;

  static const HeadlandSnapInfo none = HeadlandSnapInfo(
      crossTrackM: 0, headingErrorDeg: 0, ringIndex: -1, segmentIndex: -1);
}

typedef _HeadlandCreateNative = Pointer<Void> Function();
typedef _HeadlandDestroyNative = Void Function(Pointer<Void>);
typedef _HeadlandSetRingsNative = Void Function(
    Pointer<Void>, Pointer<Double>, Pointer<Int32>, Int32, Double, Double);
typedef _HeadlandQueryNative = FfiHeadlandResult Function(
    Pointer<Void>, Double, Double, Float);

/// Singleton wrapping the C++ HeadlandGuidance engine via dart:ffi.
class HeadlandGuidanceBridge {
  HeadlandGuidanceBridge._() {
    final lib = nativeLib;
    _create =
        lib.lookupFunction<_HeadlandCreateNative, Pointer<Void> Function()>(
            'agrinav_headland_create');
    _destroy = lib.lookupFunction<_HeadlandDestroyNative,
        void Function(Pointer<Void>)>('agrinav_headland_destroy');
    _setRings = lib.lookupFunction<
        _HeadlandSetRingsNative,
        void Function(Pointer<Void>, Pointer<Double>, Pointer<Int32>, int,
            double, double)>(
      'agrinav_headland_set_rings',
    );
    _query = lib.lookupFunction<_HeadlandQueryNative,
        FfiHeadlandResult Function(Pointer<Void>, double, double, double)>(
      'agrinav_headland_query',
    );
    _handle = _create();
  }

  static final instance = HeadlandGuidanceBridge._();

  late final Pointer<Void> _handle;
  late final Pointer<Void> Function() _create;
  late final void Function(Pointer<Void>) _destroy;
  late final void Function(
          Pointer<Void>, Pointer<Double>, Pointer<Int32>, int, double, double)
      _setRings;
  late final FfiHeadlandResult Function(Pointer<Void>, double, double, double)
      _query;

  /// Loads (or replaces) all headland rings used for snap-to-path queries.
  ///
  /// [rings]      — headland rings from [PlanResult.headlandRings].
  /// [originLat]  — WGS-84 latitude  of the ENU origin (AB-line point A).
  /// [originLon]  — WGS-84 longitude of the ENU origin.
  ///
  /// BUG#1 FIX: both calloc allocations wrapped in a single try/finally so
  /// neither buffer leaks when an exception is thrown between the two allocs or
  /// during the FFI call.
  void setRings(
    List<List<LatLng>> rings,
    double originLat,
    double originLon,
  ) {
    if (rings.isEmpty) return;

    final totalPts = rings.fold(0, (s, r) => s + r.length);
    final pointBuf = calloc<Double>(totalPts * 2);
    final countBuf = calloc<Int32>(rings.length);
    try {
      int dataOffset = 0;
      for (int ri = 0; ri < rings.length; ri++) {
        final ring = rings[ri];
        countBuf[ri] = ring.length;
        for (final pt in ring) {
          pointBuf[dataOffset++] = pt.latitude;
          pointBuf[dataOffset++] = pt.longitude;
        }
      }
      _setRings(
          _handle, pointBuf, countBuf, rings.length, originLat, originLon);
    } finally {
      calloc.free(pointBuf);
      calloc.free(countBuf);
    }
  }

  /// Queries the nearest headland ring segment for the given position/heading.
  HeadlandSnapInfo query(double lat, double lon, double headingDeg) {
    final r = _query(_handle, lat, lon, headingDeg);
    return HeadlandSnapInfo(
      crossTrackM: r.crossTrackM.toDouble(),
      headingErrorDeg: r.headingErrorDeg.toDouble(),
      ringIndex: r.ringIndex,
      segmentIndex: r.segmentIndex,
    );
  }

  void dispose() => _destroy(_handle);
}
