import 'package:latlong2/latlong.dart';

/// Wynik parsowania JEDNEGO wielokąta z pliku KML lub GeoJSON — wspólny typ
/// zwracany przez [KmlParser.parse] i [GeoJsonParser.parse] (patrz
/// `kml_parser.dart` / `geojson_parser.dart`), żeby ekran importu z pliku
/// (`FileImportSheet`) mógł obsłużyć oba formaty identycznym kodem,
/// niezależnie od tego, czy plik zawierał jeden wielokąt czy wiele.
class ParsedPolygon {
  /// Sugerowana nazwa pola — z `<name>` Placemarka (KML) albo
  /// `properties.name` (GeoJSON Feature). Null, gdy plik nie zawiera nazwy
  /// dla tego wielokąta.
  final String? suggestedName;

  /// Wierzchołki zewnętrznego pierścienia (WGS-84). Otwory (dziury) w
  /// źródłowym pliku są pomijane — tak jak w całej reszcie aplikacji,
  /// [FieldModel] nie obsługuje geometrii z dziurami (patrz
  /// `boundaryLats`/`boundaryLons` w `field_model.dart`).
  final List<LatLng> points;

  const ParsedPolygon({this.suggestedName, required this.points});

  /// Wspólna walidacja/normalizacja pierścienia — te same reguły co
  /// [WktParser] stosuje do WKT (patrz `services/wkt_parser.dart`),
  /// świadomie zduplikowane zamiast dzielić kod: WktParser obsługuje ULDK
  /// i ma zostać nietknięty, a jego pomocnicze metody są prywatne.
  ///
  /// Usuwa punkt zamykający identyczny z pierwszym (KML/GeoJSON zawsze
  /// zamykają pierścień powtórzeniem pierwszego wierzchołka na końcu),
  /// wymusza zakres WGS-84 (lon ∈ [−180, 180], lat ∈ [−90, 90]) i minimum
  /// 3 punkty. [formatLabel] trafia do komunikatu błędu (np. "KML",
  /// "GeoJSON"), żeby było wiadomo, w którym pliku szukać problemu.
  static List<LatLng> normalizeRing(
    List<LatLng> raw, {
    required String formatLabel,
  }) {
    final points = <LatLng>[];
    for (final p in raw) {
      if (p.longitude.abs() > 180.0 || p.latitude.abs() > 90.0) {
        throw FormatException(
            'Współrzędne (${p.longitude}, ${p.latitude}) poza zakresem '
            'WGS-84 w pliku $formatLabel — sprawdź układ współrzędnych '
            'użyty przy eksporcie.');
      }
      if (points.isNotEmpty &&
          points.last.latitude == p.latitude &&
          points.last.longitude == p.longitude) {
        continue; // punkt zamykający pierścień, identyczny z pierwszym
      }
      points.add(p);
    }
    if (points.length < 3) {
      throw FormatException(
          'Za mało punktów w wielokącie z pliku $formatLabel '
          '(znaleziono ${points.length}, wymagane min. 3).');
    }
    return points;
  }
}
