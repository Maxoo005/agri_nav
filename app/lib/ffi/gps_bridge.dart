import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'native_lib.dart';

// ── C struct mirrors ──────────────────────────────────────────────────────────

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

// ── Function signatures ───────────────────────────────────────────────────────

typedef _CreateNative = Pointer<Void> Function();
typedef _DestroyNative = Void Function(Pointer<Void>);
typedef _VersionNative = Int32 Function();
typedef _SetAbNative = Void Function(
    Pointer<Void>, Double, Double, Double, Double);
typedef _ResetAbNative = Void Function(Pointer<Void>);
typedef _UpdateNative = FfiGuidance Function(Pointer<Void>, FfiPosition);
typedef _GetPositionNative = FfiPosition Function(Pointer<Void>);

// ── NavBridge ────────────────────────────────────────────────────────────────

class NavBridge {
  NavBridge._() {
    final lib = nativeLib;

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

  /// Version number of the native library (currently 1).
  int get version => _version();

  void setAbLine(double ax, double ay, double bx, double by) =>
      _setAb(_handle, ax, ay, bx, by);

  /// Clears the AB line — engine.isValid returns false until next [setAbLine].
  void resetAbLine() => _resetAb(_handle);

  /// BUG#1 FIX: calloc is now wrapped in try/finally so the buffer is freed
  /// even when an exception propagates (e.g. OOM at 10 Hz).
  ({double crossTrack, double heading, bool valid}) update({
    required double lat,
    required double lon,
    required double alt,
    required double accuracy,
  }) {
    final pos = calloc<FfiPosition>();
    try {
      pos.ref
        ..latitude = lat
        ..longitude = lon
        ..altitude = alt
        ..accuracy = accuracy;
      final g = _update(_handle, pos.ref);
      return (
        crossTrack: g.crossTrackError,
        heading: g.headingError,
        valid: g.isValid != 0,
      );
    } finally {
      calloc.free(pos);
    }
  }

  void dispose() => _destroy(_handle);

  /// Reads the last position stored in the engine (after the last [update]).
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
// GPS Simulator — bindings for GnssSimulator via FFI
// ═══════════════════════════════════════════════════════════════════════════════

// Native callback type: void(double, double, double, float)
typedef _SimCallbackNative = Void Function(Double, Double, Double, Float);

// C function types
typedef _SimCreateNative = Pointer<Void> Function(Double, Double, Double);
typedef _SimStartNative = Void Function(
    Pointer<Void>, Pointer<NativeFunction<_SimCallbackNative>>);
typedef _SimStopNative = Void Function(Pointer<Void>);
typedef _SimDestroyNative = Void Function(Pointer<Void>);
typedef _SimIsRunningNative = Int32 Function(Pointer<Void>);
typedef _SimGetPositionNative = FfiPosition Function(Pointer<Void>);
typedef _SimLastNmeaNative = Pointer<Utf8> Function(Pointer<Void>);

/// Position data provided by the simulator.
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

/// GPS Simulator — wraps the native [GnssSimulator] from C++.
///
/// Usage:
/// ```dart
/// final sim = GnssSimulatorBridge.instance;
/// sim.onPosition = (pos) { /* update UI */ };
/// sim.start();
/// // ...
/// sim.stop();
/// ```
class GnssSimulatorBridge {
  GnssSimulatorBridge._() {
    final lib = nativeLib;

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

  /// Callback invoked on the Dart thread with each new position (~100 ms).
  void Function(SimPosition)? onPosition;

  /// Creates the simulator at the given start point and starts the C++ thread.
  void start({
    double startLat = 52.2297,
    double startLon = 21.0122,
    double startAlt = 100.0,
  }) {
    if (_handle != null) return; // already running

    _handle = _simCreate(startLat, startLon, startAlt);

    // NativeCallable.listener() — safe to call from a foreign C++ thread.
    _nativeCallable = NativeCallable<_SimCallbackNative>.listener(
      _onNativePosition,
    );

    _simStart(_handle!, _nativeCallable!.nativeFunction);
  }

  /// Stops the simulator thread (blocks until C++ thread exits).
  void stop() {
    if (_handle == null) return;
    _simStop(_handle!);
    _nativeCallable?.close();
    _nativeCallable = null;
    _simDestroy(_handle!);
    _handle = null;
  }

  /// Last $GPGGA sentence generated by the simulator.
  ///
  /// BUG#4 FIX: null-check the returned pointer before calling toDartString()
  /// — if the simulator hasn't generated a sentence yet, the C side may return
  /// a null pointer.
  ///
  /// Returns null when the simulator is not running or hasn't produced a
  /// sentence yet.
  String? get lastNmea {
    if (_handle == null) return null;
    final ptr = _simLastNmea(_handle!);
    if (ptr == nullptr) return null;
    return ptr.toDartString();
  }

  /// Native check of the simulator thread state.
  bool get isRunningNative => _handle != null && _simIsRunning(_handle!) != 0;

  /// Polls the latest simulator position without waiting for a callback.
  /// Returns null when the simulator has not been started.
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

  // Invoked by NativeCallable on the Dart thread (safe)
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
