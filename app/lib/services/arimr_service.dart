import 'dart:async';
import 'dart:developer' as dev;
import 'dart:io';
import 'dart:math' as math;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../models/arimr_parcel.dart';
import 'wkt_parser.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Wyjątki
// ─────────────────────────────────────────────────────────────────────────────

class ArimrNoNetworkException implements Exception {
  const ArimrNoNetworkException();
  @override
  String toString() => 'Brak zasięgu — użyj danych z cache';
}

class ArimrServiceException implements Exception {
  const ArimrServiceException(this.message);
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
  final List<ArimrParcel> parcels;
  final bool fromCache;
  final int? totalCount;
}

// ─────────────────────────────────────────────────────────────────────────────
// ArimrService — backend: ULDK GUGiK (publicznie dostępny)
//
// ARiMR FeatureServer (geoportal.arimr.gov.pl/arcgis) wymaga autoryzacji
// i nie jest publicznie dostępny. Używamy ULDK GUGiK zamiast niego.
//
// Metody:
//   fetchAgriculturalParcels(bounds) — siatkowe próbkowanie obszaru przez ULDK
//   fetchByFarmId(id)               — pobierz działkę po numerze TERYT
//   getCachedParcels([bounds])      — odczyt z cache Hive
//   clearCache()                    — wyczyść Hive
// ─────────────────────────────────────────────────────────────────────────────

const kArimrBox = 'arimr_lpis';

class ArimrService {
  ArimrService._();
  static final instance = ArimrService._();

  static const _uldkBase = 'https://uldk.gugik.gov.pl/';
  static const _timeout = Duration(seconds: 20);
  static const _headers = <String, String>{
    'User-Agent': 'AgriNav/1.0',
    'Accept': 'text/plain,*/*',
  };

  final _http = http.Client();

  static Future<void> init() async => Hive.openBox(kArimrBox);
  Box get _box => Hive.box(kArimrBox);

  // ── Pobieranie działek w obszarze (siatka XY) ─────────────────────────────────

