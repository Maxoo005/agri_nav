import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../ffi/gps_bridge.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// GpsLocationService — real GPS via Geolocator, with simulator fallback
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

/// Singleton that unifies real-device GPS (via `geolocator`) and the
/// C++ [GnssSimulatorBridge] behind a single [Stream<SimPosition>].
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
/// await GpsLocationService.instance.requestPermissions(context);
/// GpsLocationService.instance.useInternalGps = true;
/// final sub = GpsLocationService.instance.positionStream.listen(_onPos);
/// // …
/// sub.cancel();
/// ```
class GpsLocationService {
  GpsLocationService._();

  static final instance = GpsLocationService._();

  // ── Public constants ──────────────────────────────────────────────────────────

  /// Positions with `accuracy > kMaxAccuracyM` are emitted as inaccurate.
  /// 10 m is a good real-world threshold: a phone GPS in open field typically
  /// achieves 3–8 m; > 10 m indicates multipath / poor sky visibility.
  static const double kMaxAccuracyM = 10.0;

  /// Hardware heading is only trusted when ground speed ≥ this value [m/s].
  /// Below ~0.5 m/s the phone magnetometer/GPS heading is noisy; ignoring it
  /// prevents the tractor icon from spinning while stationary.
  static const double kMinHeadingSpeedMs = 0.5;

  // ── Public state ─────────────────────────────────────────────────────────────

  /// When `true` — stream emits positions from the real device GPS.
  /// When `false` — stream emits positions from [GnssSimulatorBridge].
  ///
  /// Changing this while the stream has active listeners automatically
  /// switches the underlying source.
  bool get useInternalGps => _useInternalGps;
  set useInternalGps(bool value) {
    if (_useInternalGps == value) return;
    _useInternalGps = value;
    if (_activeListeners > 0) {
      _stopCurrentSource();
      _startCurrentSource();
    }
  }

  bool _useInternalGps = false; // default: simulator

  /// Latest computed fix quality (updated on every new position).
  GpsFixStatus get fixStatus => _fixStatus;
  GpsFixStatus _fixStatus = GpsFixStatus.inactive;

  // ── Stream infrastructure ────────────────────────────────────────────────────

  final _controller = StreamController<SimPosition>.broadcast();

  /// Unified GPS stream — subscribe to receive [SimPosition] at up to 10 Hz
  /// (real GPS typically 1 Hz; simulator ~10 Hz).
  ///
  /// Each emitted position has [SimPosition.isAccurate] set appropriately.
  /// Callers should check this flag before updating navigation state.
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

  /// Start forwarding positions to [positionStream].
  /// Safe to call multiple times (ref-counted).
  void start({
    double simStartLat = 52.2297,
    double simStartLon = 21.0122,
  }) {
    _simStartLat = simStartLat;
    _simStartLon = simStartLon;
    _activeListeners++;
    if (_activeListeners == 1) {
      _fixStatus = GpsFixStatus.searching;
      _startCurrentSource();
    }
  }

  /// Stop forwarding.  Pairs with [start].
  void stop() {
    if (_activeListeners <= 0) return;
    _activeListeners--;
    if (_activeListeners == 0) {
      _stopCurrentSource();
      _fixStatus = GpsFixStatus.inactive;
    }
  }

  double _simStartLat = 52.2297;
  double _simStartLon = 21.0122;

  void _startCurrentSource() {
    if (_useInternalGps) {
      _startRealGps();
    } else {
      _startSimulator();
    }
  }

  void _stopCurrentSource() {
    if (_useInternalGps) {
      _stopRealGps();
    } else {
      _stopSimulator();
    }
  }

  // ── EMA (Exponential Moving Average) filter ──────────────────────────────────
  //
  // Applied only to *accurate* samples (accuracy ≤ kMaxAccuracyM) so that
  // a single 50 m "blip" cannot pull the smoothed track off course.
  //
  // α = 0.3 → effective memory of ≈ 1/α = 3.3 samples.
  // At 1 Hz GPS this gives ~3 s lag for step-function changes — acceptable
  // for tractor guidance where speeds are 5–15 km/h (1.5–4 m/s).
  // Effectively smooths out 3–5 m jitter at typical phone GPS accuracy.
  static const double _kEmaAlpha = 0.3;

