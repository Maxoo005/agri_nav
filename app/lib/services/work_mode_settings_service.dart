import 'package:hive_flutter/hive_flutter.dart';

const _kSettingsBox = 'work_mode_settings';
const _kOrientationModeKey = 'mapOrientationMode';

/// Orientacja mapy w Trybie Pracy.
enum MapOrientationMode {
  /// Kierunek jazdy zawsze do góry ekranu — mapa obraca się względem
  /// (wygładzonego) headingu maszyny.
  headingUp,

  /// Północ zawsze do góry — mapa nigdy się nie obraca, tylko przesuwa się
  /// za pozycją. Zero problemu z szumem headingu, kosztem tego że kierunek
  /// jazdy nie zawsze wskazuje górę ekranu.
  northUp,
}

/// Singleton — proste ustawienia UI Trybu Pracy trwałe między sesjami (Hive).
///
/// Na razie trzyma wyłącznie [orientationMode]; wzorzec (singleton + własny
/// box Hive) taki sam jak [WorkSessionService]/[MachineService], żeby łatwo
/// dołożyć kolejne ustawienia w przyszłości bez zmiany kształtu API.
class WorkModeSettingsService {
  WorkModeSettingsService._();
  static final instance = WorkModeSettingsService._();

  /// Otwiera box i wczytuje zapisaną preferencję. Wywołać w main() po
  /// Hive.initFlutter().
  static Future<void> init() async {
    final box = await Hive.openBox(_kSettingsBox);
    final raw = box.get(_kOrientationModeKey) as String?;
    instance._orientationMode = MapOrientationMode.values.asNameMap()[raw] ??
        MapOrientationMode.headingUp;
  }

  Box get _box => Hive.box(_kSettingsBox);

  MapOrientationMode _orientationMode = MapOrientationMode.headingUp;

  MapOrientationMode get orientationMode => _orientationMode;

  set orientationMode(MapOrientationMode mode) {
    if (_orientationMode == mode) return;
    _orientationMode = mode;
    _box.put(_kOrientationModeKey, mode.name);
  }
}
