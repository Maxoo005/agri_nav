/// Typ maszyny rolniczej.
enum MachineType {
  tractor,
  sprayer,
  seeder,
  cultivator,
  harvester,
  other;

  String get label {
    switch (this) {
      case MachineType.tractor:
        return 'Ciągnik';
      case MachineType.sprayer:
        return 'Nawożenie';
      case MachineType.seeder:
        return 'Siewnik';
      case MachineType.cultivator:
        return 'Kultywator';
      case MachineType.harvester:
        return 'Kombajn';
      case MachineType.other:
        return 'Inne';
    }
  }

  String get jsonKey {
    switch (this) {
      case MachineType.tractor:
        return 'tractor';
      case MachineType.sprayer:
        return 'sprayer';
      case MachineType.seeder:
        return 'seeder';
      case MachineType.cultivator:
        return 'cultivator';
      case MachineType.harvester:
        return 'harvester';
      case MachineType.other:
        return 'other';
    }
  }

  static MachineType fromJson(String? v) {
    switch (v) {
      case 'tractor':
        return MachineType.tractor;
      case 'sprayer':
        return MachineType.sprayer;
      case 'seeder':
        return MachineType.seeder;
      case 'cultivator':
        return MachineType.cultivator;
      case 'harvester':
        return MachineType.harvester;
      default:
        return MachineType.other;
    }
  }
}

/// Jednostka dawkowania dla maszyn typu [MachineType.sprayer] (Nawożenie):
/// zbiornik może być rozliczany w litrach (nawóz płynny) albo w kilogramach
/// (nawóz granulowany).
enum MaterialUnit {
  liters,
  kilograms;

  String get label {
    switch (this) {
      case MaterialUnit.liters:
        return 'Litry';
      case MaterialUnit.kilograms:
        return 'Kilogramy';
    }
  }

  String get shortLabel {
    switch (this) {
      case MaterialUnit.liters:
        return 'l';
      case MaterialUnit.kilograms:
        return 'kg';
    }
  }

  String get jsonKey {
    switch (this) {
      case MaterialUnit.liters:
        return 'liters';
      case MaterialUnit.kilograms:
        return 'kilograms';
    }
  }

  static MaterialUnit fromJson(String? v) {
    switch (v) {
      case 'kilograms':
        return MaterialUnit.kilograms;
      default:
        return MaterialUnit.liters;
    }
  }
}

/// Model maszyny rolniczej przechowywany w Hive jako mapa JSON.
class MachineModel {
  final String id;
  String name;
  MachineType type;

  /// Szerokość robocza [m]. Null dla ciągnika (napęd — brak szerokości roboczej).
  double? workingWidthM;

  /// Pojemność zbiornika — dotyczy tylko [MachineType.sprayer] (Nawożenie).
  double? tankCapacity;

  /// Jednostka pojemności zbiornika (litry/kilogramy) — dotyczy tylko
  /// [MachineType.sprayer] (Nawożenie).
  MaterialUnit? tankUnit;

  MachineModel({
    required this.id,
    required this.name,
    required this.type,
    this.workingWidthM,
    this.tankCapacity,
    this.tankUnit,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type.jsonKey,
        'workingWidthM': workingWidthM,
        'tankCapacity': tankCapacity,
        'tankUnit': tankUnit?.jsonKey,
      };

  factory MachineModel.fromJson(Map raw) => MachineModel(
        id: raw['id'] as String,
        name: raw['name'] as String,
        type: MachineType.fromJson(raw['type'] as String?),
        workingWidthM: (raw['workingWidthM'] as num?)?.toDouble(),
        tankCapacity: (raw['tankCapacity'] as num?)?.toDouble(),
        tankUnit: raw['tankUnit'] != null
            ? MaterialUnit.fromJson(raw['tankUnit'] as String?)
            : null,
      );
}
