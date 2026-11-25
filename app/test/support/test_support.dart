import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:latlong2/latlong.dart';

/// Ścisłe „oczekiwane niepowodzenie” (odpowiednik pytest xfail strict).
///
/// [body] opisuje zachowanie POPRAWNE, które dziś nie działa. Test przechodzi,
/// dopóki [body] zawodzi; po naprawie błędu zacznie się wywalać — wtedy zamień
/// `xfail` na zwykły `test`.
void xfail(
  String name,
  FutureOr<void> Function() body, {
  required String reason,
}) {
  test('[XFAIL] $name — $reason', () async {
    Object? failure;
    try {
      await body();
    } catch (e) {
      failure = e;
    }
    if (failure == null) {
      fail('Nieoczekiwany sukces: błąd wygląda na naprawiony — zamień xfail '
          'na test. ($reason)');
    }
    printOnFailure('xfail: $failure');
  });
}

/// Wczytuje plik z `test/fixtures`.
String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

const mPerDeg = 111320.0;

/// Punkt przesunięty o [e]/[n] metrów — ta sama konwencja ENU co w kodzie.
LatLng at(double e, double n, {double lat0 = 52.0, double lon0 = 17.0}) =>
    LatLng(
      lat0 + n / mPerDeg,
      lon0 + e / (mPerDeg * math.cos(lat0 * math.pi / 180.0)),
    );

List<LatLng> rect(double w, double h, {double e0 = 0, double n0 = 0}) => [
      at(e0, n0),
      at(e0 + w, n0),
      at(e0 + w, n0 + h),
      at(e0, n0 + h),
    ];

/// Dokłada `$`, sumę kontrolną i `*` do treści zdania NMEA.
String nmea(String body) {
  final cs = body.codeUnits.fold<int>(0, (a, b) => a ^ b);
  return '\$$body*${cs.toRadixString(16).padLeft(2, '0').toUpperCase()}';
}

/// Hive na katalogu tymczasowym, usuwanym po teście.
Future<void> useTempHive() async {
  final dir = await Directory.systemTemp.createTemp('agrinav_hive_');
  Hive.init(dir.path);
  addTearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });
}

/// Powód pominięcia testów FFI albo `null`, gdy biblioteka jest dostępna.
///
/// Produkcyjny `nativeLib` otwiera `agri_nav_ffi.dll` także na Linuksie, więc
/// CI podkłada `.so` pod tą nazwą (patrz ci.yml). `AGRINAV_REQUIRE_NATIVE=1`
/// zamienia ciche pominięcie w błąd.
final String? nativeSkipReason = () {
  try {
    DynamicLibrary.open('agri_nav_ffi.dll');
    return null;
  } catch (e) {
    if (Platform.environment['AGRINAV_REQUIRE_NATIVE'] == '1') rethrow;
    return 'brak biblioteki natywnej (agri_nav_ffi.dll) — patrz README';
  }
}();