  Future<LpisFetchResult> fetchAgriculturalParcels(
    LatLngBounds bounds, {
    String? cropGroupCode,
    String? farmId,
    bool fallbackToCache = true,
  }) async {
    if (!await _checkNetwork()) {
      if (fallbackToCache) {
        return LpisFetchResult(
            parcels: getCachedParcels(bounds), fromCache: true);
      }
      throw const ArimrNoNetworkException();
    }

    const stepsLat = 5;
    const stepsLon = 5;
    final dLat = (bounds.north - bounds.south) / stepsLat;
    final dLon = (bounds.east - bounds.west) / stepsLon;

    final seen = <String>{};
    final parcels = <ArimrParcel>[];

    for (var i = 0; i <= stepsLat; i++) {
      for (var j = 0; j <= stepsLon; j++) {
        final lat = bounds.south + i * dLat;
        final lon = bounds.west + j * dLon;
        try {
          final parcel = await _fetchByXY(lat, lon);
          if (parcel != null && !seen.contains(parcel.objectId)) {
            seen.add(parcel.objectId);
            parcels.add(parcel);
          }
        } catch (e) {
          dev.log('ULDK xy=$lat,$lon error: $e', name: 'ArimrService');
        }
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
    }

    dev.log('ULDK pobrano ${parcels.length} działek', name: 'ArimrService');
    await _cacheParcels(parcels);
    return LpisFetchResult(
        parcels: parcels, fromCache: false, totalCount: parcels.length);
  }

  // ── Pobieranie działki po ID TERYT ──────────────────────────────────────────

  Future<LpisFetchResult> fetchByFarmId(String parcelId) async {
    if (!await _checkNetwork()) throw const ArimrNoNetworkException();
    final parcel = await _fetchById(parcelId.trim());
    if (parcel == null) {
      throw ArimrServiceException('Nie znaleziono działki: $parcelId\n'
          'Użyj formatu TERYT, np. 141201_1.0001.AR_1.1');
    }
    await _cacheParcels([parcel]);
    return LpisFetchResult(parcels: [parcel], fromCache: false, totalCount: 1);
  }

  Future<List<String>> fetchCropGroupCodes() async => const [];

  // ── Cache Hive ────────────────────────────────────────────────────────────────

  List<ArimrParcel> getCachedParcels([LatLngBounds? bounds]) {
    final all = _box.values.map((e) => ArimrParcel.fromJson(e as Map)).toList();
    if (bounds == null) return all;
    return all.where((p) {
      if (p.boundaryLats.isEmpty) return false;
      return bounds.contains(p.center);
    }).toList();
  }

  Future<void> clearCache() => _box.clear();

  // ── ULDK: GetParcelByXY ───────────────────────────────────────────────────────

  Future<ArimrParcel?> _fetchByXY(double lat, double lon) async {
    final uri = Uri.parse(_uldkBase).replace(queryParameters: {
      'request': 'GetParcelByXY',
      'xy': '${lon.toStringAsFixed(6)},${lat.toStringAsFixed(6)}',
      'result': 'geom_wkt,teryt,powiat,gmina,obreb',
      'srid':
          '4326', // Wymuszenie re-projekcji do EPSG:4326 (WGS-84) po stronie serwera
    });
    dev.log('ULDK XY $lat,$lon', name: 'ArimrService');
    final resp = await _get(uri);
    return _parseUldkResponse(resp.body);
  }

  // ── ULDK: GetParcelById ───────────────────────────────────────────────────────

  Future<ArimrParcel?> _fetchById(String id) async {
    final uri = Uri.parse(_uldkBase).replace(queryParameters: {
      'request': 'GetParcelById',
      'id': id,
      'result': 'geom_wkt,teryt,powiat,gmina,obreb',
      'srid':
          '4326', // Wymuszenie re-projekcji do EPSG:4326 (WGS-84) po stronie serwera
    });
    dev.log('ULDK ID $id', name: 'ArimrService');
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

  ArimrParcel? _parseUldkResponse(String body) {
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
          name: 'ArimrService');
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

    return ArimrParcel(
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
    final e2 = 2 * f - f * f;
    final e4 = e2 * e2;
    final e6 = e4 * e2;
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

    final N1 = a / math.sqrt(1 - e2 * sinPhi1 * sinPhi1);
    final T1 = tanPhi1 * tanPhi1;
    final C1 = e2 / (1 - e2) * cosPhi1 * cosPhi1;
    final R1 = a * (1 - e2) / math.pow(1 - e2 * sinPhi1 * sinPhi1, 1.5);
    final D = X / (N1 * k0);
    final D2 = D * D;
    final D4 = D2 * D2;
    final D6 = D4 * D2;

    final lat = phi1 -
        (N1 * tanPhi1 / R1) *
            (D2 / 2 -
                (5 + 3 * T1 + 10 * C1 - 4 * C1 * C1 - 9 * e2 / (1 - e2)) *
                    D4 /
                    24 +
                (61 +
                        90 * T1 +
                        298 * C1 +
                        45 * T1 * T1 -
                        252 * e2 / (1 - e2) -
                        3 * C1 * C1) *
                    D6 /
                    720);

    final lon = lon0 +
        (D -
                (1 + 2 * T1 + C1) * D2 * D / 6 +
                (5 -
                        2 * C1 +
                        28 * T1 -
                        3 * C1 * C1 +
                        8 * e2 / (1 - e2) +
                        24 * T1 * T1) *
                    D4 *
                    D /
                    120) /
            cosPhi1;

    return LatLng(lat * 180 / math.pi, lon * 180 / math.pi);
  }

  // ── Helpers ───────────────────────────────────────────────────────────────────

  Future<void> _cacheParcels(List<ArimrParcel> parcels) async {
    await _box.putAll({for (final p in parcels) p.objectId: p.toJson()});
  }

  static Future<bool> _checkNetwork() async {
    final result = await Connectivity().checkConnectivity();
    return result.any((r) => r != ConnectivityResult.none);
  }

  Future<http.Response> _get(Uri uri) async {
    try {
      final resp = await _http.get(uri, headers: _headers).timeout(_timeout);
      dev.log('ULDK → ${resp.statusCode}', name: 'ArimrService');
      return resp;
    } on SocketException catch (e) {
      throw ArimrServiceException('Błąd połączenia: ${e.message}');
    } on http.ClientException catch (e) {
      throw ArimrServiceException('Błąd HTTP: ${e.message}');
    } on TimeoutException {
      throw const ArimrServiceException(
          'Serwer ULDK nie odpowiedział. Spróbuj ponownie.');
    } catch (e) {
      throw ArimrServiceException('$e');
    }
  }
}
