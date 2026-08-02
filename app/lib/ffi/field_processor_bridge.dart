import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:latlong2/latlong.dart';

import '../utils/geo_utils.dart';
import 'native_lib.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// Merge result types (shared by ParcelMergerBridge + LpisProcessorBridge)
// ═══════════════════════════════════════════════════════════════════════════════

/// Result ring type — mirrors FfiRingType in C.
enum MergeRingType {
  outerPrimary(0),
  holePrimary(1),
  outerSecondary(2),
  holeSecondary(3);

  const MergeRingType(this.value);
  final int value;

  static MergeRingType fromInt(int v) =>
      MergeRingType.values.firstWhere((e) => e.value == v,
          orElse: () => MergeRingType.outerPrimary);
}

/// One ring in a merge result.
class MergeRing {
  const MergeRing({required this.points, required this.type});
  final List<LatLng> points;
  final MergeRingType type;

  bool get isOuter =>
      type == MergeRingType.outerPrimary ||
      type == MergeRingType.outerSecondary;
}

/// Result of merging parcels.
class MergeFieldResult {
  const MergeFieldResult({required this.rings, required this.isMultipart});

  final List<MergeRing> rings;

  /// true when the parcels do not touch and the result contains multiple outer boundaries.
  final bool isMultipart;

  /// Main outer boundary (largest).
  List<LatLng> get primaryBoundary =>
      rings
          .where((r) => r.type == MergeRingType.outerPrimary)
          .map((r) => r.points)
          .firstOrNull ??
      [];

  /// All holes (cutouts) in the main boundary.
  List<List<LatLng>> get holes => rings
      .where((r) => r.type == MergeRingType.holePrimary)
      .map((r) => r.points)
      .toList();
}

// ═══════════════════════════════════════════════════════════════════════════════
// SectionControl — Coverage area + overlap detection FFI bridge
// ═══════════════════════════════════════════════════════════════════════════════

typedef _SectionCreateNative = Pointer<Void> Function(Double);
typedef _SectionDestroyNative = Void Function(Pointer<Void>);
typedef _SectionSetOriginNative = Void Function(Pointer<Void>, Double, Double);
typedef _SectionCheckOverlapNative = Float Function(
    Pointer<Void>, Double, Double, Float, Double);
typedef _SectionAddStripNative = Float Function(
    Pointer<Void>, Double, Double, Float, Double);
typedef _SectionCoveredHaNative = Double Function(Pointer<Void>);
typedef _SectionNewAreaHaNative = Double Function(Pointer<Void>);
typedef _SectionClearNative = Void Function(Pointer<Void>);

/// Singleton wrapping the C++ SectionControl engine via dart:ffi.
///
/// Provides grid-based coverage area tracking (1 m² cells) and per-strip
/// overlap detection.  Call [setOrigin] before [addStrip].
class SectionControlBridge {
  SectionControlBridge._() {
    final lib = nativeLib;
    _create = lib.lookupFunction<_SectionCreateNative,
        Pointer<Void> Function(double)>('agrinav_section_create');
    _destroy =
        lib.lookupFunction<_SectionDestroyNative, void Function(Pointer<Void>)>(
            'agrinav_section_destroy');
    _setOriginFn = lib.lookupFunction<_SectionSetOriginNative,
        void Function(Pointer<Void>, double, double)>(
      'agrinav_section_set_origin',
    );
    _checkOverlapFn = lib.lookupFunction<_SectionCheckOverlapNative,
        double Function(Pointer<Void>, double, double, double, double)>(
      'agrinav_section_check_overlap',
    );
    _addStripFn = lib.lookupFunction<_SectionAddStripNative,
        double Function(Pointer<Void>, double, double, double, double)>(
      'agrinav_section_add_strip',
    );
    _coveredHaFn = lib.lookupFunction<_SectionCoveredHaNative,
        double Function(Pointer<Void>)>('agrinav_section_covered_ha');
    _newAreaHaFn = lib.lookupFunction<_SectionNewAreaHaNative,
        double Function(Pointer<Void>)>('agrinav_section_new_area_ha');
    _clearFn =
        lib.lookupFunction<_SectionClearNative, void Function(Pointer<Void>)>(
            'agrinav_section_clear');
    _handle = _create(1.0); // 1 m² cells
  }

