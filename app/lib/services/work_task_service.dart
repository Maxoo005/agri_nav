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
}
