import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bluetooth_classic/bluetooth_classic.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import '../models/gnss_position.dart';

/// Standardowy UUID profilu SPP (Serial Port Profile) — ten sam dla
/// wszystkich urządzeń Bluetooth Classic, w tym modułu RTK. Nie jest to
/// sekret ani coś specyficznego dla ArduSimple — to stała ze specyfikacji
/// Bluetooth (Serial Port Profile), używana też np. przez HC-05/06.
const _kSppUuid = '00001101-0000-1000-8000-00805f9b34fb';

/// Stan połączenia Bluetooth z odbiornikiem RTK.
///
/// Osobny od [GnssFixQuality] — łącze może być `connected` (gniazdo BT
/// otwarte, dane płyną), a mimo to odbiornik może jeszcze nie mieć fixa
/// (`GnssFixQuality.noFix`). UI używa tego stanu do komunikatów o samym
/// połączeniu ("rozłączono, ponawiam próbę…"), a fixQuality do wskaźnika
/// dokładności.
enum BtLinkState { disconnected, connecting, connected, reconnecting }

/// Uproszczone info o sparowanym urządzeniu — tylko to, czego potrzebuje UI
/// wyboru odbiornika (nazwa do wyświetlenia, adres do zapisania/połączenia).
class BluetoothDeviceInfo {
  const BluetoothDeviceInfo({required this.name, required this.address});

  final String name;
  final String address;
}

/// Odbiera NMEA (`$..GGA`, `$..RMC`) z zewnętrznego odbiornika RTK po
/// Bluetooth Classic (SPP) i emituje sparsowane, zwalidowane pozycje.
///
/// Używa pakietu `bluetooth_classic` — łączy się z urządzeniami sparowanymi
/// w systemowych ustawieniach Bluetooth Androida ([pairedDevices]).
///
/// ### Ważny szczegół implementacji tego pakietu
/// `bluetooth_classic` udostępnia strumienie danych/statusu jako
/// pojedynczej-subskrypcji `Stream` (nie broadcast) na poziomie natywnego
/// EventChannel — można je nasłuchiwać tylko RAZ w całym cyklu życia
/// aplikacji. Dlatego subskrybujemy je raz w konstruktorze (singleton) i
/// NIGDY nie wołamy `.listen()` ponownie — cykl połącz/rozłącz/reconnect
/// steruje wyłącznie metodami `connect()`/`disconnect()` samego pakietu,
/// a nie ponownym nasłuchiwaniem strumieni.
///
/// ### Odporność na rozłączenia
/// Błąd połączenia albo zamknięcie łącza przez zdalne urządzenie (np.
/// wyładowany powerbank zasilający moduł, wyjście poza zasięg BT) —
/// wykrywane przez `onDeviceStatusChanged()` (status 0 = rozłączony) —
/// przełącza [linkState] na `reconnecting` i próbuje połączyć się ponownie
/// z rosnącym opóźnieniem (2s → 4s → 8s → maks. 15s), aż do sukcesu albo
/// wywołania [disconnect]. Żaden błąd nie wylatuje jako nieobsłużony wyjątek.
class BluetoothGnssService {
  BluetoothGnssService._() {
    // Patrz komentarz klasy — subskrybujemy TYLKO RAZ, na całe życie apki.
    _bt.onDeviceDataReceived().listen(_onBytes);
    _bt.onDeviceStatusChanged().listen(_onStatusChanged);
  }

  static final instance = BluetoothGnssService._();

  final _bt = BluetoothClassic();

  // ── Streamy publiczne ────────────────────────────────────────────────────────

  final _positionController = StreamController<GnssPosition>.broadcast();

  /// Kompletne pozycje (GGA o ważnym fixie, scalone z ostatnim RMC).
  Stream<GnssPosition> get positionStream => _positionController.stream;

  final _statusController = StreamController<GnssStatus>.broadcast();

