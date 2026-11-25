import 'package:agri_nav/models/gnss_position.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_support.dart';

GnssPosition _pos(double lat, double lon,
        {GnssFixQuality q = GnssFixQuality.rtkFixed}) =>
    GnssPosition(
      latitude: lat,
      longitude: lon,
      altitude: 101.5,
      fixQuality: q,
      satellitesCount: 9,
      hdop: 0.7,
      timestamp: DateTime.utc(2025, 5, 1, 7, 8, 9),
    );

void main() {
  // Zdania referencyjne z publicznej dokumentacji NMEA 0183.
  const gga =
      r'$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47';
  const rmc =
      r'$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6A';

  group('isNmeaChecksumValid', () {
    test('akceptuje poprawne, także z CRLF i małymi literami hex', () {
      expect(isNmeaChecksumValid(gga), isTrue);
      expect(isNmeaChecksumValid('$rmc\r\n'), isTrue);
      expect(isNmeaChecksumValid(rmc.replaceFirst('*6A', '*6a')), isTrue);
    });

    test('odrzuca uszkodzone', () {
      for (final s in [
        '',
        r'$',
        'GPGGA,1*00',
        gga.replaceFirst('4807', '4808'),
        gga.substring(0, gga.length - 1), // urwana suma
        gga.replaceFirst('*47', ''),
        gga.replaceFirst('*47', '*ZZ'),
      ]) {
        expect(isNmeaChecksumValid(s), isFalse, reason: s);
      }
    });
  });

  group('parseGga', () {
    test('wartości referencyjne', () {
      final g = parseGga(gga)!;
      expect(g.latitude, closeTo(48.1173, 1e-6));
      expect(g.longitude, closeTo(11.516667, 1e-6));
      expect(g.altitude, closeTo(545.4, 1e-9));
      expect(g.fixQuality, GnssFixQuality.gps);
      expect(g.satellitesCount, 8);
      expect(g.hdop, closeTo(0.9, 1e-9));
    });

    test('półkula S/W daje znak ujemny', () {
      final g =
          parseGga(nmea('GNGGA,1,3330.0,S,06015.0,W,4,10,0.5,10.0,M,,M,,'))!;
      expect(g.latitude, closeTo(-33.5, 1e-9));
      expect(g.longitude, closeTo(-60.25, 1e-9));
      expect(g.fixQuality, GnssFixQuality.rtkFixed);
    });

    test('biegun i dateline', () {
      final g =
          parseGga(nmea('GNGGA,1,9000.0,N,18000.0,E,1,10,0.5,10.0,M,,M,,'))!;
      expect(g.latitude, closeTo(90, 1e-9));
      expect(g.longitude, closeTo(180, 1e-9));
    });

    test('brak fixa: puste pola → null, ale status jest', () {
      final g = parseGga(nmea('GNGGA,1,,,,,0,06,99.9,,M,,M,,'))!;
      expect(g.latitude, isNull);
      expect(g.longitude, isNull);
      expect(g.altitude, isNull);
      expect(g.fixQuality, GnssFixQuality.noFix);
      expect(g.satellitesCount, 6);
    });

    test('puste satelity/hdop dostają wartości domyślne', () {
      final g = parseGga(nmea('GNGGA,1,5200.0,N,01700.0,E,1,,,1.0,M,,M,,'))!;
      expect(g.satellitesCount, 0);
      expect(g.hdop, closeTo(99.9, 1e-9));
    });

    test('złe zdania → null', () {
      expect(parseGga(''), isNull);
      expect(parseGga(rmc), isNull);
      expect(parseGga(gga.replaceFirst('*47', '*48')), isNull);
      expect(parseGga(nmea('GPGGA,1,2,N')), isNull);
      expect(parseGga(nmea('GPGGA,1,5200.0,N,01700.0,E,x,08,0.9,1,M,,M,,')),
          isNull);
    });

    test('współrzędne spoza zakresu są odrzucane', () {
      final g =
          parseGga(nmea('GNGGA,1,9959.0,N,01700.0,E,4,10,0.5,1.0,M,,M,,'));
      expect(g?.latitude, isNull);
      final h =
          parseGga(nmea('GNGGA,1,5200.0,N,18100.0,E,4,10,0.5,1.0,M,,M,,'));
      expect(h?.longitude, isNull);
    });
  });

  test('fromGgaValue — mapowanie specyfikacji NMEA', () {
    expect([
      for (var i = -1; i <= 7; i++) GnssFixQuality.fromGgaValue(i)
    ], [
      GnssFixQuality.noFix,
      GnssFixQuality.noFix,
      GnssFixQuality.gps,
      GnssFixQuality.dgps,
      GnssFixQuality.noFix,
      GnssFixQuality.rtkFixed,
      GnssFixQuality.rtkFloat,
      GnssFixQuality.noFix,
      GnssFixQuality.noFix,
    ]);
  });

  group('parseRmc', () {
    test('wartości referencyjne', () {
      final r = parseRmc(rmc)!;
      expect(r.speed, closeTo(22.4 * 0.514444, 1e-9));
      expect(r.heading, closeTo(84.4, 1e-9));
    });

    test('status V, zła suma, inne zdanie, za mało pól → null', () {
      expect(parseRmc(nmea('GPRMC,1,V,,,,,,,230394,,')), isNull);
      expect(parseRmc(rmc.replaceFirst('*6A', '*6B')), isNull);
      expect(parseRmc(gga), isNull);
      expect(parseRmc(nmea('GPRMC,1,A')), isNull);
    });

    // u-blox zostawia kurs pusty na postoju — obecnie tracimy też prędkość.
    test('postój: pusty kurs nie kasuje prędkości', () {
      final r = parseRmc(nmea('GNRMC,1,A,5200.0,N,01700.0,E,0.01,,010525,,,A'));
      expect(r?.speed, closeTo(0.01 * 0.514444, 1e-9));
      expect(r?.heading, closeTo(-1, 1e-12)); // nieznany
    });

    test('uszkodzony kurs lub prędkość, NaN → null', () {
      for (final (speed, course) in [
        ('1.0', 'abc'),
        ('1.0', 'NaN'),
        ('1.0', 'Infinity'),
        ('NaN', '45.0'),
        ('', '45.0'),
        ('', ''),
      ]) {
        expect(
            parseRmc(
                nmea('GNRMC,1,A,5200.0,N,01700.0,E,$speed,$course,010525,,,A')),
            isNull,
            reason: '$speed/$course');
      }
    });
  });

  group('buildGgaSentence', () {
    test('format i suma kontrolna', () {
      final s = buildGgaSentence(_pos(52.228745, 17.5));
      expect(
          s,
          startsWith(
              r'$GPGGA,070809.00,5213.7247,N,01730.0000,E,4,09,0.7,101.5,M,'));
      expect(s, endsWith('\r\n'));
      expect(isNmeaChecksumValid(s), isTrue);
    });

    test('round-trip przez parseGga na wszystkich półkulach', () {
      for (final (lat, lon) in [
        (52.1234567, 17.7654321),
        (-33.5, -60.25),
        (0.0, 0.0),
        (-0.00123, 0.00456),
        (89.9999, 179.9999),
        (-89.9999, -179.9999),
      ]) {
        final g = parseGga(buildGgaSentence(_pos(lat, lon)))!;
        // 4 miejsca minut ≈ 0.2 m
        expect(g.latitude, closeTo(lat, 1e-6));
        expect(g.longitude, closeTo(lon, 1e-6));
      }
    });

    test('jakość fixa zachowana', () {
      for (final q in GnssFixQuality.values) {
        expect(parseGga(buildGgaSentence(_pos(52, 17, q: q)))!.fixQuality, q);
      }
    });

    test('minuty nigdy nie są zaokrąglane do 60', () {
      expect(buildGgaSentence(_pos(51.99999999, 17)),
          isNot(contains(',5160.0000,')));
      expect(buildGgaSentence(_pos(51.99999999, 16.99999999)),
          contains(',5200.0000,N,01700.0000,E,'));
    });
  });

  test('toString zawiera współrzędne', () {
    expect(_pos(52, 17).toString(), contains('lat=52.0'));
  });
}
