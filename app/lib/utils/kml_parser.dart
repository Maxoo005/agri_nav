import 'package:latlong2/latlong.dart';
import 'package:xml/xml.dart';

import 'parsed_polygon.dart';

/// Parser plików KML (Keyhole Markup Language) — format eksportu Google
/// Earth / Google Earth Pro.
///
/// Struktura pliku KML istotna dla tego parsera (reszta znaczników jest
/// ignorowana):
/// ```xml
/// <kml>
///   <Document>
///     <Placemark>
///       <name>Pole zachodnie</name>            <!-- sugerowana nazwa -->
///       <Polygon>
///         <outerBoundaryIs>
///           <LinearRing>
///             <!-- "lon,lat,wysokość" oddzielone spacjami/nowymi liniami -->
///             <coordinates>18.123,52.456,0 18.124,52.457,0 ...</coordinates>
///           </LinearRing>
///         </outerBoundaryIs>
///         <!-- <innerBoundaryIs> (dziury) jest ignorowane — FieldModel nie
///              obsługuje otworów w granicy pola. -->
///       </Polygon>
///     </Placemark>
///     <!-- Kilka wielokątów narysowanych naraz w Google Earth trafia do
///          JEDNEGO Placemarka jako <MultiGeometry>: -->
///     <Placemark>
///       <name>Kilka pól naraz</name>
///       <MultiGeometry>
///         <Polygon>...</Polygon>
///         <Polygon>...</Polygon>
///       </MultiGeometry>
///     </Placemark>
///   </Document>
/// </kml>
/// ```
///
/// UWAGA na kolejność współrzędnych: tak jak w WKT (patrz `WktParser` w
/// `services/wkt_parser.dart`), KML zapisuje "longitude,latitude[,wysokość]"
/// — DŁUGOŚĆ geograficzna jest pierwsza, nie szerokość.
class KmlParser {
  KmlParser._();

  /// Parsuje zawartość pliku .kml i zwraca listę wielokątów — jeden wpis na
  /// każdy `<Polygon>` znaleziony w dowolnym `<Placemark>` (bezpośrednio
  /// albo wewnątrz `<MultiGeometry>`).
  ///
  /// Rzuca [FormatException] gdy XML jest niepoprawny, brak
  /// `<Placemark>`/`<Polygon>` z poprawną geometrią, albo współrzędne nie
  /// przechodzą walidacji [ParsedPolygon.normalizeRing].
  static List<ParsedPolygon> parse(String kmlContent) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(kmlContent);
    } catch (e) {
      throw FormatException('Niepoprawny plik KML (błąd XML): $e');
    }

    // namespace: '*' — dopasowanie po nazwie lokalnej, niezależnie od tego,
    // czy eksporter użył prefiksu (np. <kml:Placemark>) czy nie (typowe dla
    // Google Earth Pro, które używa domyślnego xmlns bez prefiksu). Bez
    // tego parametru pakiet `xml` porównuje pełną kwalifikowaną nazwę i
    // cicho nie znajdzie niczego w plikach z prefiksem.
    final placemarks = doc.findAllElements('Placemark', namespace: '*');
    if (placemarks.isEmpty) {
      throw const FormatException(
          'Plik KML nie zawiera żadnego znacznika <Placemark>.');
    }

    final result = <ParsedPolygon>[];
    for (final placemark in placemarks) {
      final name = placemark
          .findElements('name', namespace: '*')
          .firstOrNull
          ?.innerText
          .trim();
      final polygons =
          placemark.findAllElements('Polygon', namespace: '*').toList();

      for (var i = 0; i < polygons.length; i++) {
        final ring = _outerRing(polygons[i]);
        if (ring == null) continue; // Polygon bez outerBoundaryIs — pomiń

        // Placemark z <MultiGeometry> ma JEDNĄ nazwę dla kilku wielokątów —
        // dopisz numer, żeby pola miały odróżnialne domyślne nazwy.
        final suggestedName = (name == null || name.isEmpty)
            ? null
            : (polygons.length > 1 ? '$name (${i + 1})' : name);

        result.add(ParsedPolygon(
          suggestedName: suggestedName,
          points: ParsedPolygon.normalizeRing(ring, formatLabel: 'KML'),
        ));
      }
    }

    if (result.isEmpty) {
      throw const FormatException(
          'Plik KML nie zawiera żadnego poprawnego wielokąta <Polygon>.');
    }
    return result;
  }

  static List<LatLng>? _outerRing(XmlElement polygon) {
    final coordsText = polygon
        .findElements('outerBoundaryIs', namespace: '*')
        .firstOrNull
        ?.findElements('LinearRing', namespace: '*')
        .firstOrNull
        ?.findElements('coordinates', namespace: '*')
        .firstOrNull
        ?.innerText;
    if (coordsText == null || coordsText.trim().isEmpty) return null;
    return _parseCoordinatesText(coordsText);
  }

  /// "lon,lat,alt lon,lat,alt ..." — trójki oddzielone białymi znakami
  /// (spacja/tab/nowa linia — eksportery różnie formatują), wewnątrz trójki
  /// wartości oddzielone przecinkiem. Wysokość jest opcjonalna i ignorowana
  /// (AgriNav pracuje na granicach 2D).
  static List<LatLng> _parseCoordinatesText(String text) {
    final points = <LatLng>[];
    final tuples = text.trim().split(RegExp(r'\s+'));
    for (final tuple in tuples) {
      final parts = tuple.split(',');
      if (parts.length < 2) continue;
      final lon = double.tryParse(parts[0]);
      final lat = double.tryParse(parts[1]);
      if (lon == null || lat == null) {
        throw FormatException(
            'Niepoprawna współrzędna w pliku KML: "$tuple"');
      }
      points.add(LatLng(lat, lon));
    }
    return points;
  }
}
