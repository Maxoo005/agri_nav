import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/history_record.dart';
import 'work_session_service.dart';

/// Buduje raport PDF z wpisów historii — nawigacyjnych i ręcznych razem, w
/// jednej tabeli na pole, z dyskretną kolumną "Źródło" odróżniającą
/// rejestrację GPS od deklaracji rolnika.
///
/// Fonty: pakiet `pdf` ma tylko bazowe Helvetica bez polskich znaków
/// diakrytycznych. Zamiast dogrywać Noto Sans z sieci (Google Fonts —
/// zawodne w polu, gdzie telefon często nie ma zasięgu, a `printing` po
/// nieudanym pobraniu po cichu wraca do Helvetiki bez żadnego błędu), font
/// jest dołączony do apki jako asset i ładowany lokalnie — działa zawsze,
/// offline też.
class HistoryPdfService {
  HistoryPdfService._();

  static Future<Uint8List> build({
    required List<HistoryRecord> records,
    required DateTime from,
    required DateTime to,
    String? farmName,
    Map<String, String?> parcelNumbersByFieldId = const {},
  }) async {
    final regular = pw.Font.ttf(
      await rootBundle.load('assets/fonts/NotoSans-Regular.ttf'),
    );
    final bold = pw.Font.ttf(
      await rootBundle.load('assets/fonts/NotoSans-Bold.ttf'),
    );
    final italic = pw.Font.ttf(
      await rootBundle.load('assets/fonts/NotoSans-Italic.ttf'),
    );
    final doc = pw.Document(
      theme: pw.ThemeData.withFont(base: regular, bold: bold, italic: italic),
    );

    final byField = <String, List<HistoryRecord>>{};
    for (final r in records) {
      byField.putIfAbsent(r.fieldName, () => []).add(r);
    }
    final fieldNames = byField.keys.toList()..sort();
    final generatedAt = DateTime.now();

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(28),
        header: (context) => _buildHeader(farmName, from, to, generatedAt),
        footer: (context) => pw.Container(
          alignment: pw.Alignment.centerRight,
          margin: const pw.EdgeInsets.only(top: 8),
          child: pw.Text(
            'Strona ${context.pageNumber} z ${context.pagesCount}',
            style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
          ),
        ),
        build: (context) => [
          for (final name in fieldNames) ...[
            _buildFieldSection(name, byField[name]!, parcelNumbersByFieldId),
            pw.SizedBox(height: 16),
          ],
          _buildLegend(),
          pw.SizedBox(height: 16),
          _buildSummary(fieldNames, byField),
        ],
      ),
    );

    return doc.save();
  }

  static pw.Widget _buildHeader(
      String? farmName, DateTime from, DateTime to, DateTime generatedAt) {
    final title = (farmName != null && farmName.trim().isNotEmpty)
        ? farmName.trim()
        : 'Raport historii prac';
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(title,
            style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 4),
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text('Zakres: ${_fmtDate(from)} – ${_fmtDate(to)}',
                style:
                    const pw.TextStyle(fontSize: 11, color: PdfColors.grey700)),
            pw.Text('Wygenerowano: ${_fmtDateTime(generatedAt)}',
                style:
                    const pw.TextStyle(fontSize: 11, color: PdfColors.grey700)),
          ],
        ),
        pw.SizedBox(height: 10),
        pw.Divider(color: PdfColors.grey400),
        pw.SizedBox(height: 8),
      ],
    );
  }

  static pw.Widget _buildFieldSection(
      String fieldName,
      List<HistoryRecord> records,
      Map<String, String?> parcelNumbersByFieldId) {
    final totalHa = records.fold<double>(0, (s, r) => s + r.coveredHa);
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(fieldName,
            style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
        pw.Text(
          'Suma: ${totalHa.toStringAsFixed(2)} ha  •  '
          '${records.length} wpis(ów)',
          style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
        ),
        pw.SizedBox(height: 4),
        pw.TableHelper.fromTextArray(
          headers: const [
            'Data',
            'Zabieg',
            'Maszyna',
            'Powierzchnia [ha]',
            'Czas pracy',
            'Dawka/materiał',
            'Źródło',
            'Notatka',
            'Nr działek ewidencyjnych',
          ],
          data: [
            for (final r in records)
              [
                _fmtDate(r.completedAt),
                r.taskType.label,
                (r.machineName != null && r.machineName!.isNotEmpty)
                    ? r.machineName!
                    : '—',
                r.coveredHa.toStringAsFixed(2),
                r.workDuration != null
                    ? formatWorkDuration(r.workDuration!)
                    : '—',
                _materialLabel(r),
                r.entrySource == HistoryEntrySource.manual ? 'Ręczny' : 'GPS',
                _noteLabel(r),
                _parcelNumbersLabel(r, parcelNumbersByFieldId),
              ],
          ],
          headerStyle: pw.TextStyle(
              fontSize: 9, fontWeight: pw.FontWeight.bold, color: PdfColors.white),
          headerDecoration: const pw.BoxDecoration(color: PdfColors.green800),
          cellStyle: const pw.TextStyle(fontSize: 9),
          cellAlignment: pw.Alignment.centerLeft,
          cellAlignments: const {3: pw.Alignment.centerRight},
          columnWidths: const {
            0: pw.FixedColumnWidth(64),
            1: pw.FlexColumnWidth(1.1),
            2: pw.FlexColumnWidth(0.9),
            3: pw.FixedColumnWidth(62),
            4: pw.FixedColumnWidth(54),
            5: pw.FlexColumnWidth(1.1),
            6: pw.FixedColumnWidth(42),
            7: pw.FlexColumnWidth(1.6),
            8: pw.FlexColumnWidth(1.3),
          },
          border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
          cellPadding:
              const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        ),
      ],
    );
  }

  static String _materialLabel(HistoryRecord r) {
    final consumed = r.materialConsumed;
    if (consumed == null) return '—';
    final unit = r.materialUnit ?? '';
    final rate = r.coveredHa > 0 ? consumed / r.coveredHa : null;
    final rateStr = rate != null ? ' (${rate.toStringAsFixed(2)} $unit/ha)' : '';
    return '${consumed.toStringAsFixed(1)} $unit$rateStr';
  }

  static String _noteLabel(HistoryRecord r) {
    final note = r.note?.trim();
    return (note != null && note.isNotEmpty) ? note : '—';
  }

  static String _parcelNumbersLabel(
      HistoryRecord r, Map<String, String?> parcelNumbersByFieldId) {
    final parcels = parcelNumbersByFieldId[r.fieldId]?.trim();
    return (parcels != null && parcels.isNotEmpty) ? parcels : '—';
  }

  static pw.Widget _buildLegend() => pw.Text(
        'GPS — zarejestrowane z nawigacji (Tryb Pracy)  •  '
        'Ręczny — deklaracja rolnika (wpis bez GPS)',
        style: pw.TextStyle(
            fontSize: 8, color: PdfColors.grey600, fontStyle: pw.FontStyle.italic),
      );

  static pw.Widget _buildSummary(
      List<String> fieldNames, Map<String, List<HistoryRecord>> byField) {
    final allRecords = byField.values.expand((l) => l).toList();
    final totalHa = allRecords.fold<double>(0, (s, r) => s + r.coveredHa);
    final totalDuration = allRecords
        .where((r) => r.workDuration != null)
        .fold<Duration>(Duration.zero, (s, r) => s + r.workDuration!);

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Divider(color: PdfColors.grey400),
        pw.SizedBox(height: 8),
        pw.Text('Podsumowanie',
            style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 6),
        pw.TableHelper.fromTextArray(
          headers: const ['Pole', 'Suma powierzchni [ha]'],
          data: [
            for (final name in fieldNames)
              [
                name,
                byField[name]!
                    .fold<double>(0, (s, r) => s + r.coveredHa)
                    .toStringAsFixed(2),
              ],
            ['RAZEM', totalHa.toStringAsFixed(2)],
          ],
          headerStyle: pw.TextStyle(
              fontSize: 9, fontWeight: pw.FontWeight.bold, color: PdfColors.white),
          headerDecoration: const pw.BoxDecoration(color: PdfColors.green800),
          cellStyle: const pw.TextStyle(fontSize: 9),
          border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
          cellAlignments: const {1: pw.Alignment.centerRight},
          cellPadding:
              const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        ),
        pw.SizedBox(height: 8),
        pw.Text(
          'Łączny czas pracy (tylko wpisy zarejestrowane z nawigacji): '
          '${formatWorkDuration(totalDuration)}',
          style: const pw.TextStyle(fontSize: 10),
        ),
      ],
    );
  }

  static String _fmtDate(DateTime d) {
    final dd = d.day.toString().padLeft(2, '0');
    final mm = d.month.toString().padLeft(2, '0');
    return '$dd.$mm.${d.year}';
  }

  static String _fmtDateTime(DateTime d) {
    final hh = d.hour.toString().padLeft(2, '0');
    final mi = d.minute.toString().padLeft(2, '0');
    return '${_fmtDate(d)} $hh:$mi';
  }
}
