import 'package:flutter/material.dart';

import '../models/history_record.dart';
import '../services/history_database.dart';
import '../services/work_session_service.dart';

/// Ekran Historii: pola → wszystkie zakończone zadania danego pola w jednym
/// miejscu (bez podziału na lata czy typ zadania).
class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const HistoryScreen()),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1E1E),
        foregroundColor: Colors.white,
        title: const Text('Historia'),
      ),
      body: FutureBuilder<List<HistoryFieldSummary>>(
        future: HistoryDatabase.instance.getFields(),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(
                child: CircularProgressIndicator(color: Colors.greenAccent));
          }
          final fields = snap.data ?? const <HistoryFieldSummary>[];
          if (fields.isEmpty) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.history_rounded, size: 64, color: Colors.white24),
                  SizedBox(height: 12),
                  Text(
                    'Brak zakończonych prac.\nKażde "Zakończ pracę" zapisze zadanie w historii.',
                    style: TextStyle(color: Colors.white38, fontSize: 14),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: fields.length,
            separatorBuilder: (_, __) =>
                const Divider(height: 1, color: Colors.white10),
            itemBuilder: (context, i) {
              final f = fields[i];
              return ListTile(
                leading: const Icon(Icons.agriculture, color: Colors.greenAccent),
                title: Text(f.fieldName, style: const TextStyle(color: Colors.white)),
                subtitle: Text(
                  f.lastCompleted != null
                      ? '${f.recordCount} prac • ostatnia ${_formatDate(f.lastCompleted!)}'
                      : '${f.recordCount} prac',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                trailing: const Icon(Icons.chevron_right_rounded,
                    color: Colors.white38),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => _HistoryFieldScreen(
                      fieldId: f.fieldId,
                      fieldName: f.fieldName,
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Zadania — wszystkie zakończone prace danego pola w jednym miejscu,
// niezależnie od roku i typu zadania.
// ─────────────────────────────────────────────────────────────────────────────

class _HistoryFieldScreen extends StatelessWidget {
  const _HistoryFieldScreen({required this.fieldId, required this.fieldName});

  final String fieldId;
  final String fieldName;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1E1E),
        foregroundColor: Colors.white,
        title: Text(fieldName),
      ),
      body: FutureBuilder<List<HistoryRecord>>(
        future: HistoryDatabase.instance.getFieldRecords(fieldId),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(
                child: CircularProgressIndicator(color: Colors.greenAccent));
          }
          final records = snap.data ?? const <HistoryRecord>[];
          if (records.isEmpty) {
            return const Center(
              child: Text(
                'Brak prac w historii.',
                style: TextStyle(color: Colors.white38, fontSize: 14),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: records.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, i) => _HistoryCard(record: records[i]),
          );
        },
      ),
    );
  }
}

class _HistoryCard extends StatelessWidget {
  const _HistoryCard({required this.record});

  final HistoryRecord record;

  @override
  Widget build(BuildContext context) {
    final note = record.note?.trim() ?? '';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.assignment_turned_in_outlined,
                  color: Colors.greenAccent, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${record.taskType.label}${record.machineName != null && record.machineName!.isNotEmpty ? ' • ${record.machineName}' : ''}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            _formatDate(record.completedAt),
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              _chip('Szerokość', '${record.workingWidthM.toStringAsFixed(1)} m'),
              _chip('Zakładka', '${record.overlapM.toStringAsFixed(2)} m'),
              _chip('Kierunek', '${record.swathAngleDeg.toStringAsFixed(2)}°'),
              _chip('Czas pracy', formatWorkDuration(record.workDuration)),
              _chip('Zrobione', '${record.coveredHa.toStringAsFixed(2)} ha'),
              _chip(
                'Wydajność',
                '${_productivityOf(record).toStringAsFixed(2)} ha/h',
              ),
              if (record.materialConsumed != null)
                _chip(
                  'Zużyto',
                  '${record.materialConsumed!.toStringAsFixed(1)} '
                      '${record.materialUnit ?? ''}',
                ),
              if (_materialRateOf(record) != null)
                _chip(
                  'Dawka rzeczywista',
                  '${_materialRateOf(record)!.toStringAsFixed(2)} '
                      '${record.materialUnit ?? ''}/ha',
                ),
            ],
          ),
          if (note.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF121212),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                note,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _chip(String label, String value) => Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$label: ',
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
            TextSpan(
              text: value,
              style: const TextStyle(
                  color: Colors.white, fontSize: 12,
                  fontWeight: FontWeight.w600),
            ),
          ],
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────────

/// Wydajność rekordu — zapisana w momencie zakończenia pracy, a dla starszych
/// rekordów (bez tej wartości) przeliczona ze zrobionych ha i czasu pracy.
double _productivityOf(HistoryRecord r) =>
    r.productivityHaPerHour ?? hectaresPerHourOf(r.coveredHa, r.workDuration);

/// Rzeczywista dawka [jednostka/ha]: zużyty materiał / zrobione hektary.
/// Null gdy zadanie nie miało monitorowania materiału albo nic nie zrobiono
/// (coveredHa == 0 — np. testowe przeklikanie bez realnego przejazdu).
double? _materialRateOf(HistoryRecord r) {
  final consumed = r.materialConsumed;
  if (consumed == null || r.coveredHa <= 0) return null;
  return consumed / r.coveredHa;
}

String _formatDate(DateTime d) {
  final dd = d.day.toString().padLeft(2, '0');
  final mm = d.month.toString().padLeft(2, '0');
  final hh = d.hour.toString().padLeft(2, '0');
  final mi = d.minute.toString().padLeft(2, '0');
  return '$dd.$mm.${d.year}  $hh:$mi';
}
