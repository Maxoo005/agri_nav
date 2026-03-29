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
        return 'Opryskiwacz';
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

/// Model maszyny rolniczej przechowywany w Hive jako mapa JSON.
class MachineModel {
  final String id;
  String name;
  MachineType type;

  /// Szerokość robocza [m]. Null dla ciągnika (napęd — brak szerokości roboczej).
  double? workingWidthM;

  MachineModel({
    required this.id,
    required this.name,
    required this.type,
    this.workingWidthM,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type.jsonKey,
        'workingWidthM': workingWidthM,
      };

  factory MachineModel.fromJson(Map raw) => MachineModel(
        id: raw['id'] as String,
        name: raw['name'] as String,
        type: MachineType.fromJson(raw['type'] as String?),
        workingWidthM: (raw['workingWidthM'] as num?)?.toDouble(),
      );
}
