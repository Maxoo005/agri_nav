import 'dart:async';

import 'package:hive_flutter/hive_flutter.dart';

import '../models/work_task.dart';

const _kSessionBox = 'work_session';
const _kSessionKey = 'session';

/// Formatuje [Duration] jako `H:MM:SS` (a po 24 h jako `Dd H:MM:SS`).
String formatWorkDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  if (h >= 24) {
    return '${d.inDays}d ${h % 24}:$mm:$ss';
  }
  return '$h:$mm:$ss';
}

/// Wydajność [ha/h] na podstawie faktycznie zrobionych hektarów i czasu pracy:
/// `coveredHa / czas [h]`. Zwraca 0 przy zerowym czasie pracy.
double hectaresPerHourOf(double coveredHa, Duration duration) {
  final hours = duration.inMilliseconds / Duration.millisecondsPerHour;
  if (hours <= 0) return 0;
  return coveredHa / hours;
}

/// Singleton — stan aktywności pracy biegnącej W TLE.
///
/// Wymóg UX: praca działa w tle aż do jej jawnego zakończenia przez operatora.
/// Ten serwis trzyma licznik czasu pracy, który:
///   • liczy dalej, gdy użytkownik opuści ekran Trybu Pracy (wstecz / inny
///     ekran) lub przełączy aplikację w tło systemu,
///   • STOPUJE się w momencie wstrzymania (uzupełnianie zbiornika),
///   • ZATRZYMUJE się definitywnie po [finish] — czas się zamraża.
///
/// Stan sesji jest zapisywany w Hive, więc przetrwa restart aplikacji i
/// licznik będzie biegł aż operator jawnie nie zakończy pracy.
class WorkSessionService {
  WorkSessionService._();
  static final instance = WorkSessionService._();

  /// Otwiera box i wznawia niedokończoną sesję (jeśli istnieje). Wywołać w
  /// main() po Hive.initFlutter().
  static Future<void> init() async {
    final box = await Hive.openBox(_kSessionBox);
    final raw = box.get(_kSessionKey);
    if (raw is! Map) return;
    final paused = raw['paused'] as bool? ?? false;
    final runningSinceRaw = raw['runningSince'] as String?;
    // Sesja zakończona albo niekompletna → czyścimy, nic nie wznawiamy.
    if (raw['finished'] == true ||
        raw['fieldId'] is! String ||
        (!paused && runningSinceRaw == null)) {
      await box.delete(_kSessionKey);
      return;
    }
    instance._fieldId = raw['fieldId'] as String;
    instance._taskId = raw['taskId'] as String?;
    instance._accumulatedMs = (raw['accumulatedMs'] as num?)?.toInt() ?? 0;
    instance._runningSince =
        runningSinceRaw != null ? DateTime.tryParse(runningSinceRaw) : null;
    instance._paused = paused;
    instance._machineOff = raw['machineOff'] as bool? ?? false;
    if (instance._runningSince != null && !paused) {
      instance._startTicker();
    }
  }

  Box get _box => Hive.box(_kSessionBox);

  // ── Stan sesji ────────────────────────────────────────────────────────────

  String? _fieldId;
  String? _taskId;
  WorkTask? _task;

  /// Naliczony czas z zakończonych segmentów [ms].
  int _accumulatedMs = 0;

  /// Początek bieżącego (niewstrzymanego) segmentu; `null` gdy wstrzymany,
  /// zakończony albo brak sesji.
  DateTime? _runningSince;

  bool _paused = false;

  /// Ręczny wyłącznik maszyny (np. opryskiwacza/rozsiewacza) — operator
  /// jedzie dalej (np. na uwrociu albo drogą dojazdową), ale narzędzie jest
  /// fizycznie wyłączone: nie maluje śladu pokrycia i nie zużywa materiału.
  /// W odróżnieniu od [pause] NIE zatrzymuje licznika czasu pracy ani
  /// nawigacji — to lokalny stan sekcji, nie przerwa w pracy.
  bool _machineOff = false;

  final _controller = StreamController<Duration>.broadcast();
  Timer? _ticker;

  // ── Odczyt stanu ──────────────────────────────────────────────────────────

