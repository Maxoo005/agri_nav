import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

import '../models/gnss_position.dart';

/// Stan połączenia z serwerem (casterem) NTRIP.
///
/// Osobny od [BtLinkState] w `bluetooth_gnss_service.dart`, choć oba
/// startują/kończą się razem — patrz [GpsLocationService]. `authError`
/// (złe dane logowania) i `networkError` (zły mountpoint / nieoczekiwana
/// odpowiedź serwera) NIE próbują automatycznego reconnectu — to błędy
/// konfiguracji, powtarzanie tej samej próby w kółko nic by nie dało.
/// Prawdziwe zerwania sieci (`disconnected`→`reconnecting`) próbują ponownie
/// z rosnącym opóźnieniem, tak jak [BluetoothGnssService].
enum NtripState {
  disconnected,
  connecting,
  connected,
  reconnecting,
  authError,
  networkError,
}

/// Dane dostępowe do serwera NTRIP. ASG-EUPOS (i większość sieciowych
/// usług RTK w Polsce) wymaga loginu w formacie `NazwaFirmy/Użytkownik`
/// (konkatenacja z ukośnikiem) — stąd [loginString] zamiast osobnych pól
/// przy budowaniu nagłówka Authorization.
class NtripConfig {
  const NtripConfig({
    required this.host,
    required this.port,
    required this.company,
    required this.username,
    required this.password,
    required this.mountpoint,
  });

  final String host;
  final int port;
  final String company;
  final String username;
  final String password;
  final String mountpoint;

  String get loginString => '$company/$username';
}

/// Klient NTRIP (v2, przez zwykłe TCP — `dart:io` `Socket`) — łączy się z
/// serwerem poprawek RTK, uwierzytelnia, i strumieniuje binarne pakiety
/// RTCM3 przez [rtcmStream].
///
/// ### Luźne powiązanie z Bluetooth (celowo)
/// Ten serwis NIC nie wie o Bluetooth ani o [BluetoothGnssService] — emituje
/// tylko surowe bajty RTCM3 na [rtcmStream] i przyjmuje pozycję przez
/// [updatePosition]. To [GpsLocationService] spina oba serwisy (przekazuje
/// RTCM z tego streamu do `BluetoothGnssService.writeRtcm`, i woła
/// [updatePosition] za każdym razem gdy przyjdzie nowy [GnssPosition] z
/// Bluetootha) — dzięki temu żaden z dwóch serwisów nie zna szczegółów
/// drugiego.
///
/// ### Protokół (skrót)
/// 1. Otwieramy TCP do `host:port`.
/// 2. Wysyłamy `GET /{mountpoint} HTTP/1.1` z nagłówkiem `Authorization:
///    Basic base64(login:hasło)`.
/// 3. Serwer odpowiada linią statusu (`ICY 200 OK` / `HTTP/1.1 200 OK` przy
///    sukcesie, `401` przy złych danych, albo `SOURCETABLE 200 OK` gdy
///    mountpoint nie istnieje) + nagłówkami + pustą linią.
/// 4. Po pustej linii WSZYSTKO co przychodzi to już surowy strumień RTCM3
///    (binarny, nie tekstowy) — przekazujemy 1:1 na [rtcmStream].
/// 5. Co [_ggaInterval] wysyłamy do serwera własne `$GPGGA` (zbudowane z
///    ostatniej znanej pozycji) — wymóg protokołu dla usług sieciowych/VRS,
///    serwer na tej podstawie interpoluje poprawki dla najbliższej
///    wirtualnej stacji referencyjnej.
class NtripClientService {
  NtripClientService._();

  static final instance = NtripClientService._();

  // ── Streamy publiczne ────────────────────────────────────────────────────────

  final _rtcmController = StreamController<Uint8List>.broadcast();

  /// Surowe pakiety RTCM3 gotowe do przekazania odbiornikowi GNSS.
  Stream<Uint8List> get rtcmStream => _rtcmController.stream;

  final _stateController = StreamController<NtripState>.broadcast();
  Stream<NtripState> get stateStream => _stateController.stream;

  NtripState _state = NtripState.disconnected;
  NtripState get state => _state;

  /// Ostatni błąd — do pokazania w UI. Nie czyszczony automatycznie, tylko
  /// nadpisywany przy kolejnym zdarzeniu.
  String? lastError;

  // ── Stan wewnętrzny ──────────────────────────────────────────────────────────

  Socket? _socket;
  StreamSubscription<Uint8List>? _socketSub;
  Timer? _reconnectTimer;
  Timer? _ggaTimer;
  NtripConfig? _config;
  bool _stopRequested = true;

  bool _headerParsed = false;
  final BytesBuilder _headerBuffer = BytesBuilder(copy: false);

  /// Ostatnia znana pozycja — źródło dla wysyłanych zdań GGA. Aktualizowane
  /// z zewnątrz przez [updatePosition] (patrz [GpsLocationService]).
  GnssPosition? _lastPosition;

