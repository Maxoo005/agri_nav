import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../models/field_model.dart';
import '../services/field_service.dart';

/// Ekran listy zapisanych pól.
///
/// Zwraca (przez Navigator.pop) wybrany [FieldModel] lub null jeśli
/// użytkownik wrócił bez wyboru.
class FieldManagerScreen extends StatelessWidget {
  const FieldManagerScreen({super.key});

  static Future<FieldModel?> open(BuildContext context) =>
      Navigator.push<FieldModel>(
        context,
        MaterialPageRoute(builder: (_) => const FieldManagerScreen()),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1E1E),
        foregroundColor: Colors.white,
        title: const Text('Zarządzanie polami'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: 'Usuń wszystkie pola',
            onPressed: () => _confirmDeleteAll(context),
          ),
        ],
      ),
      body: ValueListenableBuilder<Box>(
        valueListenable: FieldService.instance.listenable,
        builder: (context, box, _) {
          final fields = FieldService.instance.getAll();

          if (fields.isEmpty) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.landscape_outlined,
                      size: 64, color: Colors.white24),
                  SizedBox(height: 12),
                  Text(
                    'Brak zapisanych pól.\nNarysuj granicę na mapie i zapisz.',
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
            itemBuilder: (context, i) => _FieldTile(
              field: fields[i],
              onTap: () => Navigator.pop(context, fields[i]),
              onDelete: () => _delete(context, fields[i]),
              onEdit: () => _editName(context, fields[i]),
            ),
          );
        },
      ),
    );
  }

  Future<void> _delete(BuildContext context, FieldModel field) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: const Text('Usuń pole', style: TextStyle(color: Colors.white)),
        content: Text('Usunąć "${field.name}"?',
            style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Anuluj')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Usuń',
                  style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    if (ok == true) await FieldService.instance.delete(field.id);
  }

  Future<void> _editName(BuildContext context, FieldModel field) async {
    final ctrl = TextEditingController(text: field.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: const Text('Zmień nazwę', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: ctrl,
          style: const TextStyle(color: Colors.white),
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Nazwa pola',
            hintStyle: TextStyle(color: Colors.white38),
            enabledBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: Colors.white38)),
            focusedBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: Colors.greenAccent)),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Anuluj')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Zapisz',
                  style: TextStyle(color: Colors.greenAccent))),
        ],
      ),
    );
    if (newName != null && newName.isNotEmpty) {
      field.name = newName;
      await FieldService.instance.save(field);
    }
  }

  Future<void> _confirmDeleteAll(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: const Text('Usuń wszystkie pola',
            style: TextStyle(color: Colors.white)),
        content: const Text('Tej operacji nie można cofnąć.',
            style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Anuluj')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Usuń wszystko',
                  style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    if (ok == true) await FieldService.instance.deleteAll();
  }
}

// ── Wiersz pola ───────────────────────────────────────────────────────────────

class _FieldTile extends StatelessWidget {
  const _FieldTile({
    required this.field,
    required this.onTap,
    required this.onDelete,
    required this.onEdit,
  });

  final FieldModel field;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final pts = field.boundaryLats.length;
    final hasAb = field.lineA != null && field.lineB != null;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
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
        '$pts wierzchołków  •  '
        'szerokość: ${field.workingWidthM.toStringAsFixed(1)} m'
        '${hasAb ? '  •  linia AB ✓' : ''}',
        style: const TextStyle(color: Colors.white54, fontSize: 12),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
              icon: const Icon(Icons.edit_outlined,
                  color: Colors.white38, size: 20),
              onPressed: onEdit),
          IconButton(
              icon: const Icon(Icons.delete_outline,
                  color: Colors.redAccent, size: 20),
              onPressed: onDelete),
        ],
      ),
      onTap: onTap,
    );
  }
}
