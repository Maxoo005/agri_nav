import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../ffi/gps_bridge.dart';

const _kGpsBox = 'gps_settings';
const _kUseInternalGpsKey = 'useInternalGps';

// ═══════════════════════════════════════════════════════════════════════════════
// GpsLocationService — real GNSS via Geolocator
// ═══════════════════════════════════════════════════════════════════════════════

/// Fix quality reported via [GpsFixStatus].
enum GpsFixStatus {
  /// Service stopped / not yet started.
  inactive,

  /// Waiting for first fix or accuracy > [GpsLocationService.kMaxAccuracyM].
  searching,

  /// Autonomous GPS fix (accuracy 5–20 m, but below threshold).
  gps,

  /// DGPS-grade fix (accuracy < 5 m).
  dgps,
}

/// Singleton that wraps the real-device GNSS receiver via `geolocator`.
///
/// ### Filtering applied to real GPS positions:
/// 1. **EMA position smoothing** (α = [_kEmaAlpha]) — applied only to
///    *accurate* samples so that large blips don't contaminate the filter.
/// 2. **Accuracy gate** — positions with `accuracy > kMaxAccuracyM` are emitted
///    with `SimPosition.isAccurate = false`.  Callers skip coverage/NavBridge
///    updates but may display the raw position as a low-opacity hint.
/// 3. **Heading speed gate** — hardware heading is only forwarded when
///    `speed ≥ kMinHeadingSpeedMs`.  At standstill the phone compass/GPS
///    bearing is noisy and would spin the field view.
///
/// Usage:
/// ```dart
/// await GpsLocationService.instance.start(context);
/// final sub = GpsLocationService.instance.positionStream.listen(_onPos);
/// // …
/// sub.cancel();
/// GpsLocationService.instance.stop();
/// ```
class GpsLocationService {
  GpsLocationService._();

  static final instance = GpsLocationService._();

  /// Inicjalizacja: otwiera box Hive i odczytuje zapisaną preferencję.
  /// Wywołać w main() po Hive.initFlutter().
  static Future<void> init() async {
    final box = await Hive.openBox(_kGpsBox);
    instance._useInternalGps = box.get(_kUseInternalGpsKey, defaultValue: true);
  }

  // ── Public constants ──────────────────────────────────────────────────────────

  /// Positions with `accuracy > kMaxAccuracyM` are emitted as inaccurate.
  static const double kMaxAccuracyM = 10.0;

  /// Hardware heading is only trusted when ground speed ≥ this value [m/s].
  static const double kMinHeadingSpeedMs = 0.5;

  // ── Public state ─────────────────────────────────────────────────────────────

  bool get useInternalGps => _useInternalGps;
  set useInternalGps(bool value) {
    if (_useInternalGps == value) return;
    _useInternalGps = value;
    Hive.box(_kGpsBox).put(_kUseInternalGpsKey, value);
  }

  bool _useInternalGps = true;

  GpsFixStatus get fixStatus => _fixStatus;
  GpsFixStatus _fixStatus = GpsFixStatus.inactive;

  // ── Stream infrastructure ────────────────────────────────────────────────────

  final _controller = StreamController<SimPosition>.broadcast();

  Stream<SimPosition> get positionStream {
    return _controller.stream.transform(
      StreamTransformer.fromHandlers(
        handleData: (pos, sink) {
          _fixStatus = _computeFixStatus(pos.accuracy, pos.isAccurate);
          sink.add(pos);
        },
        handleDone: (sink) => sink.close(),
      ),
    );
  }

  int _activeListeners = 0;
  StreamSubscription<Position>? _geolocatorSub;

  // ── Lifecycle ────────────────────────────────────────────────────────────────

  /// Start GPS.  Requests permissions first, then subscribes to the GNSS
  /// position stream.  Safe to call multiple times (ref-counted).
  ///
  /// If permissions are denied, the stream will not emit positions.
  Future<void> start(BuildContext context) async {
    _activeListeners++;
    if (_activeListeners == 1) {
      _fixStatus = GpsFixStatus.searching;

      if (_useInternalGps) {
        final granted = await requestPermissions(context);
        if (granted) {
          _startRealGps();
        } else {
          _fixStatus = GpsFixStatus.inactive;
        }
      }
    }
  }

  /// Stop forwarding.  Pairs with [start].
  void stop() {
    if (_activeListeners <= 0) return;
    _activeListeners--;
    if (_activeListeners == 0) {
      _stopRealGps();
      _fixStatus = GpsFixStatus.inactive;
    }
  }

  // ── EMA (Exponential Moving Average) filter ──────────────────────────────────

