import 'package:flutter/material.dart';

import '../services/work_session_service.dart';

/// Dane podsumowania pracy do okna "Zakończ pracę".
class FinishWorkInfo {
  final String fieldName;
  final String machineName;
  final String taskTypeLabel;
  final double workingWidthM;
  final double overlapM;
  final double swathAngleDeg;
  final Duration workDuration;
  final double coveredHa;
  final double speedKmh;

  /// Łączne zużycie materiału (l lub kg) — suma z całej pracy, liczona z
  /// bilansu masy w [MaterialMonitorService.totalConsumed] (odporna na
  /// tankowania i zmiany dawki w trakcie). Null = zadanie bez monitorowania
  /// materiału.
  final double? materialConsumed;

  /// Jednostka [materialConsumed], np. "l" lub "kg".
  final String? materialUnit;

  const FinishWorkInfo({
    required this.fieldName,
    required this.machineName,
    required this.taskTypeLabel,
    required this.workingWidthM,
    required this.overlapM,
    required this.swathAngleDeg,
    required this.workDuration,
    required this.coveredHa,
    required this.speedKmh,
    this.materialConsumed,
    this.materialUnit,
  });

  /// Wydajność [ha/h] na podstawie faktycznie zrobionych hektarów i czasu
  /// pracy: `zrobione [ha] / czas pracy [h]`.
  double get hectaresPerHour => hectaresPerHourOf(coveredHa, workDuration);

  /// Rzeczywista dawka [jednostka/ha]: zużyty materiał / zrobione hektary.
  /// To przeliczenie z faktu, nie z ustawionej dawki docelowej — może się od
  /// niej różnić przy zakładkach/uwrociach. Null gdy brak danych.
  double? get effectiveRatePerHa {
    final consumed = materialConsumed;
    if (consumed == null || coveredHa <= 0) return null;
    return consumed / coveredHa;
  }
}

/// Otwiera okno "Zakończ pracę" z podsumowaniem, notatką i przeliczeniem
/// wydajności (ha/h) ze zrobionych hektarów i czasu pracy.
///
/// Zwraca wpisaną notatkę (może być pusta), albo `null` gdy anulowano.
Future<String?> showFinishWorkDialog(
    BuildContext context, FinishWorkInfo info) async {
  final noteCtrl = TextEditingController();
  try {
    return await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: const Row(
          children: [
            Icon(Icons.stop_circle_outlined, color: Colors.redAccent),
            SizedBox(width: 10),
            Text('Zakończyć pracę?', style: TextStyle(color: Colors.white)),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _InfoRow(label: 'Pole', value: info.fieldName),
              _InfoRow(label: 'Maszyna', value: info.machineName),
              _InfoRow(
                  label: 'Rodzaj zadania', value: info.taskTypeLabel),
              _InfoRow(
                label: 'Szerokość robocza',
                value: '${info.workingWidthM.toStringAsFixed(1)} m',
              ),
              _InfoRow(
                label: 'Zakładka',
                value: '${info.overlapM.toStringAsFixed(2)} m',
              ),
              _InfoRow(
                label: 'Kierunek',
                value: '${info.swathAngleDeg.toStringAsFixed(2)}°',
              ),
              _InfoRow(
                label: 'Czas pracy',
                value: formatWorkDuration(info.workDuration),
              ),
              _InfoRow(
                label: 'Zrobione',
                value: '${info.coveredHa.toStringAsFixed(2)} ha',
              ),
              _InfoRow(
                label: 'Prędkość',
                value: '${info.speedKmh.toStringAsFixed(1)} km/h',
              ),
              // Wydajność liczona ze zrobionych ha i czasu pracy.
              _InfoRow(
                label: 'Wydajność',
                value: '${info.hectaresPerHour.toStringAsFixed(2)} ha/h',
                highlight: true,
              ),
              if (info.materialConsumed != null) ...[
                _InfoRow(
                  label: 'Zużyto materiału',
                  value:
                      '${info.materialConsumed!.toStringAsFixed(1)} ${info.materialUnit ?? ''}',
                ),
                if (info.effectiveRatePerHa != null)
                  _InfoRow(
                    label: 'Rzeczywista dawka',
                    value:
                        '${info.effectiveRatePerHa!.toStringAsFixed(2)} ${info.materialUnit ?? ''}/ha',
                  ),
              ],
              const SizedBox(height: 16),
              TextField(
                controller: noteCtrl,
                maxLines: 3,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Notatka',
                  hintText: 'np. oprysk fungicydem, stan zbóż…',
                  hintStyle: TextStyle(color: Colors.white38),
                  labelStyle: TextStyle(color: Colors.white54),
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white24),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.greenAccent),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Anuluj'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red[700]),
            onPressed: () => Navigator.pop(ctx, noteCtrl.text.trim()),
            child: const Text('Zakończ pracę'),
          ),
        ],
      ),
    );
  } finally {
    noteCtrl.dispose();
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    required this.value,
    this.highlight = false,
  });

  final String label;
  final String value;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(color: Colors.white54, fontSize: 13),
          ),
          const SizedBox(width: 16),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: highlight ? Colors.greenAccent : Colors.white,
                fontSize: 13,
                fontWeight: highlight ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
