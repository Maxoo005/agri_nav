import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

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
