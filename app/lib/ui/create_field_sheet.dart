import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'file_import_sheet.dart';
import 'lpis_import_sheet.dart';
import 'map_view.dart';

/// Bottom sheet wyboru metody tworzenia nowego pola — zastępuje dawne trzy
/// osobne kafelki na ekranie głównym ("Import działek", "Importuj z pliku",
/// "Obejdź granicę (RTK)") jedną pozycją "Utwórz pole".
///
/// Każda opcja wywołuje dokładnie ten sam kod co dawniej odpowiadający jej
/// kafelek — logika importu/obejścia granicy się nie zmienia, zmienia się
/// tylko punkt wejścia w UI.
class CreateFieldSheet {
  CreateFieldSheet._();

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _CreateFieldSheetBody(),
    );
  }
}

class _CreateFieldSheetBody extends StatelessWidget {
  const _CreateFieldSheetBody();

  Future<void> _importParcels(BuildContext context) async {
    Navigator.pop(context);
    final field =
        await LpisImportSheet.show(context, mapBounds: null, fullScreen: true);
    if (field != null && context.mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => MapView(initialField: field)),
      );
    }
  }

  Future<void> _importFile(BuildContext context) async {
    Navigator.pop(context);
    final fields = await FileImportSheet.show(context);
    if (fields.isEmpty || !context.mounted) return;
    if (fields.length == 1) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => MapView(initialField: fields.first)),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Zaimportowano ${fields.length} pól z pliku'),
          backgroundColor: Colors.green[700],
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  void _walkBoundary(BuildContext context) {
    Navigator.pop(context);
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const MapView(startBoundaryWalk: true)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
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
              'Utwórz pole',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Wybierz metodę wyznaczenia granicy',
              style: TextStyle(color: AppColors.textMuted, fontSize: 13),
            ),
            const SizedBox(height: 16),
            _CreateFieldOption(
              icon: Icons.satellite_alt,
              label: 'Import działek (ULDK)',
              description: 'Automatyczne pobranie granic z rejestru gruntów '
                  '(GUGiK) po numerze działki.',
              onTap: () => _importParcels(context),
            ),
            const SizedBox(height: 10),
            _CreateFieldOption(
              icon: Icons.upload_file,
              label: 'Import z pliku',
              description: 'Wczytaj gotową granicę z pliku KML lub GeoJSON, '
                  'np. wyrysowaną w Google Earth / QGIS.',
              onTap: () => _importFile(context),
            ),
            const SizedBox(height: 10),
            _CreateFieldOption(
              icon: Icons.directions_walk,
              label: 'Obejdź granicę (RTK)',
              description: 'Najdokładniejsza metoda — obejdź granicę pola '
                  'pieszo lub maszyną z aktywnym modułem RTK.',
              onTap: () => _walkBoundary(context),
            ),
          ],
        ),
      ),
    );
  }
}

class _CreateFieldOption extends StatelessWidget {
  const _CreateFieldOption({
    required this.icon,
    required this.label,
    required this.description,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String description;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF2A2A2A),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Colors.green[900],
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: AppColors.success, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      description,
                      style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right,
                  color: AppColors.textDisabled, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}
