import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'package:ffi/ffi.dart';
import 'package:latlong2/latlong.dart';

// ── Typy C ────────────────────────────────────────────────────────────────────

final class FfiPosition extends Struct {
  @Double()
  external double latitude;
  @Double()
  external double longitude;
  @Double()
  external double altitude; // [m] n.p.m.
  @Float()
  external double accuracy; // [m]
}

final class FfiGuidance extends Struct {
  @Float()
  external double crossTrackError;
  @Float()
  external double headingError;
  @Int32()
  external int isValid;
}

// ── Podpisy funkcji ───────────────────────────────────────────────────────────

typedef _CreateNative = Pointer<Void> Function();
typedef _DestroyNative = Void Function(Pointer<Void>);
typedef _VersionNative = Int32 Function();
typedef _SetAbNative = Void Function(
    Pointer<Void>, Double, Double, Double, Double);
typedef _ResetAbNative = Void Function(Pointer<Void>);
typedef _UpdateNative = FfiGuidance Function(Pointer<Void>, FfiPosition);
typedef _GetPositionNative = FfiPosition Function(Pointer<Void>);

// ── Singleton ładujący .so / .dll ──────────────────────────────────────────────

class NavBridge {
  NavBridge._() {
    final lib = DynamicLibrary.open(
      Platform.isAndroid ? 'libagri_nav_ffi.so' : 'agri_nav_ffi.dll',
    );

    _version = lib.lookupFunction<_VersionNative, int Function()>(
      'agrinav_version',
    );
    _create = lib.lookupFunction<_CreateNative, _CreateNative>(
      'agrinav_create',
    );
    _destroy = lib.lookupFunction<_DestroyNative, void Function(Pointer<Void>)>(
      'agrinav_destroy',
    );
    _setAb = lib.lookupFunction<
        _SetAbNative,
        void Function(Pointer<Void>, double, double, double,
            double)>('agrinav_set_ab_line');
    _resetAb = lib.lookupFunction<_ResetAbNative, void Function(Pointer<Void>)>(
        'agrinav_reset_ab_line');
    _update = lib.lookupFunction<_UpdateNative,
        FfiGuidance Function(Pointer<Void>, FfiPosition)>('agrinav_update');
    _getPosition = lib.lookupFunction<_GetPositionNative,
        FfiPosition Function(Pointer<Void>)>('agrinav_get_position');

    _handle = _create();
  }

  static final instance = NavBridge._();

  late final Pointer<Void> _handle;
  late final int Function() _version;
  late final _CreateNative _create;
  late final void Function(Pointer<Void>) _destroy;
  late final void Function(Pointer<Void>, double, double, double, double)
      _setAb;
  late final void Function(Pointer<Void>) _resetAb;
  late final FfiGuidance Function(Pointer<Void>, FfiPosition) _update;
  late final FfiPosition Function(Pointer<Void>) _getPosition;

  /// Wersja natywnej biblioteki (aktualnie 1).
  int get version => _version();

  void setAbLine(double ax, double ay, double bx, double by) =>
      _setAb(_handle, ax, ay, bx, by);

  /// Kasuje linię AB — engine.isValid równa się false do kolejnego [setAbLine].
  void resetAbLine() => _resetAb(_handle);

  ({double crossTrack, double heading, bool valid}) update({
    required double lat,
    required double lon,
    required double alt,
    required double accuracy,
  }) {
    final pos = calloc<FfiPosition>();
    pos.ref.latitude = lat;
    pos.ref.longitude = lon;
    pos.ref.altitude = alt;
    pos.ref.accuracy = accuracy;
    final g = _update(_handle, pos.ref);
    calloc.free(pos);
    return (
      crossTrack: g.crossTrackError,
      heading: g.headingError,
      valid: g.isValid != 0,
    );
  }

  void dispose() => _destroy(_handle);

