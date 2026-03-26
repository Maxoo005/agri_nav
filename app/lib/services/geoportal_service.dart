import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:math' as math;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:uuid/uuid.dart';

import '../models/field_model.dart';
import 'field_service.dart';
import 'wkt_parser.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Wyjątki
// ─────────────────────────────────────────────────────────────────────────────

/// Błąd braku połączenia z siecią.
class NoNetworkException implements Exception {
  const NoNetworkException();
  @override
  String toString() => 'Brak zasięgu — użyj zapisanych pól';
}

/// Błąd odpowiedzi serwera ULDK.
class ULDKException implements Exception {
  const ULDKException(this.message);
  final String message;
  @override
  String toString() => 'ULDK: $message';
}

// ─────────────────────────────────────────────────────────────────────────────
// Wynik multi-fetch
// ─────────────────────────────────────────────────────────────────────────────

/// Wynik asynchronicznego pobierania wielu działek.
///
/// [geometries]  — mapa parcelId → lista punktów WGS-84 (sukces)
/// [errors]      — mapa parcelId → opis błędu (niepowodzenie)
class ParcelFetchResult {
  const ParcelFetchResult({required this.geometries, required this.errors});

  final Map<String, List<LatLng>> geometries;
  final Map<String, String> errors;

  bool get hasSuccesses => geometries.isNotEmpty;
  bool get hasErrors => errors.isNotEmpty;

  /// Liczba pomyślnie pobranych działek.
  int get successCount => geometries.length;
}

// ─────────────────────────────────────────────────────────────────────────────
// GeoportalService
// ─────────────────────────────────────────────────────────────────────────────

/// Serwis integrujący API ULDK (GUGiK) z lokalnym magazynem Hive.
///
/// Kluczowe metody:
///   [fetchAndCacheParcel]   — pobierz działkę wg XY i zapisz w Hive
///   [fetchAndCacheByTeryt]  — pobierz działkę wg numeru ewidencyjnego
///   [nudgeField]            — przesuń granicę o dx/dy [m] (korekta offsetu)
///   [resetNudge]            — wyzeruj przesunięcie działki
class GeoportalService {
  GeoportalService._();
  static final instance = GeoportalService._();

  static const _baseUrl = 'https://uldk.gugik.gov.pl/';
  static const _timeout = Duration(seconds: 15);
  static const _headers = <String, String>{
    'User-Agent': 'AgriNavApp/1.0',
  };

  final _http = http.Client();

  // ── Publiczne API ────────────────────────────────────────────────────────────

  /// Pobiera działkę z ULDK na podstawie współrzędnych [lat]/[lon] (WGS-84).
  ///
  /// Zapisuje wynik jako [FieldModel] w Hive i zwraca go.
  /// Rzuca [NoNetworkException] gdy brak sieci, [ULDKException] przy błędzie API.
  Future<FieldModel> fetchAndCacheParcel(double lat, double lon) async {
    await _requireNetwork();

    // ULDK przyjmuje XY w EPSG:4326 jako lon,lat
    final uri = Uri.parse(_baseUrl).replace(
      queryParameters: {
        'request': 'GetParcelByXY',
        'xy': '${lon.toStringAsFixed(6)},${lat.toStringAsFixed(6)}',
        'result': 'id,geom_wkt,teryt,voivodeship,county,municipality',
        'srid': '4326',
      },
    );

    dev.log('ULDK GetParcelByXY → $uri', name: 'GeoportalService');
    final response = await _http.get(uri, headers: _headers).timeout(_timeout);
    return _handleParcelResponse(response);
  }

  /// Pobiera działkę z ULDK na podstawie numeru ewidencyjnego [terytId].
  ///
  /// Przykład: "141201_2.0001.1234/2"
  Future<FieldModel> fetchAndCacheByTeryt(String terytId) async {
    await _requireNetwork();

    final uri = Uri.parse(_baseUrl).replace(
      queryParameters: {
        'request': 'GetParcelById',
        'id': terytId.trim(),
        'result': 'id,geom_wkt,teryt,voivodeship,county,municipality',
        'srid': '4326',
      },
    );

    dev.log('ULDK GetParcelById → $uri', name: 'GeoportalService');
    final response = await _http.get(uri, headers: _headers).timeout(_timeout);
    return _handleParcelResponse(response);
  }

  // ── Multi-fetch ──────────────────────────────────────────────────────────────

