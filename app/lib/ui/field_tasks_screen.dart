import 'package:flutter/material.dart';

import '../models/field_model.dart';
import '../models/task_plan.dart';
import '../services/task_database.dart';
import 'new_task_screen.dart';
import 'task_summary_card.dart';

/// Ekran zadań zapisanych w SQLite dla wybranego pola.
///
/// Każde zadanie wyświetlane jest jako karta-podsumowanie (tak samo jak
/// podsumowanie w kreatorze nowego zadania).
class FieldTasksScreen extends StatefulWidget {
  const FieldTasksScreen({super.key, required this.field});

  final FieldModel field;

  static Future<void> open(BuildContext context, FieldModel field) =>
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => FieldTasksScreen(field: field)),
      );

  @override
  State<FieldTasksScreen> createState() => _FieldTasksScreenState();
}

class _FieldTasksScreenState extends State<FieldTasksScreen> {
  List<TaskPlan>? _tasks;
  bool _loading = true;
  String? _error;

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
      final all = await TaskDatabase.instance.getAll();
      final tasks =
          all.where((t) => t.fieldId == widget.field.id).toList();
      if (!mounted) return;
      setState(() {
        _tasks = tasks;
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1E1E),
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Zadania dla pola',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            Text(widget.field.name,
                style: const TextStyle(fontSize: 11, color: Colors.white54)),
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

    final tasks = _tasks ?? [];
    if (tasks.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.assignment_outlined, color: Colors.white24, size: 56),
              SizedBox(height: 12),
              Text(
                'Brak zadań dla tego pola.\nUtwórz zadanie w "Nowe zadanie".',
                style: TextStyle(color: Colors.white38, fontSize: 14),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: tasks.length,
      itemBuilder: (_, i) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TaskSummaryCard(
          plan: tasks[i],
          onRename: () => _renameTask(tasks[i]),
          onEdit: () => _editTask(tasks[i]),
        ),
      ),
    );
  }

  Future<void> _renameTask(TaskPlan plan) async {
    final controller = TextEditingController(text: plan.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Zmień nazwę zadania',
            style: TextStyle(color: Colors.white, fontSize: 16)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            labelText: 'Nazwa',
            labelStyle: const TextStyle(color: Colors.white54),
            hintText: 'np. Oprysk pszenicy',
            hintStyle: const TextStyle(color: Colors.white24),
            filled: true,
            fillColor: const Color(0xFF2A2A2A),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: Colors.white24),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: Colors.white24),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Anuluj', style: TextStyle(color: Colors.white60)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.green[700]),
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Zapisz'),
          ),
        ],
      ),
    );
    if (newName == null || newName.isEmpty) return;
    try {
      await TaskDatabase.instance.rename(plan.id, newName);
      if (!mounted) return;
      _load();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Nazwa zadania zmieniona'),
        backgroundColor: Colors.green[700],
        duration: const Duration(seconds: 2),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Błąd zmiany nazwy: $e'),
        backgroundColor: Colors.red[800],
      ));
    }
  }

  Future<void> _editTask(TaskPlan plan) async {
    await NewTaskScreen.open(context, plan: plan);
    if (mounted) _load();
  }
}
