import 'dart:developer' as dev;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;

import '../models/history_record.dart';

/// SQLite storage for completed-work history (`agrinav_history.db`).
///
/// Każde zakończenie pracy ("Zakończ pracę") zapisuje jeden rekord —
/// migawkę pola, maszyny, zadania, parametrów ścieżek, czasu pracy,
/// powierzchni i notatki operatora.
class HistoryDatabase {
  HistoryDatabase._();
  static final instance = HistoryDatabase._();

  static const _dbName = 'agrinav_history.db';
  static const _table = 'history';

  Database? _db;

  /// Ustawia domyślny silnik SQLite dla bieżącej platformy (patrz
  /// [TaskDatabase.configureFactory] — ten sam mechanizm).
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
      version: 3,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $_table (
            id                       TEXT PRIMARY KEY,
            field_id                 TEXT,
            field_name               TEXT,
            machine                  TEXT,
            task_type                TEXT,
            working_width_m          REAL,
            overlap_m                REAL,
            swath_angle_deg          REAL,
            work_duration_ms         INTEGER,
            covered_ha               REAL,
            productivity_ha_per_hour REAL,
            material_consumed        REAL,
            material_unit            TEXT,
            note                     TEXT,
            completed_at             TEXT
          )
        ''');
        await db.execute(
            'CREATE INDEX idx_history_field ON $_table (field_id, completed_at)');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
              'ALTER TABLE $_table ADD COLUMN productivity_ha_per_hour REAL');
        }
        if (oldVersion < 3) {
          await db.execute(
              'ALTER TABLE $_table ADD COLUMN material_consumed REAL');
          await db
              .execute('ALTER TABLE $_table ADD COLUMN material_unit TEXT');
        }
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
      dev.log('HistoryDatabase init error: $e', name: 'HistoryDatabase');
    }
  }

  Future<void> save(HistoryRecord record) async {
    final db = await _database;
    await db.insert(
      _table,
      record.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Unikalne pola (posortowane po ostatniej pracy) + liczba zakończonych
  /// prac na pole.
  Future<List<HistoryFieldSummary>> getFields() async {
    final db = await _database;
    final rows = await db.rawQuery('''
      SELECT field_id,
             field_name,
             COUNT(*)            AS count,
             MAX(completed_at)   AS last_completed
      FROM $_table
      GROUP BY field_id
      ORDER BY MAX(completed_at) DESC
    ''');
    return rows.map(HistoryFieldSummary.fromMap).toList();
  }

  /// Wszystkie zakończone prace danego pola — niezależnie od roku i typu
  /// zadania — od najnowszej.
  Future<List<HistoryRecord>> getFieldRecords(String fieldId) async {
    final db = await _database;
    final rows = await db.query(
      _table,
      where: 'field_id = ?',
      whereArgs: [fieldId],
      orderBy: 'completed_at DESC',
    );
    return rows.map(HistoryRecord.fromMap).toList();
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
