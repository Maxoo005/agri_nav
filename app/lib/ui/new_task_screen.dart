import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';

import '../models/field_model.dart';
import '../models/machine_model.dart';
import '../models/task_plan.dart';
import '../models/work_task.dart';
import '../services/field_service.dart';
import '../services/machine_service.dart';
import '../services/task_database.dart';
import '../utils/geo_utils.dart';
import 'field_schema_preview.dart';
import 'machine_manager_screen.dart';
import 'map_view.dart';
import 'summary_row.dart';
import 'widgets/degree_angle_input.dart';

/// Kreator nowego zadania roboczego.
///
/// Sekwencyjny kreator: Pole → Maszyna → Rodzaj zadania → Ścieżki → Zapisz.
/// Po skonfigurowaniu wszystkiego zadanie trafia do bazy SQLite (`agrinav.db`),
/// skąd można je odtworzyć lub otworzyć na mapie.
class NewTaskScreen extends StatefulWidget {
  const NewTaskScreen({super.key, this.initialPlan});

  /// Istniejący plan do edycji. Gdy podany, kreator startuje z wypełnionymi
  /// krokami, a zapis nadpisuje ten sam wiersz (ten sam `id`).
  final TaskPlan? initialPlan;

  static Future<void> open(BuildContext context, {TaskPlan? plan}) =>
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => NewTaskScreen(initialPlan: plan)),
      );

  @override
  State<NewTaskScreen> createState() => _NewTaskScreenState();
}

class _NewTaskScreenState extends State<NewTaskScreen> {
  static const _totalSteps = 5;

  static const _stepTitles = [
    '1. Wybierz pole',
    '2. Wybierz maszynę',
    '3. Rodzaj zadania',
    '4. Dostosuj ścieżki',
    '5. Zapisz do SQLite',
  ];

  int _step = 0;

  // ── Wybory użytkownika ────────────────────────────────────────────────────
  FieldModel? _field;
  MachineModel? _machine;
  TaskType? _taskType;
  final _nameCtrl = TextEditingController();
  final _rateCtrl = TextEditingController();

  // ── Parametry ścieżek ─────────────────────────────────────────────────────
  double _width = 3.0;
  double _overlap = 0.0;
  int _laps = 0;
  double _angle = 0.0;

  // ── Zapisywanie ───────────────────────────────────────────────────────────
  bool _saving = false;
  TaskPlan? _savedPlan;
  String? _savedPath;

