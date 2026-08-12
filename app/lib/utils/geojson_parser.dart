import 'dart:convert';

import 'package:latlong2/latlong.dart';

import 'parsed_polygon.dart';

/// Parser plików GeoJSON (RFC 7946) — format eksportu QGIS i wielu innych
/// narzędzi GIS.
///
/// Obsługiwane struktury (reszta typów geometrii, np. Point/LineString,
/// jest pomijana — to nie są granice pola):
/// ```json
/// // 1) "goły" wielokąt:
/// {"type": "Polygon", "coordinates": [[[lon,lat],[lon,lat],...]]}
/// //   pierwsza tablica = pierścień zewnętrzny, kolejne = dziury (IGNOROWANE,
/// //   tak jak w WktParser — FieldModel nie wspiera otworów w granicy)
///
/// // 2) kilka wielokątów naraz:
/// {"type": "MultiPolygon", "coordinates": [ [[[lon,lat],...]], [[[lon,lat],...]] ]}
/// //   każdy element najwyższego poziomu = osobny wielokąt (= osobne pole)
///
/// // 3) typowy eksport QGIS "Zapisz jako" — kolekcja cech z metadanymi:
/// {
///   "type": "FeatureCollection",
///   "features": [
///     {"type": "Feature", "properties": {"name": "Pole 1"}, "geometry": {...}},
///     ...
///   ]
/// }
/// ```
///
/// UWAGA na kolejność współrzędnych: RFC 7946 wymusza "longitude,latitude"
/// — DŁUGOŚĆ geograficzna jest pierwsza, tak samo jak w KML i WKT.
class GeoJsonParser {
  GeoJsonParser._();

  /// Parsuje zawartość pliku .geojson/.json i zwraca listę wielokątów.
  ///
  /// Rzuca [FormatException] gdy JSON jest niepoprawny, korzeń nie jest
  /// obiektem GeoJSON rozpoznanego typu, albo żadna geometria nie przechodzi
  /// walidacji [ParsedPolygon.normalizeRing].
  static List<ParsedPolygon> parse(String jsonContent) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(jsonContent);
    } catch (e) {
      throw FormatException('Niepoprawny plik GeoJSON (błąd JSON): $e');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Niepoprawny plik GeoJSON: oczekiwano '
          'obiektu JSON na najwyższym poziomie.');
    }

    final type = decoded['type'] as String?;
    final result = <ParsedPolygon>[];

    switch (type) {
      case 'Polygon':
      case 'MultiPolygon':
        result.addAll(_polygonsFromGeometry(decoded, null));
        break;
      case 'Feature':
        result.addAll(_polygonsFromFeature(decoded));
        break;
      case 'FeatureCollection':
        final features = (decoded['features'] as List?) ?? const [];
        for (final f in features) {
          if (f is Map<String, dynamic>) {
            result.addAll(_polygonsFromFeature(f));
          }
        }
        break;
      default:
        throw FormatException(
            'Nieobsługiwany typ GeoJSON: ${type ?? '(brak)'}');
    }

    if (result.isEmpty) {
      throw const FormatException('Plik GeoJSON nie zawiera żadnego '
          'wielokąta (Polygon/MultiPolygon).');
    }
    return result;
  }

  /// Cecha (Feature) → 0+ wielokątów, z nazwą z properties.name. Geometrie
  /// inne niż Polygon/MultiPolygon (np. Point ze znacznikiem gospodarstwa)
  /// są pomijane BEZ błędu — plik może zawierać inne obiekty obok granic.
  static List<ParsedPolygon> _polygonsFromFeature(
      Map<String, dynamic> feature) {
    final geometry = feature['geometry'];
    if (geometry is! Map<String, dynamic>) return const [];
    final props = feature['properties'];
    final name =
        (props is Map<String, dynamic>) ? props['name'] as String? : null;
    return _polygonsFromGeometry(geometry, name);
  }

  static List<ParsedPolygon> _polygonsFromGeometry(
      Map<String, dynamic> geometry, String? name) {
    final type = geometry['type'] as String?;
    final coords = geometry['coordinates'];
    if (coords is! List) return const [];

    switch (type) {
      case 'Polygon':
        // coords = [ring0(zewnętrzny), ring1(dziura), ...] — bierzemy ring0.
        if (coords.isEmpty) return const [];
        final outer = _ringFromCoords(coords[0]);
        return [
          ParsedPolygon(
              suggestedName: name,
              points:
                  ParsedPolygon.normalizeRing(outer, formatLabel: 'GeoJSON')),
        ];

      case 'MultiPolygon':
        // coords = [ polygon0=[ring0,...], polygon1=[ring0,...], ... ]
        final polys = <ParsedPolygon>[];
        for (var i = 0; i < coords.length; i++) {
          final rings = coords[i];
          if (rings is! List || rings.isEmpty) continue;
          final outer = _ringFromCoords(rings[0]);
          final suggestedName = (name == null)
              ? null
              : (coords.length > 1 ? '$name (${i + 1})' : name);
          polys.add(ParsedPolygon(
              suggestedName: suggestedName,
              points:
                  ParsedPolygon.normalizeRing(outer, formatLabel: 'GeoJSON')));
        }
        return polys;

      default:
        return const []; // Point/LineString/GeometryCollection — pomiń
    }
  }

  /// Jeden pierścień: [[lon,lat],[lon,lat,alt?],...].
  static List<LatLng> _ringFromCoords(dynamic ring) {
    if (ring is! List) {
      throw const FormatException('Niepoprawny pierścień w pliku GeoJSON.');
    }
    final points = <LatLng>[];
    for (final pt in ring) {
      if (pt is! List || pt.length < 2) {
        throw FormatException('Niepoprawna współrzędna w pliku GeoJSON: $pt');
      }
      final lon = (pt[0] as num).toDouble();
      final lat = (pt[1] as num).toDouble();
      points.add(LatLng(lat, lon));
    }
    return points;
  }
}
