import 'package:agri_nav/models/field_model.dart';
import 'package:agri_nav/services/field_service.dart';
import 'package:agri_nav/services/geoportal_service.dart';
import 'package:agri_nav/services/lpis_service.dart';
import 'package:agri_nav/utils/geo_utils.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/test_support.dart';

/// Odpowiedź bieżącego testu; klient HTTP w serwisach jest singletonem.
http.Response Function(http.Request) _respond = (_) => http.Response('', 500);
final _requests = <Uri>[];

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  var online = true;

  // Singletony tworzą http.Client() przy pierwszym użyciu — tworzymy je
  // w strefie z MockClient, więc żaden test nie dotyka sieci.
  http.runWithClient(() {
    GeoportalService.instance;
    LpisService.instance;
  }, () {
    return MockClient((r) async {
      _requests.add(r.url);
      return _respond(r);
    });
  });

  setUp(() async {
    online = true;
    _requests.clear();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (_) async => [online ? 'wifi' : 'none'],
    );
    await useTempHive();
    await FieldService.init();
    await LpisService.init();
  });

  const wkt = 'POLYGON((17 52,17.001 52,17.001 52.001,17 52.001,17 52))';

  group('GeoportalService', () {
    final g = GeoportalService.instance;

    test('pobiera działkę i zapisuje pole', () async {
      _respond = (_) => http.Response(
          '0\n141201_2.0001.1234/2;$wkt;1412012;maz;pow;Gmina', 200);
      final f = await g.fetchAndCacheByTeryt(' 141201_2.0001.1234/2 ');
      expect(f.uLDKParcelId, '141201_2.0001.1234/2');
      expect(f.terytCode, '1412012');
      expect(f.name, startsWith('Gmina / …'));
      expect(f.source, FieldSource.uldk);
      expect(f.areaHa, closeTo(0.761, 0.01)); // 111.2 m × 68.5 m
      expect(_requests.single.queryParameters['srid'], '4326');
      expect(_requests.single.queryParameters['id'], '141201_2.0001.1234/2');
      // Ponowne pobranie odświeża, nie duplikuje.
      final again = await g.fetchAndCacheByTeryt('141201_2.0001.1234/2');
      expect(again.id, f.id);
      expect(FieldService.instance.getAll(), hasLength(1));
    });

    test('błędy serwera i formatu → ULDKException', () async {
      for (final r in [
        http.Response('x', 503),
        http.Response('-1 brak wynikow', 200),
        http.Response('5', 200),
        http.Response('0\nbez-srednika', 200),
        http.Response('0\nid;POINT(1 2)', 200),
        http.Response('', 200),
      ]) {
        _respond = (_) => r;
        await expectLater(
            g.fetchAndCacheByTeryt('x'), throwsA(isA<ULDKException>()));
      }
      expect(FieldService.instance.getAll(), isEmpty);
    });

    xfail('niepoprawny UTF-8 w odpowiedzi → ULDKException', () async {
      _respond = (_) => http.Response.bytes([0x30, 0x0A, 0xF3, 0x77], 200);
      await expectLater(
          g.fetchAndCacheByTeryt('x'), throwsA(isA<ULDKException>()));
    }, reason: 'utf8.decode bez allowMalformed wypuszcza FormatException');

    test('brak sieci → NoNetworkException, bez żądania HTTP', () async {
      online = false;
      await expectLater(
          g.fetchAndCacheByTeryt('x'), throwsA(isA<NoNetworkException>()));
      expect(_requests, isEmpty);
    });

    test('wiele działek: sukcesy i błędy osobno, deduplikacja', () async {
      _respond = (r) => r.url.queryParameters['id']!.endsWith('.2')
          ? http.Response('-1', 200)
          : http.Response('0\nid;$wkt', 200);
      final r = await g.fetchMultipleParcels(
          ['1', ' 1 ', '2', '', '3', '4', '5'],
          districtPrefix: '141201_2.0001');
      expect(r.geometries, hasLength(4));
      expect(r.errors.keys, ['141201_2.0001.2']);
      await expectLater(
          g.fetchMultipleParcels([' ']), throwsA(isA<ULDKException>()));
    });

    test('buildFullParcelId', () {
      expect(GeoportalService.buildFullParcelId('141201_2.0001 ', ' 12/3'),
          '141201_2.0001.12/3');
      expect(GeoportalService.buildFullParcelId('x', '141201_2.0001.12'),
          '141201_2.0001.12');
    });

    test('nudge, punkty kontrolne i reset', () async {
      final r = rect(100, 100);
      final f = FieldModel(
        id: 'f',
        name: 'f',
        boundaryLats: [for (final p in r) p.latitude],
        boundaryLons: [for (final p in r) p.longitude],
      );
      await g.nudgeField(f, dxM: 3, dyM: -4);
      var d = GeoUtils.toEnu(at(0, 0), f.boundary.first);
      expect(d.e, closeTo(3, 1e-3));
      expect(d.n, closeTo(-4, 1e-3));
      await g.resetNudge(f);

      await g.applyControlPoints(f, [
        (source: r[0], target: at(1, 2)),
        (source: r[2], target: at(101, 102)),
      ]);
      expect(f.correctionMode, FieldCorrectionMode.similarity);
      d = GeoUtils.toEnu(at(0, 0), f.boundary.first);
      expect(d.e, closeTo(1, 1e-3));
      expect(d.n, closeTo(2, 1e-3));

      await g.applyControlPointsElastic(
          f, [for (final p in r) (source: p, target: p)]);
      expect(f.correctionMode, FieldCorrectionMode.elastic);
      expect(f.cpTxM, closeTo(0, 1e-12));
      expect(FieldService.instance.getById('f')!.elasticSrcLats, hasLength(4));

      await g.resetControlPoints(f);
      expect(f.correctionMode, FieldCorrectionMode.none);
      expect(f.boundary, hasLength(4));
    });
  });

  group('LpisService', () {
    final l = LpisService.instance;

    test('SRID=4326 → działka w cache', () async {
      _respond =
          (_) => http.Response('0\nSRID=4326;$wkt\n141201|Powiat||Obreb', 200);
      final r = await l.fetchByFarmId('141201');
      expect(r.parcels.single.objectId, '141201');
      expect(r.parcels.single.cropGroupLabel, 'Powiat, Obreb');
      expect(r.parcels.single.boundary.first.latitude, closeTo(52, 1e-9));
      expect(l.getCachedParcels(), hasLength(1));
    });

    test('błędy → LpisServiceException', () async {
      for (final b in ['-1\nbrak', '0', '', '0\nSRID=4326;POINT(1 2)']) {
        _respond = (_) => http.Response(b, 200);
        await expectLater(
            l.fetchByFarmId('x'), throwsA(isA<LpisServiceException>()));
      }
      _respond = (_) => throw http.ClientException('reset');
      await expectLater(
          l.fetchByFarmId('x'), throwsA(isA<LpisServiceException>()));
    });

    test('brak sieci', () async {
      online = false;
      await expectLater(
          l.fetchByFarmId('x'), throwsA(isA<LpisNoNetworkException>()));
    });

    xfail('EPSG:2180 (PUWG-92) jest przeliczane na WGS-84', () async {
      // Południk osiowy 19°E ↔ easting 500000; ~52°N.
      _respond = (_) => http.Response(
          '0\nSRID=2180;POLYGON((500000 460000,500100 460000,500100 460100))\nt',
          200);
      final r = await l.fetchByFarmId('t');
      expect(r.parcels.single.boundary.first.longitude, closeTo(19, 1e-6));
    }, reason: 'WktParser odrzuca współrzędne metryczne przed reprojekcją');
  });
}
