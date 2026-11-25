import 'dart:io';

import 'package:agri_nav/models/history_record.dart';
import 'package:agri_nav/models/task_plan.dart';
import 'package:agri_nav/models/work_task.dart';
import 'package:agri_nav/services/history_database.dart';
import 'package:agri_nav/services/task_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

HistoryRecord _rec(String id, String field, DateTime when) => HistoryRecord(
      id: id,
      fieldId: field,
      fieldName: 'Pole $field',
      taskType: TaskType.spray,
      workingWidthM: 24,
      overlapM: 0,
      swathAngleDeg: 0,
      coveredHa: 1,
      completedAt: when,
    );

TaskPlan _plan(String id, int day) => TaskPlan(
      id: id,
      name: 'n$id',
      fieldId: 'f',
      fieldName: 'F',
      boundaryLats: const [52, 52, 52.1],
      boundaryLons: const [17, 17.1, 17.1],
      taskType: TaskType.seed,
      workingWidthM: 6,
      overlapM: 0,
      headlandLaps: 1,
      swathAngleDeg: 0,
      manualOffsetM: 0.25,
      createdAt: DateTime.utc(2025, 1, day),
    );

void main() {
  late Directory dir;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    dir = await Directory.systemTemp.createTemp('agrinav_db_');
    await databaseFactory.setDatabasesPath(dir.path);

    // Baza zadań w schemacie v1 — pierwszy dostęp musi ją zmigrować do v2.
    final v1 = await openDatabase(
      p.join(dir.path, 'agrinav.db'),
      version: 1,
      onCreate: (db, _) => db.execute('''
        CREATE TABLE tasks (id TEXT PRIMARY KEY, name TEXT, field_id TEXT,
          field_name TEXT, boundary_lats TEXT, boundary_lons TEXT, ab_a TEXT,
          ab_b TEXT, machine_id TEXT, machine_name TEXT, machine_type TEXT,
          task_type TEXT, working_width_m REAL, overlap_m REAL,
          headland_laps INTEGER, swath_angle_deg REAL, target_rate REAL,
          tank_volume REAL, unit TEXT, created_at TEXT)'''),
    );
    await v1.insert('tasks', {
      'id': 'stare',
      'field_id': 'f',
      'created_at': '2020-01-01T00:00:00.000Z',
    });
    await v1.close();

    // Historia w schemacie v1 (bez wydajności, materiału i źródła wpisu).
    final h1 = await openDatabase(
      p.join(dir.path, 'agrinav_history.db'),
      version: 1,
      onCreate: (db, _) => db.execute('''
        CREATE TABLE history (id TEXT PRIMARY KEY, field_id TEXT,
          field_name TEXT, machine TEXT, task_type TEXT, working_width_m REAL,
          overlap_m REAL, swath_angle_deg REAL, work_duration_ms INTEGER,
          covered_ha REAL, note TEXT, completed_at TEXT)'''),
    );
    await h1.insert('history', {
      'id': 'stare',
      'field_id': 'old',
      'field_name': 'Stare',
      'completed_at': '2020-01-01T00:00:00.000',
    });
    await h1.close();
  });

  test('configureFactory nie nadpisuje ustawionej fabryki', () {
    final before = databaseFactory;
    TaskDatabase.configureFactory();
    HistoryDatabase.configureFactory();
    expect(databaseFactory, same(before));
  });

  test('TaskDatabase: migracja v1→v2 i CRUD', () async {
    final db = TaskDatabase.instance;
    await db.init();
    expect((await db.getById('stare'))!.manualOffsetM, closeTo(0, 1e-12));
    await db.save(_plan('a', 1));
    await db.save(_plan('b', 2));
    expect((await db.getAll()).map((t) => t.id), ['b', 'a', 'stare']);
    expect((await db.getById('a'))!.manualOffsetM, closeTo(0.25, 1e-12));
    await db.rename('a', 'nowa');
    expect((await db.getById('a'))!.name, 'nowa');
    await db.save(_plan('a', 1)); // replace, nie duplikat
    expect(await db.getAll(), hasLength(3));
    await db.delete('a');
    expect(await db.getById('a'), isNull);
    await db.clear();
    expect(await db.getAll(), isEmpty);
  });

  test('HistoryDatabase: migracja v1→v4, filtry i agregacja', () async {
    final db = HistoryDatabase.instance;
    await db.init();
    final old = (await db.getFieldRecords('old')).single;
    expect(old.productivityHaPerHour, isNull);
    expect(old.entrySource, HistoryEntrySource.navigation);
    await db.delete('stare');

    await db.save(_rec('1', 'A', DateTime(2025, 5, 1, 0, 0)));
    await db.save(_rec('2', 'A', DateTime(2025, 5, 31, 23, 59, 59)));
    await db.save(_rec('3', 'B', DateTime(2025, 6, 1)));

    expect((await db.getFieldRecords('A')).map((r) => r.id), ['2', '1']);
    final may = await db.getRecords(
        from: DateTime(2025, 5, 1, 15), to: DateTime(2025, 5, 31));
    expect(may.map((r) => r.id), ['1', '2']); // pełne dni, inkluzywnie
    expect(await db.getRecords(fieldIds: ['B']), hasLength(1));
    expect(await db.getRecords(fieldIds: []), hasLength(3));
    expect(await db.getRecords(), hasLength(3));

    final fields = await db.getFields();
    expect(fields.map((f) => (f.fieldId, f.recordCount)), [('B', 1), ('A', 2)]);

    await db.clear();
    expect(await db.getFields(), isEmpty);
  });
}
