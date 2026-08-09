import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'services/lpis_service.dart';
import 'services/coverage_service.dart';
import 'services/field_service.dart';
import 'services/gps_location_service.dart';
import 'services/history_database.dart';
import 'services/machine_service.dart';
import 'services/task_database.dart';
import 'services/work_session_service.dart';
import 'services/work_task_service.dart';
import 'ui/home_screen.dart';
import 'ui/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Inicjalizacja Hive — trwały magazyn pól uprawowych i pokrycia.
  await Hive.initFlutter();
  await GpsLocationService.init();
  await FieldService.init();
  await CoverageService.init();
  await LpisService.init();
  await MachineService.init();
  await WorkTaskService.init();
  await WorkSessionService.init();

  // SQLite — baza zapisanych zadań roboczych (agrinav.db).
  // Najpierw ustawiamy silnik dla platformy, potem otwieramy bazę.
  TaskDatabase.configureFactory();
  await TaskDatabase.instance.init();

  // SQLite — baza historii zakończonych prac (agrinav_history.db).
  HistoryDatabase.configureFactory();
  await HistoryDatabase.instance.init();

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
