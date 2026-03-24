import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../models/field_model.dart';

/// Nazwa boxa Hive.
const kFieldBox = 'fields';

/// CRUD dla pól uprawowych. Dane trwałe przez Hive.
///
/// Użycie:
/// ```dart
/// await FieldService.init();            // wywołaj raz w main()
/// FieldService.instance.save(field);
/// ```
class FieldService {
  FieldService._();
  static final instance = FieldService._();

  /// Inicjalizacja: otwiera box Hive. Wywołać w main() po Hive.initFlutter().
  static Future<void> init() async => Hive.openBox(kFieldBox);

  Box get _box => Hive.box(kFieldBox);

  // ── Odczyt ───────────────────────────────────────────────────────────────────

  /// Wszystkie zapisane pola.
  List<FieldModel> getAll() =>
      _box.values.map((e) => FieldModel.fromJson(e as Map)).toList()
        ..sort((a, b) => a.name.compareTo(b.name));

  FieldModel? getById(String id) {
    final raw = _box.get(id);
    if (raw == null) return null;
    return FieldModel.fromJson(raw as Map);
  }

  /// ValueListenable — pozwala reaktywnie słuchać zmian w UI.
  ValueListenable<Box> get listenable => _box.listenable();

  // ── Zapis / usuwanie ──────────────────────────────────────────────────────────

  Future<void> save(FieldModel field) => _box.put(field.id, field.toJson());

  Future<void> delete(String id) => _box.delete(id);

  Future<void> deleteAll() => _box.clear();
}
