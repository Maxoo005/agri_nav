import 'package:latlong2/latlong.dart';

import '../utils/geo_utils.dart';
import '../utils/elastic_warp.dart';

/// Źródło pochodzenia granicy pola.
enum FieldSource {
  /// Ręcznie narysowane przez użytkownika.
  manual,

  /// Pobrane z ULDK/GUGiK.
  uldk,

  /// Pobrane z rejestru LPIS (dane z ULDK/GUGiK).
  lpis,

  /// Wczytane z pliku KML/GeoJSON dostarczonego przez rolnika (np.
  /// narysowane w Google Earth Pro / QGIS na ortofotomapie i wyeksportowane)
  /// — patrz `FileImportSheet`.
  file,
}

/// Metoda wyznaczenia linii AB ([FieldModel.lineA]/[FieldModel.lineB]).
/// Czysto informacyjne — do pokazania w UI, nie wpływa na prowadzenie.
enum AbSource {
  /// Nie wyznaczono — SwathGuidance używa domyślnego/automatycznego kąta.
  none,

  /// Dwa stuknięcia na mapie (szybkie, wystarczające dla wąskich maszyn).
  manual2Points,

  /// Rzeczywisty przejazd RTK + dopasowanie najmniejszych kwadratów
  /// (precyzyjne, dla szerokich maszyn).
  drivenRecording,

  /// Linia AB jest zapisana (lineA/lineB niepuste), ale rekord pochodzi
  /// sprzed wprowadzenia [AbSource] — metoda wyznaczenia nie jest znana.
  unknown,
}

/// Która metoda korekty punktami kontrolnymi jest aktywna dla danego pola —
/// patrz [FieldModel.boundary]. Ustawiane automatycznie przez
/// `GeoportalService` w zależności od tego, ile par punktów użytkownik
/// zatwierdził (2-3 → [similarity], 4+ → [elastic]) — nie jest to wybór
/// dokonywany ręcznie przez użytkownika.
enum FieldCorrectionMode {
  /// Brak korekty punktami kontrolnymi.
  none,

  /// Sztywna transformacja podobieństwa (obrót+skala+przesunięcie) — patrz
  /// [FieldModel.cpRotationRad]/[cpScale]/[cpTxM]/[cpTyM] i
  /// [GeoUtils.fitSimilarity2D].
  similarity,

  /// Elastyczna transformacja (Inverse Distance Weighting) — patrz
  /// [FieldModel.elasticSrcLats] i [ElasticWarp].
  elastic,
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

  /// Metoda wyznaczenia [lineA]/[lineB] — patrz [AbSource].
  AbSource abSource;

  // ── Pola katastralne (ULDK) ─────────────────────────────────────────────────

  /// Identyfikator działki z ULDK (np. "141201_2.0001.1234/2").
  /// Null gdy pole narysowane ręcznie.
  String? uLDKParcelId;

  /// Siedmiocyfrowy kod TERYT gminy, np. "1412012" (woj+pow+gm).
  String? terytCode;

  /// Data i godzina ostatniej synchronizacji z ULDK.
  DateTime? lastSyncDate;

  /// Lista numerów ewidencyjnych działek, z których zbudowano to pole
  /// (wynik operacji union w Kreatorze Pola). Pusta gdy pole narysowane ręcznie
  /// lub pobrane jako pojedyncza działka.
  List<String> sourceParcelIds;

  /// Identyfikatory działek LPIS użytych do budowy tego pola.
  /// Puste gdy pole pochodzi ze źródła innego niż [FieldSource.lpis].
  List<String> lpisParcelIds;

  /// Źródło danych granicy.
  FieldSource source;

  /// Ręczna korekta przesunięcia granicy (WGS-84 stopnie).
  /// Rolnik może przesunąć działkę strzałkami, aby pokryła się ze zdjęciem.
  double offsetLat;
  double offsetLon;

