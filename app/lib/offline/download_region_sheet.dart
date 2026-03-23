import 'package:flutter/material.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import 'package:latlong2/latlong.dart';
import 'offline_map_manager.dart';

/// Bottom-sheet pozwalający rolnikowi pobrać/usunąć kafelki offline.
///
/// Otwiera się przez:
/// ```dart
/// DownloadRegionSheet.show(context, center: mapController.center);
/// ```
class DownloadRegionSheet extends StatefulWidget {
  const DownloadRegionSheet({super.key, required this.center});

  final LatLng center;

  static Future<void> show(BuildContext context, {required LatLng center}) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => DownloadRegionSheet(center: center),
    );
  }

  @override
  State<DownloadRegionSheet> createState() => _DownloadRegionSheetState();
}

class _DownloadRegionSheetState extends State<DownloadRegionSheet> {
  double _radiusKm = 3.0;
  int _maxZoom = 17;

  _SheetState _state = _SheetState.idle;
  DownloadProgress? _progress;
  ({double size, int length, int hits, int misses})? _stats;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    final s = await OfflineMapManager.instance.stats();
    if (mounted) setState(() => _stats = s);
  }

  Future<void> _startDownload() async {
    setState(() {
      _state = _SheetState.downloading;
      _error = null;
    });

    final stream = OfflineMapManager.instance.downloadRegion(
      center: widget.center,
      radiusKm: _radiusKm,
      maxZoom: _maxZoom,
    );

    try {
      await for (final p in stream) {
        if (!mounted) return;
        setState(() => _progress = p);
        if (p.isComplete) break;
      }
      setState(() => _state = _SheetState.done);
      await _loadStats();
    } catch (e) {
      setState(() {
        _state = _SheetState.idle;
        _error = e.toString();
      });
    }
  }

  Future<void> _cancel() async {
    await OfflineMapManager.instance.cancelDownload();
    if (mounted) setState(() => _state = _SheetState.idle);
  }

  Future<void> _clear() async {
    await OfflineMapManager.instance.clearAll();
    await _loadStats();
    if (mounted) setState(() => _state = _SheetState.idle);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        top: 16,
        left: 16,
        right: 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Nagłówek ──────────────────────────────────────────────────────
          Row(
            children: [
              const Icon(Icons.download_for_offline_outlined),
              const SizedBox(width: 8),
              Text('Mapy offline',
                  style: Theme.of(context).textTheme.titleLarge),
              const Spacer(),
              if (_stats != null)
                Text(
                  '${_stats!.length} kafelków · '
                  '${(_stats!.size / 1024).toStringAsFixed(1)} MB',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
          const SizedBox(height: 16),

          if (_state != _SheetState.downloading) ...[
            // ── Promień ────────────────────────────────────────────────────
            Text('Promień pobierania: ${_radiusKm.toStringAsFixed(1)} km'),
            Slider(
              value: _radiusKm,
              min: 1,
              max: 10,
              divisions: 18,
              label: '${_radiusKm.toStringAsFixed(1)} km',
              onChanged: (v) => setState(() => _radiusKm = v),
            ),

            // ── Max zoom ───────────────────────────────────────────────────
            Text('Szczegółowość (max zoom): $_maxZoom'),
            Slider(
              value: _maxZoom.toDouble(),
              min: 13,
              max: 18,
              divisions: 5,
              label: '$_maxZoom',
              onChanged: (v) => setState(() => _maxZoom = v.round()),
            ),

            const SizedBox(height: 8),

            // ── Szacowana liczba kafelków ──────────────────────────────────
            _TileCountEstimate(radiusKm: _radiusKm, maxZoom: _maxZoom),

            const SizedBox(height: 12),

            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),

            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    icon: const Icon(Icons.download),
                    label: const Text('Pobierz okolicę'),
                    onPressed: _startDownload,
                  ),
                ),
                if (_stats != null && _stats!.length > 0) ...[
                  const SizedBox(width: 8),
                  IconButton.outlined(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Usuń wszystkie kafelki',
                    onPressed: _clear,
                  ),
                ],
              ],
            ),
          ] else ...[
            // ── Pasek postępu ──────────────────────────────────────────────
            const SizedBox(height: 8),
            if (_progress != null) ...[
              LinearProgressIndicator(
                value: _progress!.percentageProgress / 100,
              ),
              const SizedBox(height: 8),
              Text(
                '${_progress!.cachedTiles} / '
                '${_progress!.maxTiles} kafelków  '
                '(${_progress!.percentageProgress.toStringAsFixed(0)} %)',
              ),
            ] else
              const LinearProgressIndicator(),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: const Icon(Icons.stop),
              label: const Text('Anuluj'),
              onPressed: _cancel,
            ),
          ],

          if (_state == _SheetState.done)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  Icon(Icons.check_circle, color: Colors.green),
                  SizedBox(width: 8),
                  Text('Gotowe! Mapa działa offline.'),
                ],
              ),
            ),

          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

enum _SheetState { idle, downloading, done }

// ── Szacowanie liczby kafelków ────────────────────────────────────────────────

class _TileCountEstimate extends StatelessWidget {
  const _TileCountEstimate({required this.radiusKm, required this.maxZoom});

  final double radiusKm;
  final int maxZoom;

  int _estimate() {
    // Przybliżenie: kafelek z14 ≈ 2.4 km. Przy każdym zoom ×4.
    int total = 0;
    for (int z = 12; z <= maxZoom; z++) {
      final tileSize = 156543.03 / (1 << z) * 256 / 1000; // km
      final side = (radiusKm * 2 / tileSize).ceil() + 1;
      total += side * side;
    }
    return total;
  }

  @override
  Widget build(BuildContext context) {
    final count = _estimate();
    final mb = (count * 15) / 1024; // ~15 KB/kafelek
    return Text(
      'Szacunkowo ~$count kafelków (~${mb.toStringAsFixed(0)} MB)',
      style: Theme.of(context)
          .textTheme
          .bodySmall
          ?.copyWith(color: Colors.grey[600]),
    );
  }
}
