import 'package:hive_flutter/hive_flutter.dart';

import '../models/work_task.dart';

const _kBox = 'work_tasks';

/// Persistent storage for [WorkTask] objects (Hive box: `work_tasks`).
class WorkTaskService {
  WorkTaskService._();
  static final instance = WorkTaskService._();

  static Future<void> init() => Hive.openBox(_kBox);

  Box get _box => Hive.box(_kBox);

  Future<void> save(WorkTask task) => _box.put(task.id, task.toJson());

  WorkTask? get(String id) {
    final raw = _box.get(id);
    if (raw == null) return null;
    return WorkTask.fromJson(Map<String, dynamic>.from(raw as Map));
  }

  List<WorkTask> getAll() => _box.values
      .map((v) => WorkTask.fromJson(Map<String, dynamic>.from(v as Map)))
      .toList()
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  List<WorkTask> getByField(String fieldId) =>
      getAll().where((t) => t.fieldId == fieldId).toList();

  Future<void> delete(String id) => _box.delete(id);
}
