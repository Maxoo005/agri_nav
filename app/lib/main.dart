import 'package:flutter/material.dart';
import 'ui/map_view.dart';

void main() => runApp(const AgriNavApp());

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