  static final instance = SectionControlBridge._();

  late final Pointer<Void> _handle;
  late final Pointer<Void> Function(double) _create;
  late final void Function(Pointer<Void>) _destroy;
  late final void Function(Pointer<Void>, double, double) _setOriginFn;
  late final double Function(Pointer<Void>, double, double, double, double)
      _checkOverlapFn;
  late final double Function(Pointer<Void>, double, double, double, double)
      _addStripFn;
  late final double Function(Pointer<Void>) _coveredHaFn;
  late final double Function(Pointer<Void>) _newAreaHaFn;
  late final void Function(Pointer<Void>) _clearFn;

  /// Sets the ENU origin to the field centre.  Must be called before [addStrip].
  void setOrigin(double lat, double lon) => _setOriginFn(_handle, lat, lon);

  /// Read-only overlap check; returns fraction [0–1] already covered.
  double checkOverlap(
          double lat, double lon, double headingDeg, double toolWidthM) =>
      _checkOverlapFn(_handle, lat, lon, headingDeg, toolWidthM);

  /// Marks the tool footprint as covered; returns overlap fraction BEFORE this strip.
  double addStrip(
          double lat, double lon, double headingDeg, double toolWidthM) =>
      _addStripFn(_handle, lat, lon, headingDeg, toolWidthM);

  /// Total covered area [ha].
  double coveredAreaHa() => _coveredHaFn(_handle);

  /// Net new area [ha] added by the most recent [addStrip] call.
  /// Returns 0.0 when the strip was fully inside already-covered area.
  double newAreaHaLastStrip() => _newAreaHaFn(_handle);

  /// Erases all coverage (retains origin + cell size).
  void clear() => _clearFn(_handle);

  /// Replays a saved track to restore the coverage grid after app relaunch.
  ///
  /// Yields to the event loop every 50 points so the UI thread stays
  /// responsive during large (> 1 000 point) track replays.
  Future<double> replayTrack(List<LatLng> track, double toolWidthM) async {
    if (track.length < 2) return coveredAreaHa();
    for (int i = 1; i < track.length; i++) {
      final heading = GeoUtils.bearing(track[i - 1], track[i]);
      addStrip(track[i].latitude, track[i].longitude, heading, toolWidthM);
      // Yield every 50 strips to keep the UI at 60 fps
      if (i % 50 == 0) await Future<void>.delayed(Duration.zero);
    }
    return coveredAreaHa();
  }

  void dispose() => _destroy(_handle);
}

// ═══════════════════════════════════════════════════════════════════════════════
// ParcelMerger — merging cadastral parcels via C++ Clipper2
// ═══════════════════════════════════════════════════════════════════════════════

// ── FFI struct for FfiMergeResult ─────────────────────────────────────────────

final class _FfiMergeResult extends Struct {
  external Pointer<Double> ringData;
  external Pointer<Int32> ringVertexCounts;
  external Pointer<Int32> ringTypes;
  @Int32()
  external int ringCount;
  @Int32()
  external int isMultipart;
}

// ── Function signatures ───────────────────────────────────────────────────────

typedef _MergeParcelsNative = Pointer<_FfiMergeResult> Function(
    Pointer<Double>, Pointer<Int32>, Int32, Double);
typedef _FreeMergeResultNative = Void Function(Pointer<_FfiMergeResult>);

// ── Bridge ────────────────────────────────────────────────────────────────────

