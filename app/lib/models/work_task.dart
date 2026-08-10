/// Types of agricultural tasks, shown in Polish in the UI.
enum TaskType {
  spray,
  seed,
  fertilize,
  cultivate,
  harvest,
  other;

  String get label {
    switch (this) {
      case TaskType.spray:
        return 'Oprysk';
      case TaskType.seed:
        return 'Siew';
      case TaskType.fertilize:
        return 'Nawożenie';
      case TaskType.cultivate:
        return 'Uprawka';
      case TaskType.harvest:
        return 'Zbiór';
      case TaskType.other:
        return 'Inne';
    }
  }

  /// Default unit for material monitoring; null = material tracking N/A.
  String? get defaultUnit {
    switch (this) {
      case TaskType.spray:
        return 'l/ha';
      case TaskType.seed:
      case TaskType.fertilize:
        return 'kg/ha';
      default:
        return null;
    }
  }

  bool get usesMaterial => defaultUnit != null;
}

/// One agricultural work session: field + machine + task type.
///
/// Swaths are generated ephemerally in RAM from [effectiveWidthM]; they are
/// never stored in [FieldModel] or in this object.
class WorkTask {
  final String id;
  final String fieldId;

  /// Null when no machine was selected (manual swath-params workflow).
  final String? machineId;

  final TaskType taskType;

  /// Machine working-width at moment of task creation.  Null when machine
  /// with no working-width (e.g. tractor without implement) was selected.
  final double? effectiveWidthM;

  // ── Material consumption fields ───────────────────────────────────────────

  /// Application rate per hectare (e.g. l/ha for spraying, kg/ha for seeding).
  /// Null = material monitoring disabled for this task. Mutable: can be
  /// adjusted mid-task via [MaterialMonitorService.setRate].
  double? targetRate;

  /// Volume/mass loaded into the tank at task start (same unit as [targetRate]
  /// but absolute, e.g. litres or kilograms). Null until the operator
  /// confirms the fill level at the start of Work Mode. Mutable: set once
  /// via [MaterialMonitorService.confirmInitialFill].
  double? initialTankVolume;

  /// Unit label shown in the UI, e.g. "l/ha", "kg/ha".
  final String? unit;

  final DateTime createdAt;
  String? name;

  WorkTask({
    required this.id,
    required this.fieldId,
    this.machineId,
    required this.taskType,
    this.effectiveWidthM,
    this.targetRate,
    this.initialTankVolume,
    this.unit,
    required this.createdAt,
    this.name,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'fieldId': fieldId,
        'machineId': machineId,
        'taskType': taskType.name,
        'effectiveWidthM': effectiveWidthM,
        'targetRate': targetRate,
        'initialTankVolume': initialTankVolume,
        'unit': unit,
        'createdAt': createdAt.toIso8601String(),
        'name': name,
      };

  factory WorkTask.fromJson(Map<String, dynamic> json) => WorkTask(
        id: json['id'] as String,
        fieldId: json['fieldId'] as String,
        machineId: json['machineId'] as String?,
        taskType: TaskType.values.firstWhere(
          (t) => t.name == json['taskType'],
          orElse: () => TaskType.other,
        ),
        effectiveWidthM: (json['effectiveWidthM'] as num?)?.toDouble(),
        targetRate: (json['targetRate'] as num?)?.toDouble(),
        initialTankVolume: (json['initialTankVolume'] as num?)?.toDouble(),
        unit: json['unit'] as String?,
        createdAt: DateTime.parse(json['createdAt'] as String),
        name: json['name'] as String?,
      );
}
