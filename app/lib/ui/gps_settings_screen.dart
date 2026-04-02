import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../ffi/gps_bridge.dart' show SimPosition;
import '../services/gps_location_service.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// GpsSettingsScreen — runtime toggle between real GPS and C++ simulator
// ═══════════════════════════════════════════════════════════════════════════════

class GpsSettingsScreen extends StatefulWidget {
  const GpsSettingsScreen({super.key});

  @override
  State<GpsSettingsScreen> createState() => _GpsSettingsScreenState();
}

class _GpsSettingsScreenState extends State<GpsSettingsScreen>
    with WidgetsBindingObserver {
  late bool _useInternalGps;

  @override
  void initState() {
    super.initState();
    _useInternalGps = GpsLocationService.instance.useInternalGps;
    // Observe app lifecycle so we can re-check permissions when the user
    // returns to AgriNav after granting access in the system Settings app.
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Called when the user returns to the app (e.g. after changing permissions
  /// in system Settings).  Re-check permission status and update the toggle.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    _syncPermissionState();
  }

  Future<void> _syncPermissionState() async {
    final permission = await Geolocator.checkPermission();
    final hasGps = permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse;

    // If the user revoked permission while GPS was on: force-switch to simulator
    if (!hasGps && _useInternalGps) {
      setState(() => _useInternalGps = false);
      GpsLocationService.instance.useInternalGps = false;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Uprawnienia GPS zostały cofnięte — włączono symulator.',
            ),
          ),
        );
      }
    }

    // If the user just granted permission: update toggle state to reflect reality
    if (hasGps && mounted) setState(() {/* refreshes _FixStatusTile */});
  }

  Future<void> _onToggle(bool value) async {
    if (value) {
      // Przed włączeniem realnego GPS — sprawdź/poproś o uprawnienia.
      final granted =
          await GpsLocationService.instance.requestPermissions(context);
      if (!granted) return; // odmowa — zostajemy przy symulatorze
    }
    setState(() => _useInternalGps = value);
    GpsLocationService.instance.useInternalGps = value;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Ustawienia GPS')),
      body: ListView(
        children: [
          SwitchListTile(
            secondary: Icon(
              _useInternalGps ? Icons.gps_fixed : Icons.computer,
              color: _useInternalGps ? cs.primary : cs.outline,
            ),
            title: const Text('Wbudowany GPS telefonu'),
            subtitle: Text(
              _useInternalGps
                  ? 'Używa rzeczywistego odbiornika GNSS urządzenia'
                  : 'Tryb symulacji C++ (testowy)',
            ),
            value: _useInternalGps,
            onChanged: _onToggle,
          ),
          const Divider(),
          if (_useInternalGps) ...[
            _FixStatusTile(),
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
          title: Text('Status FIX'),
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
