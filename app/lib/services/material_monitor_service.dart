import 'dart:async';

import '../models/work_task.dart';

// ─────────────────────────────────────────────────────────────────────────────
// MaterialMonitorState — immutable snapshot exposed to UI
// ─────────────────────────────────────────────────────────────────────────────

class MaterialMonitorState {
  const MaterialMonitorState({
    required this.remainingVolume,
    required this.fillFraction,
    required this.rangeHa,
    required this.unit,
  });

  /// How much material is left in the tank (litres or kg).
  final double remainingVolume;

  /// 0.0 → 1.0  (1.0 = full tank).
  final double fillFraction;

  /// Estimated area that can still be covered at the current rate.
  final double rangeHa;

  /// Unit for [remainingVolume] displayed in the UI, e.g. "l" or "kg".
  final String unit;

  static const empty = MaterialMonitorState(
    remainingVolume: 0,
    fillFraction: 0,
    rangeHa: 0,
    unit: 'l',
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// MaterialMonitorService
// ─────────────────────────────────────────────────────────────────────────────

/// Computes real-time material consumption from covered area.
///
/// Usage:
/// ```dart
/// MaterialMonitorService.instance.start(task);
/// MaterialMonitorService.instance.updateArea(coveredHa);
/// final state = MaterialMonitorService.instance.state;
/// ```
///
/// Refill is supported via [refill] — it tops up the current tank and resets
/// the "area consumed since last refill" accumulator so the next decay
/// starts fresh from the topped-up level.
class MaterialMonitorService {
  MaterialMonitorService._();
  static final instance = MaterialMonitorService._();

  // ── Active task state ─────────────────────────────────────────────────────

  WorkTask? _task;

  /// Area covered (ha) at the moment the task / last refill started.
  double _baseAreaHa = 0.0;

  /// Tank volume (same unit as task) at the moment of last refill start.
  double _tankAtBase = 0.0;

  /// Unit abbreviation stripped of the "/ha" suffix, e.g. "l" or "kg".
  String _volUnit = 'l';

  // ── Stream ────────────────────────────────────────────────────────────────

  final _stateController = StreamController<MaterialMonitorState>.broadcast();

  /// Broadcasts [MaterialMonitorState] every time [updateArea] causes a change.
  Stream<MaterialMonitorState> get stream => _stateController.stream;

  /// Last computed state (synchronous).
  MaterialMonitorState _state = MaterialMonitorState.empty;
  MaterialMonitorState get state => _state;

  /// Whether a task with material monitoring is active.
  bool get isActive =>
      _task != null &&
      _task!.targetRate != null &&
      _task!.initialTankVolume != null;

  // ── Control ───────────────────────────────────────────────────────────────

  /// Attach a [WorkTask] to the service.
  ///
  /// [currentAreaHa] is the covered area at the moment the task begins (so
  /// that tasks resumed mid-session start from the correct delta).
  void start(WorkTask task, {double currentAreaHa = 0.0}) {
    _task = task;
    _baseAreaHa = currentAreaHa;
    _tankAtBase = task.initialTankVolume ?? 0.0;
    _volUnit = _stripPerHa(task.unit ?? 'l/ha');
    _recalculate(currentAreaHa);
  }

  /// Detach the active task (e.g. when leaving work mode).
  void stop() {
    _task = null;
    _state = MaterialMonitorState.empty;
    _stateController.add(_state);
  }

  /// Call every time [coveredHa] updates (from SectionControlBridge).
  ///
  /// Only emits a new state when the value changes.
  void updateArea(double coveredHa) {
    if (!isActive) return;
    _recalculate(coveredHa);
  }

  /// Add [addedVolume] to the current tank level and reset the area baseline.
  ///
  /// Clamps to [initialTankVolume] so it never overfills past the original
  /// maximum.
  void refill({required double addedVolume, required double currentAreaHa}) {
    if (_task == null) return;
    final maxTank = _task!.initialTankVolume ?? 0.0;
    // The tank can't exceed original capacity
    final newLevel = (_state.remainingVolume + addedVolume).clamp(0.0, maxTank);
    _tankAtBase = newLevel;
    _baseAreaHa = currentAreaHa;
    _recalculate(currentAreaHa);
  }

  /// Completely refill to original capacity and reset baseline.
  void fullRefill({required double currentAreaHa}) {
    if (_task == null) return;
    _tankAtBase = _task!.initialTankVolume ?? 0.0;
    _baseAreaHa = currentAreaHa;
    _recalculate(currentAreaHa);
  }

  // ── Private ───────────────────────────────────────────────────────────────

  void _recalculate(double currentAreaHa) {
    final task = _task;
    if (task == null ||
        task.targetRate == null ||
        task.initialTankVolume == null) {
      return;
    }
    final rate = task.targetRate!; // l/ha or kg/ha
    final deltaHa = (currentAreaHa - _baseAreaHa).clamp(0.0, double.infinity);
    final consumed = deltaHa * rate;
    final remaining = (_tankAtBase - consumed).clamp(0.0, _tankAtBase);
    final fraction = _tankAtBase > 0 ? remaining / _tankAtBase : 0.0;
    final rangeHa = rate > 0 ? remaining / rate : 0.0;

    _state = MaterialMonitorState(
      remainingVolume: remaining,
      fillFraction: fraction,
      rangeHa: rangeHa,
      unit: _volUnit,
    );
    _stateController.add(_state);
  }

  static String _stripPerHa(String unit) {
    if (unit.contains('/')) return unit.split('/').first.trim();
    return unit;
  }

  void dispose() {
    _stateController.close();
  }
}
