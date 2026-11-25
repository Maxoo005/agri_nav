import 'package:agri_nav/services/wkt_parser.dart';
import 'package:agri_nav/utils/geo_utils.dart';
import 'package:agri_nav/utils/geojson_parser.dart';
import 'package:agri_nav/utils/kml_parser.dart';
import 'package:agri_nav/utils/parsed_polygon.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import '../support/test_support.dart';

const _ring = '[[17,52],[17.1,52],[17.1,52.1],[17,52.1],[17,52]]';

String _kml(String coords) => '<kml><Placemark><Polygon><outerBoundaryIs>'
    '<LinearRing><coordinates>$coords</coordinates></LinearRing>'
    '</outerBoundaryIs></Polygon></Placemark></kml>';

void main() {
  const throwsFormat = throwsFormatException;

  group('WktParser', () {
    test('POLYGON: kolejność lon lat, wysokość ignorowana, wielkość liter', () {
      final p =
          WktParser.parse(' polygon((17 52 100, 17.1 52 100, 17.1 52.1 99))');
      expect(p, hasLength(3));
      expect(p.first, const LatLng(52, 17));
    });

    test('otwór w POLYGON jest pomijany', () {
      final p = WktParser.parse('POLYGON((0 0,10 0,10 10,0 10),(1 1,2 1,2 2))');
      expect(p, hasLength(4));
    });

    test('MULTIPOLYGON → pierścień z największą liczbą punktów', () {
      final p =
          WktParser.parse('MULTIPOLYGON(((0 0,1 0,1 1)),((5 5,6 5,6 6,5 6)))');
      expect(p, hasLength(4));
      expect(p.first, const LatLng(5, 5));
    });

    test('granice zakresu są dozwolone', () {
      expect(
          WktParser.parse('POLYGON((-180 -90,180 -90,180 90))'), hasLength(3));
    });

    test('błędy', () {
      for (final s in [
        '',
        'POINT(1 2)',
        'POLYGON EMPTY',
        'POLYGON(())',
        'MULTIPOLYGON EMPTY',
        'POLYGON((0 0,1 1))',
        'POLYGON((a b,c d,e f))',
        'POLYGON((500000 5600000,500100 5600000,500100 5600100))',
      ]) {
        expect(() => WktParser.parse(s), throwsFormat, reason: s);
      }
    });

    xfail('punkt zamykający jest usuwany', () {
      expect(WktParser.parse('POLYGON((0 0,1 0,1 1,0 1,0 0))'), hasLength(4));
    }, reason: 'porównanie z points.last zamiast z points.first');

    xfail('A-B-A to nie wielokąt', () {
      expect(() => WktParser.parse('POLYGON((0 0,1 1,0 0))'), throwsFormat);
    }, reason: 'punkt zamykający liczony do minimum 3');

    xfail('NaN jest odrzucany', () {
      expect(
          () => WktParser.parse('POLYGON((NaN 0,1 0,1 1,0 1))'), throwsFormat);
    }, reason: 'NaN.abs() > 180 jest false');

    xfail('MULTIPOLYGON: większa powierzchnia wygrywa z liczbą wierzchołków',
        () {
      final p = WktParser.parse('MULTIPOLYGON(((0 0,10 0,10 10,0 10)),'
          '((20 20,20.01 20,20.02 20.01,20.01 20.02,20 20.01)))');
      expect(p.first, const LatLng(0, 0));
    }, reason: 'wybór po liczbie punktów, nie po powierzchni');
  });

  group('GeoJsonParser', () {
    test('Polygon', () {
      final r =
          GeoJsonParser.parse('{"type":"Polygon","coordinates":[$_ring]}');
      expect(r, hasLength(1));
      expect(r.single.suggestedName, isNull);
      expect(r.single.points.first, const LatLng(52, 17));
    });

    test('Feature z nazwą i MultiPolygon z numeracją', () {
      final r = GeoJsonParser.parse(
          '{"type":"Feature","properties":{"name":"Pole"},'
          '"geometry":{"type":"MultiPolygon","coordinates":[[$_ring],[],[$_ring]]}}');
      expect(r.map((p) => p.suggestedName), ['Pole (1)', 'Pole (3)']);
    });

    test('FeatureCollection pomija inne geometrie', () {
      final r = GeoJsonParser.parse('{"type":"FeatureCollection","features":['
          '{"type":"Feature","geometry":null},'
          '{"type":"Feature","geometry":{"type":"Point","coordinates":[17,52]}},'
          '3,'
          '{"type":"Feature","geometry":{"type":"Polygon","coordinates":[$_ring]}}]}');
      expect(r, hasLength(1));
    });

    test('błędy → FormatException', () {
      for (final s in [
        '',
        '{',
        '[]',
        '{}',
        '{"type":"Point","coordinates":[1,2]}',
        '{"type":"FeatureCollection","features":[]}',
        '{"type":"FeatureCollection"}',
        '{"type":"Polygon","coordinates":[]}',
        '{"type":"Polygon","coordinates":[5]}',
        '{"type":"Polygon","coordinates":[[[17]]]}',
        '{"type":"Polygon","coordinates":[[[17,52],[18,52]]]}',
        '{"type":"Polygon","coordinates":[[[500000,52],[18,52],[18,53]]]}',
      ]) {
        expect(() => GeoJsonParser.parse(s), throwsFormat, reason: s);
      }
    });

    xfail('liczbowa nazwa pola (QGIS) jest akceptowana', () {
      final r =
          GeoJsonParser.parse('{"type":"Feature","properties":{"name":12},'
              '"geometry":{"type":"Polygon","coordinates":[$_ring]}}');
      expect(r.single.suggestedName, '12');
    }, reason: 'rzut `as String?` rzuca TypeError');

    xfail('tekst w miejscu współrzędnej → FormatException', () {
      expect(
          () => GeoJsonParser.parse(
              '{"type":"Polygon","coordinates":[[["a",52],[18,52],[18,53]]]}'),
          throwsFormat);
    }, reason: 'rzut `as num` daje TypeError, łamiąc kontrakt parsera');

    xfail('zamknięty kwadrat → 4 punkty', () {
      final r =
          GeoJsonParser.parse('{"type":"Polygon","coordinates":[$_ring]}');
      expect(r.single.points, hasLength(4));
    },
        reason:
            'normalizeRing porównuje z ostatnim zamiast z pierwszym punktem');
  });

  group('KmlParser', () {
    test('białe znaki i brak wysokości', () {
      final r = KmlParser.parse(_kml('17,52,0\n\t17.1,52   17.1,52.1,5 '));
      expect(r.single.points, hasLength(3));
      expect(r.single.suggestedName, isNull);
    });

    test('prefiks przestrzeni nazw i MultiGeometry', () {
      final r = KmlParser.parse(
          '<k:kml xmlns:k="x"><k:Placemark><k:name> A </k:name>'
          '<k:MultiGeometry>'
          '${_kml('0,0 1,0 1,1').replaceAll(RegExp(r'</?(kml|Placemark)>'), '').replaceAllMapped(RegExp(r'<(/?)'), (m) => '<${m[1]}k:')}'
          '${_kml('2,2 3,2 3,3').replaceAll(RegExp(r'</?(kml|Placemark)>'), '').replaceAllMapped(RegExp(r'<(/?)'), (m) => '<${m[1]}k:')}'
          '</k:MultiGeometry></k:Placemark></k:kml>');
      expect(r.map((p) => p.suggestedName), ['A (1)', 'A (2)']);
    });

    test('błędy → FormatException', () {
      for (final s in [
        '',
        '<kml>',
        '<kml/>',
        '<kml><Placemark/></kml>',
        _kml(''),
        _kml('17,52 18,52'),
        _kml('a,52 18,52 18,53'),
        _kml('17,95 18,52 18,53'),
      ]) {
        expect(() => KmlParser.parse(s), throwsFormat, reason: s);
      }
    });

    xfail('NaN jest odrzucany', () {
      expect(() => KmlParser.parse(_kml('NaN,52 18,52 18,53 17,53')),
          throwsFormat);
    }, reason: 'double.tryParse("NaN") przechodzi walidację zakresu');
  });

  group('ParsedPolygon.normalizeRing', () {
    test('usuwa powtórzone sąsiednie punkty', () {
      final p = ParsedPolygon.normalizeRing(const [
        LatLng(0, 0),
        LatLng(0, 0),
        LatLng(0, 1),
        LatLng(1, 1),
        LatLng(1, 1),
      ], formatLabel: 'X');
      expect(p, hasLength(3));
    });

    test('komunikat zawiera etykietę formatu', () {
      expect(
          () => ParsedPolygon.normalizeRing(const [], formatLabel: 'KML'),
          throwsA(isA<FormatException>()
              .having((e) => e.message, 'message', contains('KML'))));
    });
  });

  group('fixtures', () {
    test('KML i GeoJSON tego samego pola dają tę samą powierzchnię', () {
      final k = KmlParser.parse(fixture('pole_200x100.kml')).single;
      final g = GeoJsonParser.parse(fixture('pole_200x100.geojson')).single;
      expect(k.suggestedName, 'Pole testowe');
      expect(g.suggestedName, 'Pole testowe');
      expect(GeoUtils.polygonAreaHa(k.points), closeTo(2.0, 0.01));
      expect(GeoUtils.polygonAreaHa(g.points),
          closeTo(GeoUtils.polygonAreaHa(k.points), 1e-6));
    });
  });
}
