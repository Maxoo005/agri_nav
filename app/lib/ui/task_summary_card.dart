import 'package:flutter/material.dart';

import '../models/machine_model.dart';
import '../models/task_plan.dart';
import 'summary_row.dart';

/// Karta-podsumowanie zapisanego zadania (z bazy SQLite).
///
/// Używana w: ekranie "Zadania dla pola", kreatorze nowego zadania oraz
/// w wyborze zadania do trybu pracy. Wspiera opcjonalne akcje:
///  • [onTap]    — cała karta klikalna (wybór zadania),
///  • [onRename] — pozycja "Zmień nazwę" w menu (⋮),
///  • [onEdit]   — pozycja "Edytuj zadanie" w menu (⋮).
class TaskSummaryCard extends StatelessWidget {
  const TaskSummaryCard({
    super.key,
    required this.plan,
    this.onTap,
    this.onRename,
    this.onEdit,
  });

  final TaskPlan plan;
  final VoidCallback? onTap;
  final VoidCallback? onRename;
  final VoidCallback? onEdit;

  bool get _hasMenu => onRename != null || onEdit != null;

  String get _machineLabel {
    final mt = plan.machineType;
    if (mt == null) return '—';
    return MachineType.fromJson(mt).label;
  }

  String get _date {
    final d = plan.createdAt;
    return '${d.day.toString().padLeft(2, '0')}.'
        '${d.month.toString().padLeft(2, '0')}.'
        '${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.assignment_turned_in,
                    color: Colors.greenAccent, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    plan.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(_date,
                    style:
                        const TextStyle(color: Colors.white38, fontSize: 11)),
                const SizedBox(width: 4),
                if (onTap != null)
                  const Icon(Icons.chevron_right,
                      color: Colors.white38, size: 20),
                if (_hasMenu)
                  PopupMenuButton<String>(
                    tooltip: 'Akcje',
                    color: const Color(0xFF2A2A2A),
                    icon: const Icon(Icons.more_vert,
                        color: Colors.white54, size: 20),
                    onSelected: (v) {
                      if (v == 'rename') onRename?.call();
                      if (v == 'edit') onEdit?.call();
                    },
                    itemBuilder: (_) => [
                      if (onEdit != null)
                        const PopupMenuItem(
                          value: 'edit',
                          child: Row(
                            children: [
                              Icon(Icons.edit_outlined,
                                  color: Colors.white70, size: 20),
                              SizedBox(width: 10),
                              Text('Edytuj zadanie',
                                  style: TextStyle(color: Colors.white)),
                            ],
                          ),
                        ),
                      if (onRename != null)
                        const PopupMenuItem(
                          value: 'rename',
                          child: Row(
                            children: [
                              Icon(Icons.drive_file_rename_outline,
                                  color: Colors.white70, size: 20),
                              SizedBox(width: 10),
                              Text('Zmień nazwę',
                                  style: TextStyle(color: Colors.white)),
                            ],
                          ),
                        ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 10),
            const Divider(color: Colors.white10, height: 1),
            const SizedBox(height: 6),
            SummaryRow(
              icon: Icons.agriculture,
              label: 'Maszyna',
              value: plan.machineName != null
                  ? '${plan.machineName}  •  $_machineLabel'
                  : '—',
            ),
            SummaryRow(
              icon: Icons.assignment,
              label: 'Rodzaj zadania',
              value: plan.taskType.label,
            ),
            SummaryRow(
              icon: Icons.straighten,
              label: 'Szerokość robocza',
              value: '${plan.workingWidthM.toStringAsFixed(1)} m',
            ),
            SummaryRow(
              icon: Icons.horizontal_rule,
              label: 'Zakładka',
              value: '${plan.overlapM.toStringAsFixed(2)} m',
            ),
            SummaryRow(
              icon: Icons.route,
              label: 'Uwrocie',
              value: plan.headlandLaps.toString(),
            ),
            SummaryRow(
              icon: Icons.explore,
              label: 'Kierunek ścieżek',
              value: '${plan.swathAngleDeg.toStringAsFixed(2)}°',
            ),
            if (plan.targetRate != null)
              SummaryRow(
                icon: Icons.speed,
                label: 'Dawka',
                value: '${plan.targetRate!.toStringAsFixed(2)} '
                    '${plan.unit ?? ''}',
              ),
            if (plan.tankVolume != null)
              SummaryRow(
                icon: Icons.local_gas_station,
                label: 'Zbiornik',
                value: '${plan.tankVolume!.toStringAsFixed(1)} '
                    '${plan.unit?.split('/').first ?? ''}',
              ),
          ],
        ),
      ),
    );
  }
}
