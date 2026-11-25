import 'dart:convert';

import 'package:agri_nav/models/field_model.dart';
import 'package:agri_nav/models/history_record.dart';
import 'package:agri_nav/models/lpis_parcel.dart';
import 'package:agri_nav/models/machine_model.dart';
import 'package:agri_nav/models/task_plan.dart';
import 'package:agri_nav/models/work_task.dart';
import 'package:agri_nav/utils/geo_utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import '../support/test_support.dart';

FieldModel _field([List<LatLng>? pts]) {
  final p = pts ?? rect(100, 100);
  return FieldModel(
    id: 'f1',
    name: 'Pole',
    boundaryLats: [for (final x in p) x.latitude],
    boundaryLons: [for (final x in p) x.longitude],
  );
}

Map<String, dynamic> _json(Object o) =>
    jsonDecode(jsonEncode(o)) as Map<String, dynamic>;

void _near(LatLng a, LatLng b, [double tolM = 0.001]) {
  final d = GeoUtils.toEnu(b, a);
  expect(d.e, closeTo(0, tolM));
  expect(d.n, closeTo(0, tolM));
}

void main() {
  group('FieldModel', () {
    test('puste pole: domyślny środek, pusta granica, brak AB', () {
      final f = _field([]);
      expect(f.boundary, isEmpty);
      expect(f.center, const LatLng(52.0, 19.0));
      expect(f.abHeadingDeg, isNull);
    });

    test('granica z offsetem', () {
      final f = _field()..offsetLat = 10 / mPerDeg;
      _near(f.boundary.first, at(0, 10));
    });

    test('środek prostokąta', () => _near(_field().center, at(50, 50)));

    test('kierunek AB zwinięty do [0,180)', () {
      final f = _field()
        ..lineALat = at(0, 0).latitude
        ..lineALon = at(0, 0).longitude
        ..lineBLat = at(0, -100).latitude
        ..lineBLon = at(0, -100).longitude;
      expect(f.abHeadingDeg, closeTo(0, 1e-6));
    });

    test('korekta similarity: przesunięcie o (3,4) m', () {
      final f = _field()
        ..correctionMode = FieldCorrectionMode.similarity
        ..cpTxM = 3
        ..cpTyM = 4;
      _near(f.boundary.first, at(3, 4));
    });

    test('korekta similarity: skala 2 względem środka', () {
      final f = _field()
        ..correctionMode = FieldCorrectionMode.similarity
        ..cpScale = 2;
      _near(f.boundary.first, at(-50, -50), 0.01);
    });

    test('korekta elastic przechodzi dokładnie przez punkty kontrolne', () {
      final f = _field()..correctionMode = FieldCorrectionMode.elastic;
      final src = rect(100, 100);
      final tgt = [at(1, 0), at(100, 2), at(100, 100), at(0, 100)];
      f
        ..elasticSrcLats = [for (final p in src) p.latitude]
        ..elasticSrcLons = [for (final p in src) p.longitude]
        ..elasticTgtLats = [for (final p in tgt) p.latitude]
        ..elasticTgtLons = [for (final p in tgt) p.longitude];
      final b = f.boundary;
      expect(b.length, greaterThan(4)); // zagęszczona
      _near(b.first, at(1, 0), 0.01);
      expect(
          b.any((p) => GeoUtils.toEnu(at(100, 2), p).e.abs() < 0.01), isTrue);
    });

    test('elastic z za małą liczbą par działa jak brak korekty', () {
      final f = _field()..correctionMode = FieldCorrectionMode.elastic;
      expect(f.boundary.length, 4);
      _near(f.boundary.first, at(0, 0));
    });

    test('round-trip JSON', () {
      final f = _field()
        ..lineALat = 52
        ..lineALon = 17
        ..lineBLat = 52.1
        ..lineBLon = 17
        ..abSource = AbSource.drivenRecording
        ..uLDKParcelId = 'x.1'
        ..terytCode = '1412012'
        ..lastSyncDate = DateTime.utc(2025)
        ..sourceParcelIds = ['a']
        ..lpisParcelIds = ['b']
        ..source = FieldSource.walked
        ..areaHa = 1.5
        ..parcelNumbersNote = '12/3'
        ..correctionMode = FieldCorrectionMode.similarity
        ..cpScale = 1.1;
      final g = FieldModel.fromJson(_json(f.toJson()));
      expect(g.toJson(), f.toJson());
    });

    test('zgodność wsteczna: arimr, brak abSource i correctionMode', () {
      final m = _json(_field().toJson())
        ..remove('abSource')
        ..remove('correctionMode')
        ..['source'] = 'arimr'
        ..['arimrParcelIds'] = ['9']
        ..['lineALat'] = 52.0
        ..['cpTxM'] = 2.0;
      final f = FieldModel.fromJson(m);
      expect(f.source, FieldSource.lpis);
      expect(f.lpisParcelIds, ['9']);
      expect(f.abSource, AbSource.unknown);
      expect(f.correctionMode, FieldCorrectionMode.similarity);
    });

    test('nieznane wartości enum → bezpieczne domyślne', () {
      final m = _json(_field().toJson())
        ..['source'] = 'kosmos'
        ..['abSource'] = '?'
        ..['correctionMode'] = '?'
        ..['lastSyncDate'] = 'nie-data';
      final f = FieldModel.fromJson(m);
      expect(f.source, FieldSource.manual);
      expect(f.abSource, AbSource.none);
      expect(f.correctionMode, FieldCorrectionMode.none);
      expect(f.lastSyncDate, isNull);
    });

    xfail('współrzędne całkowite w JSON są akceptowane', () {
      final m = _json(_field().toJson())
        ..['boundaryLats'] = [52, 52, 53]
        ..['boundaryLons'] = [17, 18, 18];
      expect(FieldModel.fromJson(m).boundary.length, 3);
    }, reason: 'cast<double>() na liście int rzuca TypeError');

    xfail('elastic z niezgodnymi listami src/tgt nie rzuca', () {
      final f = _field()
        ..correctionMode = FieldCorrectionMode.elastic
        ..elasticSrcLats = [52, 52, 52.1, 52.1]
        ..elasticSrcLons = [17, 17.1, 17.1, 17];
      expect(f.boundary, hasLength(4));
    }, reason: 'zabezpieczenie sprawdza tylko długość elasticSrcLats');

    xfail('lineA z samą szerokością → null', () {
      final f = _field()..lineALat = 52;
      expect(f.lineA, isNull);
    }, reason: 'lineALon! rzuca przy niekompletnym zapisie');
  });

  group('LpisParcel', () {
    test('fromArcGisFeature', () {
      final p = LpisParcel.fromArcGisFeature({
        'attributes': {
          'OBJECTID': 12,
          'CROP_GROUP': 'R',
          'CROP_GROUP_DESC': 'Grunty orne',
          'FARM_ID': 7,
          'AREA_HA': 2,
          'CAMPAIGN_YEAR': 2025,
        },
        'geometry': {
          'rings': [
            [
              [17, 52],
              [17.5, 52.0],
              [17.5, 52.5],
              [1],
            ]
          ]
        },
      });
      expect(p.objectId, '12');
      expect(p.cropGroupCode, 'R');
      expect(p.farmId, '7');
      expect(p.areaHa, closeTo(2, 1e-9));
      expect(p.campaignYear, 2025);
      expect(p.boundary, hasLength(3)); // niepełna para pominięta
      expect(p.boundary.first, const LatLng(52, 17));
      expect(p.center.longitude, closeTo(52 / 3, 1e-9));
    });

    test('pusta cecha', () {
      final p = LpisParcel.fromArcGisFeature({});
      expect(p.objectId, '');
      expect(p.boundary, isEmpty);
      expect(p.center, const LatLng(52, 19));
    });

    test('round-trip JSON', () {
      final p = LpisParcel(
        objectId: 'a',
        boundaryLats: const [52.0, 52.1, 52.2],
        boundaryLons: const [17.0, 17.1, 17.2],
        cropGroupCode: 'R',
        cropGroupLabel: 'x',
        farmId: '1',
        areaHa: 3.5,
        campaignYear: 2024,
        fetchedAt: DateTime.utc(2025),
      );
      expect(LpisParcel.fromJson(_json(p.toJson())).toJson(), p.toJson());
    });
  });

  group('MachineModel', () {
    test('round-trip i etykiety', () {
      for (final t in MachineType.values) {
        expect(MachineType.fromJson(t.jsonKey), t);
        expect(t.label, isNotEmpty);
      }
      for (final u in MaterialUnit.values) {
        expect(MaterialUnit.fromJson(u.jsonKey), u);
        expect(u.label, isNotEmpty);
        expect(u.shortLabel, isNotEmpty);
      }
      final m = MachineModel(
        id: '1',
        name: 'Amazone',
        type: MachineType.sprayer,
        workingWidthM: 24,
        tankCapacity: 3000,
        tankUnit: MaterialUnit.kilograms,
      );
      expect(MachineModel.fromJson(_json(m.toJson())).toJson(), m.toJson());
    });

    test('nieznany typ / brak pól', () {
      final m = MachineModel.fromJson({'id': '1', 'name': 'x', 'type': 'ufo'});
      expect(m.type, MachineType.other);
      expect(m.workingWidthM, isNull);
      expect(m.tankUnit, isNull);
      expect(MaterialUnit.fromJson(null), MaterialUnit.liters);
    });
  });

  group('WorkTask', () {
    test('round-trip, jednostki', () {
      final t = WorkTask(
        id: 't',
        fieldId: 'f',
        machineId: 'm',
        taskType: TaskType.spray,
        effectiveWidthM: 24,
        targetRate: 200,
        initialTankVolume: 1000,
        unit: 'l/ha',
        createdAt: DateTime.utc(2025, 4, 1),
        name: 'n',
      );
      expect(WorkTask.fromJson(_json(t.toJson())).toJson(), t.toJson());
      expect(TaskType.spray.defaultUnit, 'l/ha');
      expect(TaskType.seed.defaultUnit, 'kg/ha');
      expect(TaskType.fertilize.usesMaterial, isTrue);
      expect(TaskType.harvest.usesMaterial, isFalse);
      for (final x in TaskType.values) {
        expect(x.label, isNotEmpty);
      }
    });

    test('nieznany typ → other', () {
      final t = WorkTask.fromJson({
        'id': 't',
        'fieldId': 'f',
        'taskType': 'x',
        'createdAt': '2025-01-01T00:00:00.000Z',
      });
      expect(t.taskType, TaskType.other);
    });
  });

  group('TaskPlan', () {
    final plan = TaskPlan(
      id: 'p',
      name: 'Plan',
      fieldId: 'f',
      fieldName: 'Pole',
      boundaryLats: const [52.0, 52.0, 52.1],
      boundaryLons: const [17.0, 17.1, 17.1],
      lineALat: 52,
      lineALon: 17,
      lineBLat: 52.1,
      lineBLon: 17,
      machineId: 'm',
      machineName: 'M',
      machineType: 'sprayer',
      taskType: TaskType.seed,
      workingWidthM: 6,
      overlapM: 0.1,
      headlandLaps: 2,
      swathAngleDeg: 45,
      manualOffsetM: -0.5,
      targetRate: 180,
      tankVolume: 900,
      unit: 'kg/ha',
      createdAt: DateTime.utc(2025),
    );

    test('round-trip mapy SQLite', () {
      final back = TaskPlan.fromMap(plan.toMap());
      expect(back.toMap(), plan.toMap());
      expect(back.boundary, hasLength(3));
    });

    test('brakujące kolumny → domyślne; niepełna AB → null', () {
      final p = TaskPlan.fromMap({
        'id': 'p',
        'field_id': 'f',
        'ab_a': '[52]',
        'ab_b': '',
        'task_type': '?',
        'created_at': '2025-01-01',
      });
      expect(p.workingWidthM, closeTo(3, 1e-9));
      expect(p.headlandLaps, 0);
      expect(p.boundary, isEmpty);
      expect(p.lineALat, isNull);
      expect(p.lineBLat, isNull);
      expect(p.taskType, TaskType.other);
    });

    test('linie AB kodowane tylko w komplecie', () {
      final p = TaskPlan.fromMap(plan.toMap()..['ab_a'] = null);
      expect(p.toMap()['ab_a'], isNull);
      expect(p.lineBLat, closeTo(52.1, 1e-9));
    });
  });

  group('HistoryRecord', () {
    test('round-trip', () {
      final r = HistoryRecord(
        id: 'h',
        fieldId: 'f',
        fieldName: 'Pole',
        machineName: 'M',
        taskType: TaskType.spray,
        workingWidthM: 24,
        overlapM: 0.2,
        swathAngleDeg: 12,
        workDuration: const Duration(minutes: 90),
        coveredHa: 12.5,
        productivityHaPerHour: 8.33,
        materialConsumed: 2500,
        materialUnit: 'l',
        note: 'ok',
        completedAt: DateTime(2025, 6, 1, 12),
        entrySource: HistoryEntrySource.manual,
      );
      expect(HistoryRecord.fromMap(r.toMap()).toMap(), r.toMap());
      expect(r.year, 2025);
    });

    test('stary rekord bez nowych kolumn', () {
      final r = HistoryRecord.fromMap(
          {'id': 'h', 'completed_at': '2024-01-02T03:04:05'});
      expect(r.entrySource, HistoryEntrySource.navigation);
      expect(r.workDuration, isNull);
      expect(r.coveredHa, closeTo(0, 1e-12));
    });

    test('HistoryFieldSummary', () {
      final s = HistoryFieldSummary.fromMap({
        'field_id': 'f',
        'field_name': null,
        'count': 3,
        'last_completed': '2025-01-01T00:00:00',
      });
      expect(s.fieldName, '—');
      expect(s.recordCount, 3);
      expect(s.lastCompleted, DateTime(2025));
      expect(HistoryFieldSummary.fromMap({}).lastCompleted, isNull);
    });
  });
}
