// Pełny przepływ: plik → pole → plan (prawdziwe C++ przez FFI) → przejazd.
import 'package:agri_nav/ffi/field_processor_bridge.dart';
import 'package:agri_nav/ffi/gps_bridge.dart';
import 'package:agri_nav/ffi/guidance_bridge.dart';
import 'package:agri_nav/models/field_model.dart';
import 'package:agri_nav/services/field_service.dart';
import 'package:agri_nav/utils/geo_utils.dart';
import 'package:agri_nav/utils/geojson_parser.dart';
import 'package:agri_nav/utils/kml_parser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import '../support/test_support.dart';

List<(double, double)> _tuples(List<LatLng> pts) =>
    [for (final p in pts) (p.latitude, p.longitude)];

void main() {
  test('import KML → zapis → odczyt → powierzchnia', () async {
    await useTempHive();
    await FieldService.init();
    final parsed = KmlParser.parse(fixture('pole_200x100.kml')).single;
    await FieldService.instance.save(FieldModel(
      id: 'k',
      name: parsed.suggestedName!,
      boundaryLats: [for (final p in parsed.points) p.latitude],
      boundaryLons: [for (final p in parsed.points) p.longitude],
      source: FieldSource.file,
    ));
    expect(await FieldService.instance.populateAreas(), 1);
    final f = FieldService.instance.getById('k')!;
    expect(f.name, 'Pole testowe');
    expect(f.areaHa, closeTo(2.0, 0.01));
    expect(GeoUtils.pointInPolygon(at(100, 50), f.boundary), isTrue);
  });

  group('z biblioteką natywną', () {
    late List<LatLng> field;
    setUp(() => field =
        GeoJsonParser.parse(fixture('pole_200x100.geojson')).single.points);

    PlanResult plan({int laps = 0, double width = 10}) =>
        SwathPlannerFullBridge.instance.planFull(
          polygon: _tuples(field),
          ax: field[0].latitude,
          ay: field[0].longitude,
          bx: field[1].latitude,
          by: field[1].longitude,
          workingWidthM: width,
          headlandLaps: laps,
        );

    test('plan z pliku, prowadzenie i pełne pokrycie', () async {
      final p = plan();
      expect(p.swaths, hasLength(10));
      final g = SwathGuidanceBridge.instance
        ..setSwaths(p.swaths, field[0].latitude, field[0].longitude);
      final sc = SectionControlBridge.instance
        ..clear()
        ..setOrigin(field[0].latitude, field[0].longitude);

      for (var i = 0; i < p.swaths.length; i++) {
        final y = 5.0 + i * 10;
        // Jazda „wężykiem” ze stałym odchyleniem 0.3 m na północ.
        final fwd = i.isEven;
        for (var x = 0.25; x < 200; x += 0.5) {
          final pos = at(fwd ? x : 200 - x, y + 0.3);
          final s = g.query(pos.latitude, pos.longitude, fwd ? 90 : 270);
          expect(s.swathIndex, i);
          expect(s.distanceM, closeTo(0.3, 1e-3));
          expect(s.headingErrorDeg, closeTo(0, 1e-3));
          sc.addStrip(pos.latitude, pos.longitude, fwd ? 90 : 270, 10);
        }
      }
      // Kratka 1 m → dopuszczamy kolumnę na brzegu.
      expect(sc.coveredAreaHa(), closeTo(2.0, 0.05));
      expect(
          sc.checkOverlap(at(100, 50).latitude, at(100, 50).longitude, 90, 5),
          closeTo(1, 1e-6));
      sc.clear();
      expect(sc.coveredAreaHa(), closeTo(0, 1e-12));
    });

    test('replayTrack odtwarza pokrycie z zapisanego śladu', () async {
      final sc = SectionControlBridge.instance
        ..clear()
        ..setOrigin(52, 17);
      expect(await sc.replayTrack([], 10), closeTo(0, 1e-12));
      final ha = await sc
          .replayTrack([for (var i = 0; i <= 400; i++) at(i * 0.5, 50.3)], 10);
      expect(ha, closeTo(0.2, 0.025)); // 200 × 10 m (kratka 1 m)
      expect(sc.newAreaHaLastStrip(), greaterThanOrEqualTo(0));
    });

    test('uwrocia: pierścień i prowadzenie', () {
      final p = plan(laps: 1);
      expect(p.swaths, hasLength(8));
      expect(p.headlandRings, hasLength(1));
      final ring = [for (final (a, b) in p.headlandRings[0]) LatLng(a, b)];
      final h = HeadlandGuidanceBridge.instance
        ..setRings([ring], field[0].latitude, field[0].longitude);
      final pos = at(100, 4); // 1 m na zewnątrz od pierścienia (5 m)
      final r = h.query(pos.latitude, pos.longitude, 90);
      expect(r.ringIndex, 0);
      expect(r.crossTrackM.abs(), closeTo(1, 0.02));
    });

    test('NavBridge: XTE i ważność', () {
      final nav = NavBridge.instance;
      expect(nav.version, 1);
      nav.setAbLine(field[0].latitude, field[0].longitude, field[1].latitude,
          field[1].longitude);
      final pos = at(50, 2);
      ({double crossTrack, double heading, bool valid}) up(double acc) => nav
          .update(lat: pos.latitude, lon: pos.longitude, alt: 1, accuracy: acc);
      expect(up(0.02).crossTrack, closeTo(-2, 1e-3)); // na lewo od W→E
      expect(up(0.02).valid, isTrue);
      expect(up(1).valid, isFalse);
      expect(nav.getPosition().latitude, closeTo(pos.latitude, 1e-12));
      nav.resetAbLine();
      expect(up(0.02).valid, isFalse);
    });

    test('optymalizator kąta w izolacie', () async {
      final r = await OptimizeAngleBridge.optimizeAsync(
        polygon: _tuples(field),
        workingWidthM: 10,
      );
      expect(r.bestAngleDeg, closeTo(90, 0.5));
      expect(r.swaths, hasLength(r.swathCount));
    });

    test('scalanie działek ULDK i LPIS', () async {
      final parts = [rect(100, 100), rect(100, 100, e0: 100)];
      final m = ParcelMergerBridge.instance.merge(parts);
      expect(m.isMultipart, isFalse);
      expect(GeoUtils.polygonAreaHa(m.primaryBoundary), closeTo(2.0, 0.02));
      expect(m.holes, isEmpty);
      final l = await LpisProcessorBridge.instance.processAsync(parts);
      expect(GeoUtils.polygonAreaHa(l.primaryBoundary), closeTo(2.0, 0.02));
      // Opcje muszą dotrzeć do C++ (regresja: czytane po calloc.free):
      // bufor 2 m powiększa prostokąt 200×100 o ok. 600·2 + π·4 m².
      final wide = await LpisProcessorBridge.instance
          .processAsync(parts, bufferM: 2, simplifyEpsilonM: 0);
      expect(
          GeoUtils.polygonAreaHa(wide.primaryBoundary), closeTo(2.1213, 0.01));
      expect(() => ParcelMergerBridge.instance.merge([]), throwsStateError);
    });

    test('puste dane: plan pusty', () {
      final r = SwathPlannerFullBridge.instance.planFull(
        polygon: const [],
        ax: 52,
        ay: 17,
        bx: 52.001,
        by: 17,
        workingWidthM: 10,
      );
      expect(r.swaths, isEmpty);
      expect(r.headlandRings, isEmpty);
    });
  }, skip: nativeSkipReason);
}
