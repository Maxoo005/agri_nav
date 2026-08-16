import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../models/field_model.dart';
import '../models/history_record.dart';
import '../models/machine_model.dart';
import '../models/work_task.dart';
import '../services/field_service.dart';
import '../services/history_database.dart';
import '../services/machine_service.dart';
import '../utils/geo_utils.dart';
import 'app_theme.dart';

/// Bottom sheet do ręcznego dopisania wpisu do historii — dla pracy
/// wykonanej bez nawigacji/Trybu Pracy (np. zabieg zrobiony bez telefonu w
/// kabinie albo inną maszyną bez GPS).
///
/// Zapisuje przez [HistoryDatabase.save] — dokładnie tę samą metodę, którą
/// woła automatyczny zapis z "Zakończ pracę" (patrz `map_view.dart` i
/// `work_mode_view.dart`) — więc wpis trafia do tej samej listy i tego
/// samego eksportu PDF bez żadnej dodatkowej pracy. Jedyna różnica to
/// [HistoryRecord.entrySource] = [HistoryEntrySource.manual].
class ManualHistoryEntrySheet {
  ManualHistoryEntrySheet._();

  /// Zwraca `true` gdy zapisano nowy wpis, `null` gdy anulowano.
  static Future<bool?> show(BuildContext context) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _ManualHistoryEntrySheetBody(),
    );
  }
}

class _ManualHistoryEntrySheetBody extends StatefulWidget {
  const _ManualHistoryEntrySheetBody();

  @override
  State<_ManualHistoryEntrySheetBody> createState() =>
      _ManualHistoryEntrySheetBodyState();
}

