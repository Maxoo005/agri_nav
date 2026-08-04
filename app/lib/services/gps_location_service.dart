import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:geolocator/geolocator.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../ffi/gps_bridge.dart';
import '../models/gnss_position.dart';
import 'bluetooth_gnss_service.dart';
import 'ntrip_client_service.dart';

const _kGpsBox = 'gps_settings';
const _kUseInternalGpsKey = 'useInternalGps';
const _kRtkDeviceAddressKey = 'rtkDeviceAddress';
const _kNtripHostKey = 'ntripHost';
const _kNtripPortKey = 'ntripPort';
const _kNtripCompanyKey = 'ntripCompany';
const _kNtripUsernameKey = 'ntripUsername';
const _kNtripMountpointKey = 'ntripMountpoint';

/// Hasło NTRIP NIE trafia do Hive (niezaszyfrowane na dysku) — idzie do
/// Android Keystore przez `flutter_secure_storage`. Pozostała konfiguracja
/// (host/port/login/mountpoint) to dane jawne i tak widoczne przy każdym
/// połączeniu (host/port/mountpoint w URL, login w nagłówku Basic Auth),
/// więc trzymanie ich w zwykłym Hive to rozsądny kompromis.
const _kNtripPasswordSecureKey = 'ntripPassword';
const _secureStorage = FlutterSecureStorage();

// ═══════════════════════════════════════════════════════════════════════════════
// GpsLocationService — real GNSS via Geolocator
// ═══════════════════════════════════════════════════════════════════════════════

/// Fix quality reported via [GpsFixStatus].
enum GpsFixStatus {
  /// Service stopped / not yet started.
  inactive,

  /// Waiting for first fix or accuracy > [GpsLocationService.kMaxAccuracyM].
  searching,

  /// Autonomous GPS fix (accuracy 5–20 m, but below threshold).
  gps,

  /// DGPS-grade fix (accuracy < 5 m).
  dgps,

  /// RTK Float — external RTK receiver only, decimeter-level accuracy
  /// (correction stream not fully resolved yet).
  rtkFloat,

  /// RTK Fixed — external RTK receiver only, centimeter-level accuracy.
  rtkFixed,
}

/// Singleton — unified position source for the whole app.
///
/// Wraps EITHER the phone's built-in GNSS (via `geolocator`) OR an external
/// Bluetooth RTK receiver (via [BluetoothGnssService]), selected by
/// [useInternalGps]. Both paths converge on the same [positionStream] /
/// [fixStatus], so callers (map view, work mode, FFI via `NavBridge`) never
/// need to know which source is active — see [_fromGnss] for the RTK→
/// SimPosition mapping that makes this possible.
///
/// ### Filtering applied to real GPS positions (phone GPS only):
/// 1. **EMA position smoothing** (α = [_kEmaAlpha]) — applied only to
///    *accurate* samples so that large blips don't contaminate the filter.
/// 2. **Accuracy gate** — positions with `accuracy > kMaxAccuracyM` are emitted
///    with `SimPosition.isAccurate = false`.  Callers skip coverage/NavBridge
///    updates but may display the raw position as a low-opacity hint.
/// 3. **Heading speed gate** — hardware heading is only forwarded when
///    `speed ≥ kMinHeadingSpeedMs`.  At standstill the phone compass/GPS
///    bearing is noisy and would spin the field view.
///
/// RTK positions are NOT EMA-smoothed: an RTK Fixed sample is already
/// accurate to 1-3 cm, so smoothing would only add lag that hurts precision
/// guidance instead of helping it.
///
/// Usage:
/// ```dart
/// await GpsLocationService.instance.start(context);
/// final sub = GpsLocationService.instance.positionStream.listen(_onPos);
/// // …
/// sub.cancel();
/// GpsLocationService.instance.stop();
/// ```
class GpsLocationService {
  GpsLocationService._();

  static final instance = GpsLocationService._();

  /// Inicjalizacja: otwiera box Hive i odczytuje zapisaną preferencję.
  /// Wywołać w main() po Hive.initFlutter().
  static Future<void> init() async {
    final box = await Hive.openBox(_kGpsBox);
    instance._useInternalGps = box.get(_kUseInternalGpsKey, defaultValue: true);
  }

  // ── Public constants ──────────────────────────────────────────────────────────

  /// Positions with `accuracy > kMaxAccuracyM` are emitted as inaccurate.
  static const double kMaxAccuracyM = 10.0;

  /// Hardware heading is only trusted when ground speed ≥ this value [m/s].
  static const double kMinHeadingSpeedMs = 0.5;