  @override
  void initState() {
    super.initState();
    final plan = widget.initialPlan;
    if (plan == null) return;

    // Wypełnij kreatora wartościami z zapisanego planu (tryb edycji).
    _field = FieldModel(
      id: plan.fieldId,
      name: plan.fieldName,
      boundaryLats: plan.boundaryLats,
      boundaryLons: plan.boundaryLons,
      workingWidthM: plan.workingWidthM,
      lineALat: plan.lineALat,
      lineALon: plan.lineALon,
      lineBLat: plan.lineBLat,
      lineBLon: plan.lineBLon,
    );
    _machine = MachineModel(
      id: plan.machineId ?? '',
      name: plan.machineName ?? '—',
      type: MachineType.fromJson(plan.machineType),
      workingWidthM: plan.workingWidthM,
    );
    _taskType = plan.taskType;
    _width = plan.workingWidthM;
    _overlap = plan.overlapM;
    _laps = plan.headlandLaps;
    _angle = plan.swathAngleDeg;
    if (plan.targetRate != null) {
      _rateCtrl.text = _formatNum(plan.targetRate!);
    }
    if (plan.name.isNotEmpty) {
      _nameCtrl.text = plan.name;
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _rateCtrl.dispose();
    super.dispose();
  }

  // ── Selekcje ──────────────────────────────────────────────────────────────

  void _selectField(FieldModel f) {
    setState(() {
      _field = f;
      _width = _machine?.workingWidthM ?? f.workingWidthM;
      _angle = GeoUtils.minPassesBearing(f.boundary);
    });
  }

  void _selectMachine(MachineModel m) {
    setState(() {
      _machine = m;
      if (m.workingWidthM != null) _width = m.workingWidthM!;
    });
  }

  bool get _canGoNext {
    switch (_step) {
      case 0:
        return _field != null;
      case 1:
        return _machine != null;
      case 2:
        return _taskType != null;
      default:
        return true;
    }
  }

  void _next() {
    if (!_canGoNext) return;
    setState(() => _step++);
  }

  void _back() {
    if (_step == 0) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _step--;
      // Zmiana parametrów po zapisie unieważnia zapisany plan.
      _savedPlan = null;
      _savedPath = null;
    });
  }

  // ── Zapis do SQLite ───────────────────────────────────────────────────────

  Future<void> _save() async {
    final field = _field;
    final machine = _machine;
    final taskType = _taskType;
    if (field == null || machine == null || taskType == null) return;

    setState(() => _saving = true);
    try {
      final existing = await TaskDatabase.instance.getAll();
      final editing = widget.initialPlan;
      final enteredName = _nameCtrl.text.trim();
      final fallbackName = editing?.name;
      final plan = TaskPlan(
        id: editing?.id ?? const Uuid().v4(),
        name: enteredName.isNotEmpty
            ? enteredName
            : (fallbackName != null && fallbackName.isNotEmpty
                ? fallbackName
                : 'Zadanie ${existing.length + 1}'),
        fieldId: field.id,
        fieldName: field.name,
        boundaryLats: field.boundaryLats,
        boundaryLons: field.boundaryLons,
        lineALat: field.lineALat,
        lineALon: field.lineALon,
        lineBLat: field.lineBLat,
        lineBLon: field.lineBLon,
        machineId: machine.id,
        machineName: machine.name,
        machineType: machine.type.jsonKey,
        taskType: taskType,
        workingWidthM: _width,
        overlapM: _overlap,
        headlandLaps: _laps,
        swathAngleDeg: _angle,
        targetRate: _parseDouble(_rateCtrl.text),
        unit: taskType.defaultUnit,
        createdAt: editing?.createdAt ?? DateTime.now(),
      );

      await TaskDatabase.instance.save(plan);
      final dbPath = await TaskDatabase.instance.getDatabasePath();
      if (!mounted) return;
      setState(() {
        _savedPlan = plan;
        _savedPath = dbPath;
        _saving = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(editing != null
            ? 'Zadanie zaktualizowane w bazie SQLite (.db)'
            : 'Zadanie zapisane do bazy SQLite (.db)'),
        backgroundColor: Colors.green[700],
        duration: const Duration(seconds: 3),
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Błąd zapisu do bazy: $e'),
        backgroundColor: Colors.red[800],
        duration: const Duration(seconds: 4),
      ));
    }
  }

  void _openMap() {
    final field = _field;
    final plan = _savedPlan;
    if (field == null || plan == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => MapView(initialField: field, initialTask: plan)),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1E1E),
        foregroundColor: Colors.white,
        title: Text(
            widget.initialPlan != null ? 'Edytuj zadanie' : 'Nowe zadanie',
            style: const TextStyle(fontWeight: FontWeight.w600)),
      ),
      body: Column(
        children: [
          // ── Pasek postępu ────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_stepTitles[_step]}   (krok ${_step + 1}/$_totalSteps)',
                  style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                      fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: (_step + 1) / _totalSteps,
                    minHeight: 6,
                    backgroundColor: Colors.white12,
                    valueColor:
                        const AlwaysStoppedAnimation(Colors.greenAccent),
                  ),
                ),
              ],
            ),
          ),
          const Divider(color: Colors.white10, height: 16),
          // ── Treść kroku ──────────────────────────────────────────────────
          Expanded(child: _buildStep()),
          // ── Dolny pasek nawigacji ────────────────────────────────────────
          _buildBottomBar(),
        ],
      ),
    );
  }

  Widget _buildStep() {
    switch (_step) {
      case 0:
        return _buildFieldStep();
      case 1:
        return _buildMachineStep();
      case 2:
        return _buildTaskTypeStep();
      case 3:
        return _buildSwathStep();
      case 4:
        return _buildSummaryStep();
      default:
        return const SizedBox.shrink();
    }
  }

  // ── Krok 1: Pole ───────────────────────────────────────────────────────────

  Widget _buildFieldStep() {
    return ValueListenableBuilder<Box>(
      valueListenable: FieldService.instance.listenable,
      builder: (context, box, _) {
        final fields = FieldService.instance.getAll();
        if (fields.isEmpty) {
          return const _EmptyState(
            icon: Icons.landscape_outlined,
            message: 'Brak zapisanych pól.\n'
                'Dodaj pole przez Import działek albo rysując granicę na mapie.',
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: fields.length,
          separatorBuilder: (_, __) =>
              const Divider(height: 1, color: Colors.white10),
          itemBuilder: (_, i) {
            final f = fields[i];
            return _SelectTile(
              selected: _field?.id == f.id,
              icon: Icons.landscape,
              iconColor: Colors.greenAccent,
              title: f.name,
              subtitle:
                  '${f.boundaryLats.length} wierzchołków  •  ${_field?.id == f.id ? 'wybrane' : 'dotknij aby wybrać'}',
              onTap: () => _selectField(f),
            );
          },
        );
      },
    );
  }

  // ── Krok 2: Maszyna ────────────────────────────────────────────────────────

  Widget _buildMachineStep() {
    return ValueListenableBuilder<Box>(
      valueListenable: MachineService.instance.listenable,
      builder: (context, box, _) {
        final machines = MachineService.instance.getAll();
        if (machines.isEmpty) {
          return _EmptyState(
            icon: Icons.agriculture_outlined,
            message: 'Brak maszyn w bazie.\n'
                'Dodaj maszynę w "Zarządzanie maszynami".',
            actionLabel: 'Zarządzanie maszynami',
            onAction: () => MachineManagerScreen.open(context),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: machines.length,
          separatorBuilder: (_, __) =>
              const Divider(height: 1, color: Colors.white10),
          itemBuilder: (_, i) {
            final m = machines[i];
            final w = m.workingWidthM;
            return _SelectTile(
              selected: _machine?.id == m.id,
              icon: Icons.agriculture,
              iconColor: Colors.lightBlueAccent,
              title: m.name,
              subtitle: '${m.type.label}  •  '
                  '${w != null ? '${w.toStringAsFixed(1)} m' : 'N/A (napęd)'}',
              onTap: () => _selectMachine(m),
            );
          },
        );
      },
    );
  }

  // ── Krok 3: Rodzaj zadania ─────────────────────────────────────────────────

  Widget _buildTaskTypeStep() {
    final usesMaterial = _taskType?.usesMaterial ?? false;
    final unit = _taskType?.defaultUnit;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Rodzaj zadania',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
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
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
              backgroundColor: const Color(0xFF2A2A2A),
              side: BorderSide(
                  color: selected ? Colors.greenAccent : Colors.white24),
            );
          }).toList(),
        ),
        if (usesMaterial) ...[
          const SizedBox(height: 24),
          const Text(
            'Parametry materiału',
            style: TextStyle(
                color: Colors.white54, fontSize: 12, letterSpacing: 0.5),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _rateCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              labelText: 'Dawka ($unit)',
              labelStyle: const TextStyle(color: Colors.white54),
              prefixIcon: const Icon(Icons.speed, color: Colors.white38),
              enabledBorder: const OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.white24)),
              focusedBorder: const OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.greenAccent)),
            ),
          ),
          const Padding(
            padding: EdgeInsets.only(top: 10),
            child: Text(
              'Ile jest zatankowane, ustawisz na starcie Trybu Pracy.',
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ),
        ] else
          const Padding(
            padding: EdgeInsets.only(top: 16),
            child: Text(
              'Dla tego typu zadania monitorowanie materiału jest niedostępne.',
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ),
      ],
    );
  }

  // ── Krok 4: Ścieżki ────────────────────────────────────────────────────────

  Widget _buildSwathStep() {
    final field = _field;
    if (field == null) {
      return const _EmptyState(
        icon: Icons.error_outline,
        message: 'Najpierw wybierz pole.',
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        FieldSchemaPreview(
          field: field,
          workingWidthM: _width,
          swathAngleDeg: _angle,
          height: 180,
        ),
        const SizedBox(height: 12),
        const Text(
          'Szerokość robocza',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
        _ParamSlider(
          label: '${_width.toStringAsFixed(1)} m',
          min: 1.0,
          max: 36.0,
          divisions: 350,
          value: _width,
          color: Colors.greenAccent,
          onChanged: (v) =>
              setState(() => _width = double.parse(v.toStringAsFixed(1))),
        ),
        const SizedBox(height: 12),
        const Text(
          'Zakładka (overlap)',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
        _ParamSlider(
          label: '${_overlap.toStringAsFixed(2)} m',
          min: 0.0,
          max: 1.0,
          divisions: 20,
          value: _overlap,
          color: Colors.orangeAccent,
          onChanged: (v) => setState(() => _overlap = v),
        ),
        const SizedBox(height: 12),
        const Text(
          'Uwrocie (objazdy)',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
        _ParamSlider(
          label: '$_laps',
          min: 0,
          max: 5,
          divisions: 5,
          value: _laps.toDouble(),
          color: Colors.blueAccent,
          onChanged: (v) => setState(() => _laps = v.round()),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            const Expanded(
              child: Text(
                'Kierunek ścieżek',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ),
            TextButton(
              onPressed: () => setState(
                  () => _angle = GeoUtils.minPassesBearing(field.boundary)),
              child: const Text('Auto',
                  style: TextStyle(
                      color: Colors.greenAccent, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
        DegreeAngleInput(
          value: _angle,
          color: Colors.tealAccent,
          onChanged: (v) => setState(() => _angle = v),
        ),
      ],
    );
  }

  // ── Krok 5: Podsumowanie / zapis ───────────────────────────────────────────

  Widget _buildSummaryStep() {
    final field = _field;
    final machine = _machine;
    final taskType = _taskType;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          controller: _nameCtrl,
          style: const TextStyle(color: Colors.white),
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            labelText: 'Nazwa zadania',
            labelStyle: const TextStyle(color: Colors.white54),
            hintText: 'np. Oprysk pszenicy',
            hintStyle: const TextStyle(color: Colors.white24),
            prefixIcon: const Icon(Icons.edit_note, color: Colors.white38),
            filled: true,
            fillColor: const Color(0xFF1E1E1E),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: Colors.white24),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: Colors.white24),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: Colors.greenAccent),
            ),
          ),
        ),
        const SizedBox(height: 12),
        const Divider(color: Colors.white10, height: 1),
        const SizedBox(height: 8),
        SummaryRow(
            icon: Icons.landscape, label: 'Pole', value: field?.name ?? '—'),
        SummaryRow(
            icon: Icons.agriculture,
            label: 'Maszyna',
            value: machine != null
                ? '${machine.name}  •  ${machine.type.label}'
                : '—'),
        SummaryRow(
            icon: Icons.assignment,
            label: 'Rodzaj zadania',
            value: taskType?.label ?? '—'),
        SummaryRow(
            icon: Icons.straighten,
            label: 'Szerokość robocza',
            value: '${_width.toStringAsFixed(1)} m'),
        SummaryRow(
            icon: Icons.horizontal_rule,
            label: 'Zakładka',
            value: '${_overlap.toStringAsFixed(2)} m'),
        SummaryRow(
            icon: Icons.route, label: 'Uwrocie', value: _laps.toString()),
        SummaryRow(
            icon: Icons.explore,
            label: 'Kierunek ścieżek',
            value: '${_angle.toStringAsFixed(2)}°'),
        if (taskType?.usesMaterial == true) ...[
          SummaryRow(
              icon: Icons.speed,
              label: 'Dawka',
              value: _rateCtrl.text.trim().isEmpty
                  ? '—'
                  : '${_rateCtrl.text.trim()} ${taskType!.defaultUnit}'),
        ],
        const SizedBox(height: 16),
        if (_savedPlan != null && _savedPath != null) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.green.shade900.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.green.shade700),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.check_circle,
                        color: Colors.greenAccent, size: 20),
                    SizedBox(width: 8),
                    Text('Zapisano do SQLite',
                        style: TextStyle(
                            color: Colors.greenAccent,
                            fontWeight: FontWeight.bold)),
                  ],
                ),
                const SizedBox(height: 8),
                Text('Plik bazy: $_savedPath',
                    style:
                        const TextStyle(color: Colors.white70, fontSize: 12)),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
      ],
    );
  }

  // ── Dolny pasek ────────────────────────────────────────────────────────────

  Widget _buildBottomBar() {
    final isLastStep = _step == _totalSteps - 1;

    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        decoration: const BoxDecoration(
          color: Color(0xFF1E1E1E),
          border: Border(top: BorderSide(color: Colors.white10)),
        ),
        child: Row(
          children: [
            TextButton.icon(
              onPressed: _back,
              icon: const Icon(Icons.arrow_back, size: 18),
              label: Text(_step == 0 ? 'Zamknij' : 'Wstecz'),
              style: TextButton.styleFrom(foregroundColor: Colors.white60),
            ),
            const Spacer(),
            if (isLastStep) ...[
              if (_savedPlan != null)
                FilledButton.icon(
                  onPressed: _openMap,
                  icon: const Icon(Icons.map_rounded, size: 18),
                  label: const Text('Otwórz na mapie'),
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.green[700],
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                  ),
                )
              else
                FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.save_alt, size: 18),
                  label: Text(_saving ? 'Zapisywanie…' : 'Zapisz do SQLite'),
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.green[700],
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                  ),
                ),
            ] else
              FilledButton.icon(
                onPressed: _canGoNext ? _next : null,
                icon: const Icon(Icons.arrow_forward, size: 18),
                label: const Text('Dalej'),
                style: FilledButton.styleFrom(
                  backgroundColor:
                      _canGoNext ? Colors.green[700] : Colors.grey[800],
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static double? _parseDouble(String s) {
    final t = s.trim().replaceAll(',', '.');
    return t.isEmpty ? null : double.tryParse(t);
  }

  /// Formatuje liczbę do pola tekstowego bez zbędnych zer, np. 3.0 → "3".
  static String _formatNum(double v) {
    final s = v.toStringAsFixed(2);
    return s.replaceFirst(RegExp(r'\.?0+$'), '');
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Wiersz wyboru (pole / maszyna)
// ─────────────────────────────────────────────────────────────────────────────

class _SelectTile extends StatelessWidget {
  const _SelectTile({
    required this.selected,
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final bool selected;
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      color:
          selected ? Colors.green.withValues(alpha: 0.12) : Colors.transparent,
      child: ListTile(
        onTap: onTap,
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: selected
                ? Colors.green.withValues(alpha: 0.25)
                : const Color(0xFF1E1E1E),
            borderRadius: BorderRadius.circular(8),
            border: selected
                ? Border.all(color: Colors.greenAccent, width: 1.5)
                : Border.all(color: Colors.white12),
          ),
          child: Icon(icon, color: iconColor, size: 24),
        ),
        title: Text(
          title,
          style: TextStyle(
            color: selected ? Colors.white : Colors.white70,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
        subtitle: Text(subtitle,
            style: const TextStyle(color: Colors.white54, fontSize: 12)),
        trailing: selected
            ? const Icon(Icons.check_circle,
                color: Colors.greenAccent, size: 20)
            : null,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Suwak parametru ścieżek
// ─────────────────────────────────────────────────────────────────────────────

class _ParamSlider extends StatelessWidget {
  const _ParamSlider({
    required this.label,
    required this.min,
    required this.max,
    required this.divisions,
    required this.value,
    required this.color,
    required this.onChanged,
  });

  final String label;
  final double min;
  final double max;
  final int divisions;
  final double value;
  final Color color;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 74,
          child: Text(
            label,
            style: TextStyle(
                color: color, fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
        Expanded(
          child: Slider(
            min: min,
            max: max,
            divisions: divisions,
            value: value,
            activeColor: color,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Stan pusty
// ─────────────────────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: Colors.white24),
            const SizedBox(height: 12),
            Text(
              message,
              style: const TextStyle(color: Colors.white38, fontSize: 14),
              textAlign: TextAlign.center,
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 16),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white60,
                  side: const BorderSide(color: Colors.white24),
                ),
                onPressed: onAction,
                child: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
