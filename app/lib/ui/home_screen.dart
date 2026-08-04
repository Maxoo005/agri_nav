import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'arimr_import_sheet.dart';
import 'field_manager_screen.dart';
import 'gps_settings_screen.dart';
import 'history_screen.dart';
import 'machine_manager_screen.dart';
import 'map_view.dart';
import 'new_task_screen.dart';
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
                      onTap: () => WorkModeTaskPickerScreen.open(context),
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
                      icon: Icons.assignment_add,
                      label: 'Nowe zadanie',
                      onTap: () => NewTaskScreen.open(context),
                    ),
                    _MenuTile(
                      icon: Icons.satellite_alt,
                      label: 'Import ARiMR',
                      onTap: () async {
                        final field = await ArimrImportSheet.show(context,
                            mapBounds: null, fullScreen: true);
                        if (field != null && context.mounted) {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => MapView(initialField: field),
                            ),
                          );
                        }
                      },
                    ),
                    _MenuTile(
                      icon: Icons.gps_fixed,
                      label: 'Ustawienia GPS',
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const GpsSettingsScreen(),
                        ),
                      ),
                    ),
                    _MenuTile(
                      icon: Icons.history_rounded,
                      label: 'Historia',
                      onTap: () => HistoryScreen.open(context),
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
}

class _MenuTile extends StatelessWidget {
  const _MenuTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
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
    );
  }
}
