import 'package:agri_nav/models/field_model.dart';
import 'package:agri_nav/models/machine_model.dart';
import 'package:agri_nav/models/work_task.dart';
import 'package:agri_nav/services/coverage_service.dart';
import 'package:agri_nav/services/field_service.dart';
import 'package:agri_nav/services/machine_service.dart';
import 'package:agri_nav/services/material_monitor_service.dart';
import 'package:agri_nav/services/work_mode_settings_service.dart';
import 'package:agri_nav/services/work_session_service.dart';
import 'package:agri_nav/services/work_task_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../support/test_support.dart';

WorkTask _task({
  String id = 't1',
  double? rate = 100,
  double? tank = 1000,
  String? unit = 'l/ha',
}) =>
    WorkTask(
      id: id,
      fieldId: 'f1',
      taskType: TaskType.spray,
      targetRate: rate,
      initialTankVolume: tank,
      unit: unit,
      createdAt: DateTime.utc(2025),
    );

FieldModel _field(String id, String name) {
  final r = rect(200, 100);
  return FieldModel(
    id: id,
    name: name,
    boundaryLats: [for (final p in r) p.latitude],
    boundaryLons: [for (final p in r) p.longitude],
  );
}

void main() {
  group('MaterialMonitorService', () {
    final m = MaterialMonitorService.instance;
    setUp(m.stop);
    tearDown(m.stop);

    test('nieaktywny bez zadania, dawki lub zbiornika', () {
      expect(m.isActive, isFalse);
      m.updateArea(5);
      expect(m.state.remainingVolume, closeTo(0, 1e-12));
      m.start(_task(rate: null));
      expect(m.isActive, isFalse);
      m.start(_task(id: 't2', tank: null));
      expect(m.isActive, isFalse);
    });

    test('zużycie = powierzchnia × dawka', () {
      m.start(_task(), currentAreaHa: 2);
      m.updateArea(5);
      expect(m.state.remainingVolume, closeTo(700, 1e-9));
      expect(m.state.fillFraction, closeTo(0.7, 1e-12));
      expect(m.state.rangeHa, closeTo(7, 1e-9));
      expect(m.state.unit, 'l');
      expect(m.totalConsumed, closeTo(300, 1e-9));
    });

    test('nie schodzi poniżej zera ani nie rośnie przy cofnięciu powierzchni',
        () {
      m.start(_task(), currentAreaHa: 5);
      m.updateArea(1);
      expect(m.state.remainingVolume, closeTo(1000, 1e-9));
      m.updateArea(500);
      expect(m.state.remainingVolume, closeTo(0, 1e-9));
      expect(m.totalConsumed, closeTo(1000, 1e-9));
    });

    test('zmiana dawki nie działa wstecz', () {
      m.start(_task());
      m.setRate(200, currentAreaHa: 2);
      expect(m.state.remainingVolume, closeTo(800, 1e-9));
      m.updateArea(3);
      expect(m.state.remainingVolume, closeTo(600, 1e-9));
    });

    test('zerowa dawka → zasięg 0, bez dzielenia przez zero', () {
      m.start(_task(rate: 0));
      m.updateArea(10);
      expect(m.state.rangeHa, closeTo(0, 1e-12));
      expect(m.state.remainingVolume, closeTo(1000, 1e-9));
    });

    test('dolewka ograniczona pojemnością, bilans zachowany', () {
      m.start(_task());
      m.updateArea(4); // zostało 600
      m.refill(addedVolume: 900, currentAreaHa: 4, maxCapacity: 1200);
      expect(m.state.remainingVolume, closeTo(1200, 1e-9));
      expect(m.totalConsumed, closeTo(400, 1e-9));
      m.updateArea(5);
      expect(m.totalConsumed, closeTo(500, 1e-9));
      m.fullRefill(currentAreaHa: 5, maxCapacity: 1200);
      expect(m.state.remainingVolume, closeTo(1200, 1e-9));
      expect(m.totalConsumed, closeTo(500, 1e-9));
    });

    test('ponowny start tego samego zadania nie tankuje', () {
      final t = _task();
      m.start(t);
      m.updateArea(3);
      m.start(t, currentAreaHa: 3);
      expect(m.state.remainingVolume, closeTo(700, 1e-9));
    });

    test('pierwsze napełnienie', () {
      m.start(_task(tank: null, unit: 'kg/ha'));
      m.confirmInitialFill(500, currentAreaHa: 1);
      expect(m.isActive, isTrue);
      m.updateArea(2);
      expect(m.state.remainingVolume, closeTo(400, 1e-9));
      expect(m.state.unit, 'kg');
    });

    test('operacje bez zadania są ignorowane', () {
      m.confirmInitialFill(1, currentAreaHa: 0);
      m.setRate(1, currentAreaHa: 0);
      m.refill(addedVolume: 1, currentAreaHa: 0, maxCapacity: 1);
      m.fullRefill(currentAreaHa: 0, maxCapacity: 1);
      expect(m.isActive, isFalse);
    });

    test('strumień emituje stan', () async {
      final f = m.stream.first;
      m.start(_task());
      expect((await f).remainingVolume, closeTo(1000, 1e-9));
    });

    xfail('dolewka przy poziomie ponad pojemność nie tworzy zużycia', () {
      m.start(_task(tank: 1000));
      m.refill(addedVolume: 10, currentAreaHa: 0, maxCapacity: 800);
      expect(m.totalConsumed, closeTo(0, 1e-9));
    }, reason: 'obcięcie do pojemności liczone jako zużyte 200 l');

    test('po stop() zużycie nie rośnie do całego zbiornika', () {
      m.start(_task());
      m.updateArea(1);
      m.stop();
      expect(m.totalConsumed, lessThanOrEqualTo(100));
    });
  });

  group('WorkSessionService', () {
    final s = WorkSessionService.instance;
    setUp(() async {
      await useTempHive();
      await WorkSessionService.init();
      addTearDown(s.reset);
    });
    Map<dynamic, dynamic>? saved() =>
        Hive.box('work_session').get('session') as Map?;

    test('start → pauza → wznowienie → koniec', () {
      expect(s.isActive, isFalse);
      s.start(fieldId: 'f1', task: _task());
      expect(s.isActive, isTrue);
      expect(s.fieldId, 'f1');
      expect(s.taskId, 't1');
      expect(saved()!['paused'], isFalse);
      s.pause();
      expect(s.paused, isTrue);
      final frozen = s.elapsed;
      expect(s.elapsed, frozen); // na pauzie czas stoi
      s.pause(); // idempotentne
      s.start(fieldId: 'f1'); // nie wznawia po pauzie
      expect(s.paused, isTrue);
      s.resume();
      expect(s.paused, isFalse);
      s.resume();
      s.finish();
      expect(s.isActive, isFalse);
      expect(saved(), isNull);
    });

    test('brakujące zadanie jest podpinane do trwającej sesji', () {
      s.start(fieldId: 'f1');
      expect(s.task, isNull);
      s.start(fieldId: 'f1', task: _task());
      expect(s.taskId, 't1');
    });

    test('inne pole kończy starą sesję', () {
      s.start(fieldId: 'f1');
      s.pause();
      s.start(fieldId: 'f2');
      expect(s.fieldId, 'f2');
      expect(s.paused, isFalse);
    });

    test('wyłącznik maszyny nie zatrzymuje sesji', () {
      s.start(fieldId: 'f1');
      s.setMachineOff(true);
      s.setMachineOff(true);
      expect(s.machineOff, isTrue);
      expect(s.isActive, isTrue);
      s.finish();
      expect(s.machineOff, isFalse);
    });

    test('odtworzenie wstrzymanej sesji po restarcie', () async {
      await Hive.box('work_session').put('session', {
        'fieldId': 'f9',
        'taskId': 't9',
        'accumulatedMs': 90000,
        'runningSince': null,
        'paused': true,
        'machineOff': true,
        'finished': false,
      });
      await WorkSessionService.init();
      expect(s.fieldId, 'f9');
      expect(s.elapsed, const Duration(seconds: 90));
      expect(s.machineOff, isTrue);
    });

    test('zakończony lub uszkodzony zapis jest czyszczony', () async {
      for (final bad in [
        {'fieldId': 'f', 'paused': true, 'finished': true},
        {'paused': true},
        {'fieldId': 'f', 'paused': false},
      ]) {
        await Hive.box('work_session').put('session', bad);
        await WorkSessionService.init();
        expect(saved(), isNull);
        expect(s.isActive, isFalse);
      }
    });
  });

  test('formatWorkDuration', () {
    expect(formatWorkDuration(Duration.zero), '0:00:00');
    expect(formatWorkDuration(const Duration(hours: 1, minutes: 2, seconds: 3)),
        '1:02:03');
    expect(formatWorkDuration(const Duration(hours: 25)), '1d 1:00:00');
  });

  test('hectaresPerHourOf', () {
    expect(
        hectaresPerHourOf(5, const Duration(minutes: 30)), closeTo(10, 1e-9));
    expect(hectaresPerHourOf(5, Duration.zero), closeTo(0, 1e-12));
    expect(hectaresPerHourOf(5, const Duration(hours: -1)), closeTo(0, 1e-12));
  });

  group('CoverageService', () {
    final c = CoverageService.instance;
    setUp(() async {
      await useTempHive();
      await CoverageService.init();
      addTearDown(c.stopTracking);
    });

    test('punkty bez aktywnego nagrywania są ignorowane', () {
      c.addPoint(at(0, 0));
      expect(c.currentTrack, isEmpty);
    });

    test('zapis, wczytanie i wznowienie śladu zadania', () async {
      c.startTracking('f', taskId: 't');
      c.addPoint(at(0, 0));
      c.addPoint(at(0, 1));
      await c.stopTracking();
      expect(c.loadForTask('f', 't'), hasLength(2));
      expect(c.loadForField('f'), isEmpty);
      c.startTracking('f', taskId: 't');
      c.startTracking('f', taskId: 't');
      expect(c.currentTrack, hasLength(2));
    });

    test('automatyczny zapis co 100 punktów', () async {
      c.startTracking('f');
      for (var i = 0; i < 100; i++) {
        c.addPoint(at(0, i * 1.0));
      }
      expect(c.loadForField('f'), hasLength(100));
    });

    test('czyszczenie', () async {
      c.startTracking('f');
      c.addPoint(at(0, 0));
      await c.clearForField('f');
      expect(c.currentTrack, isEmpty);
      await c.stopTracking();
      c.startTracking('f', taskId: 't');
      c.addPoint(at(0, 0));
      await c.clearForTask('f', 't');
      expect(c.currentTrack, isEmpty);
    });

    xfail('przełączenie pola bez stopTracking nie gubi punktów', () async {
      c.startTracking('a');
      c.addPoint(at(0, 0));
      c.startTracking('b');
      expect(c.loadForField('a'), hasLength(1));
    }, reason: 'startTracking czyści bufor bez zapisu');
  });

  group('CRUD Hive', () {
    setUp(useTempHive);

    test('FieldService: sortowanie, powierzchnie, usuwanie', () async {
      await FieldService.init();
      final s = FieldService.instance;
      await s.save(_field('2', 'B'));
      await s.save(_field('1', 'A'));
      expect(s.getAll().map((f) => f.name), ['A', 'B']);
      expect(await s.populateAreas(), 2);
      expect(await s.populateAreas(), 0);
      expect(s.getById('1')!.areaHa, closeTo(2, 0.01));
      expect(s.getById('x'), isNull);
      await s.delete('1');
      expect(s.getAll(), hasLength(1));
      await s.deleteAll();
      expect(s.getAll(), isEmpty);
    });

    test('populateAreas pomija pola bez geometrii', () async {
      await FieldService.init();
      await FieldService.instance.save(
          FieldModel(id: 'x', name: 'x', boundaryLats: [], boundaryLons: []));
      expect(await FieldService.instance.populateAreas(), 0);
    });

    test('MachineService', () async {
      await MachineService.init();
      final s = MachineService.instance;
      await s.save(
          MachineModel(id: '1', name: 'Siewnik', type: MachineType.seeder));
      expect(s.getById('1')!.name, 'Siewnik');
      expect(s.getById(null), isNull);
      expect(s.getById('x'), isNull);
      expect(s.getAll(), hasLength(1));
      await s.delete('1');
      await s.deleteAll();
      expect(s.getAll(), isEmpty);
    });

    test('WorkTaskService', () async {
      await WorkTaskService.init();
      await WorkTaskService.instance.save(_task());
      expect(WorkTaskService.instance.getById('t1')!.targetRate,
          closeTo(100, 1e-9));
      expect(WorkTaskService.instance.getById('x'), isNull);
    });

    test('WorkModeSettingsService: zapis i nieznana wartość', () async {
      await WorkModeSettingsService.init();
      final s = WorkModeSettingsService.instance;
      expect(s.orientationMode, MapOrientationMode.headingUp);
      s.orientationMode = MapOrientationMode.northUp;
      await WorkModeSettingsService.init();
      expect(s.orientationMode, MapOrientationMode.northUp);
      await Hive.box('work_mode_settings').put('mapOrientationMode', '?');
      await WorkModeSettingsService.init();
      expect(s.orientationMode, MapOrientationMode.headingUp);
    });
  });
}
