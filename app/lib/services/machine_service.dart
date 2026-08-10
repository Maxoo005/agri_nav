import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../models/machine_model.dart';

const _kMachineBox = 'machines';

/// CRUD dla maszyn rolniczych. Dane trwałe przez Hive.
class MachineService {
  MachineService._();
  static final instance = MachineService._();

  static Future<void> init() async => Hive.openBox(_kMachineBox);

  Box get _box => Hive.box(_kMachineBox);

  List<MachineModel> getAll() =>
      _box.values.map((e) => MachineModel.fromJson(e as Map)).toList()
        ..sort((a, b) => a.name.compareTo(b.name));

  MachineModel? getById(String? id) {
    if (id == null) return null;
    final raw = _box.get(id);
    return raw != null ? MachineModel.fromJson(raw as Map) : null;
  }

  ValueListenable<Box> get listenable => _box.listenable();

  Future<void> save(MachineModel m) => _box.put(m.id, m.toJson());

  Future<void> delete(String id) => _box.delete(id);

  Future<void> deleteAll() => _box.clear();
}