  /// Odczytuje ostatnią pozycję zapisaną w silniku (po ostatnim [update]).
  SimPosition getPosition() {
    final p = _getPosition(_handle);
    return SimPosition(
      latitude: p.latitude,
      longitude: p.longitude,
      altitude: p.altitude,
      accuracy: p.accuracy,
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// GPS Simulator – bindingi do GnssSimulator przez FFI
// ═══════════════════════════════════════════════════════════════════════════════

// Typ callbacku po stronie C: void(double, double, double, float)
typedef _SimCallbackNative = Void Function(Double, Double, Double, Float);

// Typy funkcji C
typedef _SimCreateNative = Pointer<Void> Function(Double, Double, Double);
typedef _SimStartNative = Void Function(
    Pointer<Void>, Pointer<NativeFunction<_SimCallbackNative>>);
typedef _SimStopNative = Void Function(Pointer<Void>);
typedef _SimDestroyNative = Void Function(Pointer<Void>);
typedef _SimIsRunningNative = Int32 Function(Pointer<Void>);
typedef _SimGetPositionNative = FfiPosition Function(Pointer<Void>);
typedef _SimLastNmeaNative = Pointer<Utf8> Function(Pointer<Void>);

// Dane pozycji dostarczane przez symulator
class SimPosition {
  const SimPosition({
    required this.latitude,
    required this.longitude,
    required this.altitude,
    required this.accuracy,
  });

  final double latitude;
  final double longitude;
  final double altitude; // [m]
  final double accuracy; // [m]

  @override
  String toString() =>
      'SimPosition(lat=$latitude, lon=$longitude, alt=$altitude, acc=$accuracy)';
}

/// Symulator GPS – opakowuje natywny [GnssSimulator] z C++.
///
/// Użycie:
/// ```dart
/// final sim = GnssSimulatorBridge.instance;
/// sim.onPosition = (pos) { /* aktualizuj UI */ };
/// sim.start();
/// // ...
/// sim.stop();
/// ```
class GnssSimulatorBridge {
  GnssSimulatorBridge._() {
    final lib = DynamicLibrary.open(
      Platform.isAndroid ? 'libagri_nav_ffi.so' : 'agri_nav_ffi.dll',
    );

    _simCreate = lib.lookupFunction<_SimCreateNative,
        Pointer<Void> Function(double, double, double)>(
      'agrinav_sim_create',
    );
    _simStart = lib.lookupFunction<
        _SimStartNative,
        void Function(
            Pointer<Void>, Pointer<NativeFunction<_SimCallbackNative>>)>(
      'agrinav_sim_start',
    );
    _simStop = lib.lookupFunction<_SimStopNative, void Function(Pointer<Void>)>(
      'agrinav_sim_stop',
    );
    _simDestroy =
        lib.lookupFunction<_SimDestroyNative, void Function(Pointer<Void>)>(
      'agrinav_sim_destroy',
    );
    _simIsRunning =
        lib.lookupFunction<_SimIsRunningNative, int Function(Pointer<Void>)>(
            'agrinav_sim_is_running');
    _simGetPosition = lib.lookupFunction<_SimGetPositionNative,
        FfiPosition Function(Pointer<Void>)>('agrinav_sim_get_position');
    _simLastNmea = lib.lookupFunction<_SimLastNmeaNative,
        Pointer<Utf8> Function(Pointer<Void>)>(
      'agrinav_sim_last_nmea',
    );
  }

  static final instance = GnssSimulatorBridge._();

  late final Pointer<Void> Function(double, double, double) _simCreate;
  late final void Function(
      Pointer<Void>, Pointer<NativeFunction<_SimCallbackNative>>) _simStart;
  late final void Function(Pointer<Void>) _simStop;
  late final void Function(Pointer<Void>) _simDestroy;
  late final int Function(Pointer<Void>) _simIsRunning;
  late final FfiPosition Function(Pointer<Void>) _simGetPosition;
  late final Pointer<Utf8> Function(Pointer<Void>) _simLastNmea;

  Pointer<Void>? _handle;
  NativeCallable<_SimCallbackNative>? _nativeCallable;

  /// Callback wywoływany na wątku Dart przy każdej nowej pozycji (~100 ms).
  void Function(SimPosition)? onPosition;

  /// Tworzy symulator w punkcie startowym i uruchamia wątek C++.
  ///
  /// [startLat] / [startLon] – WGS-84 stopnie dziesiętne.
  /// [startAlt]              – wysokość [m n.p.m.], domyślnie 100.
  void start({
    double startLat = 52.2297,
    double startLon = 21.0122,
    double startAlt = 100.0,
  }) {
    if (_handle != null) return; // już uruchomiony

    _handle = _simCreate(startLat, startLon, startAlt);

    // NativeCallable.listener() – bezpieczny do wywołania z obcego wątku C++.
    _nativeCallable = NativeCallable<_SimCallbackNative>.listener(
      _onNativePosition,
    );

    _simStart(_handle!, _nativeCallable!.nativeFunction);
  }

  /// Zatrzymuje wątek symulatora (blokuje do zakończenia po stronie C++).
  void stop() {
    if (_handle == null) return;
    _simStop(_handle!);
    _nativeCallable?.close();
    _nativeCallable = null;
    _simDestroy(_handle!);
    _handle = null;
  }

  /// Ostatnie zdanie \$GPGGA wygenerowane przez symulator.
  /// Zwraca null jeśli symulator nie jest uruchomiony.
  String? get lastNmea {
    if (_handle == null) return null;
    return _simLastNmea(_handle!).toDartString();
  }

  /// Natywne sprawdzenie stanu wątku symulatora.
  bool get isRunningNative => _handle != null && _simIsRunning(_handle!) != 0;

  /// Polling: ostatnia pozycja symulatora bez oczekiwania na callback.
  /// Zwraca null jeśli symulator nie został uruchomiony.
  SimPosition? getPosition() {
    if (_handle == null) return null;
    final p = _simGetPosition(_handle!);
    return SimPosition(
      latitude: p.latitude,
      longitude: p.longitude,
      altitude: p.altitude,
      accuracy: p.accuracy,
    );
  }

  bool get isRunning => _handle != null;

  // Wywoływany przez NativeCallable z wątku Dart (bezpieczne)
  void _onNativePosition(
    double lat,
    double lon,
    double alt,
    double accuracy,
  ) {
    onPosition?.call(SimPosition(
      latitude: lat,
      longitude: lon,
      altitude: alt,
      accuracy: accuracy,
    ));
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// SwathPlanner — bindingi do agrinav_plan_swaths / agrinav_free_swaths
// ═══════════════════════════════════════════════════════════════════════════════

/// Jeden przejazd uprawowy (odcinek start → end).
class Swath {
  const Swath(
      {required this.startLat,
      required this.startLon,
      required this.endLat,
      required this.endLon});

  final double startLat;
  final double startLon;
  final double endLat;
  final double endLon;
}

// Natywna struktura FfiSwathList:
//   double* data          — wskaźnik na dane
//   int32_t swath_count   — liczba swath'ów
final class FfiSwathList extends Struct {
  external Pointer<Double> data;
  @Int32()
  external int swathCount;
}

typedef _PlanSwathsNative = Pointer<FfiSwathList> Function(
    Pointer<Double>, Int32, Double, Double, Double, Double, Double);
typedef _FreeSwathsNative = Void Function(Pointer<FfiSwathList>);

/// Singleton opakowujący C++ SwathPlanner przez FFI.
class SwathPlannerBridge {
  SwathPlannerBridge._() {
    final lib = DynamicLibrary.open(
      Platform.isAndroid ? 'libagri_nav_ffi.so' : 'agri_nav_ffi.dll',
    );

    _planSwaths = lib.lookupFunction<
        _PlanSwathsNative,
        Pointer<FfiSwathList> Function(
            Pointer<Double>, int, double, double, double, double, double)>(
      'agrinav_plan_swaths',
    );
    _freeSwaths = lib.lookupFunction<_FreeSwathsNative,
        void Function(Pointer<FfiSwathList>)>(
      'agrinav_free_swaths',
    );
  }

  static final instance = SwathPlannerBridge._();

  late final Pointer<FfiSwathList> Function(
      Pointer<Double>, int, double, double, double, double, double) _planSwaths;
  late final void Function(Pointer<FfiSwathList>) _freeSwaths;

  /// Generuje równoległe ścieżki uprawowe wypełniające wielokąt pola.
  ///
  /// [polygon]       — lista punktów granicy pola (lat/lon, ≥ 3 punkty).
  /// [ax],[ay]       — punkt A linii AB (lat, lon).
  /// [bx],[by]       — punkt B linii AB (lat, lon).
  /// [workingWidthM] — szerokość robocza maszyny [m].
  List<Swath> plan({
    required List<(double lat, double lon)> polygon,
    required double ax,
    required double ay,
    required double bx,
    required double by,
    required double workingWidthM,
  }) {
    if (polygon.length < 3) return const [];

    // Zbuduj płaski bufor double [lat₀, lon₀, lat₁, lon₁, ...]
    final buf = calloc<Double>(polygon.length * 2);
    for (int i = 0; i < polygon.length; i++) {
      buf[i * 2] = polygon[i].$1; // lat
      buf[i * 2 + 1] = polygon[i].$2; // lon
    }

    final result =
        _planSwaths(buf, polygon.length, ax, ay, bx, by, workingWidthM);
    calloc.free(buf);

    final count = result.ref.swathCount;
    final List<Swath> swaths = List.generate(count, (i) {
      final d = result.ref.data;
      return Swath(
        startLat: d[i * 4 + 0],
        startLon: d[i * 4 + 1],
        endLat: d[i * 4 + 2],
        endLon: d[i * 4 + 3],
      );
    });

    _freeSwaths(result);
    return swaths;
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Full SwathPlanner — bindingi do agrinav_plan_full / agrinav_free_plan
// ═══════════════════════════════════════════════════════════════════════════════

/// Natywna struktura FfiPlanResult (64-bit layout, 32 bytes):
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

/// Wynik pełnego planowania: ścieżki wewnętrzne + pierścienie uwrociowe.
class PlanResult {
  const PlanResult({required this.swaths, required this.headlandRings});

  /// Równoległe ścieżki uprawowe wewnątrz pola.
  final List<Swath> swaths;

  /// Pierścienie uwrociowe jako listy punktów.
  /// Index 0 = zewnętrzny (objazd 1), ostatni = wewnętrzny (przy polu).
  final List<List<(double lat, double lon)>> headlandRings;

  static const PlanResult empty = PlanResult(swaths: [], headlandRings: []);
}

/// Singleton opakowujący agrinav_plan_full — zwraca swath'y + pierścienie uwroci.
class SwathPlannerFullBridge {
  SwathPlannerFullBridge._() {
    final lib = DynamicLibrary.open(
      Platform.isAndroid ? 'libagri_nav_ffi.so' : 'agri_nav_ffi.dll',
    );

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

  /// Generuje ścieżki wewnętrzne ORAZ pierścienie uwrocia.
  ///
  /// [polygon]       — granica pola (lat/lon, ≥ 3 punkty).
  /// [overlapM]      — zakładka między pasami [m]  (0 = brak zakładki).
  /// [headlandLaps]  — liczba objazdów uwrocia (0 = tylko ścieżki wewnętrzne).
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
    for (int i = 0; i < polygon.length; i++) {
      buf[i * 2] = polygon[i].$1;
      buf[i * 2 + 1] = polygon[i].$2;
    }

    final r = _planFull(buf, polygon.length, ax, ay, bx, by, workingWidthM,
        overlapM, headlandLaps);
    calloc.free(buf);

    // ── Ścieżki wewnętrzne ─────────────────────────────────────────────────
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

    // ── Pierścienie uwrocia ────────────────────────────────────────────────
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
    final lib = DynamicLibrary.open(
      Platform.isAndroid ? 'libagri_nav_ffi.so' : 'agri_nav_ffi.dll',
    );
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

  /// Load (or replace) the swath list used for snap-to-path queries.
  ///
  /// Call after [SwathPlannerFullBridge.planFull] succeeds.
  /// [originLat] / [originLon] should be AB-line point A coordinates.
  void setSwaths(List<Swath> swaths, double originLat, double originLon) {
    if (swaths.isEmpty) return;
    final buf = calloc<Double>(swaths.length * 4);
    for (int i = 0; i < swaths.length; i++) {
      buf[i * 4 + 0] = swaths[i].startLat;
      buf[i * 4 + 1] = swaths[i].startLon;
      buf[i * 4 + 2] = swaths[i].endLat;
      buf[i * 4 + 3] = swaths[i].endLon;
    }
    _setSwaths(_handle, buf, swaths.length, originLat, originLon);
    calloc.free(buf);
  }

  /// Query the nearest swath for the given position and machine heading.
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
typedef _SectionClearNative = Void Function(Pointer<Void>);

/// Singleton wrapping the C++ SectionControl engine via dart:ffi.
///
/// Provides grid-based coverage area tracking (1 m² cells) and per-strip
/// overlap detection.  Call [setOrigin] before [addStrip].
class SectionControlBridge {
  SectionControlBridge._() {
    final lib = DynamicLibrary.open(
      Platform.isAndroid ? 'libagri_nav_ffi.so' : 'agri_nav_ffi.dll',
    );
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
  late final void Function(Pointer<Void>) _clearFn;

  /// Set ENU origin to the field centre.  Must be called before [addStrip].
  void setOrigin(double lat, double lon) => _setOriginFn(_handle, lat, lon);

  /// Read-only overlap check; returns fraction [0–1] already covered.
  double checkOverlap(
          double lat, double lon, double headingDeg, double toolWidthM) =>
      _checkOverlapFn(_handle, lat, lon, headingDeg, toolWidthM);

  /// Mark tool footprint covered; returns overlap fraction BEFORE this strip.
  double addStrip(
          double lat, double lon, double headingDeg, double toolWidthM) =>
      _addStripFn(_handle, lat, lon, headingDeg, toolWidthM);

  /// Total covered area [ha].
  double coveredAreaHa() => _coveredHaFn(_handle);

  /// Erase all coverage (retains origin + cell size).
  void clear() => _clearFn(_handle);

  /// Replay a saved track to restore the coverage grid after app relaunch.
  /// Uses consecutive point pairs to determine heading.
  void replayTrack(List<LatLng> track, double toolWidthM) {
    if (track.length < 2) return;
    for (int i = 1; i < track.length; i++) {
      final heading = _bearing(track[i - 1], track[i]);
      addStrip(track[i].latitude, track[i].longitude, heading, toolWidthM);
    }
  }

  static double _bearing(LatLng from, LatLng to) {
    const toRad = math.pi / 180.0;
    final dLon = (to.longitude - from.longitude) * toRad;
    final lat1 = from.latitude * toRad;
    final lat2 = to.latitude * toRad;
    final y = math.sin(dLon) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
    return (math.atan2(y, x) * 180.0 / math.pi + 360.0) % 360.0;
  }

  void dispose() => _destroy(_handle);
}

// ═══════════════════════════════════════════════════════════════════════════════
// ParcelMergerBridge — scalanie działek katastralnych przez C++ Clipper2
// ═══════════════════════════════════════════════════════════════════════════════

/// Typ pierścienia wynikowego — odpowiada FfiRingType w C.
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

/// Jeden pierścień w wyniku scalania.
class MergeRing {
  const MergeRing({required this.points, required this.type});
  final List<LatLng> points;
  final MergeRingType type;

  bool get isOuter =>
      type == MergeRingType.outerPrimary ||
      type == MergeRingType.outerSecondary;
}

/// Wynik scalania działek.
class MergeFieldResult {
  const MergeFieldResult({required this.rings, required this.isMultipart});

  final List<MergeRing> rings;

  /// true gdy działki nie stykają się i wynik zawiera wiele zewnętrznych granic.
  final bool isMultipart;

  /// Główna granica zewnętrzna (największa).
  List<LatLng> get primaryBoundary =>
      rings
          .where((r) => r.type == MergeRingType.outerPrimary)
          .map((r) => r.points)
          .firstOrNull ??
      [];

  /// Wszystkie otwory (dziury) w głównej granicy.
  List<List<LatLng>> get holes => rings
      .where((r) => r.type == MergeRingType.holePrimary)
      .map((r) => r.points)
      .toList();
}

// ── FFI struct dla FfiMergeResult ────────────────────────────────────────────

final class _FfiMergeResult extends Struct {
  external Pointer<Double> ringData;
  external Pointer<Int32> ringVertexCounts;
  external Pointer<Int32> ringTypes;
  @Int32()
  external int ringCount;
  @Int32()
  external int isMultipart;
}

// ── Sygnatury funkcji ────────────────────────────────────────────────────────

typedef _MergeParcelsNative = Pointer<_FfiMergeResult> Function(
    Pointer<Double>, Pointer<Int32>, Int32, Double);
typedef _FreeMergeResultNative = Void Function(Pointer<_FfiMergeResult>);

// ── Bridge ───────────────────────────────────────────────────────────────────

/// Singleton do scalania geometrii działek przez C++ Clipper2.
class ParcelMergerBridge {
  ParcelMergerBridge._() {
    final lib = DynamicLibrary.open(
      Platform.isAndroid ? 'libagri_nav_ffi.so' : 'agri_nav_ffi.dll',
    );
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

  /// Scala listę wielokątów w jeden obrys pola.
  ///
  /// [polygons] — lista wielokątów WGS-84.
  /// [bufferM]  — outward buffer [m] do zamknięcia szczelin (domyślnie 5 cm).
  ///
  /// Rzuca [StateError] gdy wynik jest pusty (np. wszystkie wejścia niepoprawne).
  MergeFieldResult merge(
    List<List<LatLng>> polygons, {
    double bufferM = 0.05,
  }) {
    if (polygons.isEmpty) throw StateError('Brak wielokątów do scalenia');

    // Zbuduj płaski bufor danych
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
      if (result == nullptr)
        throw StateError('agrinav_merge_parcels zwrócił NULL');

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
