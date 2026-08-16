import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';

import '../models/history_record.dart';
import '../services/field_service.dart';
import '../services/history_database.dart';
import '../services/history_pdf_service.dart';

/// Ekran wyboru zakresu (pola + daty) i generowania raportu PDF z historii —
/// obejmuje zarówno wpisy zarejestrowane z nawigacji, jak i dopisane ręcznie
/// (patrz `ManualHistoryEntrySheet`), bo oba trafiają do tej samej bazy.
class HistoryExportScreen extends StatefulWidget {
  const HistoryExportScreen({super.key});

  @override
  State<HistoryExportScreen> createState() => _HistoryExportScreenState();
}

class _HistoryExportScreenState extends State<HistoryExportScreen> {
  List<HistoryFieldSummary> _fields = [];
  final Set<String> _selectedFieldIds = {};
  late DateTime _from;
  late DateTime _to;
  final _farmNameCtrl = TextEditingController();

  int _previewCount = 0;
  bool _loadingFields = true;
  bool _loadingPreview = false;
  bool _generating = false;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _from = DateTime(now.year, 1, 1);
    _to = now;
    _loadFields();
  }

  @override
  void dispose() {
    _farmNameCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadFields() async {
    final fields = await HistoryDatabase.instance.getFields();
    if (!mounted) return;
    setState(() {
      _fields = fields;
      _selectedFieldIds
        ..clear()
        ..addAll(fields.map((f) => f.fieldId));
      _loadingFields = false;
    });
    _refreshPreview();
  }

  Future<void> _refreshPreview() async {
    setState(() => _loadingPreview = true);
    final records = await HistoryDatabase.instance.getRecords(
      from: _from,
      to: _to,
      fieldIds: _selectedFieldIds.toList(),
    );
    if (!mounted) return;
    setState(() {
      _previewCount = records.length;
      _loadingPreview = false;
    });
  }

  bool get _allSelected =>
      _fields.isNotEmpty && _selectedFieldIds.length == _fields.length;

  void _toggleAll(bool value) {
    setState(() {
      if (value) {
        _selectedFieldIds
          ..clear()
          ..addAll(_fields.map((f) => f.fieldId));
      } else {
        _selectedFieldIds.clear();
      }
    });
    _refreshPreview();
  }

  void _toggleField(String fieldId, bool value) {
    setState(() {
      if (value) {
        _selectedFieldIds.add(fieldId);
      } else {
        _selectedFieldIds.remove(fieldId);
      }
    });
    _refreshPreview();
  }

  Future<void> _pickFrom() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _from,
      firstDate: DateTime(2000),
      lastDate: _to,
      helpText: 'Data początkowa',
    );
    if (picked != null) {
      setState(() => _from = picked);
      _refreshPreview();
    }
  }

  Future<void> _pickTo() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _to,
      firstDate: _from,
      lastDate: DateTime.now(),
      helpText: 'Data końcowa',
    );
    if (picked != null) {
      setState(() => _to = picked);
      _refreshPreview();
    }
  }

  Future<Uint8List> _buildPdfBytes() async {
    final records = await HistoryDatabase.instance.getRecords(
      from: _from,
      to: _to,
      fieldIds: _selectedFieldIds.toList(),
    );
    final parcelNumbersByFieldId = {
      for (final f in FieldService.instance.getAll()) f.id: f.parcelNumbersNote,
    };
    return HistoryPdfService.build(
      records: records,
      from: _from,
      to: _to,
      farmName: _farmNameCtrl.text,
      parcelNumbersByFieldId: parcelNumbersByFieldId,
    );
  }

  Future<void> _generate() async {
    setState(() => _generating = true);
    try {
      final bytes = await _buildPdfBytes();
      final fileName =
          'historia_${_fmtFileDate(_from)}_${_fmtFileDate(_to)}.pdf';

      final dir = await getApplicationDocumentsDirectory();
      final reportsDir = Directory('${dir.path}/raporty');
      if (!await reportsDir.exists()) {
        await reportsDir.create(recursive: true);
      }
      final file = File('${reportsDir.path}/$fileName');
      await file.writeAsBytes(bytes);

      if (!mounted) return;
      setState(() => _generating = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Zapisano: ${file.path}'),
        backgroundColor: Colors.green[700],
        duration: const Duration(seconds: 4),
      ));

      await Printing.layoutPdf(onLayout: (_) async => bytes, name: fileName);
    } catch (e) {
      if (!mounted) return;
      setState(() => _generating = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Błąd generowania PDF: $e'),
        backgroundColor: Colors.red[800],
        duration: const Duration(seconds: 4),
      ));
    }
  }

  Future<void> _share() async {
    setState(() => _generating = true);
    try {
      final bytes = await _buildPdfBytes();
      final fileName =
          'historia_${_fmtFileDate(_from)}_${_fmtFileDate(_to)}.pdf';
      if (!mounted) return;
      setState(() => _generating = false);
      await Printing.sharePdf(bytes: bytes, filename: fileName);
    } catch (e) {
      if (!mounted) return;
      setState(() => _generating = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Błąd udostępniania PDF: $e'),
        backgroundColor: Colors.red[800],
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1E1E),
        foregroundColor: Colors.white,
        title: const Text('Eksportuj do PDF'),
      ),
      body: _loadingFields
          ? const Center(
              child: CircularProgressIndicator(color: Colors.greenAccent))
          : _fields.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Brak wpisów w historii do wyeksportowania.',
                      style: TextStyle(color: Colors.white38, fontSize: 14),
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : Column(
                  children: [
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.all(16),
                        children: [
                          TextField(
                            controller: _farmNameCtrl,
                            style: const TextStyle(color: Colors.white),
                            decoration: const InputDecoration(
                              labelText: 'Nazwa gospodarstwa / właściciela '
                                  '(opcjonalnie)',
                              labelStyle: TextStyle(color: Colors.white54),
                              prefixIcon: Icon(Icons.badge_outlined,
                                  color: Colors.white38),
                              enabledBorder: OutlineInputBorder(
                                  borderSide:
                                      BorderSide(color: Colors.white24)),
                              focusedBorder: OutlineInputBorder(
                                  borderSide:
                                      BorderSide(color: Colors.greenAccent)),
                            ),
                          ),
                          const SizedBox(height: 20),
                          const Text('Zakres dat',
                              style: TextStyle(
                                  color: Colors.white54, fontSize: 12)),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: _DateButton(
                                  label: 'Od',
                                  date: _from,
                                  onTap: _pickFrom,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: _DateButton(
                                  label: 'Do',
                                  date: _to,
                                  onTap: _pickTo,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),
                          Row(
                            children: [
                              const Expanded(
                                child: Text('Pola',
                                    style: TextStyle(
                                        color: Colors.white54, fontSize: 12)),
                              ),
                              Text(
                                '${_selectedFieldIds.length}/${_fields.length}',
                                style: const TextStyle(
                                    color: Colors.white38, fontSize: 12),
                              ),
                            ],
                          ),
                          CheckboxListTile(
                            value: _allSelected,
                            onChanged: (v) => _toggleAll(v ?? false),
                            title: const Text(
                              'Wszystkie pola',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600),
                            ),
                            activeColor: Colors.greenAccent,
                            checkColor: Colors.black,
                            controlAffinity: ListTileControlAffinity.leading,
                            contentPadding: EdgeInsets.zero,
                          ),
                          const Divider(color: Colors.white10, height: 1),
                          for (final f in _fields)
                            CheckboxListTile(
                              value: _selectedFieldIds.contains(f.fieldId),
                              onChanged: (v) =>
                                  _toggleField(f.fieldId, v ?? false),
                              title: Text(f.fieldName,
                                  style: const TextStyle(color: Colors.white)),
                              subtitle: Text('${f.recordCount} wpis(ów)',
                                  style: const TextStyle(
                                      color: Colors.white54, fontSize: 12)),
                              activeColor: Colors.greenAccent,
                              checkColor: Colors.black,
                              controlAffinity:
                                  ListTileControlAffinity.leading,
                              contentPadding: EdgeInsets.zero,
                            ),
                        ],
                      ),
                    ),
                    _buildBottomBar(),
                  ],
                ),
    );
  }

  Widget _buildBottomBar() {
    final canGenerate =
        !_generating && _selectedFieldIds.isNotEmpty && _previewCount > 0;
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        decoration: const BoxDecoration(
          color: Color(0xFF1E1E1E),
          border: Border(top: BorderSide(color: Colors.white10)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _loadingPreview
                  ? 'Liczenie…'
                  : '$_previewCount wpis(ów) trafi do raportu',
              style: const TextStyle(
                  color: Colors.greenAccent,
                  fontWeight: FontWeight.w600,
                  fontSize: 13),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: canGenerate ? _share : null,
                    icon: const Icon(Icons.share, size: 18),
                    label: const Text('Udostępnij'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white70,
                      side: const BorderSide(color: Colors.white24),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    onPressed: canGenerate ? _generate : null,
                    icon: _generating
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.picture_as_pdf, size: 18),
                    label: Text(_generating ? 'Generowanie…' : 'Generuj PDF'),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.green[700],
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _fmtFileDate(DateTime d) =>
      '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';
}

class _DateButton extends StatelessWidget {
  const _DateButton({
    required this.label,
    required this.date,
    required this.onTap,
  });

  final String label;
  final DateTime date;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF2A2A2A),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white12),
        ),
        child: Row(
          children: [
            const Icon(Icons.event, color: Colors.white54, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 11)),
                  Text(
                    _fmt(date),
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _fmt(DateTime d) {
    final dd = d.day.toString().padLeft(2, '0');
    final mm = d.month.toString().padLeft(2, '0');
    return '$dd.$mm.${d.year}';
  }
}