  /// Buduje pełny identyfikator ewidencyjny z prefiksu obrębu i numeru działki.
  ///
  /// Przykład: prefiks="141201_2.0001", number="1234/2"
  ///   → "141201_2.0001.1234/2"
  ///
  /// Jeśli [parcelNumber] już zawiera prefiks (ma więcej niż jedną kropkę),
  /// jest zwracany bez zmian.
  static String buildFullParcelId(String districtPrefix, String parcelNumber) {
    final trimmed = parcelNumber.trim();
    // Już pełny identyfikator (np. "141201_2.0001.1234/2")
    if (trimmed.contains('.') && trimmed.split('.').length >= 3) {
      return trimmed;
    }
    final prefix = districtPrefix.trim().trimRight();
    return '$prefix.$trimmed';
  }

  /// Pobiera geometrię dla listy numerów działek równolegle.
  ///
  /// [parcelIds] — pełne lub częściowe numery (patrz [buildFullParcelId]).
  /// [districtPrefix] — opcjonalny prefiks obrębu łączony z krótkimi numerami.
  ///
  /// Zwraca [ParcelFetchResult] z listami sukcesów i błędów.
  /// Nie zapisuje do Hive — to robi dopiero [FieldService] po union.
  Future<ParcelFetchResult> fetchMultipleParcels(
    List<String> parcelIds, {
    String districtPrefix = '',
  }) async {
    await _requireNetwork();

    final fullIds = parcelIds
        .map((id) {
          final trimmed = id.trim();
          if (trimmed.isEmpty) return null;
          return districtPrefix.isEmpty
              ? trimmed
              : buildFullParcelId(districtPrefix, trimmed);
        })
        .whereType<String>()
        .toSet()
        .toList();

    if (fullIds.isEmpty) {
      throw const ULDKException('Lista identyfikatorów jest pusta');
    }

    dev.log('fetchMultipleParcels: ${fullIds.length} działek',
        name: 'GeoportalService');

    // Concurrent fetch — limit concurrency to 4 to avoid hammering ULDK
    final successes = <String, List<LatLng>>{};
    final errors = <String, String>{};

    // Process in batches of 4
    for (var i = 0; i < fullIds.length; i += 4) {
      final batch = fullIds.sublist(i, math.min(i + 4, fullIds.length));
      final results = await Future.wait(
        batch.map((id) async {
          try {
            final parts = await _fetchRawParcel(id);
            return (id: id, points: parts, error: null as String?);
          } catch (e) {
            dev.log('fetchMultipleParcels: błąd dla "$id": $e',
                name: 'GeoportalService', level: 900);
            return (id: id, points: null as List<LatLng>?, error: e.toString());
          }
        }),
      );
      for (final r in results) {
        if (r.error != null) {
          errors[r.id] = r.error!;
        } else {
          successes[r.id] = r.points!;
        }
      }
    }

    dev.log(
        'fetchMultipleParcels: ${successes.length} ok, ${errors.length} błędów',
        name: 'GeoportalService');
    return ParcelFetchResult(geometries: successes, errors: errors);
  }

  /// Pobiera surową geometrię WKT jednej działki bez zapisywania do Hive.
  Future<List<LatLng>> _fetchRawParcel(String parcelId) async {
    final uri = Uri.parse(_baseUrl).replace(
      queryParameters: {
        'request': 'GetParcelById',
        'id': parcelId.trim(),
        'result': 'id,geom_wkt',
        'srid': '4326',
      },
    );

    final response = await _http.get(uri, headers: _headers).timeout(_timeout);

    if (response.statusCode != 200) {
      throw ULDKException('HTTP ${response.statusCode}');
    }

    final body = utf8.decode(response.bodyBytes).trim();
    final lines = body.split('\n');
    final statusLine = lines[0].trim();
    if (statusLine.startsWith('-1') || statusLine == '5') {
      throw const ULDKException('Nie znaleziono działki w tym miejscu');
    }

    final dataLine = (lines.length > 1 && lines[1].trim().isNotEmpty)
        ? lines[1].trim()
        : lines[0].trim();
    final parts = dataLine.split(';');
    if (parts.length < 2)
      throw ULDKException('Niepoprawna odpowiedź: $dataLine');

    return WktParser.parse(parts[1].trim());
  }