/// Singleton for merging parcel geometries via C++ Clipper2.
class ParcelMergerBridge {
  ParcelMergerBridge._() {
    final lib = nativeLib;
    _merge = lib.lookupFunction<
        _MergeParcelsNative,
        Pointer<_FfiMergeResult> Function(
            Pointer<Double>, Pointer<Int32>, int, double)>(
      'agrinav_merge_parcels',
    );
    _free = lib.lookupFunction<_FreeMergeResultNative,
        void Function(Pointer<_FfiMergeResult>)>(
      'agrinav_free_merge_result',
    );
  }

  static final instance = ParcelMergerBridge._();

  late final Pointer<_FfiMergeResult> Function(
      Pointer<Double>, Pointer<Int32>, int, double) _merge;
  late final void Function(Pointer<_FfiMergeResult>) _free;

  /// Merges a list of polygons into a single field outline.
  ///
  /// [polygons] — list of WGS-84 polygons.
  /// [bufferM]  — outward buffer [m] to close gaps (default 5 cm).
  ///
  /// Throws [StateError] when the result is empty (e.g. all inputs invalid).
  MergeFieldResult merge(
    List<List<LatLng>> polygons, {
    double bufferM = 0.05,
  }) {
    if (polygons.isEmpty) throw StateError('Brak wielokątów do scalenia');

    final totalVerts = polygons.fold(0, (s, p) => s + p.length);
    final polyData = calloc<Double>(totalVerts * 2);
    final vertCounts = calloc<Int32>(polygons.length);

    try {
      int dataOffset = 0;
      for (int i = 0; i < polygons.length; i++) {
        final poly = polygons[i];
        vertCounts[i] = poly.length;
        for (final pt in poly) {
          polyData[dataOffset++] = pt.latitude;
          polyData[dataOffset++] = pt.longitude;
        }
      }

      final result = _merge(polyData, vertCounts, polygons.length, bufferM);
      if (result == nullptr) {
        throw StateError('agrinav_merge_parcels zwrócił NULL');
      }

      try {
        return _parseResult(result);
      } finally {
        _free(result);
      }
    } finally {
      calloc.free(polyData);
      calloc.free(vertCounts);
    }
  }

