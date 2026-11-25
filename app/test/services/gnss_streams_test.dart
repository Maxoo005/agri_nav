import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agri_nav/models/gnss_position.dart';
import 'package:agri_nav/services/bluetooth_gnss_service.dart';
import 'package:agri_nav/services/ntrip_client_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_support.dart';

const _bt = 'com.matteogassend/bluetooth_classic';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  group('BluetoothGnssService (mock kanałów, bez sprzętu)', () {
    late MockStreamHandlerEventSink data;
    late MockStreamHandlerEventSink status;
    late BluetoothGnssService s;
    final calls = <String>[];

    setUp(() {
      final m = binding.defaultBinaryMessenger;
      m.setMockMethodCallHandler(const MethodChannel(_bt), (c) async {
        calls.add(c.method);
        if (c.method == 'getDevices') {
          return [
            {'name': 'RTK', 'address': 'AA'},
            {'name': '', 'address': 'BB'},
          ];
        }
        return true;
      });
    });

    setUpAll(() async {
      final m = binding.defaultBinaryMessenger;
      m.setMockStreamHandler(const EventChannel('$_bt/read'),
          MockStreamHandler.inline(onListen: (_, sink) => data = sink));
      m.setMockStreamHandler(const EventChannel('$_bt/status'),
          MockStreamHandler.inline(onListen: (_, sink) => status = sink));
      s = BluetoothGnssService.instance;
      await pumpEventQueue();
    });

    tearDown(() => s.disconnect());

    Future<List<GnssPosition>> feed(List<String> chunks) async {
      final out = <GnssPosition>[];
      final sub = s.positionStream.listen(out.add);
      for (final c in chunks) {
        data.success(Uint8List.fromList(latin1.encode(c)));
      }
      await pumpEventQueue();
      await sub.cancel();
      return out;
    }

    final gga = nmea('GNGGA,1,5213.7247,N,01730.0,E,4,12,0.5,101.0,M,,M,,');
    final rmc = nmea('GNRMC,1,A,5213.7,N,01730.0,E,10.0,45.0,010525,,,A');

    test('składa linie pocięte na dowolne pakiety i łączy z RMC', () async {
      final text = '$rmc\r\n$gga\r\n';
      final out = await feed([
        text.substring(0, 7),
        text.substring(7, 90),
        text.substring(90),
      ]);
      expect(out.single.latitude, closeTo(52.228745, 1e-7));
      expect(out.single.heading, closeTo(45, 1e-9));
      expect(out.single.speed, closeTo(5.14444, 1e-6));
      expect(out.single.fixQuality, GnssFixQuality.rtkFixed);
    });

    test('bez RMC kurs i prędkość = -1', () async {
      final out = await feed(['$gga\r\n']);
      expect(out.single.heading, closeTo(-1, 1e-12));
      expect(out.single.speed, closeTo(-1, 1e-12));
    });

    test('uszkodzone bajty i obce zdania nie blokują strumienia', () async {
      final out = await feed([
        '\xff\xfe\x00garbage\n',
        '${gga.replaceFirst('5213', '5214')}\n', // zła suma
        '${nmea('GNGSA,A,3')}\n\n',
        '$gga\n',
      ]);
      expect(out, hasLength(1));
    });

    test('zalew bez znaku nowej linii nie rośnie w nieskończoność', () async {
      final out = await feed(['x' * 5000, '\n$gga\n']);
      expect(out, hasLength(1));
    });

    test('brak fixa: status tak, pozycja nie', () async {
      final st = s.statusStream.first;
      final out = await feed(['${nmea('GNGGA,1,,,,,0,06,99.9,,M,,M,,')}\n']);
      expect(out, isEmpty);
      expect((await st).satellitesCount, 6);
    });

    test('połączenie, zapis RTCM, zerwanie łącza', () async {
      calls.clear();
      await s.writeRtcm(Uint8List(3)); // rozłączony → cicho ignorowane
      expect(calls, isNot(contains('writeBytes')));
      await s.connect('AA');
      expect(s.linkState, BtLinkState.connected);
      await s.writeRtcm(Uint8List(3));
      expect(calls, contains('writeBytes'));
      status.success(0);
      await pumpEventQueue();
      expect(s.linkState, BtLinkState.reconnecting);
      expect(s.lastError, isNotNull);
      s.disconnect();
      expect(s.linkState, BtLinkState.disconnected);
    });

    test('lista sparowanych: pusta nazwa → adres', () async {
      final d = await s.pairedDevices();
      expect(d.map((x) => x.name), ['RTK', 'BB']);
      expect(s.permissionDenied, isFalse);
    });

    test('odmowa uprawnień', () async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel(_bt), (c) async => false);
      expect(await s.pairedDevices(), isEmpty);
      expect(s.permissionDenied, isTrue);
    });
  });

  // Tylko loopback z portem efemerycznym — bez sieci zewnętrznej.
  group('NtripClientService (lokalny caster)', () {
    final n = NtripClientService.instance;
    late ServerSocket server;
    final requests = <String>[];
    late void Function(Socket) onRequest;

    setUp(() async {
      requests.clear();
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((c) {
        var answered = false;
        c.listen((b) {
          requests.add(latin1.decode(b));
          if (!answered) {
            answered = true;
            onRequest(c);
          }
        }, onError: (_) {});
        c.done.ignore();
      });
      addTearDown(() async {
        n.disconnect();
        await server.close();
      });
    });

    Future<void> connect() => n.connect(NtripConfig(
          host: '127.0.0.1',
          port: server.port,
          company: 'Firma',
          username: 'jan',
          password: 'sekret',
          mountpoint: 'RTN',
        ));

    Future<void> waitState(NtripState st) async {
      if (n.state == st) return;
      await n.stateStream
          .firstWhere((x) => x == st)
          .timeout(const Duration(seconds: 5));
    }

    test('sukces: nagłówek odcięty, RTCM przekazany, GGA wysłane', () async {
      n.updatePosition(GnssPosition(
        latitude: 52,
        longitude: 17,
        altitude: 100,
        fixQuality: GnssFixQuality.gps,
        satellitesCount: 8,
        hdop: 1,
        timestamp: DateTime.utc(2025),
      ));
      onRequest =
          (c) => c.add([...ascii.encode('ICY 200 OK\r\n\r\n'), 0xD3, 0, 1]);
      final rtcm = n.rtcmStream.first;
      await connect();
      expect(await rtcm.timeout(const Duration(seconds: 5)), [0xD3, 0, 1]);
      expect(n.state, NtripState.connected);
      expect(requests.first, startsWith('GET /RTN HTTP/1.1\r\n'));
      expect(requests.first,
          contains('Basic ${base64Encode(utf8.encode('Firma/jan:sekret'))}'));
      while (!requests.join().contains(r'$GPGGA')) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      n.disconnect();
      expect(n.state, NtripState.disconnected);
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('401 → authError bez ponawiania', () async {
      onRequest = (c) => c.write('HTTP/1.1 401 Unauthorized\r\n\r\n');
      await connect();
      await waitState(NtripState.authError);
      expect(n.lastError, contains('401'));
    });

    test('SOURCETABLE → networkError', () async {
      onRequest = (c) => c.write('SOURCETABLE 200 OK\r\n\r\n');
      await connect();
      await waitState(NtripState.networkError);
      expect(n.lastError, contains('RTN'));
    });

    test('nagłówek bez końca → przerwanie', () async {
      onRequest = (c) => c.write('x' * 9000);
      await connect();
      await waitState(NtripState.reconnecting);
      expect(n.lastError, isNotNull);
    });

    test('lista mountpointów', () async {
      onRequest = (c) {
        c.write(
            'SOURCETABLE 200 OK\r\n\r\nCAS;x\r\nSTR;A;..\r\nSTR;B\r\nSTR;\r\n');
        c.close();
      };
      expect(
          await n.fetchMountpoints('127.0.0.1', server.port), ['A', 'B', '']);
      onRequest = (c) => c.close();
      expect(await n.fetchMountpoints('127.0.0.1', server.port), isEmpty);
      expect(n.lastError, contains('mountpoint'));
    });

    for (final status in [
      'HTTP/1.1 404 Not Found',
      'HTTP/1.1 503 wait 200 s'
    ]) {
      test('treść odpowiedzi „$status” nie trafia do odbiornika', () async {
        final got = <int>[];
        final sub = n.rtcmStream.listen(got.addAll);
        addTearDown(sub.cancel);
        final sent = Completer<void>();
        onRequest = (c) async {
          c.write('$status\r\n\r\n<html>');
          await c.flush();
          // Osobny pakiet TCP — treść dochodzi po nagłówku.
          await Future<void>.delayed(const Duration(milliseconds: 100));
          try {
            c.write('<html>blad</html>');
            await c.flush();
          } catch (_) {
            // Klient zamknął gniazdo — dokładnie tego oczekujemy.
          }
          sent.complete();
        };
        await connect();
        await waitState(NtripState.reconnecting);
        await sent.future;
        await pumpEventQueue();
        expect(got, isEmpty);
        expect(n.lastError, contains(status));
      });
    }

    final frame = [0xD3, 0x00, 0x04, 1, 2, 3, 4, 9, 9, 9];

    /// Łączy się z casterem odpowiadającym [parts] (osobne pakiety TCP) i
    /// zwraca wszystko, co trafiłoby do odbiornika.
    Future<List<int>> serve(List<List<int>> parts, NtripState expected,
        {bool close = false}) async {
      final got = <int>[];
      final sub = n.rtcmStream.listen(got.addAll);
      addTearDown(sub.cancel);
      final sent = Completer<void>();
      onRequest = (c) async {
        try {
          for (final p in parts) {
            c.add(p);
            await c.flush();
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          if (close) c.destroy();
        } catch (_) {
          // Klient zamknął gniazdo.
        }
        sent.complete();
      };
      await connect();
      await waitState(expected);
      await sent.future;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return got;
    }

    group('strumień poprawny', () {
      for (final (name, header) in [
        ('v1 z pustą linią', 'ICY 200 OK\r\n\r\n'),
        ('v1 bez pustej linii', 'ICY 200 OK\r\n'),
        (
          'v2',
          'HTTP/1.1 200 OK\r\nNtrip-Version: Ntrip/2.0\r\n'
              'CONTENT-type:  GNSS/Data; x=1\r\n\r\n'
        ),
        ('HTTP bez typu treści', 'HTTP/1.0 200 OK\r\nServer: x\r\n\r\n'),
      ]) {
        test('$name — jeden pakiet', () async {
          final got = await serve([
            [...ascii.encode(header), ...frame],
            [1, 2, 3],
          ], NtripState.connected);
          expect(got, [...frame, 1, 2, 3]);
          expect(n.lastError, isNull);
        });

        test('$name — nagłówek i dane osobno', () async {
          final got = await serve([
            ascii.encode(header.substring(0, 5)),
            ascii.encode(header.substring(5)),
            frame,
          ], NtripState.connected);
          expect(got, frame);
        });
      }
    });

    group('odpowiedź niebędąca strumieniem', () {
      const table = 'STR;RTN;Polska;RTCM 3.2\r\nENDSOURCETABLE\r\n';

      test('sourcetable z kodem 200 → błąd mountpointu, bez ponawiania',
          () async {
        final got = await serve([
          ascii.encode('HTTP/1.1 200 OK\r\nNtrip-Version: Ntrip/2.0\r\n'
              'Content-Type: gnss/sourcetable\r\n\r\n$table'),
          ascii.encode(table),
        ], NtripState.networkError);
        expect(got, isEmpty);
        expect(n.state, NtripState.networkError);
        expect(n.lastError, contains('RTN'));
      });

      test('ICY z typem sourcetable też jest odrzucane', () async {
        final got = await serve([
          ascii.encode(
              'ICY 200 OK\r\nContent-Type: gnss/sourcetable\r\n\r\n$table'),
        ], NtripState.networkError);
        expect(got, isEmpty);
      });

      test('200 z HTML → czytelny błąd', () async {
        final got = await serve([
          ascii.encode('HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n'),
          ascii.encode('<html>portal</html>'),
        ], NtripState.reconnecting);
        expect(got, isEmpty);
        expect(n.lastError, contains('text/html'));
      });

      test('200 bez typu i bez RTCM3 → błąd', () async {
        final got = await serve([
          ascii.encode('HTTP/1.1 200 OK\r\n\r\n'),
          ascii.encode(table),
        ], NtripState.reconnecting);
        expect(got, isEmpty);
        expect(n.lastError, contains('RTCM3'));
      });

      test('401 z treścią → authError, nic do odbiornika', () async {
        final got = await serve([
          ascii.encode('HTTP/1.1 401 Unauthorized\r\n\r\n'),
          ascii.encode('denied'),
        ], NtripState.authError);
        expect(got, isEmpty);
        expect(n.state, NtripState.authError);
      });

      test('404 → błąd, nic do odbiornika', () async {
        final got = await serve([
          ascii.encode('HTTP/1.1 404 Not Found\r\n'
              'Content-Type: gnss/data\r\n\r\n'),
          frame,
        ], NtripState.reconnecting);
        expect(got, isEmpty);
        expect(n.lastError, contains('404'));
      });
    });

    group('rozłączenie', () {
      test('w trakcie strumienia: dane przed zerwaniem są, potem ponawianie',
          () async {
        final got = await serve([
          [...ascii.encode('ICY 200 OK\r\n\r\n'), ...frame],
        ], NtripState.reconnecting, close: true);
        expect(got, frame);
        expect(n.lastError, isNotNull);
      });

      test('w trakcie nagłówka: nic do odbiornika', () async {
        final got = await serve([
          ascii.encode('HTTP/1.1 200 OK\r\nContent-Ty'),
        ], NtripState.reconnecting, close: true);
        expect(got, isEmpty);
      });
    });
  });
}
