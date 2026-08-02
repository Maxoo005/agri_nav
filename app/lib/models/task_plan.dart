import 'dart:convert';

import 'package:latlong2/latlong.dart';

import 'work_task.dart';

/// Zapisany plan zadania roboczego — migawka całej konfiguracji:
/// pole (z granicą), maszyna, rodzaj zadania, parametry ścieżek i materiału.
///
/// Przechowywany w SQLite (`agrinav.db`, tabela `tasks`).
/// Różni się od [WorkTask] (Hive) tym, że zawiera pełną granicę pola i
/// parametry generowania ścieżek, dzięki czemu zadanie jest samowystarczalne
/// i można je odtworzyć bez ponownego wybierania pól/maszyn.
class TaskPlan {
  final String id;
  String name;

  // ── Pole (migawka) ─────────────────────────────────────────────────────────
  final String fieldId;
  final String fieldName;
  final List<double> boundaryLats;
  final List<double> boundaryLons;
  final double? lineALat, lineALon;
  final double? lineBLat, lineBLon;

  // ── Maszyna (migawka) ──────────────────────────────────────────────────────
  final String? machineId;
  final String? machineName;
  final String? machineType;

  // ── Rodzaj zadania ─────────────────────────────────────────────────────────
  final TaskType taskType;

  // ── Parametry ścieżek ──────────────────────────────────────────────────────
  final double workingWidthM;
  final double overlapM;
  final int headlandLaps;
  final double swathAngleDeg;

  // ── Parametry materiału (opcjonalnie) ──────────────────────────────────────
  final double? targetRate;
  final double? tankVolume;
  final String? unit;

  final DateTime createdAt;

  TaskPlan({
    required this.id,
    required this.name,
    required this.fieldId,
    required this.fieldName,
    required this.boundaryLats,
    required this.boundaryLons,
    this.lineALat,
    this.lineALon,
    this.lineBLat,
    this.lineBLon,
    this.machineId,
    this.machineName,
    this.machineType,
    required this.taskType,
    required this.workingWidthM,
    required this.overlapM,
    required this.headlandLaps,
    required this.swathAngleDeg,
    this.targetRate,
    this.tankVolume,
    this.unit,
    required this.createdAt,
  });

  /// Granica jako lista LatLng (do podglądu / generowania ścieżek).
  List<LatLng> get boundary => List.generate(
        boundaryLats.length,
        (i) => LatLng(boundaryLats[i], boundaryLons[i]),
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'field_id': fieldId,
        'field_name': fieldName,
        'boundary_lats': _encodeList(boundaryLats),
        'boundary_lons': _encodeList(boundaryLons),
        'ab_a': _encodeAb(lineALat, lineALon),
        'ab_b': _encodeAb(lineBLat, lineBLon),
        'machine_id': machineId,
        'machine_name': machineName,
        'machine_type': machineType,
        'task_type': taskType.name,
        'working_width_m': workingWidthM,
        'overlap_m': overlapM,
        'headland_laps': headlandLaps,
        'swath_angle_deg': swathAngleDeg,
        'target_rate': targetRate,
        'tank_volume': tankVolume,
        'unit': unit,
        'created_at': createdAt.toIso8601String(),
      };

  factory TaskPlan.fromMap(Map<String, Object?> map) => TaskPlan(
        id: map['id'] as String,
        name: (map['name'] as String?) ?? '',
        fieldId: map['field_id'] as String,
        fieldName: (map['field_name'] as String?) ?? '',
        boundaryLats: _decodeList(map['boundary_lats'] as String?),
        boundaryLons: _decodeList(map['boundary_lons'] as String?),
        lineALat: _decodeAb(map['ab_a'] as String?)?.$1,
        lineALon: _decodeAb(map['ab_a'] as String?)?.$2,
        lineBLat: _decodeAb(map['ab_b'] as String?)?.$1,
        lineBLon: _decodeAb(map['ab_b'] as String?)?.$2,
        machineId: map['machine_id'] as String?,
        machineName: map['machine_name'] as String?,
        machineType: map['machine_type'] as String?,
        taskType: TaskType.values.firstWhere(
          (t) => t.name == map['task_type'],
          orElse: () => TaskType.other,
        ),
        workingWidthM: (map['working_width_m'] as num?)?.toDouble() ?? 3.0,
        overlapM: (map['overlap_m'] as num?)?.toDouble() ?? 0.0,
        headlandLaps: (map['headland_laps'] as num?)?.toInt() ?? 0,
        swathAngleDeg: (map['swath_angle_deg'] as num?)?.toDouble() ?? 0.0,
        targetRate: (map['target_rate'] as num?)?.toDouble(),
        tankVolume: (map['tank_volume'] as num?)?.toDouble(),
        unit: map['unit'] as String?,
        createdAt: DateTime.parse(map['created_at'] as String),
      );

  static String _encodeList(List<double> list) =>
      jsonEncode(list, toEncodable: (v) => v);

  static List<double> _decodeList(String? s) {
    if (s == null || s.isEmpty) return [];
    final raw = jsonDecode(s) as List;
    return raw.map((e) => (e as num).toDouble()).toList();
  }

  static String? _encodeAb(double? lat, double? lon) {
    if (lat == null || lon == null) return null;
    return jsonEncode([lat, lon]);
  }

  static (double, double)? _decodeAb(String? s) {
    if (s == null || s.isEmpty) return null;
    final raw = jsonDecode(s) as List;
    if (raw.length < 2) return null;
    return ((raw[0] as num).toDouble(), (raw[1] as num).toDouble());
  }
}
