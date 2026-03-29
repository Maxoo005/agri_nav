import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';

import '../models/machine_model.dart';
import '../services/machine_service.dart';

/// Ekran zarządzania maszynami w gospodarstwie.
class MachineManagerScreen extends StatelessWidget {
  const MachineManagerScreen({super.key});

  static Future<MachineModel?> open(BuildContext context) =>
      Navigator.push<MachineModel>(
        context,
        MaterialPageRoute(builder: (_) => const MachineManagerScreen()),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1E1E),
        foregroundColor: Colors.white,
        title: const Text('Zarządzanie maszynami'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Dodaj maszynę',
            onPressed: () => _addMachine(context),
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: 'Usuń wszystkie maszyny',
            onPressed: () => _confirmDeleteAll(context),
          ),
          Container(
            margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.orangeAccent,
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Text(
              'DEBUG',
              style: TextStyle(
                color: Colors.black,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ValueListenableBuilder<Box>(
              valueListenable: MachineService.instance.listenable,
              builder: (context, box, _) {
                final machines = MachineService.instance.getAll();

                if (machines.isEmpty) {
                  return const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.agriculture_outlined,
                            size: 64, color: Colors.white24),
                        SizedBox(height: 12),
                        Text(
                          'Brak maszyn w bazie.\nDodaj maszynę przyciskiem + powyżej.',
                          style: TextStyle(color: Colors.white38, fontSize: 14),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  );
                }

                return ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: machines.length,
                  separatorBuilder: (_, __) =>
                      const Divider(height: 1, color: Colors.white10),
                  itemBuilder: (context, i) => _MachineTile(
                    machine: machines[i],
                    onTap: () => Navigator.pop(context, machines[i]),
                    onDelete: () => _delete(context, machines[i]),
                    onEdit: () => _editMachine(context, machines[i]),
                  ),
                );
              },
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Text(
              'Baza danych maszyn gospodarstwa',
              style: TextStyle(color: Colors.white24, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _addMachine(BuildContext context) async {
    await _showMachineDialog(context, null);
  }

  Future<void> _editMachine(BuildContext context, MachineModel m) async {
    await _showMachineDialog(context, m);
  }

  Future<void> _showMachineDialog(
      BuildContext context, MachineModel? existing) async {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final widthCtrl = TextEditingController(
        text: existing?.workingWidthM?.toStringAsFixed(1) ?? '');
    MachineType selectedType = existing?.type ?? MachineType.tractor;

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          backgroundColor: const Color(0xFF2A2A2A),
          title: Text(
            existing == null ? 'Dodaj maszynę' : 'Edytuj maszynę',
            style: const TextStyle(color: Colors.white),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Typ maszyny
                const Text('Typ maszyny',
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: MachineType.values.map((t) {
                    final sel = selectedType == t;
                    return ChoiceChip(
                      label: Text(t.label,
                          style: TextStyle(
                            fontSize: 12,
                            color: sel ? Colors.black : Colors.white70,
                          )),
                      selected: sel,
                      selectedColor: Colors.greenAccent,
                      backgroundColor: const Color(0xFF1E1E1E),
                      side: BorderSide(
                          color: sel ? Colors.greenAccent : Colors.white24),
                      onSelected: (_) => setS(() => selectedType = t),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),
                // Nazwa
                TextField(
                  controller: nameCtrl,
                  style: const TextStyle(color: Colors.white),
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Nazwa maszyny',
                    labelStyle: TextStyle(color: Colors.white54),
                    hintText: 'np. John Deere 6155R',
                    hintStyle: TextStyle(color: Colors.white24),
                    enabledBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: Colors.white24)),
                    focusedBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: Colors.greenAccent)),
                  ),
                ),
                const SizedBox(height: 12),
                // Szerokość robocza
                TextField(
                  controller: widthCtrl,
                  style: const TextStyle(color: Colors.white),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Szerokość robocza [m]  — opcjonalnie',
                    labelStyle: TextStyle(color: Colors.white54),
                    hintText: 'np. 24.0',
                    hintStyle: TextStyle(color: Colors.white24),
                    suffixText: 'm',
                    suffixStyle: TextStyle(color: Colors.white38),
                    enabledBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: Colors.white24)),
                    focusedBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: Colors.greenAccent)),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Anuluj')),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Zapisz',
                  style: TextStyle(color: Colors.greenAccent)),
            ),
          ],
        ),
      ),
    );

    if (result != true) return;
    final name = nameCtrl.text.trim();
    if (name.isEmpty) return;

    final width = double.tryParse(widthCtrl.text.trim().replaceAll(',', '.'));

    final machine = MachineModel(
      id: existing?.id ?? const Uuid().v4(),
      name: name,
      type: selectedType,
      workingWidthM: width,
    );
    await MachineService.instance.save(machine);
  }

  Future<void> _delete(BuildContext context, MachineModel m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title:
            const Text('Usuń maszynę', style: TextStyle(color: Colors.white)),
        content: Text('Usunąć "${m.name}"?',
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
    if (ok == true) await MachineService.instance.delete(m.id);
  }

  Future<void> _confirmDeleteAll(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: const Text('Usuń wszystkie maszyny',
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
    if (ok == true) await MachineService.instance.deleteAll();
  }
}

// ── Wiersz maszyny ─────────────────────────────────────────────────────────

class _MachineTile extends StatelessWidget {
  const _MachineTile({
    required this.machine,
    required this.onTap,
    required this.onDelete,
    required this.onEdit,
  });

  final MachineModel machine;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onEdit;

  static IconData _iconFor(MachineType t) {
    switch (t) {
      case MachineType.tractor:
        return Icons.agriculture;
      case MachineType.sprayer:
        return Icons.water_drop_outlined;
      case MachineType.seeder:
        return Icons.grain;
      case MachineType.cultivator:
        return Icons.construction;
      case MachineType.harvester:
        return Icons.content_cut;
      case MachineType.other:
        return Icons.build_outlined;
    }
  }

  static Color _colorFor(MachineType t) {
    switch (t) {
      case MachineType.tractor:
        return Colors.greenAccent;
      case MachineType.sprayer:
        return Colors.lightBlueAccent;
      case MachineType.seeder:
        return Colors.amberAccent;
      case MachineType.cultivator:
        return Colors.orangeAccent;
      case MachineType.harvester:
        return Colors.deepOrangeAccent;
      case MachineType.other:
        return Colors.white54;
    }
  }

  static Color _bgFor(MachineType t) {
    switch (t) {
      case MachineType.tractor:
        return const Color(0xFF0A2A0A);
      case MachineType.sprayer:
        return const Color(0xFF0A1A2A);
      case MachineType.seeder:
        return const Color(0xFF2A1A00);
      case MachineType.cultivator:
        return const Color(0xFF2A1200);
      case MachineType.harvester:
        return const Color(0xFF2A0A00);
      case MachineType.other:
        return const Color(0xFF1E1E1E);
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = machine.workingWidthM;
    final subtitle = w != null
        ? '${machine.type.label}  •  szerokość robocza: ${w.toStringAsFixed(1)} m'
        : '${machine.type.label}  •  szerokość: N/A (napęd)';

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: _bgFor(machine.type),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(_iconFor(machine.type),
            color: _colorFor(machine.type), size: 24),
      ),
      title: Text(machine.name,
          style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.w600)),
      subtitle: Text(
        subtitle,
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
