import 'package:flutter/material.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'services/field_service.dart';
import 'ui/map_view.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Inicjalizacja FMTC — tworzy lokalną bazę kafelków na urządzeniu.
  await FMTCObjectBoxBackend().initialise();
  // Utwórz domyślny magazyn jeśli jeszcze nie istnieje.
  await const FMTCStore('osmTiles').manage.create();

  // Inicjalizacja Hive — trwały magazyn pól uprawowych.
  await Hive.initFlutter();
  await FieldService.init();

  runApp(const AgriNavApp());
}

class AgriNavApp extends StatelessWidget {
  const AgriNavApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AgriNav',
      theme: ThemeData(colorSchemeSeed: Colors.green, useMaterial3: true),
      home: const MapView(),
    );
  }
}
