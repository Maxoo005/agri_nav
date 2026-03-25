import 'dart:convert';
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

    final response = await _http.get(uri).timeout(_timeout);
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

    final response = await _http.get(uri).timeout(_timeout);
    return _handleParcelResponse(response);
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
      throw ULDKException('Serwer zwrócił ${response.statusCode}');
    }

    final body  = utf8.decode(response.bodyBytes).trim();
    final lines = body.split('\n');
    if (lines.isEmpty) throw const ULDKException('Pusta odpowiedź serwera');

    // Pierwsza linia to status: "0" = sukces, "-1 <opis>" = błąd
    final statusLine = lines[0].trim();
    if (statusLine.startsWith('-1')) {
      final msg = lines.length > 1 ? lines[1].trim() : statusLine;
      throw ULDKException('Działka nie znaleziona: $msg');
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
    final wkt      = parts[1].trim();
    final commune  = parts.length > 5 ? parts[5].trim() : '';

    final List<LatLng> boundary;
    try {
      boundary = WktParser.parse(wkt);
    } on FormatException catch (e) {
      throw ULDKException('Błąd parsowania WKT: $e');
    }

    // Czytelna nazwa: gmina + skrócony ID działki
    final shortId = parcelId.length > 12
        ? '…${parcelId.substring(parcelId.length - 12)}'
        : parcelId;
    final name =
        commune.isNotEmpty ? '$commune / $shortId' : 'Działka $shortId';

    // Unikaj duplikatów — jeśli ta działka już jest, zwróć istniejącą
    final existing = FieldService.instance
        .getAll()
        .where((f) => f.uLDKParcelId == parcelId)
        .firstOrNull;
    if (existing != null) return existing;

    final field = FieldModel(
      id:           const Uuid().v4(),
      name:         name,
      boundaryLats: boundary.map((p) => p.latitude).toList(),
      boundaryLons: boundary.map((p) => p.longitude).toList(),
      uLDKParcelId: parcelId,
      source:       FieldSource.uldk,
    );

    await FieldService.instance.save(field);
    return field;
  }
}
