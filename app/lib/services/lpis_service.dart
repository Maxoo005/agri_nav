import 'dart:async';
import 'dart:developer' as dev;
import 'dart:io';
import 'dart:math' as math;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../models/lpis_parcel.dart';
import 'wkt_parser.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Wyjątki
// ─────────────────────────────────────────────────────────────────────────────

class LpisNoNetworkException implements Exception {
  const LpisNoNetworkException();
  @override
  String toString() => 'Brak zasięgu — użyj danych z cache';
}

class LpisServiceException implements Exception {
  const LpisServiceException(this.message);
  final String message;
  @override
  String toString() => message;
}

// ─────────────────────────────────────────────────────────────────────────────
// Wynik zapytania
// ─────────────────────────────────────────────────────────────────────────────

class LpisFetchResult {
  const LpisFetchResult({
    required this.parcels,
    required this.fromCache,
    this.totalCount,
  });
  final List<LpisParcel> parcels;
  final bool fromCache;
  final int? totalCount;
}

// ─────────────────────────────────────────────────────────────────────────────
// LpisService — backend: ULDK GUGiK (publicznie dostępny)
//
// Dane działek rolnych LPIS pobieramy z publicznego API ULDK GUGiK
// (GetParcelById) — bez formularzy i bez autoryzacji.
//
// Metody:
//   fetchByFarmId(id)               — pobierz działkę po numerze TERYT
//   getCachedParcels([bounds])      — odczyt z cache Hive
//   clearCache()                    — wyczyść Hive
// ─────────────────────────────────────────────────────────────────────────────

const _kLpisBox = 'lpis_cache';

class LpisService {
  LpisService._();
  static final instance = LpisService._();

  static const _uldkBase = 'https://uldk.gugik.gov.pl/';
  static const _timeout = Duration(seconds: 45);
  static const _headers = <String, String>{
    'User-Agent': 'AgriNav/1.0',
    'Accept': 'text/plain,*/*',
  };

  final _http = http.Client();

  static Future<void> init() async => Hive.openBox(_kLpisBox);
  Box get _box => Hive.box(_kLpisBox);

  // ── Pobieranie działki po ID TERYT ──────────────────────────────────────────

  Future<LpisFetchResult> fetchByFarmId(String parcelId) async {
    if (!await _checkNetwork()) throw const LpisNoNetworkException();
    final parcel = await _fetchById(parcelId.trim());
    if (parcel == null) {
      throw LpisServiceException('Nie znaleziono działki: $parcelId\n'
          'Użyj formatu TERYT, np. 141201_1.0001.AR_1.1');
    }
    await _cacheParcels([parcel]);
    return LpisFetchResult(parcels: [parcel], fromCache: false, totalCount: 1);
  }

  Future<List<String>> fetchCropGroupCodes() async => const [];

  // ── Cache Hive ────────────────────────────────────────────────────────────────

  List<LpisParcel> getCachedParcels([LatLngBounds? bounds]) {
    final all = _box.values.map((e) => LpisParcel.fromJson(e as Map)).toList();
    if (bounds == null) return all;
    return all.where((p) {
      if (p.boundaryLats.isEmpty) return false;
      return bounds.contains(p.center);
    }).toList();
  }

  // ── ULDK: GetParcelById ───────────────────────────────────────────────────────

  Future<LpisParcel?> _fetchById(String id) async {
    final uri = Uri.parse(_uldkBase).replace(queryParameters: {
      'request': 'GetParcelById',
      'id': id,
      'result': 'geom_wkt,teryt,powiat,gmina,obreb',
      'srid':
          '4326', // Wymuszenie re-projekcji do EPSG:4326 (WGS-84) po stronie serwera
    });
    dev.log('ULDK ID $id', name: 'LpisService');
    final resp = await _get(uri);
    return _parseUldkResponse(resp.body);
  }

  // ── Parser odpowiedzi ULDK ────────────────────────────────────────────────────
  //
  // Format sukcesu (linia 1 = "0"):
  //   0
  //   SRID=2180;POLYGON((x y, ...))
  //   teryt|powiat|gmina|obreb
  //
  // Format błędu (linia 1 = "-1"):
  //   -1
  //   komunikat

  LpisParcel? _parseUldkResponse(String body) {
    final lines = body.trim().split('\n');
    if (lines.isEmpty) return null;
    if (lines[0].trim().startsWith('-')) return null;
    if (lines.length < 2) return null;

    final wktRaw = lines[1].trim();

    // Wykryj SRID z prefiksu "SRID=XXXX;" — decyduje o strategii parsowania.
    // srid=4326 w żądaniu powinien skutkować SRID=4326 w odpowiedzi;
    // zachowujemy obsługę SRID=2180 jako fallback dla starych wpisów z cache.
    String detectedSrid = '2180'; // domyślnie EPSG:2180 (PUWG-92, legacy)
    String wkt;
    if (wktRaw.contains(';')) {
      final sridMatch =
          RegExp(r'SRID=(\d+)', caseSensitive: false).firstMatch(wktRaw);
      if (sridMatch != null) detectedSrid = sridMatch.group(1)!;
      wkt = wktRaw.split(';').last.trim();
    } else {
      wkt = wktRaw;
    }

    List<LatLng> boundary;
    try {
      if (detectedSrid == '4326') {
        // EPSG:4326 — WKT zawiera już współrzędne WGS-84.
        // WktParser traktuje pierwszą liczbę jako Longitude (X),
        // drugą jako Latitude (Y) → zwraca LatLng(lat, lon) bezpośrednio.
        boundary = WktParser.parse(wkt);
      } else {
        // EPSG:2180 (PUWG-92, legacy) — X=Easting, Y=Northing.
        // WktParser zwraca LatLng(northing, easting); przekazujemy
        // easting jako x i northing jako y do ręcznej reprojekcji.
        final pts = WktParser.parse(wkt);
        boundary =
            pts.map((p) => _epsg2180toWgs84(p.longitude, p.latitude)).toList();
      }
    } catch (e) {
      dev.log('ULDK WKT parse error: $e  srid=$detectedSrid  wkt=$wkt',
          name: 'LpisService');
      return null;
    }
    if (boundary.length < 3) return null;

    String teryt = '';
    String? opis;
    if (lines.length >= 3) {
      final meta = lines[2].trim().split('|');
      teryt = meta.isNotEmpty ? meta[0].trim() : '';
      opis = meta.skip(1).where((s) => s.trim().isNotEmpty).join(', ');
    }

    return LpisParcel(
      objectId: teryt.isNotEmpty
          ? teryt
          : 'uldk_${DateTime.now().millisecondsSinceEpoch}',
      boundaryLats: boundary.map((p) => p.latitude).toList(),
      boundaryLons: boundary.map((p) => p.longitude).toList(),
      cropGroupCode: null,
      cropGroupLabel: opis,
      farmId: null,
      areaHa: null,
      campaignYear: null,
      fetchedAt: DateTime.now(),
    );
  }