  /// Korekta punktami kontrolnymi — transformacja podobieństwa (obrót +
  /// skala + przesunięcie w metrach ENU) dopasowana metodą najmniejszych
  /// kwadratów do par punktów wskazanych przez rolnika. Niezależna od
  /// [offsetLat]/[offsetLon] — patrz [boundary].
  double cpRotationRad;
  double cpScale;
  double cpTxM;
  double cpTyM;

  /// Która metoda korekty punktami kontrolnymi jest aktywna — patrz
  /// [FieldCorrectionMode] i [boundary]. Wzajemnie wyłączna z drugą metodą:
  /// zatwierdzenie jednej zeruje dane drugiej (patrz `GeoportalService`).
  FieldCorrectionMode correctionMode;

  /// Korekta punktami kontrolnymi — transformacja elastyczna (Inverse
  /// Distance Weighting) dopasowana do ≥4 par punktów wskazanych przez
  /// rolnika. W przeciwieństwie do [cpRotationRad] i spółki (4 liczby), nie
  /// da się jej skompresować do stałej liczby parametrów — przechowywane są
  /// surowe pary WGS-84 (źródło↔cel), a dopasowanie ([ElasticWarp.fit])
  /// jest liczone od nowa przy każdym odczycie [boundary]. Cztery równoległe
  /// listy tej samej długości (jak [boundaryLats]/[boundaryLons]). Puste, gdy
  /// [correctionMode] != [FieldCorrectionMode.elastic].
  List<double> elasticSrcLats;
  List<double> elasticSrcLons;
  List<double> elasticTgtLats;
  List<double> elasticTgtLons;

