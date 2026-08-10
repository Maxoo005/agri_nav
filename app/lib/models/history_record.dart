import 'work_task.dart';

/// Jeden wpis historii — migawka zakończonej pracy: pole, maszyna, rodzaj
/// zadania, parametry ścieżek, czas pracy, powierzchnia i notatka operatora.
///
/// Zapisywany do SQLite (`agrinav_history.db`, tabela `history`) w momencie
/// kliknięcia "Zakończ pracę".
class HistoryRecord {
  final String id;
  final String fieldId;
  final String fieldName;

  /// Nazwa maszyny w momencie zakończenia pracy (null = brak wybranej).
  final String? machineName;

  final TaskType taskType;

  /// Szerokość robocza [m].
  final double workingWidthM;

  /// Zakładka (overlap) między przejściami [m].
  final double overlapM;

  /// Kierunek ścieżek (azymut) [°].
  final double swathAngleDeg;

  /// Czas pracy (bez przerw) w momencie zakończenia.
  final Duration workDuration;

  /// Powierzchnia zrobiona w momencie zakończenia [ha].
  final double coveredHa;

  /// Wydajność [ha/h] w momencie zakończenia — `coveredHa / czas pracy`.
  /// Null dla starszych rekordów (przed wersją z wydajnością).
  final double? productivityHaPerHour;

  /// Łączne zużycie materiału (l/kg) w momencie zakończenia. Null = zadanie
  /// bez monitorowania materiału (albo starszy rekord sprzed tej wersji).
  final double? materialConsumed;

  /// Jednostka [materialConsumed], np. "l" lub "kg".
  final String? materialUnit;

  /// Notatka operatora wpisana przy "Zakończ pracę" (może być pusta).
  final String? note;

  /// Data zakończenia pracy (pełny znacznik czasu).
  final DateTime completedAt;

  HistoryRecord({
    required this.id,
    required this.fieldId,
    required this.fieldName,
    this.machineName,
    required this.taskType,
    required this.workingWidthM,
    required this.overlapM,
    required this.swathAngleDeg,
    required this.workDuration,
    required this.coveredHa,
    this.productivityHaPerHour,
    this.materialConsumed,
    this.materialUnit,
    this.note,
    required this.completedAt,
  });

  /// Rok kalendarzowy zakończenia pracy.
  int get year => completedAt.year;

  Map<String, Object?> toMap() => {
        'id': id,
        'field_id': fieldId,
        'field_name': fieldName,
        'machine': machineName,
        'task_type': taskType.name,
        'working_width_m': workingWidthM,
        'overlap_m': overlapM,
        'swath_angle_deg': swathAngleDeg,
        'work_duration_ms': workDuration.inMilliseconds,
        'covered_ha': coveredHa,
        'productivity_ha_per_hour': productivityHaPerHour,
        'material_consumed': materialConsumed,
        'material_unit': materialUnit,
        'note': note,
        'completed_at': completedAt.toIso8601String(),
      };

  factory HistoryRecord.fromMap(Map<String, Object?> map) => HistoryRecord(
        id: map['id'] as String,
        fieldId: (map['field_id'] as String?) ?? '',
        fieldName: (map['field_name'] as String?) ?? '',
        machineName: map['machine'] as String?,
        taskType: TaskType.values.firstWhere(
          (t) => t.name == map['task_type'],
          orElse: () => TaskType.other,
        ),
        workingWidthM: (map['working_width_m'] as num?)?.toDouble() ?? 0.0,
        overlapM: (map['overlap_m'] as num?)?.toDouble() ?? 0.0,
        swathAngleDeg:
            (map['swath_angle_deg'] as num?)?.toDouble() ?? 0.0,
        workDuration: Duration(
            milliseconds: (map['work_duration_ms'] as num?)?.toInt() ?? 0),
        coveredHa: (map['covered_ha'] as num?)?.toDouble() ?? 0.0,
        productivityHaPerHour:
            (map['productivity_ha_per_hour'] as num?)?.toDouble(),
        materialConsumed: (map['material_consumed'] as num?)?.toDouble(),
        materialUnit: map['material_unit'] as String?,
        note: map['note'] as String?,
        completedAt: DateTime.parse(map['completed_at'] as String),
      );
}

/// Zagregowany widok pola na liście Historii (jedno pole + liczba prac).
class HistoryFieldSummary {
  final String fieldId;
  final String fieldName;
  final int recordCount;
  final DateTime? lastCompleted;

  HistoryFieldSummary({
    required this.fieldId,
    required this.fieldName,
    required this.recordCount,
    this.lastCompleted,
  });

  factory HistoryFieldSummary.fromMap(Map<String, Object?> map) =>
      HistoryFieldSummary(
        fieldId: (map['field_id'] as String?) ?? '',
        fieldName: (map['field_name'] as String?) ?? '—',
        recordCount: (map['count'] as num?)?.toInt() ?? 0,
        lastCompleted: map['last_completed'] is String
            ? DateTime.tryParse(map['last_completed'] as String)
            : null,
      );
}