  /// Status (jakość fixa + satelity + HDOP) z KAŻDEGO poprawnego
  /// strukturalnie zdania GGA — również gdy fix jest niedostępny (quality=0,
  /// brak współrzędnych). Dzięki temu UI może pokazać "brak fixa, ale widzę
  /// 6 satelitów" na żywo, mimo że w takiej sytuacji [positionStream] nic
  /// nie emituje (nie ma poprawnych współrzędnych). Przydatne do diagnozy:
  /// patrz dokumentacja [GnssStatus].
  Stream<GnssStatus> get statusStream => _statusController.stream;

  final _linkStateController = StreamController<BtLinkState>.broadcast();
  Stream<BtLinkState> get linkStateStream => _linkStateController.stream;

  BtLinkState _linkState = BtLinkState.disconnected;
  BtLinkState get linkState => _linkState;

  /// Ostatni błąd (połączenia/odczytu) — do pokazania w UI. Nie czyszczony
  /// automatycznie, tylko nadpisywany przy kolejnym zdarzeniu.
  String? lastError;

  /// `true` gdy ostatnie [pairedDevices] nie powiodło się konkretnie z
  /// powodu braku uprawnień (a nie np. błędu transmisji) — UI może wtedy
  /// pokazać przycisk wprost do Ustawień aplikacji zamiast ogólnego komunikatu.
  bool permissionDenied = false;

  /// Włącz TYLKO na czas diagnozowania problemów z odbiorem — loguje każdy
  /// pojedynczy pakiet bajtów z Bluetooth (surowy tekst) do konsoli.
  ///
  /// UWAGA: przy dużej częstotliwości danych (a zwłaszcza przy odbiorze
  /// samego binarnego szumu zamiast NMEA — wtedy pakiety lecą znacznie
  /// częściej niż normalne ~1-10 zdań/s) to realnie obciąża wątek UI i
  /// powoduje zauważalne lagi w aplikacji. Domyślnie wyłączone.
  bool debugLogRawBytes = false;

  // ── Stan wewnętrzny połączenia ──────────────────────────────────────────────

  bool _connected = false;
  Timer? _reconnectTimer;
  String? _address;
  bool _stopRequested = true;

  static const _initialReconnectDelay = Duration(seconds: 2);
  static const _maxReconnectDelay = Duration(seconds: 15);
  Duration _nextReconnectDelay = _initialReconnectDelay;

  // Bufor na niedokończone linie — Bluetooth dostarcza dane w dowolnych
  // kawałkach bajtów, niekoniecznie wyrównanych do końca linijki NMEA.
  final StringBuffer _lineBuffer = StringBuffer();

  // Ostatnie dane z RMC (prędkość/kurs), łączone z kolejnym GGA. NMEA GGA
  // i RMC to dwa osobne zdania z tej samej "epoki" pomiaru — RMC nie niesie
  // pozycji/jakości fixa, GGA nie niesie prędkości/kursu.
  RmcData? _lastRmc;
  DateTime? _lastRmcTime;
  static const _rmcMaxAge = Duration(seconds: 3);

  // ── Lista sparowanych urządzeń ──────────────────────────────────────────────

  static const _kPermissionMessage =
      'Brak uprawnień Bluetooth. Otwórz Ustawienia → Aplikacje → AgriNav → '
      'Uprawnienia i włącz Bluetooth (oraz lokalizację — Android wymaga jej '
      'do wykrywania urządzeń Bluetooth, nawet jeśli nie skanujemy).';

  /// Zwraca urządzenia już sparowane w systemie (Ustawienia → Bluetooth).
  /// Pusta lista przy błędzie — powód trafia do [lastError], a
  /// [permissionDenied] mówi czy to konkretnie kwestia uprawnień (UI może
  /// wtedy zaproponować przejście do Ustawień zamiast ogólnego komunikatu).
  ///
  /// UWAGA: `bluetooth_classic.initPermissions()` — w odróżnieniu od tego,
  /// czego można by się spodziewać — nie zwraca `false` gdy użytkownik
  /// odmówi zgody, tylko RZUCA wyjątek (`PlatformException`). Dlatego to
  /// wywołanie ma OSOBNY blok try/catch, żeby dało się rozróżnić "odmowa
  /// uprawnień" od "coś innego padło przy pobieraniu listy".
  Future<List<BluetoothDeviceInfo>> pairedDevices() async {
    permissionDenied = false;

    bool granted;
    try {
      granted = await _bt.initPermissions();
    } catch (e) {
      debugPrint('[BluetoothGnssService] initPermissions() rzuciło: $e');
      permissionDenied = true;
      lastError = _kPermissionMessage;
      return [];
    }

    if (!granted) {
      permissionDenied = true;
      lastError = _kPermissionMessage;
      return [];
    }

    try {
      final devices = await _bt.getPairedDevices();
      return devices
          .map((d) => BluetoothDeviceInfo(
                name: (d.name != null && d.name!.isNotEmpty)
                    ? d.name!
                    : d.address,
                address: d.address,
              ))
          .toList();
    } catch (e) {
      debugPrint('[BluetoothGnssService] getPairedDevices() rzuciło: $e');
      lastError = 'Nie udało się pobrać listy sparowanych urządzeń: $e';
      return [];
    }
  }

