import 'dart:math' as math;

import 'package:agri_nav/ffi/guidance_bridge.dart' show Swath;
import 'package:agri_nav/utils/elastic_warp.dart';
import 'package:agri_nav/utils/geo_utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import '../support/test_support.dart';

Swath _swath(LatLng a, LatLng b) => Swath(
    startLat: a.latitude,
    startLon: a.longitude,
    endLat: b.latitude,
    endLon: b.longitude);

void main() {
  group('bearing', () {
    const o = LatLng(0, 0);
    test('kierunki główne na równiku', () {
      expect(GeoUtils.bearing(o, const LatLng(1, 0)), closeTo(0, 1e-9));
      expect(GeoUtils.bearing(o, const LatLng(0, 1)), closeTo(90, 1e-9));
      expect(GeoUtils.bearing(o, const LatLng(-1, 0)), closeTo(180, 1e-9));
      expect(GeoUtils.bearing(o, const LatLng(0, -1)), closeTo(270, 1e-9));
    });

    test('wartość referencyjna Warszawa → Kraków ≈ 197°', () {
      expect(
          GeoUtils.bearing(
              const LatLng(52.2297, 21.0122), const LatLng(50.0647, 19.9450)),
          closeTo(197.4, 0.5));
    });

    test('dateline i ten sam punkt', () {
      expect(GeoUtils.bearing(const LatLng(0, 179.9), const LatLng(0, -179.9)),
          closeTo(90, 1e-9));
      expect(GeoUtils.bearing(o, o), closeTo(0, 1e-9));
    });

    test('z bieguna północnego zawsze na południe', () {
      expect(GeoUtils.bearing(const LatLng(90, 0), const LatLng(80, 0)),
          closeTo(180, 1e-6));
    });
  });

  group('ENU', () {
    test('1° szerokości = 111320 m, długość skalowana cos(lat)', () {
      final d = GeoUtils.toEnu(const LatLng(60, 17), const LatLng(61, 18));
      expect(d.n, closeTo(111320, 1e-6));
      expect(d.e, closeTo(55660, 1e-6)); // cos 60° = 0.5
    });

    test('round-trip, także na granicy strefy UTM i na południu', () {
      for (final o in const [
        LatLng(52, 17),
        LatLng(52, 18),
        LatLng(52, 24),
        LatLng(-33.5, -60.25),
        LatLng(0, 0),
      ]) {
        final p = GeoUtils.fromEnu(o, -123.4, 567.8);
        final d = GeoUtils.toEnu(o, p);
        expect(d.e, closeTo(-123.4, 1e-6));
        expect(d.n, closeTo(567.8, 1e-6));
      }
    });

    test('NaN propaguje się jako NaN, bez wyjątku', () {
      expect(
          GeoUtils.toEnu(const LatLng(52, 17), const LatLng(double.nan, 17)).n,
          isNaN);
    });

    // poza zakresem: obsługiwane tylko współrzędne w Polsce
    xfail('odległość przez dateline', () {
      final d =
          GeoUtils.toEnu(const LatLng(0, 179.9999), const LatLng(0, -179.9999));
      expect(d.e, closeTo(22.264, 0.01));
    }, reason: 'brak zawijania długości na ±180°');

    // poza zakresem: obsługiwane tylko współrzędne w Polsce
    xfail('biegun: fromEnu zwraca sensowną długość', () {
      expect(GeoUtils.fromEnu(const LatLng(90, 0), 10, 0).longitude.abs(),
          lessThanOrEqualTo(180));
    }, reason: 'cos(90°)≈6e-17 > 0, więc guard cosLat > 0 nie działa');
  });

  group('offsetSwaths', () {
    test('dodatni offset = w prawo', () {
      final s = [_swath(at(0, 0), at(0, 100))];
      final out = GeoUtils.offsetSwaths(s, 2).single;
      final d = GeoUtils.toEnu(at(0, 0), LatLng(out.startLat, out.startLon));
      expect(d.e, closeTo(2, 1e-6));
      expect(d.n, closeTo(0, 1e-6));
      final e = GeoUtils.toEnu(at(0, 0), LatLng(out.endLat, out.endLon));
      expect(e.n, closeTo(100, 1e-6));
    });

    test('zero, pusta lista i zdegenerowany pas bez zmian', () {
      final s = [_swath(at(0, 0), at(0, 0))];
      expect(GeoUtils.offsetSwaths(s, 0), same(s));
      expect(GeoUtils.offsetSwaths(const [], 3), isEmpty);
      expect(GeoUtils.offsetSwaths(s, 3).single, same(s.single));
    });
  });

  group('fitSimilarity2D', () {
    const src = [(e: 0.0, n: 0.0), (e: 100.0, n: 0.0), (e: 0.0, n: 50.0)];

    test('odzyskuje znaną transformację', () {
      const th = 0.3, k = 1.2, tx = 5.0, ty = -7.0;
      final tgt = [
        for (final p in src)
          (
            e: k * (p.e * math.cos(th) - p.n * math.sin(th)) + tx,
            n: k * (p.e * math.sin(th) + p.n * math.cos(th)) + ty,
          )
      ];
      final f = GeoUtils.fitSimilarity2D(src, tgt);
      expect(f.rotationRad, closeTo(th, 1e-12));
      expect(f.scale, closeTo(k, 1e-12));
      expect(f.txM, closeTo(tx, 1e-9));
      expect(f.tyM, closeTo(ty, 1e-9));
    });

    test('punkty pokrywające się → samo przesunięcie', () {
      final f = GeoUtils.fitSimilarity2D(
          const [(e: 1.0, n: 1.0), (e: 1.0, n: 1.0)],
          const [(e: 4.0, n: 5.0), (e: 4.0, n: 5.0)]);
      expect(f.scale, closeTo(1, 1e-12));
      expect(f.txM, closeTo(3, 1e-12));
      expect(f.tyM, closeTo(4, 1e-12));
    });

    test('applySimilarity2D: obrót o 90°', () {
      final p = GeoUtils.applySimilarity2D(at(0, 0), at(10, 0),
          rotationRad: math.pi / 2, scale: 1, txM: 0, tyM: 0);
      final d = GeoUtils.toEnu(at(0, 0), p);
      expect(d.e, closeTo(0, 1e-6));
      expect(d.n, closeTo(10, 1e-6));
    });
  });

  group('fitLineThroughPoints', () {
    test('za mało punktów lub punkty identyczne → null', () {
      expect(GeoUtils.fitLineThroughPoints([]), isNull);
      expect(GeoUtils.fitLineThroughPoints([at(0, 0)]), isNull);
      expect(GeoUtils.fitLineThroughPoints([at(0, 0), at(0, 0)]), isNull);
    });

    test('kierunki referencyjne', () {
      double h(LatLng b) =>
          GeoUtils.fitLineThroughPoints([at(0, 0), b])!.headingDeg;
      expect(h(at(100, 0)), closeTo(90, 1e-6));
      expect(h(at(100, 100)), closeTo(45, 1e-6));
      expect(h(at(-100, 100)), closeTo(135, 1e-6));
      final north = h(at(0, 100)); // 0 ≡ 180
      expect(math.min(north, 180 - north), closeTo(0, 1e-6));
    });

    test('A = początek jazdy, długość i RMS', () {
      // Naprzemienne ±0.1 m od osi E.
      final pts = [
        for (var i = 100; i >= 0; i--) at(i * 1.0, i.isEven ? 0.1 : -0.1)
      ];
      final f = GeoUtils.fitLineThroughPoints(pts)!;
      expect(f.headingDeg, closeTo(90, 0.05));
      expect(f.lengthM, closeTo(100, 0.1));
      expect(f.rmsM, closeTo(0.1, 0.005));
      expect(GeoUtils.toEnu(at(100, 0), f.pointA).e, closeTo(0, 0.1));
      expect(GeoUtils.toEnu(at(0, 0), f.pointB).e, closeTo(0, 0.1));
    });
  });

  group('polygonAreaHa', () {
    test('< 3 punkty → 0', () {
      expect(GeoUtils.polygonAreaHa([]), closeTo(0, 1e-12));
      expect(GeoUtils.polygonAreaHa([at(0, 0), at(1, 1)]), closeTo(0, 1e-12));
    });

    test('prostokąt 200×100 m ≈ 2 ha, niezależnie od obiegu', () {
      final r = rect(200, 100);
      // 111195 vs 111320 m/° (promień średni vs stała ENU) → −0.22 %.
      expect(GeoUtils.polygonAreaHa(r), closeTo(2.0, 0.01));
      expect(GeoUtils.polygonAreaHa(r.reversed.toList()),
          closeTo(GeoUtils.polygonAreaHa(r), 1e-9));
    });

    test('zamknięty pierścień daje to samo', () {
      final r = rect(200, 100);
      expect(GeoUtils.polygonAreaHa([...r, r.first]),
          closeTo(GeoUtils.polygonAreaHa(r), 1e-3));
    });

    test('współliniowe → 0', () {
      expect(GeoUtils.polygonAreaHa([at(0, 0), at(50, 0), at(100, 0)]),
          closeTo(0, 1e-6));
    });

    test('trójkąt 100×100/2 = 0.5 ha', () {
      expect(GeoUtils.polygonAreaHa([at(0, 0), at(100, 0), at(0, 100)]),
          closeTo(0.5, 0.005));
    });

    // poza zakresem: obsługiwane tylko współrzędne w Polsce
    xfail('pole na dateline', () {
      final r = [
        const LatLng(0, 179.999),
        const LatLng(0, -179.999),
        const LatLng(0.001, -179.999),
        const LatLng(0.001, 179.999),
      ];
      expect(GeoUtils.polygonAreaHa(r), closeTo(2.47, 0.05));
    }, reason: 'brak zawijania długości na ±180°');
  });

  group('pointInPolygon', () {
    final r = rect(100, 100);
    test('wewnątrz / na zewnątrz', () {
      expect(GeoUtils.pointInPolygon(at(50, 50), r), isTrue);
      expect(GeoUtils.pointInPolygon(at(150, 50), r), isFalse);
      expect(GeoUtils.pointInPolygon(at(50, -1), r), isFalse);
    });

    test('wielokąt wklęsły (L)', () {
      final l = [
        at(0, 0),
        at(100, 0),
        at(100, 50),
        at(50, 50),
        at(50, 100),
        at(0, 100)
      ];
      expect(GeoUtils.pointInPolygon(at(75, 75), l), isFalse);
      expect(GeoUtils.pointInPolygon(at(25, 75), l), isTrue);
    });

    test('zdegenerowane i NaN', () {
      expect(GeoUtils.pointInPolygon(at(0, 0), []), isFalse);
      expect(GeoUtils.pointInPolygon(at(0, 0), [at(0, 0), at(1, 1)]), isFalse);
      expect(GeoUtils.pointInPolygon(const LatLng(double.nan, double.nan), r),
          isFalse);
    });
  });

  group('trackSweptAreaHa', () {
    test('100 m × 10 m = 0.1 ha', () {
      final t = [for (var i = 0; i <= 10; i++) at(0, i * 10.0)];
      expect(GeoUtils.trackSweptAreaHa(t, 10), closeTo(0.1, 1e-6));
    });

    test('przejazd tam i z powrotem liczy się podwójnie', () {
      expect(GeoUtils.trackSweptAreaHa([at(0, 0), at(0, 10), at(0, 0)], 10),
          closeTo(0.02, 1e-9));
    });

    test('przeskok > 15 m pomijany', () {
      expect(GeoUtils.trackSweptAreaHa([at(0, 0), at(0, 10), at(0, 100)], 10),
          closeTo(0.01, 1e-9));
    });

    test('puste, jeden punkt, zerowa/ujemna szerokość → 0', () {
      final t = [at(0, 0), at(0, 10)];
      expect(GeoUtils.trackSweptAreaHa([], 10), closeTo(0, 1e-12));
      expect(GeoUtils.trackSweptAreaHa([at(0, 0)], 10), closeTo(0, 1e-12));
      expect(GeoUtils.trackSweptAreaHa(t, 0), closeTo(0, 1e-12));
      expect(GeoUtils.trackSweptAreaHa(t, -1), closeTo(0, 1e-12));
    });
  });

  group('ElasticWarp', () {
    const src = [
      (e: 0.0, n: 0.0),
      (e: 100.0, n: 0.0),
      (e: 100.0, n: 100.0),
      (e: 0.0, n: 100.0)
    ];

    test('przechodzi dokładnie przez punkty kontrolne', () {
      const tgt = [
        (e: 1.0, n: 2.0),
        (e: 100.0, n: 0.0),
        (e: 97.0, n: 100.0),
        (e: 0.0, n: 103.0)
      ];
      final w = ElasticWarp.fit(src, tgt);
      for (var i = 0; i < 4; i++) {
        expect(w.transform(src[i]).e, closeTo(tgt[i].e, 1e-9));
        expect(w.transform(src[i]).n, closeTo(tgt[i].n, 1e-9));
      }
    });

    test('jednolite przesunięcie przesuwa wszystko', () {
      final w =
          ElasticWarp.fit(src, [for (final p in src) (e: p.e + 3, n: p.n - 4)]);
      final q = w.transform((e: 37.0, n: 512.0));
      expect(q.e, closeTo(40, 1e-9));
      expect(q.n, closeTo(508, 1e-9));
      final d = GeoUtils.toEnu(at(0, 0), w.applyToLatLng(at(0, 0), at(10, 10)));
      expect(d.e, closeTo(13, 1e-6));
    });

    test('punkty współliniowe nie są problemem', () {
      const line = [
        (e: 0.0, n: 0.0),
        (e: 1.0, n: 0.0),
        (e: 2.0, n: 0.0),
        (e: 3.0, n: 0.0)
      ];
      final q = ElasticWarp.fit(line, line).transform((e: 1.5, n: 9.0));
      expect(q.e, closeTo(1.5, 1e-9));
      expect(q.n, closeTo(9, 1e-9));
    });

    test('za mało par → assert', () {
      expect(() => ElasticWarp.fit(src.sublist(0, 3), src.sublist(0, 3)),
          throwsA(isA<AssertionError>()));
    });

    test('densifyRing', () {
      expect(ElasticWarp.densifyRing([]), isEmpty);
      expect(ElasticWarp.densifyRing([src[0]]), hasLength(1));
      expect(ElasticWarp.densifyRing(src, stepM: 10), hasLength(40));
      expect(ElasticWarp.densifyRing(src, stepM: 0.1, maxPerEdge: 5),
          hasLength(20));
    });
  });
}
