import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../models/field_model.dart';
import '../models/task_plan.dart';
import '../services/field_service.dart';
import '../services/task_database.dart';
import 'map_view.dart';
import 'new_task_screen.dart';
import 'task_summary_card.dart';

/// Wybór zadania przed wejściem w Tryb Pracy.
///
/// Pola są wypisane jako rozwijane sekcje — po rozwinięciu widać zapisane
/// zadania (karty-podsumowania, jak w "Zadania dla pola"). Wybór zadania
/// otwiera [MapView] z polem i konfiguracją wczytaną z planu.
class WorkModeTaskPickerScreen extends StatefulWidget {
  const WorkModeTaskPickerScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const WorkModeTaskPickerScreen()),
      );

  @override
  State<WorkModeTaskPickerScreen> createState() =>
      _WorkModeTaskPickerScreenState();
}

class _WorkModeTaskPickerScreenState extends State<WorkModeTaskPickerScreen> {
  bool _loading = true;
  String? _error;
  Map<String, List<TaskPlan>> _tasksByField = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final tasks = await TaskDatabase.instance.getAll();
      final byField = <String, List<TaskPlan>>{};
      for (final t in tasks) {
        byField.putIfAbsent(t.fieldId, () => []).add(t);
      }
      if (!mounted) return;
      setState(() {
        _tasksByField = byField;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  int get _totalTasks =>
      _tasksByField.values.fold(0, (sum, list) => sum + list.length);

  void _openTask(TaskPlan plan) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => MapView(initialTask: plan)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1E1E),
        foregroundColor: Colors.white,
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Wybierz zadanie',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            Text('Tryb pracy',
                style: TextStyle(fontSize: 11, color: Colors.white54)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white70),
            tooltip: 'Odśwież',
            onPressed: _load,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
          child: CircularProgressIndicator(color: Colors.greenAccent));
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline,
                  color: Colors.redAccent, size: 48),
              const SizedBox(height: 12),
              Text(_error!,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                  textAlign: TextAlign.center),
              const SizedBox(height: 16),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white60,
                  side: const BorderSide(color: Colors.white24),
                ),
                onPressed: _load,
                child: const Text('Spróbuj ponownie'),
              ),
            ],
          ),
        ),
      );
    }

    final fields = FieldService.instance.getAll();
    if (fields.isEmpty && _totalTasks == 0) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.map_outlined, color: Colors.white24, size: 56),
              SizedBox(height: 12),
              Text(
                'Brak pól i zadań.\nUtwórz zadanie w "Nowe zadanie".',
                style: TextStyle(color: Colors.white38, fontSize: 14),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    if (_totalTasks == 0) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.assignment_outlined,
                  color: Colors.white24, size: 56),
              const SizedBox(height: 12),
              const Text(
                'Brak zapisanych zadań.\nUtwórz zadanie, aby rozpocząć tryb pracy.',
                style: TextStyle(color: Colors.white38, fontSize: 14),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => NewTaskScreen.open(context),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Nowe zadanie'),
                style: FilledButton.styleFrom(backgroundColor: Colors.green[700]),
              ),
            ],
          ),
        ),
      );
    }

    return ValueListenableBuilder<Box>(
      valueListenable: FieldService.instance.listenable,
      builder: (context, box, _) {
        final fields = FieldService.instance.getAll();
        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: fields.length,
          separatorBuilder: (_, __) =>
              const Divider(height: 1, color: Colors.white10),
          itemBuilder: (context, i) => _buildFieldSection(fields[i]),
        );
      },
    );
  }

  Widget _buildFieldSection(FieldModel field) {
    final tasks = _tasksByField[field.id] ?? [];
    return ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      iconColor: Colors.greenAccent,
      collapsedIconColor: Colors.white38,
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: Colors.green[900],
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(Icons.landscape, color: Colors.greenAccent, size: 24),
      ),
      title: Text(field.name,
          style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.w600)),
      subtitle: Text(
        tasks.isEmpty
            ? 'Brak zadań'
            : '${tasks.length} ${tasks.length == 1 ? 'zadanie' : 'zadań'}',
        style: const TextStyle(color: Colors.white54, fontSize: 12),
      ),
      children: [
        if (tasks.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E1E),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white12),
            ),
            child: const Text(
              'Brak zadań dla tego pola.\nUtwórz zadanie w "Nowe zadanie".',
              style: TextStyle(color: Colors.white38, fontSize: 13),
              textAlign: TextAlign.center,
            ),
          )
        else
          ...tasks.map(
            (plan) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TaskSummaryCard(
                plan: plan,
                onTap: () => _openTask(plan),
              ),
            ),
          ),
      ],
    );
  }
}