  // ── Połączenie ───────────────────────────────────────────────────────────────

  /// Łączy się z urządzeniem o podanym adresie MAC. Bezpieczne wywołać
  /// ponownie z nowym adresem — zamyka poprzednie połączenie.
  Future<void> connect(String address) async {
    disconnect();
    _stopRequested = false;
    _address = address;
    _nextReconnectDelay = _initialReconnectDelay;
    await _attemptConnect();
  }

  /// Zamyka połączenie i zatrzymuje automatyczne próby ponownego łączenia.
  void disconnect() {
    _stopRequested = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _safeNativeDisconnect();
    _lineBuffer.clear();
    _lastRmc = null;
    _lastRmcTime = null;
    _setLinkState(BtLinkState.disconnected);
  }

  /// `bluetooth_classic.disconnect()` rzuca po stronie natywnej, jeśli nie
  /// ma aktywnego połączenia (`thread!!` na nullu) — więc wołamy je TYLKO
  /// gdy wiemy, że jesteśmy połączeni, i tak czy inaczej łapiemy błąd.
  void _safeNativeDisconnect() {
    if (!_connected) return;
    _connected = false;
    _bt.disconnect().catchError((_) => false);
  }

  Future<void> _attemptConnect() async {
    if (_stopRequested || _address == null) return;
    _setLinkState(
      _linkState == BtLinkState.disconnected
          ? BtLinkState.connecting
          : BtLinkState.reconnecting,
    );

    try {
      final ok = await _bt.connect(_address!, _kSppUuid);
      if (_stopRequested) {
        _safeNativeDisconnect();
        return;
      }
      if (!ok) throw Exception('Urządzenie odrzuciło połączenie');

      _connected = true;
      _nextReconnectDelay = _initialReconnectDelay;
      lastError = null;
      _setLinkState(BtLinkState.connected);
    } catch (e) {
      _connected = false;
      lastError = 'Nie udało się połączyć: $e';
      _scheduleReconnect();
    }
  }