  static const _initialReconnectDelay = Duration(seconds: 3);
  static const _maxReconnectDelay = Duration(seconds: 30);
  Duration _nextReconnectDelay = _initialReconnectDelay;

  /// Odstęp wysyłki GGA do serwera — wymóg protokołu NTRIP dla usług
  /// sieciowych (VRS): 10-15s zgodnie ze specyfikacją zadania.
  static const _ggaInterval = Duration(seconds: 12);

  /// Nagłówek odpowiedzi serwera nie powinien być większy niż to — jeśli
  /// jest, to znak uszkodzonej/nieoczekiwanej odpowiedzi (zabezpieczenie
  /// przed buforem rosnącym w nieskończoność, analogicznie do
  /// `BluetoothGnssService._kMaxLineBufferLength`).
  static const _kMaxHeaderBytes = 8192;

  /// Aktualizuje pozycję używaną do budowania wysyłanych zdań GGA. Wołane
  /// przez [GpsLocationService] przy każdej nowej pozycji z odbiornika —
  /// ten serwis sam nie subskrybuje żadnego strumienia GPS.
  void updatePosition(GnssPosition pos) => _lastPosition = pos;

  // ── Lista mountpointów (source table) ───────────────────────────────────────

  /// Pobiera listę mountpointów z serwera NTRIP (tzw. source table) —
  /// osobne, jednorazowe połączenie TCP niezależne od [connect]/[disconnect].
  /// Zwraca pustą listę przy błędzie (powód w [lastError]).
  Future<List<String>> fetchMountpoints(String host, int port) async {
    Socket? socket;
    try {
      socket = await Socket.connect(host, port,
          timeout: const Duration(seconds: 10));

      final request = 'GET / HTTP/1.1\r\n'
          'Host: $host\r\n'
          'Ntrip-Version: Ntrip/2.0\r\n'
          'User-Agent: NTRIP AgriNav/1.0\r\n'
          'Connection: close\r\n'
          '\r\n';
      socket.write(request);

      final bytes = BytesBuilder(copy: false);
      await for (final chunk
          in socket.timeout(const Duration(seconds: 10))) {
        bytes.add(chunk);
      }

      final text = utf8.decode(bytes.takeBytes(), allowMalformed: true);
      final mountpoints = text
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.startsWith('STR;'))
          .map((line) => line.split(';'))
          .where((fields) => fields.length > 1)
          .map((fields) => fields[1])
          .toList();

      if (mountpoints.isEmpty) {
        lastError = 'Serwer odpowiedział, ale nie znaleziono żadnych '
            'mountpointów (linii "STR;...") w source table.';
      }
      return mountpoints;
    } catch (e) {
      lastError = 'Nie udało się pobrać listy mountpointów: $e';
      return [];
    } finally {
      socket?.destroy();
    }
  }

  // ── Połączenie (strumień poprawek) ──────────────────────────────────────────

  /// Łączy się z serwerem NTRIP i zaczyna strumieniować RTCM3 na
  /// [rtcmStream]. Bezpieczne wywołać ponownie z nową konfiguracją — zamyka
  /// poprzednie połączenie.
  Future<void> connect(NtripConfig config) async {
    disconnect();
    _stopRequested = false;
    _config = config;
    _nextReconnectDelay = _initialReconnectDelay;
    await _attemptConnect();
  }

  /// Zamyka połączenie i zatrzymuje automatyczne próby ponownego łączenia.
  void disconnect() {
    _stopRequested = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _teardownSocket();
    _setState(NtripState.disconnected);
  }

  void _teardownSocket() {
    _ggaTimer?.cancel();
    _ggaTimer = null;
    _socketSub?.cancel();
    _socketSub = null;
    _socket?.destroy();
    _socket = null;
    _headerParsed = false;
    _headerBuffer.clear();
  }

  Future<void> _attemptConnect() async {
    if (_stopRequested || _config == null) return;
    final config = _config!;
    _setState(
      _state == NtripState.disconnected
          ? NtripState.connecting
          : NtripState.reconnecting,
    );

    try {
      final socket = await Socket.connect(config.host, config.port,
          timeout: const Duration(seconds: 10));
      if (_stopRequested) {
        socket.destroy();
        return;
      }

      _socket = socket;
      _headerParsed = false;
      _headerBuffer.clear();

      final credentials = base64Encode(
        utf8.encode('${config.loginString}:${config.password}'),
      );
      final request = 'GET /${config.mountpoint} HTTP/1.1\r\n'
          'Host: ${config.host}\r\n'
          'Ntrip-Version: Ntrip/2.0\r\n'
          'User-Agent: NTRIP AgriNav/1.0\r\n'
          'Authorization: Basic $credentials\r\n'
          '\r\n';
      socket.write(request);

      _socketSub = socket.listen(
        _onSocketData,
        onError: (Object e) {
          lastError = 'Błąd połączenia NTRIP: $e';
          _handleUnexpectedDisconnect();
        },
        onDone: _handleUnexpectedDisconnect,
        cancelOnError: true,
      );
    } catch (e) {
      lastError = 'Nie udało się połączyć z serwerem NTRIP: $e';
      _scheduleReconnect();
    }
  }

  /// Rozłączenie, które NIE zostało zainicjowane przez [disconnect] —
  /// zerwane połączenie sieciowe albo serwer zamknął gniazdo. W
  /// odróżnieniu od błędów uwierzytelniania/mountpointu (patrz
  /// [_handleNtripResponseHeader]) tu PRÓBUJEMY ponownie — to zazwyczaj
  /// przejściowy problem sieci komórkowej.
  void _handleUnexpectedDisconnect() {
    _teardownSocket();
    if (_stopRequested) {
      _setState(NtripState.disconnected);
      return;
    }
    lastError ??= 'Połączenie z serwerem NTRIP zostało przerwane';
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_stopRequested) return;
    _setState(NtripState.reconnecting);
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(_nextReconnectDelay, _attemptConnect);
    final doubled = _nextReconnectDelay * 2;
    _nextReconnectDelay =
        doubled > _maxReconnectDelay ? _maxReconnectDelay : doubled;
  }

  void _setState(NtripState state) {
    _state = state;
    if (!_stateController.isClosed) _stateController.add(state);
  }

  // ── Odbiór odpowiedzi: nagłówek → potem czysty strumień RTCM3 ──────────────

  void _onSocketData(Uint8List chunk) {
    if (_headerParsed) {
      if (!_rtcmController.isClosed) _rtcmController.add(chunk);
      return;
    }

    _headerBuffer.add(chunk);
    final buffered = _headerBuffer.toBytes();
    final sepIndex = _indexOfCrLfCrLf(buffered);

    if (sepIndex == -1) {
      if (buffered.length > _kMaxHeaderBytes) {
        lastError = 'Serwer NTRIP nie odpowiedział poprawnym nagłówkiem '
            '(brak końca nagłówka mimo ${buffered.length} odebranych bajtów).';
        _handleUnexpectedDisconnect();
      }
      return;
    }

    final headerText =
        ascii.decode(buffered.sublist(0, sepIndex), allowInvalid: true);
    final remainder = Uint8List.sublistView(buffered, sepIndex + 4);
    _headerBuffer.clear();
    _headerParsed = true;

    _handleNtripResponseHeader(headerText, remainder);
  }

  void _handleNtripResponseHeader(String headerText, Uint8List remainder) {
    final firstLine = headerText.split('\r\n').first.trim();
    debugPrint('[NtripClientService] odpowiedź serwera: $firstLine');

    if (firstLine.contains('401')) {
      lastError = 'Serwer NTRIP odrzucił login/hasło (401 Unauthorized). '
          'Sprawdź format loginu (Firma/Użytkownik) i hasło.';
      _setState(NtripState.authError);
      _teardownSocket();
      return;
    }

    if (firstLine.startsWith('SOURCETABLE')) {
      lastError = 'Serwer zwrócił listę mountpointów zamiast strumienia '
          'poprawek — sprawdź, czy mountpoint "${_config?.mountpoint}" '
          'faktycznie istnieje na tym serwerze.';
      _setState(NtripState.networkError);
      _teardownSocket();
      return;
    }

    if (!firstLine.contains('200')) {
      lastError = 'Nieoczekiwana odpowiedź serwera NTRIP: $firstLine';
      _setState(NtripState.networkError);
      _scheduleReconnect();
      return;
    }

    // Sukces — od teraz to czysty strumień RTCM3.
    lastError = null;
    _nextReconnectDelay = _initialReconnectDelay;
    _setState(NtripState.connected);
    _startGgaTimer();
    if (remainder.isNotEmpty && !_rtcmController.isClosed) {
      _rtcmController.add(remainder);
    }
  }

  /// Szuka bajtowej sekwencji `\r\n\r\n` (koniec nagłówków HTTP/NTRIP).
  int _indexOfCrLfCrLf(Uint8List bytes) {
    for (int i = 0; i + 3 < bytes.length; i++) {
      if (bytes[i] == 13 &&
          bytes[i + 1] == 10 &&
          bytes[i + 2] == 13 &&
          bytes[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }

  // ── Wysyłka GGA (wymóg protokołu dla usług sieciowych/VRS) ─────────────────

  void _startGgaTimer() {
    _ggaTimer?.cancel();
    _sendGga(); // od razu po połączeniu — caster potrzebuje pozycji zanim
    // zacznie liczyć poprawki dla najbliższej wirtualnej stacji.
    _ggaTimer = Timer.periodic(_ggaInterval, (_) => _sendGga());
  }

  void _sendGga() {
    final pos = _lastPosition;
    final socket = _socket;
    if (pos == null || socket == null) return;
    try {
      socket.write(buildGgaSentence(pos));
    } catch (e) {
      debugPrint('[NtripClientService] wysyłka GGA nie powiodła się: $e');
    }
  }
}
