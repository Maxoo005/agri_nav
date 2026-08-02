import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../models/field_model.dart';
import '../models/machine_model.dart';
import '../services/machine_service.dart';
import 'field_schema_preview.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Wynik wyboru — maszyna + zaktualizowana szerokość robocza dla pola
// ─────────────────────────────────────────────────────────────────────────────

class MachineSelectorResult {
  const MachineSelectorResult({
    required this.machine,
  });
  final MachineModel machine;
}

// ─────────────────────────────────────────────────────────────────────────────
// MachineSelectorScreen
// ─────────────────────────────────────────────────────────────────────────────

class MachineSelectorScreen extends StatefulWidget {
  const MachineSelectorScreen({super.key, required this.field});

  final FieldModel field;

  static Future<MachineSelectorResult?> open(
    BuildContext context, {
    required FieldModel field,
  }) =>
      Navigator.push<MachineSelectorResult>(
        context,
        MaterialPageRoute(
          builder: (_) => MachineSelectorScreen(field: field),
        ),
      );

  @override
  State<MachineSelectorScreen> createState() => _MachineSelectorScreenState();
}

class _MachineSelectorScreenState extends State<MachineSelectorScreen> {
  String? _selectedId;

  void _select(MachineModel m) => setState(() => _selectedId = m.id);

  void _confirm(List<MachineModel> machines) {
    final m = machines.firstWhere((m) => m.id == _selectedId);
    Navigator.pop(context, MachineSelectorResult(machine: m));
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
            const Text('Wybierz maszynę do pracy',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            Text(
              'Wybór maszyny dla pola  "${widget.field.name}"',
              style: const TextStyle(fontSize: 11, color: Colors.white54),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          // ── Podgląd schematu pola ────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: FieldSchemaPreview(
              field: widget.field,
              workingWidthM: _currentWidth(null),
            ),
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 18, bottom: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Schemat pola: ${widget.field.name}'
                '  •  ${widget.field.boundaryLats.length} wierzchołków',
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
            ),
          ),

          // ── Lista maszyn ─────────────────────────────────────────────────
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                Icon(Icons.agriculture_outlined,
                    size: 16, color: Colors.white38),
                SizedBox(width: 6),
                Text('Maszyny w bazie',
                    style: TextStyle(color: Colors.white38, fontSize: 12)),
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.white10),
          Expanded(
            child: ValueListenableBuilder<Box>(
              valueListenable: MachineService.instance.listenable,
              builder: (context, _, __) {
                final machines = MachineService.instance.getAll();

                if (machines.isEmpty) {
                  return const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.agriculture_outlined,
                            size: 48, color: Colors.white24),
                        SizedBox(height: 12),
                        Text(
                          'Brak maszyn w bazie.\nDodaj maszynę w ekranie\n"Zarządzanie maszynami".',
                          style:
                              TextStyle(color: Colors.white38, fontSize: 13),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  );
                }

                return ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  itemCount: machines.length,
                  separatorBuilder: (_, __) =>
                      const Divider(height: 1, color: Colors.white10),
                  itemBuilder: (_, i) => _MachineSelectorTile(
                    machine: machines[i],
                    isSelected: machines[i].id == _selectedId,
                    onSelect: () => _select(machines[i]),
                  ),
                );
              },
            ),
          ),

          // ── Przycisk Rozpocznij pracę ─────────────────────────────────
          ValueListenableBuilder<Box>(
            valueListenable: MachineService.instance.listenable,
            builder: (context, _, __) {
              final machines = MachineService.instance.getAll();
              final canStart = _selectedId != null &&
                  machines.any((m) => m.id == _selectedId);
              final selected = canStart
                  ? machines.firstWhere((m) => m.id == _selectedId)
                  : null;

              return SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (selected != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.check_circle_outline,
                                  color: Colors.greenAccent, size: 16),
                              const SizedBox(width: 6),
                              Text(
                                'Wybrano: ${selected.name}'
                                '${selected.workingWidthM != null ? '  •  ${selected.workingWidthM!.toStringAsFixed(1)} m' : ''}',
                                style: const TextStyle(
                                    color: Colors.greenAccent, fontSize: 13),
                              ),
                            ],
                          ),
                        ),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor:
                                canStart ? Colors.green[700] : Colors.grey[800],
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                          icon: const Icon(Icons.play_arrow_rounded, size: 22),
                          label: const Text(
                            'Rozpocznij pracę z wybraną maszyną',
                            style: TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w600),
                          ),
                          onPressed: canStart ? () => _confirm(machines) : null,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  double _currentWidth(MachineModel? m) =>
      m?.workingWidthM ?? widget.field.workingWidthM;
}

// ─────────────────────────────────────────────────────────────────────────────
// Wiersz maszyny z przyciskiem Wybierz
// ─────────────────────────────────────────────────────────────────────────────

class _MachineSelectorTile extends StatelessWidget {
  const _MachineSelectorTile({
    required this.machine,
    required this.isSelected,
    required this.onSelect,
  });

  final MachineModel machine;
  final bool isSelected;
  final VoidCallback onSelect;

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

  @override
  Widget build(BuildContext context) {
    final w = machine.workingWidthM;
    final subtitle = w != null
        ? '${machine.type.label}  •  ${w.toStringAsFixed(1)} m'
        : '${machine.type.label}  •  N/A (napęd)';

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      color: isSelected
          ? Colors.green.withValues(alpha: 0.12)
          : Colors.transparent,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: isSelected
                ? Colors.green.withValues(alpha: 0.25)
                : const Color(0xFF1E1E1E),
            borderRadius: BorderRadius.circular(8),
            border: isSelected
                ? Border.all(color: Colors.greenAccent, width: 1.5)
                : Border.all(color: Colors.white12),
          ),
          child: Icon(_iconFor(machine.type),
              color: _colorFor(machine.type), size: 24),
        ),
        title: Text(
          machine.name,
          style: TextStyle(
            color: isSelected ? Colors.white : Colors.white70,
            fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
        subtitle: Text(subtitle,
            style: const TextStyle(color: Colors.white54, fontSize: 12)),
        trailing: isSelected
            ? FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.greenAccent,
                  foregroundColor: Colors.black,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  minimumSize: const Size(80, 36),
                ),
                onPressed: onSelect,
                child: const Text('Wybrano',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              )
            : OutlinedButton(
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.white30),
                  foregroundColor: Colors.white70,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  minimumSize: const Size(80, 36),
                ),
                onPressed: onSelect,
                child: const Text('Wybierz'),
              ),
        onTap: onSelect,
      ),
    );
  }
}

