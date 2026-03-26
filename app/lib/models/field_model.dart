import 'package:latlong2/latlong.dart';

/// Źródło pochodzenia granicy pola.
enum FieldSource {
  /// Ręcznie narysowane przez użytkownika.
  manual,

  /// Pobrane z ULDK/GUGiK.
  uldk,
}

/// Model pola uprawowego przechowywany w Hive jako zwykła mapa JSON.
/// Brak generatora kodu — serializacja ręczna.
class FieldModel {
  final String id;
  String name;

  /// Wierzchołki granicy pola jako dwie równoległe listy (WGS-84).
  List<double> boundaryLats;
  List<double> boundaryLons;

  /// Szerokość robocza maszyny [m].
  double workingWidthM;

  /// Ostatnio używana linia AB (opcjonalnie).
  double? lineALat, lineALon;
  double? lineBLat, lineBLon;

  // ── Pola katastralne (ULDK) ─────────────────────────────────────────────────

  /// Identyfikator działki z ULDK (np. "141201_2.0001.1234/2").
  /// Null gdy pole narysowane ręcznie.
  String? uLDKParcelId;

  /// Alias semantyczny — identyfikator urzędowy działki.
  String? get officialId => uLDKParcelId;

  /// Siedmiocyfrowy kod TERYT gminy, np. "1412012" (woj+pow+gm).
  String? terytCode;

  /// Data i godzina ostatniej synchronizacji z ULDK.
  DateTime? lastSyncDate;

  /// Lista numerów ewidencyjnych działek, z których zbudowano to pole
  /// (wynik operacji union w Kreatorze Pola). Pusta gdy pole narysowane ręcznie
  /// lub pobrane jako pojedyncza działka.
  List<String> sourceParcelIds;

  /// Źródło danych granicy.
  FieldSource source;

  /// Ręczna korekta przesunięcia granicy (WGS-84 stopnie).
  /// Rolnik może przesunąć działkę strzałkami, aby pokryła się ze zdjęciem.
  double offsetLat;
  double offsetLon;

  FieldModel({
    required this.id,
    required this.name,
    required this.boundaryLats,
    required this.boundaryLons,
    this.workingWidthM = 3.0,
    this.lineALat,
    this.lineALon,
    this.lineBLat,
    this.lineBLon,
    this.uLDKParcelId,
    this.terytCode,
    this.lastSyncDate,
    List<String>? sourceParcelIds,
    this.source = FieldSource.manual,
    this.offsetLat = 0.0,
    this.offsetLon = 0.0,
  }) : sourceParcelIds = sourceParcelIds ?? [];

  // ── Wygoda ──────────────────────────────────────────────────────────────────

  /// Granica jako lista LatLng z uwzględnieniem przesunięcia offsetowego.
  List<LatLng> get boundary => List.generate(
        boundaryLats.length,
        (i) => LatLng(
          boundaryLats[i] + offsetLat,
          boundaryLons[i] + offsetLon,
        ),
      );

  /// Granica bez offsetu (oryginalne wartości z bazy).
  List<LatLng> get boundaryRaw => List.generate(
        boundaryLats.length,
        (i) => LatLng(boundaryLats[i], boundaryLons[i]),
      );

  LatLng? get lineA => lineALat != null ? LatLng(lineALat!, lineALon!) : null;
  LatLng? get lineB => lineBLat != null ? LatLng(lineBLat!, lineBLon!) : null;

  /// Punkt środkowy wielokąta (do centrowania mapy).
  LatLng get center {
    if (boundaryLats.isEmpty) return const LatLng(52.0, 19.0);
    final lat = boundaryLats.reduce((a, b) => a + b) / boundaryLats.length;
    final lon = boundaryLons.reduce((a, b) => a + b) / boundaryLons.length;
    return LatLng(lat, lon);
  }

  /// Przesuwa offset całej granicy o [latOffset] stopni szerokości i
  /// [lonOffset] stopni długości geograficznej.
  ///
  /// Modyfikuje [offsetLat] i [offsetLon] addytywnie.
  /// Aby użyć metrów, przelicz najpierw przez [GeoportalService.nudgeField].
  void applyOffset(double latOffset, double lonOffset) {
    offsetLat += latOffset;
    offsetLon += lonOffset;
  }

  // ── Serializacja ─────────────────────────────────────────────────────────────

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'boundaryLats': boundaryLats,
        'boundaryLons': boundaryLons,
        'workingWidthM': workingWidthM,
        if (lineALat != null) 'lineALat': lineALat,
        if (lineALon != null) 'lineALon': lineALon,
        if (lineBLat != null) 'lineBLat': lineBLat,
        if (lineBLon != null) 'lineBLon': lineBLon,
        if (uLDKParcelId != null) 'uLDKParcelId': uLDKParcelId,
        if (terytCode != null) 'terytCode': terytCode,
        if (lastSyncDate != null)
          'lastSyncDate': lastSyncDate!.toIso8601String(),
        if (sourceParcelIds.isNotEmpty) 'sourceParcelIds': sourceParcelIds,
        'source': source.name,
        'offsetLat': offsetLat,
        'offsetLon': offsetLon,
      };

  factory FieldModel.fromJson(Map<dynamic, dynamic> map) => FieldModel(
        id: map['id'] as String,
        name: map['name'] as String,
        boundaryLats: (map['boundaryLats'] as List).cast<double>(),
        boundaryLons: (map['boundaryLons'] as List).cast<double>(),
        workingWidthM: (map['workingWidthM'] as num).toDouble(),
        lineALat: (map['lineALat'] as num?)?.toDouble(),
        lineALon: (map['lineALon'] as num?)?.toDouble(),
        lineBLat: (map['lineBLat'] as num?)?.toDouble(),
        lineBLon: (map['lineBLon'] as num?)?.toDouble(),
        uLDKParcelId: map['uLDKParcelId'] as String?,
        terytCode: map['terytCode'] as String?,
        lastSyncDate: map['lastSyncDate'] != null
            ? DateTime.tryParse(map['lastSyncDate'] as String)
            : null,
        sourceParcelIds: (map['sourceParcelIds'] as List?)?.cast<String>(),
        source: FieldSource.values.firstWhere(
          (e) => e.name == (map['source'] as String?),
          orElse: () => FieldSource.manual,
        ),
        offsetLat: (map['offsetLat'] as num?)?.toDouble() ?? 0.0,
        offsetLon: (map['offsetLon'] as num?)?.toDouble() ?? 0.0,
      );
}
