import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import 'package:latlong2/latlong.dart';

/// Nazwa magazynu FMTC używana w całej aplikacji.
const String kTileStore = 'osmTiles';

/// URL satelitarny Esri World Imagery — wysoka rozdzielczość, brak klucza API.
/// UWAGA: Esri używa kolejności {z}/{y}/{x} (nie {z}/{x}/{y} jak OSM).
const String kSatUrl =
    'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';

/// URL OSM — zachowany jako fallback / do pobierania przez FMTC.
const String kOsmUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

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
