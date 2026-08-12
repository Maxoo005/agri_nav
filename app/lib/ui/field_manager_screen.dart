import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../models/field_model.dart';
import '../services/field_service.dart';
import '../utils/geo_utils.dart';
import 'field_tasks_screen.dart';

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
            icon: const Icon(Icons.download_for_offline_outlined),
            tooltip: 'Pobierz powierzchnie',
            onPressed: () => _populateAreas(context),
          ),
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

          return Column(
            children: [
              _buildSummary(fields),
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: fields.length,
                  separatorBuilder: (_, __) =>
                      const Divider(height: 1, color: Colors.white10),
                  itemBuilder: (context, i) => _FieldTile(
                    field: fields[i],
                    onTap: () => Navigator.pop(context, fields[i]),
                    onTasks: () => FieldTasksScreen.open(context, fields[i]),
                    onDelete: () => _delete(context, fields[i]),
                    onEdit: () => _editName(context, fields[i]),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Podsumowanie na górze listy pól — łączna powierzchnia wszystkich pól [ha].
  Widget _buildSummary(List<FieldModel> fields) {
    var totalHa = 0.0;
    for (final f in fields) {
      totalHa += f.areaHa ?? GeoUtils.polygonAreaHa(f.boundary);
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF1A2A1A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.green.shade900),
      ),
      child: Row(
        children: [
          const Icon(Icons.landscape, color: Colors.greenAccent, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'SUMA POWIERZCHNI',
                  style: TextStyle(
                    color: Colors.white38,
                    fontSize: 10,
                    letterSpacing: 0.8,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${totalHa.toStringAsFixed(2)} ha',
                  style: const TextStyle(
                    color: Colors.greenAccent,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          Text(
            '${fields.length} pól',
            style: const TextStyle(color: Colors.white54, fontSize: 13),
          ),
        ],
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

  Future<void> _populateAreas(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final count = await FieldService.instance.populateAreas();
    messenger.showSnackBar(SnackBar(
      content: Text(count > 0
          ? 'Zapisano powierzchnię dla $count pól'
          : 'Powierzchnie pól są już aktualne'),
      backgroundColor: count > 0 ? Colors.green[700] : Colors.blueGrey[800],
      duration: const Duration(seconds: 2),
    ));
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
    required this.onTasks,
    required this.onDelete,
    required this.onEdit,
  });

  final FieldModel field;
  final VoidCallback onTap;
  final VoidCallback onTasks;
  final VoidCallback onDelete;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final pts = field.boundaryLats.length;
    final hasAb = field.lineA != null && field.lineB != null;
    final abLabel = switch (field.abSource) {
      AbSource.manual2Points => '  •  AB: ręcznie',
      AbSource.drivenRecording => '  •  AB: przejazd',
      AbSource.unknown => '  •  AB: nieznana metoda',
      AbSource.none => '',
    };
    final areaHa = field.areaHa ?? GeoUtils.polygonAreaHa(field.boundary);

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: Colors.green[900],
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.landscape,
                color: Colors.greenAccent, size: 24),
          ),
          // Odznaka źródła pochodzenia granicy — widoczna dla każdego pola,
          // niezależnie skąd trafiło do aplikacji (katastr, LPIS, plik,
          // ręcznie narysowane).
          Positioned(
            right: -4,
            bottom: -4,
            child: Tooltip(
              message: _sourceLabel(field.source),
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1E),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white24),
                ),
                child: Icon(_sourceIcon(field.source),
                    size: 12, color: Colors.white70),
              ),
            ),
          ),
        ],
      ),
      title: Text(field.name,
          style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.w600)),
      subtitle: Text(
        '${areaHa > 0 ? '${areaHa.toStringAsFixed(2)} ha  •  ' : ''}'
        '$pts wierzchołków'
        '${hasAb ? abLabel : ''}',
        style: const TextStyle(color: Colors.white54, fontSize: 12),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.assignment_outlined,
                color: Colors.white70, size: 20),
            tooltip: 'Zadania dla pola',
            onPressed: onTasks,
          ),
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

  IconData _sourceIcon(FieldSource s) => switch (s) {
        FieldSource.manual => Icons.edit_outlined,
        FieldSource.uldk => Icons.satellite_alt,
        FieldSource.lpis => Icons.grid_on,
        FieldSource.file => Icons.upload_file,
      };

  String _sourceLabel(FieldSource s) => switch (s) {
        FieldSource.manual => 'Rysowane ręcznie',
        FieldSource.uldk => 'Import ULDK/GUGiK',
        FieldSource.lpis => 'Import LPIS',
        FieldSource.file => 'Import z pliku (KML/GeoJSON)',
      };
}