  // ── Public state ─────────────────────────────────────────────────────────────

  bool get useInternalGps => _useInternalGps;
  set useInternalGps(bool value) {
    if (_useInternalGps == value) return;
    final wasActive = _activeListeners > 0;
    if (wasActive) {
      _useInternalGps ? _stopRealGps() : _stopExternalRtk();
    }

    _useInternalGps = value;
    Hive.box(_kGpsBox).put(_kUseInternalGpsKey, value);

    if (wasActive) {
      _updateFixStatus(GpsFixStatus.searching);
      if (value) {
        // Uwaga: przełączenie na GPS telefonu w locie nie prosi ponownie o
        // uprawnienia (nie mamy tu BuildContext) — zakładamy, że zostały już
        // przyznane przy pierwszym starcie (domyślny tryb to internal GPS).
        // Jeśli użytkownik nigdy nie uruchomił GPS telefonu i cofnął
        // uprawnienia, geolocator po prostu zwróci błąd przez onError.
        _startRealGps();
      } else {
        _startExternalRtk();
      }
    }
  }

  bool _useInternalGps = true;

  /// Adres MAC ostatnio wybranego odbiornika RTK (zapamiętany w Hive).
  /// `null` gdy użytkownik jeszcze nigdy nie wybrał urządzenia.
  String? get rtkDeviceAddress =>
      Hive.box(_kGpsBox).get(_kRtkDeviceAddressKey) as String?;

  /// Zapisuje wybrane urządzenie RTK i — jeśli tryb zewnętrzny jest właśnie
  /// aktywny — od razu się z nim łączy (przełącza z poprzedniego, jeśli był).
  Future<void> setRtkDevice(String address) async {
    await Hive.box(_kGpsBox).put(_kRtkDeviceAddressKey, address);
    if (!_useInternalGps && _activeListeners > 0) {
      _updateFixStatus(GpsFixStatus.searching);
      await BluetoothGnssService.instance.connect(address);
    }
  }

  // ── Konfiguracja NTRIP ────────────────────────────────────────────────────────

  String? get ntripHost => Hive.box(_kGpsBox).get(_kNtripHostKey) as String?;
  int? get ntripPort => Hive.box(_kGpsBox).get(_kNtripPortKey) as int?;
  String? get ntripCompany =>
      Hive.box(_kGpsBox).get(_kNtripCompanyKey) as String?;
  String? get ntripUsername =>
      Hive.box(_kGpsBox).get(_kNtripUsernameKey) as String?;
  String? get ntripMountpoint =>
      Hive.box(_kGpsBox).get(_kNtripMountpointKey) as String?;

  /// Hasło NTRIP z bezpiecznego magazynu (Android Keystore). `null` gdy
  /// jeszcze nigdy nie zapisane.
  Future<String?> get ntripPassword =>
      _secureStorage.read(key: _kNtripPasswordSecureKey);

  /// `true` gdy zapisano komplet danych potrzebnych do połączenia z NTRIP
  /// (host/port/firma/użytkownik/mountpoint — hasło sprawdzane osobno w
  /// [_loadNtripConfig], bo odczyt z bezpiecznego magazynu jest asynchroniczny).
  bool get hasNtripBasicConfig =>
      (ntripHost?.isNotEmpty ?? false) &&
      ntripPort != null &&
      (ntripCompany?.isNotEmpty ?? false) &&
      (ntripUsername?.isNotEmpty ?? false) &&
      (ntripMountpoint?.isNotEmpty ?? false);

  /// Zapisuje pełną konfigurację NTRIP (Hive dla danych jawnych, bezpieczny
  /// magazyn dla hasła) i — jeśli tryb zewnętrzny jest właśnie aktywny — od
  /// razu (re)łączy się z serwerem na nowej konfiguracji.
  Future<void> saveNtripConfig({
    required String host,
    required int port,
    required String company,
    required String username,
    required String password,
    required String mountpoint,
  }) async {
    final box = Hive.box(_kGpsBox);
    await box.put(_kNtripHostKey, host);
    await box.put(_kNtripPortKey, port);
    await box.put(_kNtripCompanyKey, company);
    await box.put(_kNtripUsernameKey, username);
    await box.put(_kNtripMountpointKey, mountpoint);
    await _secureStorage.write(
        key: _kNtripPasswordSecureKey, value: password);

    if (!_useInternalGps && _activeListeners > 0) {
      await _startNtripIfConfigured();
    }
  }

