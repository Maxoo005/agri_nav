import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import 'package:latlong2/latlong.dart';

/// Nazwa magazynu FMTC używana w całej aplikacji.
const String kTileStore = 'osmTiles';

/// URL OpenStreetMap — globalny podkład wektorowy, poprawnie wyrównany z GUGiK.
const String kSatUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
const String kOsmUrl = kSatUrl;

/// URL bazowy serwisu WMS — Ortofotomapa HighResolution GUGiK (Polska).
///
/// GetCapabilities:
///   $kGeoportalWmsUrl?SERVICE=WMS&REQUEST=GetCapabilities
/// Pokrycie: obszar Polski (≈ lat 49–55, lon 14–24.5).
/// Obsługiwane CRS: EPSG:4326, EPSG:3857, EPSG:2178–2183, EPSG:2180.
const String kGeoportalWmsUrl =
    'https://mapy.geoportal.gov.pl/wss/service/PZGIK/ORTO/WMS/HighResolution';

/// Osobny magazyn FMTC dla kafelków Geoportal (nie miesza z OSM).
const String kGeoportalTileStore = 'geoportalTiles';

/// Tryby podkładu mapowego dostępne w MapView.
enum MapLayerMode {
  /// Tryb konfiguracji — Ortofotomapa Geoportal GUGiK (WMS EPSG:4326).
  /// Umożliwia weryfikację granic ARiMR/ULDK względem rzeczywistości.
  geoportal,

  /// Tryb pracy — brak kafelków mapowych, ciemne tło #1A1A1A + siatka pomocnicza.
  /// Oszczędza transfer danych i zasoby GPU podczas rzeczywistej pracy w polu.
  work,
}

/// Zarządza pobieraniem i usuwaniem kafelków offline dla FMTC.
class OfflineMapManager {
  OfflineMapManager._();
  static final instance = OfflineMapManager._();

  final _store = const FMTCStore(kTileStore);

  // ── Statystyki ──────────────────────────────────────────────────────────────

  /// Liczba zapisanych kafelków i zajęte miejsce.
  /// Zwraca record: `(size: KiB, length: liczba kafelków, hits: trafienia, misses: pudła)`.
  Future<({double size, int length, int hits, int misses})> stats() =>
      _store.stats.all;

  // ── Pobieranie regionu ───────────────────────────────────────────────────────

  /// Pobiera prostokątny obszar wokół [center] o promieniu [radiusKm] km
  /// dla poziomów zoom [minZoom]–[maxZoom].
  ///
  /// Zwraca strumień postępu [DownloadProgress].
  Stream<DownloadProgress> downloadRegion({
    required LatLng center,
    double radiusKm = 3.0,
    int minZoom = 12,
    int maxZoom = 17,
  }) {
    // Przybliżone przesunięcie w stopniach: 1 km ≈ 0.009°
    final delta = radiusKm * 0.009;
    final region = RectangleRegion(
      LatLngBounds(
        LatLng(center.latitude - delta, center.longitude - delta),
        LatLng(center.latitude + delta, center.longitude + delta),
      ),
    );

    return _store.download.startForeground(
      region: region.toDownloadable(
        minZoom: minZoom,
        maxZoom: maxZoom,
        options: TileLayer(
          urlTemplate: kSatUrl,
          userAgentPackageName: 'com.example.agri_nav',
        ),
      ),
    );
  }

  /// Anuluje aktywne pobieranie.
  Future<void> cancelDownload() => _store.download.cancel();

  // ── Czyszczenie ─────────────────────────────────────────────────────────────

  /// Usuwa wszystkie zapisane kafelki.
  Future<void> clearAll() => _store.manage.reset();
}
