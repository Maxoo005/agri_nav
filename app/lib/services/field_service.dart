import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../models/field_model.dart';
import '../utils/geo_utils.dart';

/// Nazwa boxa Hive.
const _kFieldBox = 'fields';

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
  static Future<void> init() async => Hive.openBox(_kFieldBox);

  Box get _box => Hive.box(_kFieldBox);

  // ── Odczyt ───────────────────────────────────────────────────────────────────

  /// Wszystkie zapisane pola.
  List<FieldModel> getAll() =>
      _box.values.map((e) => FieldModel.fromJson(e as Map)).toList()
        ..sort((a, b) => a.name.compareTo(b.name));

  /// ValueListenable — pozwala reaktywnie słuchać zmian w UI.
  ValueListenable<Box> get listenable => _box.listenable();

  // ── Zapis / usuwanie ──────────────────────────────────────────────────────────

  Future<void> save(FieldModel field) => _box.put(field.id, field.toJson());

  Future<void> delete(String id) => _box.delete(id);

  Future<void> deleteAll() => _box.clear();

  // ── Powierzchnia ──────────────────────────────────────────────────────────────

  /// Oblicza powierzchnię [ha] z geometrii i zapisuje ją dla WSZYSTKICH pól.
  ///
  /// Uzupełnia brakujące dane w istniejących (poprawionych) polach.
  /// Zwraca liczbę zaktualizowanych pól.
  Future<int> populateAreas() async {
    var updated = 0;
    for (final field in getAll()) {
      final area = GeoUtils.polygonAreaHa(field.boundary);
      if (area <= 0) continue;
      final current = field.areaHa;
      if (current == null || (current - area).abs() > 0.0005) {
        field.areaHa = area;
        await save(field);
        updated++;
      }
    }
    return updated;
  }
}