class _ManualHistoryEntrySheetBodyState
    extends State<_ManualHistoryEntrySheetBody> {
  FieldModel? _field;
  MachineModel? _machine;
  TaskType? _taskType;
  DateTime _date = DateTime.now();
  bool _saving = false;

  final _doseCtrl = TextEditingController();
  final _areaCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();

  @override
  void dispose() {
    _doseCtrl.dispose();
    _areaCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  bool get _canSave =>
      !_saving && _field != null && _taskType != null && _parseArea() != null;

  double? _parseArea() {
    final t = _areaCtrl.text.trim().replaceAll(',', '.');
    if (t.isEmpty) return null;
    final v = double.tryParse(t);
    return (v != null && v > 0) ? v : null;
  }

  double? _parseDose() {
    final t = _doseCtrl.text.trim().replaceAll(',', '.');
    if (t.isEmpty) return null;
    return double.tryParse(t);
  }

  Future<void> _selectField() async {
    final picked = await _pickFromList<FieldModel>(
      context: context,
      items: FieldService.instance.getAll(),
      icon: Icons.landscape,
      iconColor: Colors.greenAccent,
      labelOf: (f) => f.name,
      subtitleOf: (f) => '${f.boundaryLats.length} wierzchołków',
      emptyMessage: 'Brak zapisanych pól.',
    );
    if (picked == null) return;
    setState(() {
      _field = picked;
      final area = GeoUtils.polygonAreaHa(picked.boundary);
      _areaCtrl.text = area > 0 ? area.toStringAsFixed(2) : '';
    });
  }

  Future<void> _selectMachine() async {
    final picked = await _pickFromList<MachineModel>(
      context: context,
      items: MachineService.instance.getAll(),
      icon: Icons.agriculture,
      iconColor: Colors.lightBlueAccent,
      labelOf: (m) => m.name,
      subtitleOf: (m) => m.type.label,
      emptyMessage: 'Brak maszyn w bazie.',
    );
    if (picked == null) return;
    setState(() => _machine = picked);
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: now.subtract(const Duration(days: 3650)),
      lastDate: now,
      helpText: 'Data wykonania pracy',
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _save() async {
    final field = _field;
    final taskType = _taskType;
    final area = _parseArea();
    if (field == null || taskType == null || area == null) return;

    setState(() => _saving = true);
    final dose = taskType.usesMaterial ? _parseDose() : null;
    final baseUnit = taskType.defaultUnit?.split('/').first;
    final note = _noteCtrl.text.trim();

    try {
      await HistoryDatabase.instance.save(HistoryRecord(
        id: const Uuid().v4(),
        fieldId: field.id,
        fieldName: field.name,
        machineName: _machine?.name,
        taskType: taskType,
        workingWidthM: 0.0,
        overlapM: 0.0,
        swathAngleDeg: 0.0,
        workDuration: null,
        coveredHa: area,
        productivityHaPerHour: null,
        materialConsumed: dose != null ? dose * area : null,
        materialUnit: dose != null ? baseUnit : null,
        note: note.isEmpty ? null : note,
        completedAt: DateTime(_date.year, _date.month, _date.day, 12),
        entrySource: HistoryEntrySource.manual,
      ));
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Błąd zapisu: $e'),
        backgroundColor: Colors.red[800],
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final usesMaterial = _taskType?.usesMaterial ?? false;
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: Container(
          margin: const EdgeInsets.all(12),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.88,
          ),
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E1E),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Dodaj wpis ręczny',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Praca wykonana bez nawigacji — np. zabieg zrobiony bez '
                'telefonu w kabinie albo inną maszyną bez GPS.',
                style: TextStyle(color: AppColors.textMuted, fontSize: 13),
              ),
              const SizedBox(height: 16),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _PickRow(
                        label: 'Pole',
                        value: _field?.name,
                        icon: Icons.landscape,
                        onTap: _selectField,
                      ),
                      const SizedBox(height: 10),
                      _PickRow(
                        label: 'Maszyna (opcjonalnie)',
                        value: _machine?.name,
                        icon: Icons.agriculture,
                        onTap: _selectMachine,
                      ),
                      const SizedBox(height: 16),
                      const Text('Działanie',
                          style:
                              TextStyle(color: Colors.white54, fontSize: 12)),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: TaskType.values.map((tt) {
                          final selected = _taskType == tt;
                          return ChoiceChip(
                            label: Text(tt.label),
                            selected: selected,
                            onSelected: (_) => setState(() => _taskType = tt),
                            selectedColor: Colors.green[700],
                            labelStyle: TextStyle(
                              color: selected ? Colors.white : Colors.white70,
                              fontWeight: selected
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                            backgroundColor: const Color(0xFF2A2A2A),
                            side: BorderSide(
                                color: selected
                                    ? Colors.greenAccent
                                    : Colors.white24),
                          );
                        }).toList(),
                      ),
                      if (usesMaterial) ...[
                        const SizedBox(height: 16),
                        TextField(
                          controller: _doseCtrl,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          style: const TextStyle(color: Colors.white),
                          decoration: InputDecoration(
                            labelText:
                                'Dawka (${_taskType!.defaultUnit}) — opcjonalnie',
                            labelStyle: const TextStyle(color: Colors.white54),
                            prefixIcon: const Icon(Icons.speed,
                                color: Colors.white38),
                            enabledBorder: const OutlineInputBorder(
                                borderSide: BorderSide(color: Colors.white24)),
                            focusedBorder: const OutlineInputBorder(
                                borderSide:
                                    BorderSide(color: Colors.greenAccent)),
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      _PickRow(
                        label: 'Data wykonania',
                        value: _formatPickedDate(_date),
                        icon: Icons.event,
                        onTap: _pickDate,
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _areaCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        style: const TextStyle(color: Colors.white),
                        decoration: const InputDecoration(
                          labelText: 'Powierzchnia (ha)',
                          labelStyle: TextStyle(color: Colors.white54),
                          helperText: 'Domyślnie cała powierzchnia pola — '
                              'popraw, jeśli zabieg objął tylko część.',
                          helperStyle:
                              TextStyle(color: Colors.white38, fontSize: 11),
                          helperMaxLines: 2,
                          prefixIcon:
                              Icon(Icons.square_foot, color: Colors.white38),
                          enabledBorder: OutlineInputBorder(
                              borderSide: BorderSide(color: Colors.white24)),
                          focusedBorder: OutlineInputBorder(
                              borderSide:
                                  BorderSide(color: Colors.greenAccent)),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _noteCtrl,
                        maxLines: 2,
                        style: const TextStyle(color: Colors.white),
                        decoration: const InputDecoration(
                          labelText: 'Notatka (opcjonalnie)',
                          labelStyle: TextStyle(color: Colors.white54),
                          enabledBorder: OutlineInputBorder(
                              borderSide: BorderSide(color: Colors.white24)),
                          focusedBorder: OutlineInputBorder(
                              borderSide:
                                  BorderSide(color: Colors.greenAccent)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Anuluj'),
                  ),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: _canSave ? _save : null,
                    icon: _saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.save_alt, size: 18),
                    label: Text(_saving ? 'Zapisywanie…' : 'Zapisz'),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.green[700],
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _formatPickedDate(DateTime d) {
  final dd = d.day.toString().padLeft(2, '0');
  final mm = d.month.toString().padLeft(2, '0');
  return '$dd.$mm.${d.year}';
}

// ─────────────────────────────────────────────────────────────────────────────
// Wiersz wyboru (pole / maszyna / data) — tap otwiera picker.
// ─────────────────────────────────────────────────────────────────────────────

class _PickRow extends StatelessWidget {
  const _PickRow({
    required this.label,
    required this.value,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final String? value;
  final IconData icon;
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
            Icon(icon, color: Colors.white54, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 11)),
                  Text(
                    value ?? 'Dotknij aby wybrać',
                    style: TextStyle(
                      color: value != null ? Colors.white : Colors.white38,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: Colors.white38),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Picker generyczny — lista wyboru w zagnieżdżonym bottom sheet.
// ─────────────────────────────────────────────────────────────────────────────

Future<T?> _pickFromList<T>({
  required BuildContext context,
  required List<T> items,
  required IconData icon,
  required Color iconColor,
  required String Function(T) labelOf,
  required String Function(T) subtitleOf,
  required String emptyMessage,
}) {
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: const Color(0xFF1E1E1E),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      return SafeArea(
        child: items.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Text(emptyMessage,
                    style: const TextStyle(color: Colors.white38)),
              )
            : ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: items.length,
                separatorBuilder: (_, __) =>
                    const Divider(height: 1, color: Colors.white10),
                itemBuilder: (_, i) {
                  final item = items[i];
                  return ListTile(
                    leading: Icon(icon, color: iconColor),
                    title: Text(labelOf(item),
                        style: const TextStyle(color: Colors.white)),
                    subtitle: Text(subtitleOf(item),
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 12)),
                    onTap: () => Navigator.pop(ctx, item),
                  );
                },
              ),
      );
    },
  );
}
