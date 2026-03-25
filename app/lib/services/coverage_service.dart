import 'package:hive_flutter/hive_flutter.dart';
import 'package:latlong2/latlong.dart';

/// Hive box name for coverage tracks.
const kCoverageBox = 'coverage';

/// Persists and exposes the GPS track recorded during field work.
///
/// One track per field (keyed by [FieldModel.id]).  Points are accumulated
/// in an in-memory buffer and flushed to Hive every [_flushInterval] points,
/// keeping disk I/O minimal without risking data loss on crash.
class CoverageService {
  CoverageService._();
  static final instance = CoverageService._();

  /// Open the Hive box.  Call once in main() after Hive.initFlutter().
  static Future<void> init() => Hive.openBox(kCoverageBox);

  Box get _box => Hive.box(kCoverageBox);

  static const int _flushInterval = 100; // flush every N new points

  // ── In-memory session state ───────────────────────────────────────────────

  final List<LatLng> _buffer = [];
  String? _activeFieldId;

  /// Starts (or resumes) recording for the given field.
  /// Loads any previously saved track for that field.
  void startTracking(String fieldId) {
    if (_activeFieldId == fieldId) return;
    _activeFieldId = fieldId;
    _buffer
      ..clear()
      ..addAll(_loadRaw(fieldId));
  }

  /// Stops recording and flushes the remaining buffer to Hive.
  Future<void> stopTracking() async {
    await _flush();
    _buffer.clear();
    _activeFieldId = null;
  }

  /// Appends a new GPS point to the current track.
  /// Ignored when no field is active ([startTracking] not called).
  void addPoint(LatLng point) {
    if (_activeFieldId == null) return;
    _buffer.add(point);
    if (_buffer.length % _flushInterval == 0) {
      _flush(); // fire-and-forget — no need to await per tick
    }
  }

  /// Live read-only view of the current in-memory track.
  List<LatLng> get currentTrack => List.unmodifiable(_buffer);

  // ── Persistence ───────────────────────────────────────────────────────────

  /// Load the stored track for any field (suitable for replay/display).
  List<LatLng> loadForField(String fieldId) => _loadRaw(fieldId);

  /// Erase the stored track for a field (also clears in-memory buffer if active).
  Future<void> clearForField(String fieldId) async {
    if (_activeFieldId == fieldId) _buffer.clear();
    await _box.delete(fieldId);
  }

  // ── Private helpers ───────────────────────────────────────────────────────

  Future<void> _flush() async {
    final id = _activeFieldId;
    if (id == null || _buffer.isEmpty) return;
    await _box.put(id, {
      'lats': _buffer.map((p) => p.latitude).toList(),
      'lons': _buffer.map((p) => p.longitude).toList(),
    });
  }

  List<LatLng> _loadRaw(String fieldId) {
    final raw = _box.get(fieldId);
    if (raw == null) return [];
    final lats = (raw['lats'] as List).cast<double>();
    final lons = (raw['lons'] as List).cast<double>();
    return List.generate(lats.length, (i) => LatLng(lats[i], lons[i]));
  }
}