  /// Składa [NtripConfig] z zapisanych danych, albo `null` gdy konfiguracja
  /// jest niekompletna (np. świeża instalacja, użytkownik jeszcze nic nie
  /// wpisał) — w takim wypadku po prostu nie ma się z czym łączyć, to nie
  /// jest błąd.
  Future<NtripConfig?> _loadNtripConfig() async {
    final host = ntripHost;
    final port = ntripPort;
    final company = ntripCompany;
    final username = ntripUsername;
    final mountpoint = ntripMountpoint;
    final password = await ntripPassword;

    if (host == null ||
        host.isEmpty ||
        port == null ||
        company == null ||
        company.isEmpty ||
        username == null ||
        username.isEmpty ||
        mountpoint == null ||
        mountpoint.isEmpty ||
        password == null ||
        password.isEmpty) {
      return null;
    }

    return NtripConfig(
      host: host,
      port: port,
      company: company,
      username: username,
      password: password,
      mountpoint: mountpoint,
    );
  }

  Future<void> _startNtripIfConfigured() async {
    final config = await _loadNtripConfig();
    if (config == null) return;
    await NtripClientService.instance.connect(config);
  }

  GpsFixStatus get fixStatus => _fixStatus;
  GpsFixStatus _fixStatus = GpsFixStatus.inactive;

  final _fixStatusController = StreamController<GpsFixStatus>.broadcast();

  /// Emituje przy KAŻDEJ zmianie [fixStatus] — w odróżnieniu od
  /// [positionStream] robi to również gdy zewnętrzny odbiornik jest
  /// połączony, ale jeszcze nie ma fixa (wtedy nie ma współrzędnych do
  /// wyemitowania jako [SimPosition]). Widgety pokazujące sam wskaźnik
  /// jakości (bez pozycji na mapie) powinny słuchać tego strumienia.
  Stream<GpsFixStatus> get fixStatusStream => _fixStatusController.stream;

  void _updateFixStatus(GpsFixStatus status) {
    _fixStatus = status;
    if (!_fixStatusController.isClosed) _fixStatusController.add(status);
  }

  // ── Stream infrastructure ────────────────────────────────────────────────────

  final _controller = StreamController<SimPosition>.broadcast();

  Stream<SimPosition> get positionStream => _controller.stream;

  int _activeListeners = 0;
  StreamSubscription<Position>? _geolocatorSub;

  StreamSubscription<GnssPosition>? _gnssPosSub;
  StreamSubscription<GnssStatus>? _gnssQualitySub;
  StreamSubscription<BtLinkState>? _gnssLinkSub;
  StreamSubscription<Uint8List>? _rtcmSub;

  // ── Lifecycle ────────────────────────────────────────────────────────────────

  /// Start GPS.  Requests permissions first, then subscribes to the GNSS
  /// position stream.  Safe to call multiple times (ref-counted).
  ///
  /// If permissions are denied, the stream will not emit positions.
  Future<void> start(BuildContext context) async {
    _activeListeners++;
    if (_activeListeners == 1) {
      _updateFixStatus(GpsFixStatus.searching);

      if (_useInternalGps) {
        final granted = await requestPermissions(context);
        if (granted) {
          _startRealGps();
        } else {
          _updateFixStatus(GpsFixStatus.inactive);
        }
      } else {
        _startExternalRtk();
      }
    }
  }

  /// Stop forwarding.  Pairs with [start].
  void stop() {
    if (_activeListeners <= 0) return;
    _activeListeners--;
    if (_activeListeners == 0) {
      _stopRealGps();
      _stopExternalRtk();
      _updateFixStatus(GpsFixStatus.inactive);
    }
  }

  // ── EMA (Exponential Moving Average) filter ──────────────────────────────────

  static const double _kEmaAlpha = 0.3;

  double? _emaLat;
  double? _emaLon;
  double? _emaAlt;

  void _resetEma() {
    _emaLat = null;
    _emaLon = null;
    _emaAlt = null;
  }

  // ── Real GNSS (Geolocator) ──────────────────────────────────────────────────

  void _startRealGps() {
    final settings = AndroidSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      intervalDuration: const Duration(milliseconds: 100),
      distanceFilter: 0,
      foregroundNotificationConfig: const ForegroundNotificationConfig(
        notificationText: 'AgriNav — aktywna nawigacja GPS',
        notificationTitle: 'AgriNav GPS',
        enableWakeLock: true,
        setOngoing: true,
        notificationIcon: AndroidResource(
          name: 'ic_launcher',
          defType: 'mipmap',
        ),
      ),
    );

