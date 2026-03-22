import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

// ── Typy C ────────────────────────────────────────────────────────────────────

final class FfiPosition extends Struct {
  @Double()
  external double latitude;
  @Double()
  external double longitude;
  @Float()
  external double accuracy;
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
typedef _SetAbNative =
    Void Function(Pointer<Void>, Double, Double, Double, Double);
typedef _UpdateNative = FfiGuidance Function(Pointer<Void>, FfiPosition);

// ── Singleton ładujący .so / .dll ──────────────────────────────────────────────

class NavBridge {
  NavBridge._() {
    final lib = DynamicLibrary.open(
      Platform.isAndroid ? 'libagri_nav_ffi.so' : 'agri_nav_ffi.dll',
    );

    _create = lib.lookupFunction<_CreateNative, _CreateNative>(
      'agrinav_create',
    );
    _destroy = lib.lookupFunction<_DestroyNative, void Function(Pointer<Void>)>(
      'agrinav_destroy',
    );
    _setAb = lib
        .lookupFunction<
          _SetAbNative,
          void Function(Pointer<Void>, double, double, double, double)
        >('agrinav_set_ab_line');
    _update = lib
        .lookupFunction<
          _UpdateNative,
          FfiGuidance Function(Pointer<Void>, FfiPosition)
        >('agrinav_update');

    _handle = _create();
  }

  static final instance = NavBridge._();

  late final Pointer<Void> _handle;
  late final _CreateNative _create;
  late final void Function(Pointer<Void>) _destroy;
  late final void Function(Pointer<Void>, double, double, double, double)
  _setAb;
  late final FfiGuidance Function(Pointer<Void>, FfiPosition) _update;

  void setAbLine(double ax, double ay, double bx, double by) =>
      _setAb(_handle, ax, ay, bx, by);

  ({double crossTrack, double heading, bool valid}) update({
    required double lat,
    required double lon,
    required double accuracy,
  }) {
    final pos = calloc<FfiPosition>();
    pos.ref.latitude = lat;
    pos.ref.longitude = lon;
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
}
