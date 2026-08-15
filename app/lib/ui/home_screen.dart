import 'package:flutter/material.dart';

import '../services/field_service.dart';
import '../services/task_database.dart';
import '../services/work_session_service.dart';
import 'app_theme.dart';
import 'create_field_sheet.dart';
import 'field_manager_screen.dart';
import 'gps_settings_screen.dart';
import 'history_screen.dart';
import 'machine_manager_screen.dart';
import 'map_view.dart';
import 'work_mode_task_picker.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 32),
              const Text(
                'AgriNav',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 34,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Nawigacja rolnicza',
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 32),
              Expanded(
                child: GridView.count(
                  crossAxisCount: 2,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 1.2,
                  children: [
                    _MenuTile(
                      icon: Icons.map_rounded,
                      label: 'Tryb pracy',
                      onTap: () => _openWorkMode(context),
                    ),
                    _MenuTile(
                      icon: Icons.agriculture,
                      label: 'Pola',
                      onTap: () async {
                        final selected = await FieldManagerScreen.open(context);
                        if (selected != null && context.mounted) {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => MapView(initialField: selected),
                            ),
                          );
                        }
                      },
                    ),
                    _MenuTile(
                      icon: Icons.agriculture_outlined,
                      label: 'Maszyny',
                      onTap: () => MachineManagerScreen.open(context),
                    ),
                    _MenuTile(
                      icon: Icons.assignment,
                      label: 'Zadania',
                      onTap: () => WorkModeTaskPickerScreen.openManage(context),
                    ),
                    _MenuTile(
                      icon: Icons.add_location_alt,
                      label: 'Utwórz pole',
                      tooltip: 'Import działek (ULDK), import z pliku '
                          'KML/GeoJSON albo obejście granicy z RTK.',
                      onTap: () => CreateFieldSheet.show(context),
                    ),
                    _MenuTile(
                      icon: Icons.history_rounded,
                      label: 'Historia',
                      onTap: () => HistoryScreen.open(context),
                    ),
                    _MenuTile(
                      icon: Icons.settings,
                      label: 'Ustawienia',
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const GpsSettingsScreen(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// "Tryb pracy": gdy jest aktywna (trwająca lub wstrzymana) sesja pracy —
  /// [WorkSessionService] przetrwa restart appki — wchodzi wprost w [MapView]
  /// z tym polem/zadaniem, gdzie istniejący baner "PRACA W TOKU" pozwala
  /// jednym tapnięciem wznowić Tryb Pracy. Bez aktywnej sesji: dzisiejszy
  /// wybór zadania ([WorkModeTaskPickerScreen]).
  Future<void> _openWorkMode(BuildContext context) async {
    final session = WorkSessionService.instance;
    if (session.isActive && session.fieldId != null) {
      if (session.taskId != null) {
        final plan = await TaskDatabase.instance.getById(session.taskId!);
        if (plan != null && context.mounted) {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => MapView(initialTask: plan)),
          );
          return;
        }
      }
      final field = FieldService.instance.getById(session.fieldId!);
      if (field != null && context.mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => MapView(initialField: field)),
        );
        return;
      }
    }
    if (context.mounted) await WorkModeTaskPickerScreen.open(context);
  }
}

class _MenuTile extends StatelessWidget {
  const _MenuTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.tooltip,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// Krótki opis metody, np. kiedy jej użyć — pokazywany na long-press/hover.
  /// Domyślnie [label], gdy nie podano nic bardziej szczegółowego.
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip ?? label,
      child: Card(
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        child: InkWell(
          onTap: onTap,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: AppColors.success, size: 32),
              const SizedBox(height: 8),
              Text(
                label,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