    _geolocatorSub = Geolocator.getPositionStream(
      locationSettings: settings,
    ).listen(
      _onGeolocatorPosition,
      onError: (Object e) {
        debugPrint('[GpsLocationService] Geolocator error: $e');
        _updateFixStatus(GpsFixStatus.searching);
      },
    );
  }

  void _stopRealGps() {
    _geolocatorSub?.cancel();
    _geolocatorSub = null;
    _resetEma();
  }

  void _onGeolocatorPosition(Position pos) {
    final bool isAccurate = pos.accuracy <= kMaxAccuracyM;

    double lat = pos.latitude;
    double lon = pos.longitude;
    double alt = pos.altitude;

    if (isAccurate) {
      _emaLat ??= lat;
      _emaLon ??= lon;
      _emaAlt ??= alt;

      _emaLat = _kEmaAlpha * lat + (1.0 - _kEmaAlpha) * _emaLat!;
      _emaLon = _kEmaAlpha * lon + (1.0 - _kEmaAlpha) * _emaLon!;
      _emaAlt = _kEmaAlpha * alt + (1.0 - _kEmaAlpha) * _emaAlt!;

      lat = _emaLat!;
      lon = _emaLon!;
      alt = _emaAlt!;
    }

    final double speed = pos.speed >= 0 ? pos.speed : -1.0;
    final double heading =
        (speed >= kMinHeadingSpeedMs && pos.headingAccuracy >= 0)
            ? pos.heading
            : -1.0;

    final simPos = SimPosition(
      latitude: lat,
      longitude: lon,
      altitude: alt,
      accuracy: pos.accuracy,
      heading: heading,
      speed: speed,
      isAccurate: isAccurate,
    );

    _updateFixStatus(_computeFixStatus(pos.accuracy, isAccurate));
    if (!_controller.isClosed) _controller.add(simPos);
  }

  // ── External RTK (Bluetooth) ────────────────────────────────────────────────

  /// Uruchamia odbiór z [BluetoothGnssService] i podpina go pod ten sam
  /// [positionStream]/[fixStatus], co GPS telefonu — reszta aplikacji
  /// (map_view, work_mode_view, FFI przez NavBridge) nie widzi różnicy.
  void _startExternalRtk() {
    final address = rtkDeviceAddress;
    if (address == null) {
      // Użytkownik nie wybrał jeszcze urządzenia — ekran ustawień GPS musi
      // pokazać wybór urządzenia; nie ma tu nic do połączenia.
      _updateFixStatus(GpsFixStatus.inactive);
      return;
    }

    _gnssPosSub =
        BluetoothGnssService.instance.positionStream.listen(_onGnssPosition);

    // statusStream (nie positionStream!) napędza fixStatus, bo emituje też
    // przy braku fixa (quality=0), kiedy nie ma jeszcze współrzędnych do
    // wyemitowania jako SimPosition — patrz dokumentacja tego streamu.
    _gnssQualitySub = BluetoothGnssService.instance.statusStream.listen(
      (status) => _updateFixStatus(_mapGnssFixQuality(status.fixQuality)),
    );

    // Gdy łącze BT padnie/ponawia próbę, ostatni znany fixStatus (np.
    // "rtkFixed") byłby mylący — cofamy do "searching", dopóki nie
    // przyjdzie nowe GGA po odzyskaniu połączenia.
    _gnssLinkSub = BluetoothGnssService.instance.linkStateStream.listen(
      (state) {
        if (state != BtLinkState.connected) {
          _updateFixStatus(GpsFixStatus.searching);
        }
      },
    );

    // Most RTCM: NtripClientService nie zna Bluetootha, BluetoothGnssService
    // nie zna NTRIP — to połączenie jest jedynym miejscem, które wie o obu.
    _rtcmSub = NtripClientService.instance.rtcmStream.listen(
      (bytes) => BluetoothGnssService.instance.writeRtcm(bytes),
    );

    BluetoothGnssService.instance.connect(address);
    // Fire-and-forget: po cichu nic nie robi, jeśli konfiguracja NTRIP jest
    // niekompletna (użytkownik jeszcze nie wypełnił formularza).
    _startNtripIfConfigured();
  }

  void _stopExternalRtk() {
    _gnssPosSub?.cancel();
    _gnssPosSub = null;
    _gnssQualitySub?.cancel();
    _gnssQualitySub = null;
    _gnssLinkSub?.cancel();
    _gnssLinkSub = null;
    _rtcmSub?.cancel();
    _rtcmSub = null;
    BluetoothGnssService.instance.disconnect();
    NtripClientService.instance.disconnect();
  }

  void _onGnssPosition(GnssPosition pos) {
    // Most GGA: NTRIP (usługi sieciowe/VRS) potrzebuje okresowo naszej
    // przybliżonej pozycji, żeby interpolować poprawki — patrz
    // NtripClientService.updatePosition.
    NtripClientService.instance.updatePosition(pos);
    if (!_controller.isClosed) _controller.add(_fromGnss(pos));
  }

  /// Mapuje [GnssPosition] (parsowana NMEA) na [SimPosition] — DOKŁADNIE ten
  /// sam typ, który emituje ścieżka GPS telefonu. To jest cały "klej"
  /// pozwalający reszcie aplikacji (włącznie z FFI/NavBridge) działać bez
  /// zmian niezależnie od źródła pozycji.
  ///
  /// NMEA nie podaje dokładności w metrach wprost — [accuracy] jest więc
  /// szacowana z [GnssFixQuality] (typowe wartości dla ZED-F9P). Dzięki temu
  /// istniejący próg [kMaxAccuracyM] i gate `isAccurate` w map_view/
  /// work_mode_view działają bez żadnych zmian również dla RTK.
  SimPosition _fromGnss(GnssPosition pos) {
    final isAccurate = pos.fixQuality == GnssFixQuality.rtkFixed ||
        pos.fixQuality == GnssFixQuality.rtkFloat ||
        pos.fixQuality == GnssFixQuality.dgps;

    final double accuracy = switch (pos.fixQuality) {
      GnssFixQuality.rtkFixed => 0.02,
      GnssFixQuality.rtkFloat => 0.4,
      GnssFixQuality.dgps => 2.0,
      GnssFixQuality.gps => 8.0,
      GnssFixQuality.noFix => 9999.0,
    };

    return SimPosition(
      latitude: pos.latitude,
      longitude: pos.longitude,
      altitude: pos.altitude,
      accuracy: accuracy,
      heading: pos.heading,
      speed: pos.speed,
      isAccurate: isAccurate,
    );
  }

  GpsFixStatus _mapGnssFixQuality(GnssFixQuality quality) => switch (quality) {
        GnssFixQuality.noFix => GpsFixStatus.searching,
        GnssFixQuality.gps => GpsFixStatus.gps,
        GnssFixQuality.dgps => GpsFixStatus.dgps,
        GnssFixQuality.rtkFloat => GpsFixStatus.rtkFloat,
        GnssFixQuality.rtkFixed => GpsFixStatus.rtkFixed,
      };

  // ── Permissions ──────────────────────────────────────────────────────────────

  /// Request all required location permissions.
  ///
  /// Returns `true` when the app may use precise location.
  Future<bool> requestPermissions(BuildContext context) async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (context.mounted) {
        await _showDialog(
          context,
          title: 'Lokalizacja wyłączona',
          message: 'Usługa lokalizacji jest wyłączona na tym urządzeniu. '
              'Włącz GPS w ustawieniach systemu, aby korzystać z nawigacji.',
          onSettings: () => Geolocator.openLocationSettings(),
        );
      }
      return false;
    }

    LocationPermission permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.deniedForever) {
      if (context.mounted) {
        await _showDialog(
          context,
          title: 'Brak dostępu do GPS',
          message: 'AgriNav nie ma uprawnień do lokalizacji. '
              'Przyznaj dostęp w Ustawieniach → Aplikacje → AgriNav → Uprawnienia.',
          onSettings: () => Geolocator.openAppSettings(),
        );
      }
      permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.deniedForever ||
          permission == LocationPermission.denied) {
        return false;
      }
    }

    if (permission == LocationPermission.denied) return false;

    if (permission == LocationPermission.whileInUse) {
      final always = await Geolocator.requestPermission();
      if (always == LocationPermission.always) {
        permission = LocationPermission.always;
      }
    }

    return permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse;
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

  GpsFixStatus _computeFixStatus(double accuracyM, bool isAccurate) {
    if (!isAccurate || accuracyM <= 0) return GpsFixStatus.searching;
    if (accuracyM < 5.0) return GpsFixStatus.dgps;
    return GpsFixStatus.gps;
  }

  Future<void> _showDialog(
    BuildContext context, {
    required String title,
    required String message,
    required VoidCallback onSettings,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Anuluj'),
          ),
          FilledButton.icon(
            onPressed: () {
              Navigator.of(context).pop();
              onSettings();
            },
            icon: const Icon(Icons.settings),
            label: const Text('Ustawienia'),
          ),
        ],
      ),
    );
  }
}
