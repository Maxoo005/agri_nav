import 'package:flutter/material.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import 'ui/map_view.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Inicjalizacja FMTC — tworzy lokalną bazę kafelków na urządzeniu.
  await FMTCObjectBoxBackend().initialise();
  // Utwórz domyślny magazyn jeśli jeszcze nie istnieje.
  await const FMTCStore('osmTiles').manage.create();

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