  static const double _kEmaAlpha = 0.3;

  double? _emaLat;
  double? _emaLon;
  double? _emaAlt;

  void _resetEma() {
    _emaLat = null;
    _emaLon = null;
    _emaAlt = null;
  }

  // ── Real GNSS (Geolocator) ──────────────────────────────────────────────────

  void _startRealGps() {
    final settings = AndroidSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      intervalDuration: const Duration(milliseconds: 100),
      distanceFilter: 0,
      foregroundNotificationConfig: ForegroundNotificationConfig(
        notificationText: 'AgriNav — aktywna nawigacja GPS',
        notificationTitle: 'AgriNav GPS',
        enableWakeLock: true,
        setOngoing: true,
        notificationIcon: AndroidResource(
          name: 'ic_launcher',
          defType: 'mipmap',
        ),
      ),
    );

    _geolocatorSub = Geolocator.getPositionStream(
      locationSettings: settings,
    ).listen(
      _onGeolocatorPosition,
      onError: (Object e) {
        debugPrint('[GpsLocationService] Geolocator error: $e');
        _fixStatus = GpsFixStatus.searching;
      },
    );
  }

  void _stopRealGps() {
    _geolocatorSub?.cancel();
    _geolocatorSub = null;
    _resetEma();
  }

  void _onGeolocatorPosition(Position pos) {
    final bool isAccurate = pos.accuracy <= kMaxAccuracyM;

    double lat = pos.latitude;
    double lon = pos.longitude;
    double alt = pos.altitude;

    if (isAccurate) {
      _emaLat ??= lat;
      _emaLon ??= lon;
      _emaAlt ??= alt;

      _emaLat = _kEmaAlpha * lat + (1.0 - _kEmaAlpha) * _emaLat!;
      _emaLon = _kEmaAlpha * lon + (1.0 - _kEmaAlpha) * _emaLon!;
      _emaAlt = _kEmaAlpha * alt + (1.0 - _kEmaAlpha) * _emaAlt!;

      lat = _emaLat!;
      lon = _emaLon!;
      alt = _emaAlt!;
    }

    final double speed = pos.speed >= 0 ? pos.speed : -1.0;
    final double heading =
        (speed >= kMinHeadingSpeedMs && pos.headingAccuracy >= 0)
            ? pos.heading
            : -1.0;

    final simPos = SimPosition(
      latitude: lat,
      longitude: lon,
      altitude: alt,
      accuracy: pos.accuracy,
      heading: heading,
      speed: speed,
      isAccurate: isAccurate,
    );

    if (!_controller.isClosed) _controller.add(simPos);
  }

  // ── Permissions ──────────────────────────────────────────────────────────────

  /// Request all required location permissions.
  ///
  /// Returns `true` when the app may use precise location.
  Future<bool> requestPermissions(BuildContext context) async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (context.mounted) {
        await _showDialog(
          context,
          title: 'Lokalizacja wyłączona',
          message: 'Usługa lokalizacji jest wyłączona na tym urządzeniu. '
              'Włącz GPS w ustawieniach systemu, aby korzystać z nawigacji.',
          onSettings: () => Geolocator.openLocationSettings(),
        );
      }
      return false;
    }

    LocationPermission permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.deniedForever) {
      if (context.mounted) {
        await _showDialog(
          context,
          title: 'Brak dostępu do GPS',
          message: 'AgriNav nie ma uprawnień do lokalizacji. '
              'Przyznaj dostęp w Ustawieniach → Aplikacje → AgriNav → Uprawnienia.',
          onSettings: () => Geolocator.openAppSettings(),
        );
      }
      permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.deniedForever ||
          permission == LocationPermission.denied) {
        return false;
      }
    }

    if (permission == LocationPermission.denied) return false;

    if (permission == LocationPermission.whileInUse) {
      final always = await Geolocator.requestPermission();
      if (always == LocationPermission.always) {
        permission = LocationPermission.always;
      }
    }

    return permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse;
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

  GpsFixStatus _computeFixStatus(double accuracyM, bool isAccurate) {
    if (!isAccurate || accuracyM <= 0) return GpsFixStatus.searching;
    if (accuracyM < 5.0) return GpsFixStatus.dgps;
    return GpsFixStatus.gps;
  }

  Future<void> _showDialog(
    BuildContext context, {
    required String title,
    required String message,
    required VoidCallback onSettings,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Anuluj'),
          ),
          FilledButton.icon(
            onPressed: () {
              Navigator.of(context).pop();
              onSettings();
            },
            icon: const Icon(Icons.settings),
            label: const Text('Ustawienia'),
          ),
        ],
      ),
    );
  }
}