  /// Status wg [Device]: 0 = rozłączony, 1 = łączenie, 2 = połączony.
  /// Jedyny sposób, żeby wykryć rozłączenie, które nastąpiło W TRAKCIE
  /// działającej sesji (np. moduł wyjechał poza zasięg) — [_attemptConnect]
  /// wykrywa tylko błędy PRZY nawiązywaniu połączenia.
  void _onStatusChanged(int status) {
    if (status != 0 || _stopRequested || !_connected) return;
    _connected = false;
    lastError = 'Połączenie Bluetooth zostało przerwane';
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_stopRequested) return;
    _setLinkState(BtLinkState.reconnecting);
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(_nextReconnectDelay, _attemptConnect);
    final doubled = _nextReconnectDelay * 2;
    _nextReconnectDelay =
        doubled > _maxReconnectDelay ? _maxReconnectDelay : doubled;
  }

  void _setLinkState(BtLinkState state) {
    _linkState = state;
    if (!_linkStateController.isClosed) _linkStateController.add(state);
  }

  // ── Parsowanie strumienia bajtów ────────────────────────────────────────────

  /// Bufor linii nie powinien nigdy urosnąć do rozmiaru zdania NMEA razy
  /// kilka — jeśli to się dzieje, to znak, że nigdy nie znaleźliśmy `\n`
  /// (np. moduł kończy linie inaczej niż oczekujemy, albo to w ogóle nie
  /// jest tekst NMEA), więc bufor rósłby w nieskończoność.
  static const _kMaxLineBufferLength = 4096;

  void _onBytes(Uint8List chunk) {
    // NMEA to czysty ASCII — dekodujemy permisywnie, żeby pojedynczy
    // uszkodzony bajt (kolizja transmisji BT) nie zablokował całego bufora.
    final text = ascii.decode(chunk, allowInvalid: true);
    // Kosztowne (replaceAll na każdym pakiecie) — tylko gdy jawnie włączone,
    // patrz dokumentacja [debugLogRawBytes].
    if (debugLogRawBytes) {
      debugPrint('[BluetoothGnssService] RX ${chunk.length}B: '
          '${text.replaceAll('\r', '\\r').replaceAll('\n', '\\n')}');
    }

    _lineBuffer.write(text);

    final combined = _lineBuffer.toString();
    final lines = combined.split('\n');
    // Ostatni fragment to niedokończona linia (albo pusty string) —
    // zostaje w buforze do uzupełnienia kolejnym pakietem bajtów.
    _lineBuffer
      ..clear()
      ..write(lines.removeLast());

    if (_lineBuffer.length > _kMaxLineBufferLength) {
      if (debugLogRawBytes) {
        debugPrint('[BluetoothGnssService] bufor linii przekroczył '
            '$_kMaxLineBufferLength znaków bez "\\n" — czyszczę. Możliwe, że '
            'moduł nie kończy linii znakiem nowej linii, albo to nie jest '
            'tekst NMEA.');
      }
      _lineBuffer.clear();
    }

    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      _handleLine(line);
    }
  }

  void _handleLine(String line) {
    final gga = parseGga(line);
    if (gga != null) {
      _onGga(gga);
      return;
    }
    final rmc = parseRmc(line);
    if (rmc != null) {
      _lastRmc = rmc;
      _lastRmcTime = DateTime.now();
      return;
    }
    // Inne zdania (GSA, GSV, VTG) są prawidłowym NMEA, ale nas nie
    // interesują — logujemy tylko żeby potwierdzić że linia w ogóle
    // wygląda jak NMEA (zaczyna się od '$'), inaczej pomijamy po cichu.
    if (debugLogRawBytes && line.startsWith(r'$')) {
      debugPrint('[BluetoothGnssService] linia NMEA (nie GGA/RMC lub zła '
          'checksuma): $line');
    }
  }

  void _onGga(GgaData gga) {
    debugPrint('[BluetoothGnssService] GGA: fix=${gga.fixQuality} '
        'sats=${gga.satellitesCount} hdop=${gga.hdop}');

    // Status aktualizujemy zawsze — nawet przy braku fixa (quality=0, gdy
    // latitude/longitude/altitude są null), żeby UI mogło pokazać "brak
    // fixa, widzę N satelitów" na żywo (patrz dokumentacja [statusStream]).
    if (!_statusController.isClosed) {
      _statusController.add(GnssStatus(
        fixQuality: gga.fixQuality,
        satellitesCount: gga.satellitesCount,
        hdop: gga.hdop,
      ));
    }
    if (gga.fixQuality == GnssFixQuality.noFix) return;
    if (gga.latitude == null || gga.longitude == null || gga.altitude == null) {
      return; // zdanie strukturalnie OK, ale bez faktycznej pozycji
    }

    final now = DateTime.now();
    final rmc = (_lastRmcTime != null &&
            now.difference(_lastRmcTime!) <= _rmcMaxAge)
        ? _lastRmc
        : null;

    final position = GnssPosition(
      latitude: gga.latitude!,
      longitude: gga.longitude!,
      altitude: gga.altitude!,
      fixQuality: gga.fixQuality,
      satellitesCount: gga.satellitesCount,
      hdop: gga.hdop,
      timestamp: now,
      heading: rmc?.heading ?? -1.0,
      speed: rmc?.speed ?? -1.0,
    );

    if (!_positionController.isClosed) _positionController.add(position);
  }
}