  /// Powierzchnia pola [ha] (dane LPIS), przeliczona
  /// z geometrii granicy. Null gdy jeszcze nie obliczono.
  double? areaHa;

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
    this.abSource = AbSource.none,
    this.uLDKParcelId,
    this.terytCode,
    this.lastSyncDate,
    List<String>? sourceParcelIds,
    List<String>? lpisParcelIds,
    this.source = FieldSource.manual,
    this.offsetLat = 0.0,
    this.offsetLon = 0.0,
    this.cpRotationRad = 0.0,
    this.cpScale = 1.0,
    this.cpTxM = 0.0,
    this.cpTyM = 0.0,
    this.correctionMode = FieldCorrectionMode.none,
    List<double>? elasticSrcLats,
    List<double>? elasticSrcLons,
    List<double>? elasticTgtLats,
    List<double>? elasticTgtLons,
    this.areaHa,
  })  : sourceParcelIds = sourceParcelIds ?? [],
        lpisParcelIds = lpisParcelIds ?? [],
        elasticSrcLats = elasticSrcLats ?? [],
        elasticSrcLons = elasticSrcLons ?? [],
        elasticTgtLats = elasticTgtLats ?? [],
        elasticTgtLons = elasticTgtLons ?? [];

  // ── Wygoda ──────────────────────────────────────────────────────────────────

  /// Granica jako lista LatLng: (1) oryginalna geometria katastralna →
  /// (2) korekta punktami kontrolnymi ([correctionMode] — [similarity] przez
  /// [cpRotationRad]/[cpScale]/[cpTxM]/[cpTyM], albo [elastic] przez
  /// [elasticSrcLats] i spółka), jeśli ustawiona → (3) przesunięcie offsetowe
  /// ([offsetLat]/[offsetLon]).
  ///
  /// Fast path: gdy [correctionMode] to [FieldCorrectionMode.none] (brak
  /// korekty punktami kontrolnymi), krok (2) jest pomijany — zachowanie
  /// identyczne jak przed wprowadzeniem tego mechanizmu.
  List<LatLng> get boundary {
    switch (correctionMode) {
      case FieldCorrectionMode.none:
        return List.generate(
          boundaryLats.length,
          (i) => LatLng(
            boundaryLats[i] + offsetLat,
            boundaryLons[i] + offsetLon,
          ),
        );

      case FieldCorrectionMode.similarity:
        final origin = center;
        return List.generate(boundaryLats.length, (i) {
          final raw = LatLng(boundaryLats[i], boundaryLons[i]);
          final corrected = GeoUtils.applySimilarity2D(
            origin,
            raw,
            rotationRad: cpRotationRad,
            scale: cpScale,
            txM: cpTxM,
            tyM: cpTyM,
          );
          return LatLng(
            corrected.latitude + offsetLat,
            corrected.longitude + offsetLon,
          );
        });

      case FieldCorrectionMode.elastic:
        // Dane niekompletne (np. ręcznie edytowany zapis) — zachowaj się
        // jak brak korekty, zamiast wywalić się na assercie w fit().
        if (elasticSrcLats.length < ElasticWarp.minControlPoints) {
          return List.generate(
            boundaryLats.length,
            (i) => LatLng(
              boundaryLats[i] + offsetLat,
              boundaryLons[i] + offsetLon,
            ),
          );
        }
        final origin = center;
        final src = List.generate(
            elasticSrcLats.length,
            (i) => GeoUtils.toEnu(
                origin, LatLng(elasticSrcLats[i], elasticSrcLons[i])));
        final tgt = List.generate(
            elasticTgtLats.length,
            (i) => GeoUtils.toEnu(
                origin, LatLng(elasticTgtLats[i], elasticTgtLons[i])));
        final warp = ElasticWarp.fit(src, tgt);
        // Zagęść surowe krawędzie PRZED transformacją — inaczej krzywizna
        // byłaby widoczna tylko w narożnikach (jedynych istniejących
        // wierzchołkach), a środek długiego, prostego boku (dokładnie to,
        // co ta korekta ma naprawić) nadal rysowałby się jako prosta. Patrz
        // [ElasticWarp.densifyRing].
        final rawEnu = ElasticWarp.densifyRing(List.generate(
            boundaryLats.length,
            (i) => GeoUtils.toEnu(
                origin, LatLng(boundaryLats[i], boundaryLons[i]))));
        return rawEnu.map((p) {
          final t = warp.transform(p);
          final corrected = GeoUtils.fromEnu(origin, t.e, t.n);
          return LatLng(
            corrected.latitude + offsetLat,
            corrected.longitude + offsetLon,
          );
        }).toList();
    }
  }

  LatLng? get lineA => lineALat != null ? LatLng(lineALat!, lineALon!) : null;
  LatLng? get lineB => lineBLat != null ? LatLng(lineBLat!, lineBLon!) : null;

  /// Kierunek linii AB [°], liczony na żądanie z [lineA]/[lineB] — nie jest
  /// osobno przechowywany, żeby nie powstało drugie, ręcznie synchronizowane
  /// źródło prawdy obok współrzędnych. `null` gdy AB nie jest wyznaczona.
  /// Konwencja `[0,180)` — jak wszędzie indziej w kodzie (linia AB ma
  /// kierunek, nie zwrot).
  double? get abHeadingDeg {
    final a = lineA, b = lineB;
    if (a == null || b == null) return null;
    return GeoUtils.bearing(a, b) % 180.0;
  }

  /// Punkt środkowy wielokąta (do centrowania mapy).
  LatLng get center {
    if (boundaryLats.isEmpty) return const LatLng(52.0, 19.0);
    final lat = boundaryLats.reduce((a, b) => a + b) / boundaryLats.length;
    final lon = boundaryLons.reduce((a, b) => a + b) / boundaryLons.length;
    return LatLng(lat, lon);
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
        'abSource': abSource.name,
        if (uLDKParcelId != null) 'uLDKParcelId': uLDKParcelId,
        if (terytCode != null) 'terytCode': terytCode,
        if (lastSyncDate != null)
          'lastSyncDate': lastSyncDate!.toIso8601String(),
        if (sourceParcelIds.isNotEmpty) 'sourceParcelIds': sourceParcelIds,
        if (lpisParcelIds.isNotEmpty) 'lpisParcelIds': lpisParcelIds,
        'source': source.name,
        'offsetLat': offsetLat,
        'offsetLon': offsetLon,
        'cpRotationRad': cpRotationRad,
        'cpScale': cpScale,
        'cpTxM': cpTxM,
        'cpTyM': cpTyM,
        'correctionMode': correctionMode.name,
        if (elasticSrcLats.isNotEmpty) 'elasticSrcLats': elasticSrcLats,
        if (elasticSrcLons.isNotEmpty) 'elasticSrcLons': elasticSrcLons,
        if (elasticTgtLats.isNotEmpty) 'elasticTgtLats': elasticTgtLats,
        if (elasticTgtLons.isNotEmpty) 'elasticTgtLons': elasticTgtLons,
        if (areaHa != null) 'areaHa': areaHa,
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
        // Wsteczna kompatybilność: rekordy zapisane przed wprowadzeniem
        // AbSource mogą już mieć lineALat (z testów), ale nie mają klucza
        // 'abSource' — uczciwie oznacz to jako "nieznana metoda", zamiast
        // zgadywać "ręcznie" czy "przejazd".
        abSource: AbSource.values.firstWhere(
          (e) => e.name == (map['abSource'] as String?),
          orElse: () => map['lineALat'] != null
              ? AbSource.unknown
              : AbSource.none,
        ),
        uLDKParcelId: map['uLDKParcelId'] as String?,
        terytCode: map['terytCode'] as String?,
        lastSyncDate: map['lastSyncDate'] != null
            ? DateTime.tryParse(map['lastSyncDate'] as String)
            : null,
        sourceParcelIds: (map['sourceParcelIds'] as List?)?.cast<String>(),
        // Wsteczna kompatybilność: starsze zapisy używały klucza 'arimrParcelIds'.
        lpisParcelIds: ((map['lpisParcelIds'] ?? map['arimrParcelIds'])
                as List?)
            ?.cast<String>(),
        // Wsteczna kompatybilność: starsze zapisy używały nazwy 'arimr'.
        source: FieldSource.values.firstWhere(
          (e) => e.name == (map['source'] as String?) ||
              ((map['source'] == 'arimr') && e == FieldSource.lpis),
          orElse: () => FieldSource.manual,
        ),
        offsetLat: (map['offsetLat'] as num?)?.toDouble() ?? 0.0,
        offsetLon: (map['offsetLon'] as num?)?.toDouble() ?? 0.0,
        cpRotationRad: (map['cpRotationRad'] as num?)?.toDouble() ?? 0.0,
        cpScale: (map['cpScale'] as num?)?.toDouble() ?? 1.0,
        cpTxM: (map['cpTxM'] as num?)?.toDouble() ?? 0.0,
        cpTyM: (map['cpTyM'] as num?)?.toDouble() ?? 0.0,
        // Wsteczna kompatybilność: rekordy zapisane przed wprowadzeniem
        // correctionMode mogą już mieć niezerową korektę similarity (stary
        // mechanizm "punktów kontrolnych"), ale nie mają klucza
        // 'correctionMode' — odtwórz dokładnie dzisiejszy niejawny warunek
        // "hasCp", żeby renderowały się identycznie jak przed tą zmianą.
        correctionMode: FieldCorrectionMode.values.firstWhere(
          (e) => e.name == (map['correctionMode'] as String?),
          orElse: () =>
              ((map['cpRotationRad'] as num?)?.toDouble() ?? 0.0) != 0.0 ||
                      ((map['cpScale'] as num?)?.toDouble() ?? 1.0) != 1.0 ||
                      ((map['cpTxM'] as num?)?.toDouble() ?? 0.0) != 0.0 ||
                      ((map['cpTyM'] as num?)?.toDouble() ?? 0.0) != 0.0
                  ? FieldCorrectionMode.similarity
                  : FieldCorrectionMode.none,
        ),
        elasticSrcLats: (map['elasticSrcLats'] as List?)?.cast<double>(),
        elasticSrcLons: (map['elasticSrcLons'] as List?)?.cast<double>(),
        elasticTgtLats: (map['elasticTgtLats'] as List?)?.cast<double>(),
        elasticTgtLons: (map['elasticTgtLons'] as List?)?.cast<double>(),
        areaHa: (map['areaHa'] as num?)?.toDouble(),
      );
}