  /// Przesuwa granicę [field] o [dxM] metrów na wschód i [dyM] metrów na północ.
  ///
  /// Nie modyfikuje surowych współrzędnych — zmienia tylko
  /// [FieldModel.offsetLat] / [FieldModel.offsetLon] i zapisuje do Hive.
  Future<FieldModel> nudgeField(
    FieldModel field, {
    required double dxM,
    required double dyM,
  }) async {
    const mPerDeg = 111320.0;
    final cosLat = math.cos(field.center.latitude * math.pi / 180.0);
    field.offsetLat += dyM / mPerDeg;
    field.offsetLon += (cosLat > 0.0) ? dxM / (mPerDeg * cosLat) : 0.0;
    await FieldService.instance.save(field);
    return field;
  }

  /// Resetuje przesunięcie [field] do zera i zapisuje do Hive.
  Future<FieldModel> resetNudge(FieldModel field) async {
    field.offsetLat = 0.0;
    field.offsetLon = 0.0;
    await FieldService.instance.save(field);
    return field;
  }

  // ── Prywatne pomocnicze ──────────────────────────────────────────────────────

  Future<void> _requireNetwork() async {
    final result = await Connectivity().checkConnectivity();
    if (result == ConnectivityResult.none) throw const NoNetworkException();
  }

  Future<FieldModel> _handleParcelResponse(http.Response response) async {
    if (response.statusCode != 200) {
      dev.log('ULDK HTTP ${response.statusCode}',
          name: 'GeoportalService', level: 900);
      throw ULDKException('Serwer zwrócił ${response.statusCode}');
    }

    final body = utf8.decode(response.bodyBytes).trim();
    dev.log('ULDK odpowiedź: ${body.substring(0, body.length.clamp(0, 200))}',
        name: 'GeoportalService');

    final lines = body.split('\n');
    if (lines.isEmpty) throw const ULDKException('Pusta odpowiedź serwera');

    // Pierwsza linia to status:
    //   "0" = sukces
    //   "-1 <opis>" = działka nie znaleziona
    //   "5" = żądany obiekt nie istnieje
    final statusLine = lines[0].trim();
    if (statusLine.startsWith('-1') || statusLine == '5') {
      final detail = lines.length > 1 ? lines[1].trim() : statusLine;
      dev.log('ULDK status błędu: $statusLine | $detail',
          name: 'GeoportalService', level: 900);
      throw const ULDKException('Nie znaleziono działki w tym miejscu');
    }

    // Linia danych (może być linia 0 lub 1 zależnie od wersji API)
    final dataLine = (lines.length > 1 && lines[1].trim().isNotEmpty)
        ? lines[1].trim()
        : lines[0].trim();
    final parts = dataLine.split(';');
    if (parts.length < 2) {
      throw ULDKException('Niepoprawny format odpowiedzi: $dataLine');
    }

    final parcelId = parts[0].trim();
    final wkt = parts[1].trim();
    final terytCode = parts.length > 2 ? parts[2].trim() : null;
    final commune = parts.length > 5 ? parts[5].trim() : '';

    final List<LatLng> boundary;
    try {
      boundary = WktParser.parse(wkt);
    } on FormatException catch (e) {
      dev.log('WKT parse error: $e', name: 'GeoportalService', level: 900);
      throw ULDKException('Błąd parsowania WKT: $e');
    }

    // Czytelna nazwa: gmina + skrócony ID działki
    final shortId = parcelId.length > 12
        ? '…${parcelId.substring(parcelId.length - 12)}'
        : parcelId;
    final name =
        commune.isNotEmpty ? '$commune / $shortId' : 'Działka $shortId';

    // Unikaj duplikatów — jeśli ta działka już jest, odśwież dane i zwróć
    final existing = FieldService.instance
        .getAll()
        .where((f) => f.uLDKParcelId == parcelId)
        .firstOrNull;
    if (existing != null) {
      // Zaktualizuj datę synchronizacji przy ponownym pobraniu
      existing.lastSyncDate = DateTime.now();
      await FieldService.instance.save(existing);
      dev.log('ULDK: działka już istnieje — zaktualizowano lastSyncDate',
          name: 'GeoportalService');
      return existing;
    }

    final field = FieldModel(
      id: const Uuid().v4(),
      name: name,
      boundaryLats: boundary.map((p) => p.latitude).toList(),
      boundaryLons: boundary.map((p) => p.longitude).toList(),
      uLDKParcelId: parcelId,
      terytCode: terytCode?.isNotEmpty == true ? terytCode : null,
      lastSyncDate: DateTime.now(),
      source: FieldSource.uldk,
    );

    dev.log('ULDK: zapisano nową działkę "${field.name}"',
        name: 'GeoportalService');
    await FieldService.instance.save(field);
    return field;
  }
}
