import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'native_lib.dart';

// ── C struct mirrors ──────────────────────────────────────────────────────────

final class FfiPosition extends Struct {
  @Double()
  external double latitude; // 64-bit — preserves sub-mm precision at equator
  @Double()
  external double
      longitude; // 64-bit — NEVER downcast to float; would lose ~1 m
  @Double()
  external double altitude; // [m] a.s.l. — 64-bit
  @Float()
  external double accuracy; // [m] horizontal accuracy — 32-bit is sufficient
  //                         //   float gives ~7 sig. digits; for a value of
  //                         //   3.1415 m the error is < 0.001 m — acceptable.
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

/// Position data from any GPS source (simulator or real hardware).
///
/// [heading] — true bearing in degrees (0 = N, 90 = E). Returns −1 when the
///             hardware heading is unavailable OR ground speed is below
///             [GpsLocationService.kMinHeadingSpeedMs] (phone GPS "spins" at
///             standstill). The UI layer falls back to bearing from two positions.
/// [speed]   — ground speed in m/s. −1 when unavailable.
/// [isAccurate] — `false` when [accuracy] > [GpsLocationService.kMaxAccuracyM].
///               Callers should skip NavBridge updates and coverage tracking but
///               may still render the approximate position as a visual hint.
class SimPosition {
  const SimPosition({
    required this.latitude,
    required this.longitude,
    required this.altitude,
    required this.accuracy,
    this.heading = -1.0,
    this.speed = -1.0,
    this.isAccurate = true,
  });

  final double latitude;
  final double longitude;
  final double altitude; // [m] above sea level  (EMA-smoothed on real GPS)
  final double accuracy; // [m] horizontal accuracy, raw (not smoothed)
  final double heading; // [°] from north, −1 = unavailable / speed too low
  final double speed; // [m/s], −1 = unavailable
  /// `true` when accuracy ≤ [GpsLocationService.kMaxAccuracyM] (or simulator).
  final bool isAccurate;

  @override
  String toString() =>
      'SimPosition(lat=$latitude, lon=$longitude, alt=$altitude, '
      'acc=$accuracy, hdg=$heading, spd=$speed, ok=$isAccurate)';
}

// NOTE: GnssSimulatorBridge (C++ simulator) has been disconnected.
// The class and its FFI bindings are preserved in the C++ layer
// (core/src/GnssSimulator.cpp, bridge/agri_nav_ffi.*) for future use.
// GPS positions are now sourced exclusively from the real device GPS
// via GpsLocationService → Geolocator.
//
// class GnssSimulatorBridge {
