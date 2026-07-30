import 'package:flutter/material.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'services/arimr_service.dart';
import 'services/coverage_service.dart';
import 'services/field_service.dart';
import 'services/gps_location_service.dart';
import 'services/machine_service.dart';
import 'services/work_task_service.dart';
import 'ui/home_screen.dart';
import 'ui/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Inicjalizacja FMTC — tworzy lokalną bazę kafelków na urządzeniu.
  await FMTCObjectBoxBackend().initialise();
  // Utwórz magazyny kafelków jeśli jeszcze nie istnieją.
  await const FMTCStore('osmTiles').manage.create();
  await const FMTCStore('geoportalTiles').manage.create();

  // Inicjalizacja Hive — trwały magazyn pól uprawowych i pokrycia.
  await Hive.initFlutter();
  await GpsLocationService.init();
  await FieldService.init();
  await CoverageService.init();
  await ArimrService.init();
  await MachineService.init();
  await WorkTaskService.init();

  runApp(const AgriNavApp());
}

class AgriNavApp extends StatelessWidget {
  const AgriNavApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AgriNav',
      theme: buildAppTheme(),
      home: const HomeScreen(),
    );
  }
}