  double? _emaLat;
  double? _emaLon;
  double? _emaAlt;

  void _resetEma() {
    _emaLat = null;
    _emaLon = null;
    _emaAlt = null;
  }

  // ── Real GPS (Geolocator) ────────────────────────────────────────────────────

  void _startRealGps() {
    final settings = AndroidSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      intervalDuration: const Duration(milliseconds: 100), // request 10 Hz
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
    // Reset EMA so the next GPS session starts from a clean state;
    // stale values from the previous session would cause a "teleport" jitter
    // at startup (the first accurate fix would be pulled toward old coordinates).
    _resetEma();
  }

  void _onGeolocatorPosition(Position pos) {
    // ── 1. Accuracy gate ──────────────────────────────────────────────────────
    final bool isAccurate = pos.accuracy <= kMaxAccuracyM;

    // ── 2. EMA position smoothing ─────────────────────────────────────────────
    // Only update the filter with accurate samples. Inaccurate samples are
    // forwarded as-is (raw coordinates) so the UI can show a faded indicator,
    // but they do not contaminate the smooth path used for navigation.
    double lat = pos.latitude;
    double lon = pos.longitude;
    double alt = pos.altitude;

    if (isAccurate) {
      // Seed from first accurate fix
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

    // ── 3. Heading speed gate ─────────────────────────────────────────────────
    // Phone GPS heading from Geolocator is computed from consecutive fixes
    // (not a magnetometer bearing). At low speed the fixes are so close
    // together that quantisation error dominates → heading oscillates wildly.
    // Only forward the hardware heading above kMinHeadingSpeedMs.
    final double speed = pos.speed >= 0 ? pos.speed : -1.0;
    final double heading =
        (speed >= kMinHeadingSpeedMs && pos.headingAccuracy >= 0)
            ? pos.heading
            : -1.0;

    final simPos = SimPosition(
      latitude: lat,
      longitude: lon,
      altitude: alt,
      accuracy: pos.accuracy, // raw — callers see true fix quality
      heading: heading,
      speed: speed,
      isAccurate: isAccurate,
    );

    if (!_controller.isClosed) _controller.add(simPos);
  }

  // ── GnssSimulatorBridge adapter ──────────────────────────────────────────────

  void _startSimulator() {
    final sim = GnssSimulatorBridge.instance;
    sim.onPosition = _onSimulatorPosition;
    sim.start(startLat: _simStartLat, startLon: _simStartLon);
  }

  void _stopSimulator() {
    GnssSimulatorBridge.instance
      ..onPosition = null
      ..stop();
  }

  void _onSimulatorPosition(SimPosition pos) {
    if (!_controller.isClosed) _controller.add(pos);
  }

  // ── Permissions ──────────────────────────────────────────────────────────────

  /// Request all required location permissions.
  ///
  /// Returns `true` when the app may use precise location.
  /// Handles all branches including [LocationPermission.deniedForever]
  /// (shows a dialog that redirects to system settings).
  ///
  /// **"Tylko tym razem"** — Android grants `whileInUse`; this is sufficient
  /// for foreground navigation with a foreground service.  The app
  /// never silently falls back to background-only operation.
  Future<bool> requestPermissions(BuildContext context) async {
    // 1. Check if location services are enabled at OS level.
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

    // 2. Check current permission status before requesting.
    LocationPermission permission = await Geolocator.checkPermission();

    // 3. If denied (but NOT permanently), show the system dialog once.
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    // 4. Permanently denied — user must go to system settings manually.
    //    After openAppSettings() returns, re-check in case user just granted.
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
      // Re-check — user may have just granted access in settings.
      permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.deniedForever ||
          permission == LocationPermission.denied) {
        return false;
      }
    }

    // 5. Soft denial (system dialog dismissed without choosing).
    if (permission == LocationPermission.denied) return false;

    // 6. Optionally upgrade whileInUse → always for screen-off fieldwork.
    //    Android 10+ requires a SEPARATE runtime request for background access.
    //    Not critical: foreground service keeps GPS alive with the screen on.
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