  MergeFieldResult _parseResult(Pointer<_FfiMergeResult> ptr) {
    final r = ptr.ref;
    if (r.ringCount == 0) {
      return const MergeFieldResult(rings: [], isMultipart: false);
    }

    final rings = <MergeRing>[];
    int dataOffset = 0;

    for (int i = 0; i < r.ringCount; i++) {
      final vc = r.ringVertexCounts[i];
      final type = MergeRingType.fromInt(r.ringTypes[i]);
      final points = <LatLng>[];
      for (int j = 0; j < vc; j++) {
        final lat = r.ringData[dataOffset++];
        final lon = r.ringData[dataOffset++];
        points.add(LatLng(lat, lon));
      }
      rings.add(MergeRing(points: points, type: type));
    }

    return MergeFieldResult(
      rings: rings,
      isMultipart: r.isMultipart != 0,
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// LpisProcessor — union + simplify + buffer for ARiMR LPIS parcels
// ═══════════════════════════════════════════════════════════════════════════════

/// Native struct _FfiLpisOptions (32 bytes, identical to C).
/// Fields must be in the same order and size as in agri_nav_ffi.h.
final class _FfiLpisOptions extends Struct {
  @Double()
  external double bufferM;
  @Double()
  external double simplifyEpsilonM;
  @Int32()
  external int minRingVertices;
  @Int32()
  external int pad; // padding
}

typedef _ProcessLpisNative = Pointer<_FfiMergeResult> Function(
    Pointer<Double>, Pointer<Int32>, Int32, _FfiLpisOptions);

/// Singleton wrapping `agrinav_process_lpis` — scales LPIS geometry via
/// C++ GeometryProcessor (union + RDP simplify + Clipper2 buffer).
///
/// The call is launched in `Isolate.run` — does not block the UI thread.
class LpisProcessorBridge {
  LpisProcessorBridge._() {
    final lib = nativeLib;
    _processLpis = lib.lookupFunction<
        _ProcessLpisNative,
        Pointer<_FfiMergeResult> Function(
            Pointer<Double>, Pointer<Int32>, int, _FfiLpisOptions)>(
      'agrinav_process_lpis',
    );
    _free = lib.lookupFunction<_FreeMergeResultNative,
        void Function(Pointer<_FfiMergeResult>)>(
      'agrinav_free_merge_result',
    );
  }

  static final instance = LpisProcessorBridge._();

  late final Pointer<_FfiMergeResult> Function(
      Pointer<Double>, Pointer<Int32>, int, _FfiLpisOptions) _processLpis;
  late final void Function(Pointer<_FfiMergeResult>) _free;

  /// Merges and simplifies a list of LPIS polygons.
  ///
  /// [polygons]         — ARiMR agricultural parcels (WGS-84).
  /// [bufferM]          — outward buffer [m], default 2 cm.
  /// [simplifyEpsilonM] — RDP epsilon [m], default 0.3 m.
  ///
  /// Runs C++ in `Isolate.run` — safe to call from async UI code.
  Future<MergeFieldResult> processAsync(
    List<List<LatLng>> polygons, {
    double bufferM = 0.02,
    double simplifyEpsilonM = 0.3,
  }) async {
    if (polygons.isEmpty) {
      throw StateError('Brak działek LPIS do przetworzenia');
    }

    // Serialise to plain lists — safe to transfer between Isolates
    final flatCoords = <double>[];
    final counts = <int>[];
    for (final poly in polygons) {
      counts.add(poly.length);
      for (final pt in poly) {
        flatCoords.add(pt.latitude);
        flatCoords.add(pt.longitude);
      }
    }

    return Isolate.run(() {
      return LpisProcessorBridge.instance._processSync(
        flatCoords,
        counts,
        bufferM: bufferM,
        simplifyEpsilonM: simplifyEpsilonM,
      );
    });
  }

  MergeFieldResult _processSync(
    List<double> flatCoords,
    List<int> counts, {
    required double bufferM,
    required double simplifyEpsilonM,
  }) {
    final polyData = calloc<Double>(flatCoords.length);
    final vertCounts = calloc<Int32>(counts.length);

    try {
      for (int i = 0; i < flatCoords.length; i++) {
        polyData[i] = flatCoords[i];
      }
      for (int i = 0; i < counts.length; i++) {
        vertCounts[i] = counts[i];
      }

      final opts = calloc<_FfiLpisOptions>();
      opts.ref.bufferM = bufferM;
      opts.ref.simplifyEpsilonM = simplifyEpsilonM;
      opts.ref.minRingVertices = 3;
      opts.ref.pad = 0;
      final optsVal = opts.ref;
      calloc.free(opts);

      final result = _processLpis(polyData, vertCounts, counts.length, optsVal);
      if (result == nullptr) {
        throw StateError('agrinav_process_lpis zwrócił NULL');
      }

      try {
        return _parseMergeResult(result);
      } finally {
        _free(result);
      }
    } finally {
      calloc.free(polyData);
      calloc.free(vertCounts);
    }
  }

  MergeFieldResult _parseMergeResult(Pointer<_FfiMergeResult> ptr) {
    final r = ptr.ref;
    if (r.ringCount == 0) {
      return const MergeFieldResult(rings: [], isMultipart: false);
    }

    final rings = <MergeRing>[];
    int dataOffset = 0;
    for (int i = 0; i < r.ringCount; i++) {
      final vc = r.ringVertexCounts[i];
      final type = MergeRingType.fromInt(r.ringTypes[i]);
      final points = <LatLng>[];
      for (int j = 0; j < vc; j++) {
        final lat = r.ringData[dataOffset++];
        final lon = r.ringData[dataOffset++];
        points.add(LatLng(lat, lon));
      }
      rings.add(MergeRing(points: points, type: type));
    }
    return MergeFieldResult(rings: rings, isMultipart: r.isMultipart != 0);
  }
}
