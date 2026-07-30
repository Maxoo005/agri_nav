import 'package:flutter/material.dart';

import '../ffi/gps_bridge.dart' show SimPosition;
import '../services/gps_location_service.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// GpsSettingsScreen — GPS status and permission management
// ═══════════════════════════════════════════════════════════════════════════════

class GpsSettingsScreen extends StatefulWidget {
  const GpsSettingsScreen({super.key});

  @override
  State<GpsSettingsScreen> createState() => _GpsSettingsScreenState();
}

class _GpsSettingsScreenState extends State<GpsSettingsScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ustawienia GPS')),
      body: ListView(
        children: [
          _FixStatusTile(),
          const Divider(),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('Wskazówka'),
            subtitle: Text(
              'Aby GPS działał przy wygaszonym ekranie, '
              'odznacz "Optymalizację baterii" dla aplikacji AgriNav '
              'w Ustawieniach → Aplikacje.',
            ),
          ),
        ],
      ),
    );
  }
}

class _FixStatusTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<SimPosition>(
      stream: GpsLocationService.instance.positionStream,
      builder: (context, snapshot) {
        final status = GpsLocationService.instance.fixStatus;
        final (label, color, icon) = switch (status) {
          GpsFixStatus.inactive => ('Nieaktywny', Colors.grey, Icons.gps_off),
          GpsFixStatus.searching => (
              'Szukanie sygnału…',
              Colors.orange,
              Icons.gps_not_fixed
            ),
          GpsFixStatus.gps => (
              'GPS (dokładność autonomiczna)',
              Colors.green,
              Icons.gps_fixed
            ),
          GpsFixStatus.dgps => (
              'DGPS (wysoka dokładność)',
              Colors.teal,
              Icons.satellite_alt
            ),
        };
        return ListTile(
          leading: Icon(icon, color: color),
          title: const Text('Status FIX'),
          subtitle: Text(label),
          trailing: snapshot.hasData
              ? Text(
                  '±${snapshot.data!.accuracy.toStringAsFixed(1)} m',
                  style: TextStyle(color: color, fontWeight: FontWeight.bold),
                )
              : null,
        );
      },
    );
  }
}