  // ── Projekcja EPSG:2180 → WGS-84 ─────────────────────────────────────────────
  // PUWG-1992: Transverse Mercator, GRS80, lon0=19°, k0=0.9993,
  //            FE=500000, FN=-5300000

  LatLng _epsg2180toWgs84(double x, double y) {
    const a = 6378137.0;
    const f = 1 / 298.257222101;
    const e2 = 2 * f - f * f;
    const e4 = e2 * e2;
    const e6 = e4 * e2;
    const k0 = 0.9993;
    const lon0 = 19.0 * math.pi / 180.0;
    const fe = 500000.0;
    const fn = -5300000.0;

    final X = (x - fe) / k0;
    final Y = (y - fn) / k0;

    final e1 = (1 - math.sqrt(1 - e2)) / (1 + math.sqrt(1 - e2));
    final mu = Y / (a * (1 - e2 / 4 - 3 * e4 / 64 - 5 * e6 / 256));
    final phi1 = mu +
        (3 * e1 / 2 - 27 * e1 * e1 * e1 / 32) * math.sin(2 * mu) +
        (21 * e1 * e1 / 16 - 55 * e1 * e1 * e1 * e1 / 32) * math.sin(4 * mu) +
        (151 * e1 * e1 * e1 / 96) * math.sin(6 * mu);

    final sinPhi1 = math.sin(phi1);
    final cosPhi1 = math.cos(phi1);
    final tanPhi1 = math.tan(phi1);

    final n1 = a / math.sqrt(1 - e2 * sinPhi1 * sinPhi1);
    final t1 = tanPhi1 * tanPhi1;
    final c1 = e2 / (1 - e2) * cosPhi1 * cosPhi1;
    final r1 = a * (1 - e2) / math.pow(1 - e2 * sinPhi1 * sinPhi1, 1.5);
    final d = X / (n1 * k0);
    final d2 = d * d;
    final d4 = d2 * d2;
    final d6 = d4 * d2;

    final lat = phi1 -
        (n1 * tanPhi1 / r1) *
            (d2 / 2 -
                (5 + 3 * t1 + 10 * c1 - 4 * c1 * c1 - 9 * e2 / (1 - e2)) *
                    d4 /
                    24 +
                (61 +
                        90 * t1 +
                        298 * c1 +
                        45 * t1 * t1 -
                        252 * e2 / (1 - e2) -
                        3 * c1 * c1) *
                    d6 /
                    720);

    final lon = lon0 +
        (d -
                (1 + 2 * t1 + c1) * d2 * d / 6 +
                (5 -
                        2 * c1 +
                        28 * t1 -
                        3 * c1 * c1 +
                        8 * e2 / (1 - e2) +
                        24 * t1 * t1) *
                    d4 *
                    d /
                    120) /
            cosPhi1;

    return LatLng(lat * 180 / math.pi, lon * 180 / math.pi);
  }

  // ── Helpers ───────────────────────────────────────────────────────────────────

  Future<void> _cacheParcels(List<LpisParcel> parcels) async {
    await _box.putAll({for (final p in parcels) p.objectId: p.toJson()});
  }

  static Future<bool> _checkNetwork() async {
    final result = await Connectivity().checkConnectivity();
    return result.any((r) => r != ConnectivityResult.none);
  }

  Future<http.Response> _get(Uri uri, {int attempt = 1}) async {
    try {
      final resp = await _http.get(uri, headers: _headers).timeout(_timeout);
      dev.log('ULDK → ${resp.statusCode}', name: 'LpisService');
      return resp;
    } on SocketException catch (e) {
      throw LpisServiceException('Błąd połączenia: ${e.message}');
    } on http.ClientException catch (e) {
      throw LpisServiceException('Błąd HTTP: ${e.message}');
    } on TimeoutException {
      if (attempt < 2) {
        dev.log('ULDK timeout, retry $attempt/2…', name: 'LpisService');
        await Future<void>.delayed(const Duration(seconds: 3));
        return _get(uri, attempt: attempt + 1);
      }
      throw const LpisServiceException(
          'Serwer ULDK nie odpowiedział (45 s × 2 próby). Sprawdź sieć lub spróbuj ponownie później.');
    } catch (e) {
      throw LpisServiceException('$e');
    }
  }
}
