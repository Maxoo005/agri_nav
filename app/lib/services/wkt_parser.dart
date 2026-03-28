import 'package:latlong2/latlong.dart';

/// Prosty parser WKT (Well-Known Text) obsługujący typy zwracane przez ULDK:
///   POLYGON((...))
///   MULTIPOLYGON(((...),(...),...))
///
/// Konwencja kolejności współrzędnych w WKT (ISO 19125 / OGC):
///   pierwsza liczba = X = Longitude (easting)
///   druga  liczba  = Y = Latitude  (northing)
///
/// Parser wymusza zakres WGS-84 (lon ∈ [−180, 180], lat ∈ [−90, 90]).
/// Wartości spoza tego zakresu oznaczają, że serwer zwrócił dane w układzie
/// projected (np. EPSG:2180) — należy dodać parametr `srid=4326` do żądania.
class WktParser {
  WktParser._();

  /// Parsuje ciąg WKT i zwraca wierzchołki pierwszego (largest) pierścienia.
  ///
  /// Rzuca [FormatException] gdy format jest nierozpoznany lub pusty.
  static List<LatLng> parse(String wkt) {
    final s = wkt.trim().toUpperCase();

    if (s.startsWith('POLYGON')) {
      return _parsePolygon(wkt.trim());
    }
    if (s.startsWith('MULTIPOLYGON')) {
      return _parseMultiPolygon(wkt.trim());
    }

    throw FormatException('Nieobsługiwany typ WKT: $wkt');
  }

  // ── Pomocnicze ───────────────────────────────────────────────────────────────

  static List<LatLng> _parsePolygon(String wkt) {
    // POLYGON ((lon lat, lon lat, ...))
    final match = RegExp(r'\(\s*\(([^)]+)\)').firstMatch(wkt);
    if (match == null) throw FormatException('Niepoprawny POLYGON WKT: $wkt');
    return _parseRing(match.group(1)!);
  }

  static List<LatLng> _parseMultiPolygon(String wkt) {
    // Zbierz wszystkie pierścienie i zwróć ten z największą liczbą punktów
    // (zwykle zewnętrzna granica największej działki składowej).
    final ringPat = RegExp(r'\(([^()]+)\)');
    final rings =
        ringPat.allMatches(wkt).map((m) => _parseRing(m.group(1)!)).toList();
    if (rings.isEmpty)
      throw FormatException('MULTIPOLYGON bez pierścieni: $wkt');
    rings.sort((a, b) => b.length.compareTo(a.length));
    return rings.first;
  }

  static List<LatLng> _parseRing(String ring) {
    // Każda para: "lon lat" lub "lon lat alt"
    final pairs = ring.trim().split(RegExp(r',\s*'));
    final points = <LatLng>[];
    for (final pair in pairs) {
      final nums = pair.trim().split(RegExp(r'\s+'));
      if (nums.length < 2) continue;
      final lon = double.tryParse(nums[0]);
      final lat = double.tryParse(nums[1]);
      if (lon == null || lat == null) continue;
      // Walidacja zakresu WGS-84: lon ∈ [−180, 180], lat ∈ [−90, 90].
      // Przekroczenie oznacza, że serwer zwrócił dane w układzie projected
      // (np. EPSG:2180, gdzie X≈500 000, Y≈5 600 000) zamiast EPSG:4326.
      // Rozwiązanie: dodaj parametr srid=4326 / outSR=4326 do żądania.
      if (lon.abs() > 180.0 || lat.abs() > 90.0) {
        throw FormatException('Współrzędne ($lon, $lat) poza zakresem WGS-84 — '
            'wymuś re-projekcję przez parametr srid=4326 w żądaniu do serwera');
      }
      // Pomijamy punkt zamykający identyczny z pierwszym
      if (points.isNotEmpty &&
          points.last.latitude == lat &&
          points.last.longitude == lon) continue;
      points.add(LatLng(lat, lon));
    }
    if (points.length < 3) {
      throw FormatException('Za mało punktów w pierścieniu WKT: $ring');
    }
    return points;
  }
}
