import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart' show Geolocator;

import '../ffi/gps_bridge.dart' show SimPosition;
import '../models/gnss_position.dart' show GnssFixQuality, GnssStatus;
import '../services/bluetooth_gnss_service.dart';
import '../services/gps_location_service.dart';
import '../services/ntrip_client_service.dart';
import 'widgets/fix_quality_badge.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// GpsSettingsScreen — GPS status, source switch (phone / RTK) and permissions
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
    // GpsLocationService działa na liczniku aktywnych ekranów — bez tego
    // wywołania przełącznik źródła i wybór urządzenia RTK w tym ekranie nic
    // by nie robiły, gdyby ekran mapy nie był akurat otwarty w tle.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await GpsLocationService.instance.start(context);
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    GpsLocationService.instance.stop();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (mounted) setState(() {});
  }

  Future<void> _pickDevice() async {
    final devices = await BluetoothGnssService.instance.pairedDevices();
    if (!mounted) return;

    if (devices.isEmpty) {
      if (BluetoothGnssService.instance.permissionDenied) {
        await _showPermissionDialog();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              BluetoothGnssService.instance.lastError ??
                  'Brak sparowanych urządzeń Bluetooth. Sparuj odbiornik RTK '
                      'w systemowych Ustawieniach → Bluetooth, a potem wróć tutaj.',
            ),
          ),
        );
      }
      return;
    }

    final selected = await showModalBottomSheet<BluetoothDeviceInfo>(
      context: context,
      builder: (_) => _DevicePickerSheet(devices: devices),
    );

    if (selected == null) return;
    await GpsLocationService.instance.setRtkDevice(selected.address);
    if (mounted) setState(() {});
  }

  /// Pokazywane gdy `bluetooth_classic` zgłosi brak uprawnień. W odróżnieniu
  /// od zwykłego SnackBara zostaje na ekranie i daje bezpośrednie przejście
  /// do Ustawień — bo systemowe okno z pytaniem o zgodę mogło się już nie
  /// pojawić ponownie (Android czasem odmawia go pokazać po jednej odmowie),
  /// więc jedyna droga to ręczne włączenie uprawnienia w Ustawieniach.
  Future<void> _showPermissionDialog() {
    return showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Brak uprawnień Bluetooth'),
        content: const Text(
          'AgriNav potrzebuje uprawnień Bluetooth (oraz lokalizacji — wymaga '
          'tego system Android do wykrywania urządzeń Bluetooth), żeby '
          'połączyć się z odbiornikiem RTK.\n\n'
          'Otwórz Ustawienia → Aplikacje → AgriNav → Uprawnienia i włącz je '
          'ręcznie, a potem wróć tutaj i spróbuj ponownie.\n\n'
          'Jeśli to się powtarza mimo przyznanych uprawnień, spróbuj '
          'całkowicie zamknąć i ponownie otworzyć AgriNav — to znany błąd '
          'wtyczki Bluetooth po przerwanym oknie z pytaniem o zgodę.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Anuluj'),
          ),
          FilledButton.icon(
            onPressed: () {
              Navigator.of(context).pop();
              Geolocator.openAppSettings();
            },
            icon: const Icon(Icons.settings),
            label: const Text('Ustawienia'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final useInternal = GpsLocationService.instance.useInternalGps;

    return Scaffold(
      appBar: AppBar(title: const Text('Ustawienia GPS')),
      body: ListView(
        children: [
          const _FixStatusTile(),
          const Divider(),
          SwitchListTile(
            secondary:
                Icon(useInternal ? Icons.phone_iphone : Icons.bluetooth),
            title: const Text('Zewnętrzny odbiornik RTK (Bluetooth)'),
            subtitle: Text(
              useInternal
                  ? 'Wyłączony — używany GPS telefonu (dokładność ok. 3-5 m)'
                  : 'Włączony — pozycja z odbiornika RTK po Bluetooth '
                      '(1-3 cm przy fixie RTK Fixed)',
            ),
            value: !useInternal,
            onChanged: (external) {
              setState(() {
                GpsLocationService.instance.useInternalGps = !external;
              });
            },
          ),
          if (!useInternal) ...[
            ListTile(
              leading: const Icon(Icons.bluetooth_searching),
              title: const Text('Odbiornik RTK'),
              subtitle: Text(
                GpsLocationService.instance.rtkDeviceAddress ??
                    'Nie wybrano urządzenia — dotknij, aby wybrać',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: _pickDevice,
            ),
            const _BtLinkStateTile(),
            const _SatelliteInfoTile(),
            const Divider(),
            const _NtripSection(),
          ],
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

// ─────────────────────────────────────────────────────────────────────────────
// Status FIX — łączy fixStatusStream (żywy, nawet bez współrzędnych) z
// ostatnią znaną dokładnością z positionStream.
// ─────────────────────────────────────────────────────────────────────────────

class _FixStatusTile extends StatefulWidget {
  const _FixStatusTile();

  @override
  State<_FixStatusTile> createState() => _FixStatusTileState();
}

class _FixStatusTileState extends State<_FixStatusTile> {
  GpsFixStatus _status = GpsLocationService.instance.fixStatus;
  double? _accuracy;

  StreamSubscription<GpsFixStatus>? _statusSub;
  StreamSubscription<SimPosition>? _posSub;

  @override
  void initState() {
    super.initState();
    _statusSub = GpsLocationService.instance.fixStatusStream
        .listen((status) => setState(() => _status = status));
    _posSub = GpsLocationService.instance.positionStream
        .listen((pos) => setState(() => _accuracy = pos.accuracy));
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _posSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: FixQualityBadge(status: _status),
      title: const Text('Status FIX'),
      subtitle: Text(_statusLabel(_status)),
      trailing: _accuracy != null
          ? Text(
              '±${_accuracy!.toStringAsFixed(_accuracy! < 1 ? 2 : 1)} m',
              style: const TextStyle(fontWeight: FontWeight.bold),
            )
          : null,
    );
  }

  static String _statusLabel(GpsFixStatus status) => switch (status) {
        GpsFixStatus.inactive => 'Nieaktywny',
        GpsFixStatus.searching => 'Szukanie sygnału…',
        GpsFixStatus.gps => 'GPS (dokładność autonomiczna)',
        GpsFixStatus.dgps => 'DGPS (podwyższona dokładność)',
        GpsFixStatus.rtkFloat => 'RTK Float (dokładność dm)',
        GpsFixStatus.rtkFixed => 'RTK Fixed (dokładność 1-3 cm)',
      };
}

// ─────────────────────────────────────────────────────────────────────────────
// Stan łącza Bluetooth — osobny od jakości fixa (patrz BluetoothGnssService).
// ─────────────────────────────────────────────────────────────────────────────

class _BtLinkStateTile extends StatelessWidget {
  const _BtLinkStateTile();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<BtLinkState>(
      stream: BluetoothGnssService.instance.linkStateStream,
      initialData: BluetoothGnssService.instance.linkState,
      builder: (context, snapshot) {
        final state = snapshot.data ?? BtLinkState.disconnected;
        final (icon, color, label) = switch (state) {
          BtLinkState.disconnected => (
              Icons.bluetooth_disabled,
              Colors.grey,
              'Rozłączony'
            ),
          BtLinkState.connecting => (
              Icons.bluetooth_searching,
              Colors.orange,
              'Łączenie…'
            ),
          BtLinkState.connected => (
              Icons.bluetooth_connected,
              Colors.green,
              'Połączony'
            ),
          BtLinkState.reconnecting => (
              Icons.bluetooth_searching,
              Colors.orange,
              'Rozłączono — ponawiam próbę połączenia…'
            ),
        };

        final address = GpsLocationService.instance.rtkDeviceAddress;
        return ListTile(
          leading: Icon(icon, color: color),
          title: Text('Bluetooth: $label'),
          subtitle: BluetoothGnssService.instance.lastError != null &&
                  state != BtLinkState.connected
              ? Text(BluetoothGnssService.instance.lastError!)
              : null,
          trailing: state == BtLinkState.disconnected && address != null
              ? IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Połącz ponownie',
                  onPressed: () =>
                      GpsLocationService.instance.setRtkDevice(address),
                )
              : null,
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Satelity / HDOP — diagnostyka: pozwala odróżnić "dane NMEA nie docierają"
// (brak tego kafelka mimo aktywnego połączenia BT) od "odbiornik naprawdę
// jeszcze nie ma fixa" (liczba satelitów > 0, ale fix wciąż "Szukanie…").
// ─────────────────────────────────────────────────────────────────────────────

class _SatelliteInfoTile extends StatelessWidget {
  const _SatelliteInfoTile();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<GnssStatus>(
      stream: BluetoothGnssService.instance.statusStream,
      builder: (context, snapshot) {
        final status = snapshot.data;
        return ListTile(
          leading: const Icon(Icons.satellite_alt_outlined),
          title: const Text('Satelity / HDOP'),
          subtitle: Text(
            status == null
                ? 'Brak jeszcze danych NMEA — jeśli to się nie zmienia mimo '
                    '"Połączony" powyżej, dane z modułu nie docierają '
                    '(sprawdź czy moduł faktycznie nadaje po SPP).'
                : '${status.satellitesCount} satelitów, '
                    'HDOP ${status.hdop.toStringAsFixed(1)}'
                    '${status.fixQuality == GnssFixQuality.noFix ? ' — czekam na fix' : ''}',
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Konfiguracja NTRIP — formularz danych dostępowych + wybór mountpointu +
// status połączenia. Łączy się automatycznie razem z Bluetoothem (patrz
// GpsLocationService._startExternalRtk) — to nie jest osobny ręczny krok.
// ─────────────────────────────────────────────────────────────────────────────

class _NtripSection extends StatefulWidget {
  const _NtripSection();

  @override
  State<_NtripSection> createState() => _NtripSectionState();
}

class _NtripSectionState extends State<_NtripSection> {
  final _hostCtrl = TextEditingController();
  final _portCtrl = TextEditingController(text: '2101');
  final _companyCtrl = TextEditingController();
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();

  List<String> _mountpoints = [];
  String? _selectedMountpoint;
  bool _loadingMountpoints = false;
  bool _obscurePassword = true;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadSavedConfig();
  }

  Future<void> _loadSavedConfig() async {
    final gps = GpsLocationService.instance;
    final savedPassword = await gps.ntripPassword;
    if (!mounted) return;
    setState(() {
      _hostCtrl.text = gps.ntripHost ?? '';
      _portCtrl.text = (gps.ntripPort ?? 2101).toString();
      _companyCtrl.text = gps.ntripCompany ?? '';
      _usernameCtrl.text = gps.ntripUsername ?? '';
      _passwordCtrl.text = savedPassword ?? '';
      _selectedMountpoint = gps.ntripMountpoint;
      if (_selectedMountpoint != null) {
        // Pokaż zapisany mountpoint na liście, dopóki użytkownik nie
        // odświeży source table — inaczej dropdown nie miałby co wyświetlić.
        _mountpoints = [_selectedMountpoint!];
      }
      _loaded = true;
    });
  }

  @override
  void dispose() {
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _companyCtrl.dispose();
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _fetchMountpoints() async {
    final host = _hostCtrl.text.trim();
    final port = int.tryParse(_portCtrl.text.trim());
    if (host.isEmpty || port == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Podaj adres i port serwera NTRIP.')),
      );
      return;
    }

    setState(() => _loadingMountpoints = true);
    final mountpoints =
        await NtripClientService.instance.fetchMountpoints(host, port);
    if (!mounted) return;

    setState(() {
      _loadingMountpoints = false;
      _mountpoints = mountpoints;
      if (_selectedMountpoint != null &&
          !mountpoints.contains(_selectedMountpoint)) {
        // Zachowaj wcześniej zapisany wybór na liście, nawet jeśli świeże
        // pobranie source table go nie zwróciło (np. chwilowy problem sieci).
        _mountpoints = [_selectedMountpoint!, ...mountpoints];
      }
      if (_selectedMountpoint == null && mountpoints.isNotEmpty) {
        _selectedMountpoint = mountpoints.first;
      }
    });

    if (mountpoints.isEmpty && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            NtripClientService.instance.lastError ??
                'Nie znaleziono mountpointów.',
          ),
        ),
      );
    }
  }

  Future<void> _save() async {
    final host = _hostCtrl.text.trim();
    final port = int.tryParse(_portCtrl.text.trim());
    final company = _companyCtrl.text.trim();
    final username = _usernameCtrl.text.trim();
    final password = _passwordCtrl.text;
    final mountpoint = _selectedMountpoint;

    if (host.isEmpty ||
        port == null ||
        company.isEmpty ||
        username.isEmpty ||
        password.isEmpty ||
        mountpoint == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Uzupełnij wszystkie pola (adres, port, firma, użytkownik, '
            'hasło) i wybierz mountpoint z listy.',
          ),
        ),
      );
      return;
    }

    await GpsLocationService.instance.saveNtripConfig(
      host: host,
      port: port,
      company: company,
      username: username,
      password: password,
      mountpoint: mountpoint,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Zapisano konfigurację NTRIP — łączenie nastąpi automatycznie '
          'razem z Bluetooth.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            'Poprawki NTRIP (RTK Fixed)',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            'Dane z Twojej usługi sieciowej (np. ASG-EUPOS). Login wysyłany '
            'jest jako "Firma/Użytkownik" — tak wymaga ASG-EUPOS.',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: _hostCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Adres serwera',
                        hintText: 'system.asgeupos.pl',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 1,
                    child: TextField(
                      controller: _portCtrl,
                      decoration: const InputDecoration(labelText: 'Port'),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _companyCtrl,
                decoration: const InputDecoration(labelText: 'Nazwa firmy'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _usernameCtrl,
                decoration:
                    const InputDecoration(labelText: 'Nazwa użytkownika'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _passwordCtrl,
                obscureText: _obscurePassword,
                decoration: InputDecoration(
                  labelText: 'Hasło',
                  suffixIcon: IconButton(
                    icon: Icon(_obscurePassword
                        ? Icons.visibility
                        : Icons.visibility_off),
                    onPressed: () =>
                        setState(() => _obscurePassword = !_obscurePassword),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: _mountpoints.contains(_selectedMountpoint)
                          ? _selectedMountpoint
                          : null,
                      decoration:
                          const InputDecoration(labelText: 'Mountpoint'),
                      items: _mountpoints
                          .map((m) => DropdownMenuItem(
                                value: m,
                                child:
                                    Text(m, overflow: TextOverflow.ellipsis),
                              ))
                          .toList(),
                      onChanged: (v) => setState(() => _selectedMountpoint = v),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _loadingMountpoints
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : IconButton(
                          icon: const Icon(Icons.refresh),
                          tooltip: 'Pobierz listę mountpointów',
                          onPressed: _fetchMountpoints,
                        ),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _save,
                  child: const Text('Zapisz konfigurację NTRIP'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        const _NtripStateTile(),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Stan połączenia z serwerem NTRIP.
// ─────────────────────────────────────────────────────────────────────────────

class _NtripStateTile extends StatelessWidget {
  const _NtripStateTile();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<NtripState>(
      stream: NtripClientService.instance.stateStream,
      initialData: NtripClientService.instance.state,
      builder: (context, snapshot) {
        final state = snapshot.data ?? NtripState.disconnected;
        final (icon, color, label) = switch (state) {
          NtripState.disconnected => (
              Icons.cloud_off,
              Colors.grey,
              'Rozłączony'
            ),
          NtripState.connecting => (
              Icons.cloud_sync,
              Colors.orange,
              'Łączenie…'
            ),
          NtripState.connected => (
              Icons.cloud_done,
              Colors.green,
              'Połączono — poprawki płyną'
            ),
          NtripState.reconnecting => (
              Icons.cloud_sync,
              Colors.orange,
              'Rozłączono — ponawiam próbę połączenia…'
            ),
          NtripState.authError => (
              Icons.error_outline,
              Colors.red,
              'Błąd logowania (login/hasło)'
            ),
          NtripState.networkError => (
              Icons.error_outline,
              Colors.red,
              'Błąd połączenia / zły mountpoint'
            ),
        };

        return ListTile(
          leading: Icon(icon, color: color),
          title: Text('NTRIP: $label'),
          subtitle: NtripClientService.instance.lastError != null &&
                  state != NtripState.connected
              ? Text(NtripClientService.instance.lastError!)
              : null,
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Wybór sparowanego urządzenia Bluetooth (bottom sheet).
// ─────────────────────────────────────────────────────────────────────────────

class _DevicePickerSheet extends StatelessWidget {
  const _DevicePickerSheet({required this.devices});

  final List<BluetoothDeviceInfo> devices;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Sparowane urządzenia Bluetooth',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
          ),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: devices.length,
              itemBuilder: (context, index) {
                final device = devices[index];
                return ListTile(
                  leading: const Icon(Icons.satellite_alt),
                  title: Text(device.name),
                  subtitle: Text(device.address),
                  onTap: () => Navigator.of(context).pop(device),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
