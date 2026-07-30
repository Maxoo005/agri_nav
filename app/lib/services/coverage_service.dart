import 'package:hive_flutter/hive_flutter.dart';
import 'package:latlong2/latlong.dart';

/// Hive box name for coverage tracks.
const _kCoverageBox = 'coverage';

/// Persists and exposes the GPS track recorded during field work.
///
/// Tracks are keyed either by a plain [fieldId] (legacy, backward-compat) or
/// by `"${fieldId}_${taskId}"` when a [WorkTask] is active.  Old tracks stored
/// under the plain key are still loadable via [loadForField].
class CoverageService {
  CoverageService._();
  static final instance = CoverageService._();

  /// Open the Hive box.  Call once in main() after Hive.initFlutter().
  static Future<void> init() => Hive.openBox(_kCoverageBox);

  Box get _box => Hive.box(_kCoverageBox);

  static const int _flushInterval = 100; // flush every N new points

  // ── In-memory session state ───────────────────────────────────────────────

  final List<LatLng> _buffer = [];

  /// Active Hive key: either `fieldId` (legacy) or `${fieldId}_${taskId}`.
  String? _activeKey;

  // ── Tracking control ─────────────────────────────────────────────────────

  /// Starts (or resumes) recording.
  ///
  /// When [taskId] is provided the track is stored under `"${fieldId}_${taskId}"`.
  /// When [taskId] is null the plain [fieldId] key is used (legacy behaviour,
  /// keeps backward-compatibility with existing saved tracks).
  void startTracking(String fieldId, {String? taskId}) {
    final key = taskId != null ? '${fieldId}_$taskId' : fieldId;
    if (_activeKey == key) return;
    _activeKey = key;
    _buffer
      ..clear()
      ..addAll(_loadRaw(key));
  }

  /// Stops recording and flushes the remaining buffer to Hive.
  Future<void> stopTracking() async {
    await _flush();
    _buffer.clear();
    _activeKey = null;
  }

  /// Appends a new GPS point to the current track.
  /// Ignored when tracking is not active.
  void addPoint(LatLng point) {
    if (_activeKey == null) return;
    _buffer.add(point);
    if (_buffer.length % _flushInterval == 0) {
      _flush(); // fire-and-forget — no need to await per tick
    }
  }

  /// Live read-only view of the current in-memory track.
  List<LatLng> get currentTrack => List.unmodifiable(_buffer);

  // ── Persistence ───────────────────────────────────────────────────────────

  /// Load the stored track for a field using the legacy plain-key scheme.
  List<LatLng> loadForField(String fieldId) => _loadRaw(fieldId);

  /// Load the stored track for a specific task.
  List<LatLng> loadForTask(String fieldId, String taskId) =>
      _loadRaw('${fieldId}_$taskId');

  /// Erase the legacy (plain-key) track for a field.
  Future<void> clearForField(String fieldId) async {
    if (_activeKey == fieldId) _buffer.clear();
    await _box.delete(fieldId);
  }

  /// Erase the track for a specific task.
  Future<void> clearForTask(String fieldId, String taskId) async {
    final key = '${fieldId}_$taskId';
    if (_activeKey == key) _buffer.clear();
    await _box.delete(key);
  }

  // ── Private helpers ───────────────────────────────────────────────────────

  Future<void> _flush() async {
    final key = _activeKey;
    if (key == null || _buffer.isEmpty) return;
    await _box.put(key, {
      'lats': _buffer.map((p) => p.latitude).toList(),
      'lons': _buffer.map((p) => p.longitude).toList(),
    });
  }

  List<LatLng> _loadRaw(String key) {
    final raw = _box.get(key);
    if (raw == null) return [];
    final lats = (raw['lats'] as List).cast<double>();
    final lons = (raw['lons'] as List).cast<double>();
    return List.generate(lats.length, (i) => LatLng(lats[i], lons[i]));
  }
}
