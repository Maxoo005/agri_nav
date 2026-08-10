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

  /// Everything ever loaded into the tank this task (initial fill + all
  /// refills). Used with [_state.remainingVolume] to derive [totalConsumed]
  /// by mass/volume balance, independent of rate changes/refills/pauses.
  double _totalAdded = 0.0;

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

  /// Lifetime material used so far this task, by mass/volume balance:
  /// everything ever loaded into the tank minus what's currently left.
  /// Correct across refills, rate changes and pauses — those only move
  /// material between "in tank" and "used", they never lose track of it.
  double get totalConsumed =>
      (_totalAdded - _state.remainingVolume).clamp(0.0, double.infinity);

  // ── Control ───────────────────────────────────────────────────────────────

  /// Attach a [WorkTask] to the service.
  ///
  /// [currentAreaHa] is the covered area at the moment the task begins (so
  /// that tasks resumed mid-session start from the correct delta).
  ///
  /// Idempotent per task: re-entering Work Mode for the same [WorkTask] must
  /// NOT reset the tank to full — the tank level and the area baseline are
  /// preserved until the task changes (or a refill happens).  Otherwise the
  /// "work runs in the background" flow would silently top the tank up on
  /// every screen re-entry.
  void start(WorkTask task, {double currentAreaHa = 0.0}) {
    final sameTask = _task?.id == task.id;
    _task = task;
    if (!sameTask) {
      _baseAreaHa = currentAreaHa;
      _tankAtBase = task.initialTankVolume ?? 0.0;
      _totalAdded = _tankAtBase;
    }
    _volUnit = _stripPerHa(task.unit ?? 'l/ha');
    _recalculate(currentAreaHa);
  }

  /// First-time tank fill, confirmed by the operator at the start of Work
  /// Mode ([WorkTask.initialTankVolume] is null until this is called — the
  /// amount is no longer fixed back at task-planning time). Establishes the
  /// tank/area baseline that [_recalculate] measures consumption from.
  void confirmInitialFill(double amount, {required double currentAreaHa}) {
    final task = _task;
    if (task == null) return;
    task.initialTankVolume = amount;
    _tankAtBase = amount;
    _baseAreaHa = currentAreaHa;
    _totalAdded = amount;
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
  /// Clamps to [maxCapacity] — the machine's physical tank capacity — so it
  /// never overfills past what the tank can actually hold.
  void refill({
    required double addedVolume,
    required double currentAreaHa,
    required double maxCapacity,
  }) {
    if (_task == null) return;
    final newLevel =
        (_state.remainingVolume + addedVolume).clamp(0.0, maxCapacity);
    final actualAdded = newLevel - _state.remainingVolume;
    if (actualAdded > 0) _totalAdded += actualAdded;
    _tankAtBase = newLevel;
    _baseAreaHa = currentAreaHa;
    _recalculate(currentAreaHa);
  }

  /// Completely refill to [maxCapacity] (machine's physical tank capacity)
  /// and reset baseline.
  void fullRefill({required double currentAreaHa, required double maxCapacity}) {
    if (_task == null) return;
    final actualAdded = maxCapacity - _state.remainingVolume;
    if (actualAdded > 0) _totalAdded += actualAdded;
    _tankAtBase = maxCapacity;
    _baseAreaHa = currentAreaHa;
    _recalculate(currentAreaHa);
  }

  /// Changes the application rate (l/ha or kg/ha) mid-task.
  ///
  /// Consumption so far (at the OLD rate) is locked in first — the current
  /// [_recalculate] result becomes the new base tank level and area baseline
  /// — so the rate change only affects consumption going forward, never
  /// retroactively recomputes what was already used.
  void setRate(double newRate, {required double currentAreaHa}) {
    final task = _task;
    if (task == null) return;
    _recalculate(currentAreaHa);
    _tankAtBase = _state.remainingVolume;
    _baseAreaHa = currentAreaHa;
    task.targetRate = newRate;
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
