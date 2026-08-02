import 'dart:developer' as dev;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;

import '../models/task_plan.dart';

/// SQLite storage for saved work-task plans (`agrinav.db`, table `tasks`).
///
/// The database file lives in the app's databases directory, e.g. on Android:
///   /data/data/<pkg>/databases/agrinav.db
/// On desktop it uses the platform databases directory too.
class TaskDatabase {
  TaskDatabase._();
  static final instance = TaskDatabase._();

  static const _dbName = 'agrinav.db';
  static const _table = 'tasks';

  Database? _db;

  /// Ustawia domyślny silnik SQLite dla bieżącej platformy.
  ///
  /// Bez tego wywołanie globalnego `getDatabasesPath()`/`openDatabase()`
  /// rzuca `StateError: databaseFactory not initialized`.
  ///  • Android/iOS → wtyczka `sqflite` (kanał natywny),
  ///  • desktop (Windows) → silnik FFI (`sqflite_common_ffi` + sqlite3).
  static void configureFactory() {
    if (kIsWeb) return;
    if (Platform.isAndroid || Platform.isIOS) {
      databaseFactoryOrNull ??= databaseFactorySqflitePlugin;
    } else {
      ffi.sqfliteFfiInit();
      databaseFactoryOrNull ??= ffi.databaseFactoryFfi;
    }
  }

  Future<Database> get _database async {
    _db ??= await _open();
    return _db!;
  }

  Future<Database> _open() async {
    final path = await getDatabasePath();
    return openDatabase(
      path,
      version: 1,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $_table (
            id              TEXT PRIMARY KEY,
            name            TEXT,
            field_id        TEXT,
            field_name      TEXT,
            boundary_lats   TEXT,
            boundary_lons   TEXT,
            ab_a            TEXT,
            ab_b            TEXT,
            machine_id      TEXT,
            machine_name    TEXT,
            machine_type    TEXT,
            task_type       TEXT,
            working_width_m REAL,
            overlap_m       REAL,
            headland_laps   INTEGER,
            swath_angle_deg REAL,
            target_rate     REAL,
            tank_volume     REAL,
            unit            TEXT,
            created_at      TEXT
          )
        ''');
        await db.execute(
            'CREATE INDEX idx_tasks_created ON $_table (created_at)');
      },
    );
  }

  /// Absolute path of the .db file (useful to show in the UI).
  Future<String> getDatabasePath() async {
    final dir = await getDatabasesPath();
    return p.join(dir, _dbName);
  }

  /// Otwiera bazę przy starcie. Błąd nie zatrzymuje aplikacji — ponowna
  /// próba nastąpi przy pierwszym zapisie (błąd jest tylko logowany).
  Future<void> init() async {
    try {
      await _database;
    } catch (e) {
      dev.log('TaskDatabase init error: $e', name: 'TaskDatabase');
    }
  }

  Future<void> save(TaskPlan plan) async {
    final db = await _database;
    await db.insert(
      _table,
      plan.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<TaskPlan>> getAll() async {
    final db = await _database;
    final rows = await db.query(_table, orderBy: 'created_at DESC');
    return rows.map(TaskPlan.fromMap).toList();
  }

  Future<TaskPlan?> getById(String id) async {
    final db = await _database;
    final rows = await db.query(_table, where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : TaskPlan.fromMap(rows.first);
  }

  /// Zmienia nazwę zadania o podanym `id`.
  Future<void> rename(String id, String newName) async {
    final db = await _database;
    await db.update(
      _table,
      {'name': newName},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> delete(String id) async {
    final db = await _database;
    await db.delete(_table, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> clear() async {
    final db = await _database;
    await db.delete(_table);
  }
}