  String? get fieldId => _fieldId;
  String? get taskId => _taskId;
  WorkTask? get task => _task;

  /// Sesja rozpoczęta i nie zakończona (liczy czas lub jest wstrzymana).
  bool get isActive => _runningSince != null || _paused;

  bool get paused => _paused;

  bool get machineOff => _machineOff;

  /// Aktualny łączny czas pracy (uwzględnia bieżący segment i przerwy).
  Duration get elapsed {
    var ms = _accumulatedMs;
    if (_runningSince != null) {
      ms += DateTime.now().difference(_runningSince!).inMilliseconds;
    }
    return Duration(milliseconds: ms);
  }

  /// Emituje [elapsed] przy każdej zmianie stanu i co sekundę podczas pracy.
  Stream<Duration> get stream => _controller.stream;

  // ── Sterowanie ────────────────────────────────────────────────────────────

  /// Rozpoczyna (lub kontynuuje) sesję dla pola [fieldId].
  ///
  /// Gdy dla tego samego pola trwa już sesja — tylko podpina brakujące
  /// zadanie; NIGDY nie zeruje naliczonego czasu i NIE wznawia po pauzie
  /// (wznowienie robi wyłącznie jawne [resume] przyciskiem "Wznów").
  void start({required String fieldId, WorkTask? task}) {
    if (_runningSince != null || _paused) {
      if (_fieldId != null && _fieldId != fieldId) {
        // Inne pole przy aktywnej sesji → zamknij starą i zacznij nową.
        finish();
      } else {
        if (_task == null && task != null) {
          _task = task;
          _taskId = task.id;
          _persist();
        }
        return;
      }
    }
    _fieldId = fieldId;
    _task = task;
    _taskId = task?.id;
    _accumulatedMs = 0;
    _paused = false;
    _runningSince = DateTime.now();
    _startTicker();
    _emit();
    _persist();
  }

  /// Wstrzymuje licznik czasu (uzupełnianie zbiornika, przerwa).
  void pause() {
    if (_runningSince == null) return;
    _accumulatedMs += DateTime.now().difference(_runningSince!).inMilliseconds;
    _runningSince = null;
    _paused = true;
    _emit();
    _persist();
  }

  /// Wznawia odliczanie czasu pracy.
  void resume() {
    if (!_paused) return;
    _paused = false;
    _runningSince = DateTime.now();
    _startTicker();
    _emit();
    _persist();
  }

  /// Przełącza ręczny wyłącznik maszyny (patrz [machineOff]).
  void setMachineOff(bool value) {
    if (_machineOff == value) return;
    _machineOff = value;
    _emit();
    _persist();
  }

  /// Kończy pracę: czas się zamraża, sesja przestaje istnieć w tle.
  /// Nagrywanie pokrycia zatrzymuje wywołujący (CoverageService).
  void finish() {
    if (_runningSince != null) {
      _accumulatedMs += DateTime.now().difference(_runningSince!).inMilliseconds;
    }
    _runningSince = null;
    _paused = false;
    _machineOff = false;
    _ticker?.cancel();
    _ticker = null;
    _emit();
    _box.delete(_kSessionKey);
  }

  /// Całkowicie usuwa sesję (bez zachowywania czasu).
  void reset() {
    _ticker?.cancel();
    _ticker = null;
    _fieldId = null;
    _task = null;
    _taskId = null;
    _accumulatedMs = 0;
    _runningSince = null;
    _paused = false;
    _machineOff = false;
    _emit();
    _box.delete(_kSessionKey);
  }

  // ── Prywatne ──────────────────────────────────────────────────────────────

  void _startTicker() {
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) => _emit());
  }

  void _emit() {
    if (!_controller.isClosed) _controller.add(elapsed);
  }

  void _persist() {
    _box.put(_kSessionKey, {
      'fieldId': _fieldId,
      'taskId': _taskId,
      'accumulatedMs': _accumulatedMs,
      'runningSince': _runningSince?.toIso8601String(),
      'paused': _paused,
      'machineOff': _machineOff,
      'finished': false,
    });
  }

  void dispose() {
    _ticker?.cancel();
    _controller.close();
  }
}
