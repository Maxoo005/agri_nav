import 'package:latlong2/latlong.dart';

// ─────────────────────────────────────────────────────────────────────────────
// LpisParcel — działka rolna LPIS (dane z ULDK GUGiK)
// ─────────────────────────────────────────────────────────────────────────────

/// Model działki rolnej z rejestru LPIS.
///
/// Dane pobierane są z publicznego API ULDK (GUGiK) — ten sam rejestr
/// katastralny co działki ewidencyjne. Serializacja ręczna do JSON
/// (brak generatora kodu, jak w [FieldModel]).
class LpisParcel {
  /// Identifikator działki (numer ewidencyjny / TERYT).
  final String objectId;

  /// Wierzchołki granicy działki rolnej (WGS-84, EPSG:4326).
  final List<double> boundaryLats;
  final List<double> boundaryLons;

  /// Kod grupy upraw (CROP_GROUP), np. "R" (grunty orne), "TR" (trwałe użytki).
  /// Null gdy serwer nie zwróci tego atrybutu w danym zapytaniu.
  final String? cropGroupCode;

  /// Opis grupy upraw w języku polskim, np. "Grunty orne".
  final String? cropGroupLabel;

  /// Numer identyfikacyjny gospodarstwa (FARM_ID / Nr gosp.).
  final String? farmId;

  /// Powierzchnia działki rolnej [ha].
  final double? areaHa;

  /// Rok kampanii (np. 2025).
  final int? campaignYear;

  /// Data i godzina pobrania z serwisu ULDK.
  final DateTime fetchedAt;

  const LpisParcel({
    required this.objectId,
    required this.boundaryLats,
    required this.boundaryLons,
    this.cropGroupCode,
    this.cropGroupLabel,
    this.farmId,
    this.areaHa,
    this.campaignYear,
    required this.fetchedAt,
  });

  // ── Wygoda ──────────────────────────────────────────────────────────────────

  List<LatLng> get boundary => List.generate(
        boundaryLats.length,
        (i) => LatLng(boundaryLats[i], boundaryLons[i]),
      );

  LatLng get center {
    if (boundaryLats.isEmpty) return const LatLng(52.0, 19.0);
    final lat = boundaryLats.reduce((a, b) => a + b) / boundaryLats.length;
    final lon = boundaryLons.reduce((a, b) => a + b) / boundaryLons.length;
    return LatLng(lat, lon);
  }

  // ── Factory: parsowanie cechy GeoJSON ─────────────────────────────────────

  /// Buduje [LpisParcel] z jednej cechy GeoJSON zwracanej przez API.
  ///
  /// Oczekiwana struktura:
  /// ```json
  /// {
  ///   "attributes": { "OBJECTID": 123, "CROP_GROUP": "R", ... },
  ///   "geometry":   { "rings": [[lon, lat], ...] }
  /// }
  /// ```
  factory LpisParcel.fromArcGisFeature(Map<String, dynamic> feature) {
    final attrs = (feature['attributes'] as Map<String, dynamic>?) ?? {};
    final geom = (feature['geometry'] as Map<String, dynamic>?) ?? {};

    // ── Parsuj geometrię ─────────────────────────────────────────────────────
    // API zwraca geometry.rings jako listę pierścieni.
    // Weź pierwszy (zewnętrzny) pierścień.
    final List<double> lats = [];
    final List<double> lons = [];

    final rawRings = geom['rings'] as List<dynamic>?;
    if (rawRings != null && rawRings.isNotEmpty) {
      final ring = rawRings[0] as List<dynamic>;
      for (final coord in ring) {
        final pair = coord as List<dynamic>;
        if (pair.length >= 2) {
          lons.add((pair[0] as num).toDouble()); // [lon, lat]
          lats.add((pair[1] as num).toDouble());
        }
      }
    }

    // ── Parsuj atrybuty ──────────────────────────────────────────────────────
    final objectId =
        attrs['OBJECTID']?.toString() ?? attrs['objectid']?.toString() ?? '';
    final cropCode = attrs['CROP_GROUP']?.toString() ??
        attrs['crop_group']?.toString() ??
        attrs['GR_UPRAW']?.toString();
    final cropLabel = attrs['CROP_GROUP_DESC']?.toString() ??
        attrs['crop_group_desc']?.toString() ??
        attrs['GR_UPRAW_OPIS']?.toString();
    final farmIdRaw = attrs['FARM_ID']?.toString() ??
        attrs['farm_id']?.toString() ??
        attrs['NR_GOSP']?.toString();
    final areaRaw = attrs['AREA_HA'] ?? attrs['area_ha'] ?? attrs['POW_HA'];
    final yearRaw =
        attrs['CAMPAIGN_YEAR'] ?? attrs['campaign_year'] ?? attrs['ROK'];

    return LpisParcel(
      objectId: objectId,
      boundaryLats: lats,
      boundaryLons: lons,
      cropGroupCode: cropCode,
      cropGroupLabel: cropLabel,
      farmId: farmIdRaw,
      areaHa: areaRaw != null ? (areaRaw as num).toDouble() : null,
      campaignYear: yearRaw != null ? (yearRaw as num).toInt() : null,
      fetchedAt: DateTime.now(),
    );
  }

  // ── Serializacja Hive (JSON map) ─────────────────────────────────────────────

  Map<String, dynamic> toJson() => {
        'objectId': objectId,
        'boundaryLats': boundaryLats,
        'boundaryLons': boundaryLons,
        if (cropGroupCode != null) 'cropGroupCode': cropGroupCode,
        if (cropGroupLabel != null) 'cropGroupLabel': cropGroupLabel,
        if (farmId != null) 'farmId': farmId,
        if (areaHa != null) 'areaHa': areaHa,
        if (campaignYear != null) 'campaignYear': campaignYear,
        'fetchedAt': fetchedAt.toIso8601String(),
      };

  factory LpisParcel.fromJson(Map<dynamic, dynamic> map) => LpisParcel(
        objectId: map['objectId'] as String,
        boundaryLats: (map['boundaryLats'] as List).cast<double>(),
        boundaryLons: (map['boundaryLons'] as List).cast<double>(),
        cropGroupCode: map['cropGroupCode'] as String?,
        cropGroupLabel: map['cropGroupLabel'] as String?,
        farmId: map['farmId'] as String?,
        areaHa: (map['areaHa'] as num?)?.toDouble(),
        campaignYear: map['campaignYear'] as int?,
        fetchedAt: DateTime.tryParse(map['fetchedAt'] as String? ?? '') ??
            DateTime.now(),
      );
}
