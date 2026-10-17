import 'dart:async';

import 'package:flutter/foundation.dart';

import 'native_apps.dart';

/// Live network throughput for the 当前网速 tile.
///
/// Samples the device-wide byte counters and reports the difference per second,
/// smoothed so a single burst does not make the number jump. Sampling only runs
/// while something is listening (the tile), and several tiles share one sampler.
class NetSpeedService extends ChangeNotifier {
  NetSpeedService._();

  static final NetSpeedService instance = NetSpeedService._();

  static const Duration _interval = Duration(seconds: 2);

  /// Weight of a new sample in the smoothed value.
  static const double _smoothing = 0.4;

  int _downBytesPerSecond = 0;
  int _upBytesPerSecond = 0;
  bool _supported = true;
  DateTime? _sampledAt;

  int get downBytesPerSecond => _downBytesPerSecond;
  int get upBytesPerSecond => _upBytesPerSecond;

  /// False when the ROM does not expose the counters.
  bool get supported => _supported;
  bool get hasReading => _sampledAt != null;

  Timer? _timer;
  int? _lastRx;
  int? _lastTx;
  DateTime? _lastAt;
  int _listeners = 0;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _listeners++;
    _start();
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    _listeners--;
    if (_listeners <= 0) _stop();
  }

  void _start() {
    _timer ??= Timer.periodic(_interval, (_) => unawaited(_sample()));
    unawaited(_sample());
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    _lastRx = null;
    _lastTx = null;
    _lastAt = null;
  }

  Future<void> _sample() async {
    final totals = await NativeApps.trafficTotals();
    if (!totals.supported) {
      if (_supported) {
        _supported = false;
        notifyListeners();
      }
      return;
    }
    final now = DateTime.now();
    final lastRx = _lastRx;
    final lastTx = _lastTx;
    final lastAt = _lastAt;
    _lastRx = totals.rxBytes;
    _lastTx = totals.txBytes;
    _lastAt = now;
    if (lastRx == null || lastTx == null || lastAt == null) return;
    final seconds = now.difference(lastAt).inMilliseconds / 1000;
    if (seconds <= 0) return;
    final down = ((totals.rxBytes - lastRx) / seconds).clamp(0, 1 << 40);
    final up = ((totals.txBytes - lastTx) / seconds).clamp(0, 1 << 40);
    _downBytesPerSecond = _smooth(_downBytesPerSecond, down.toDouble());
    _upBytesPerSecond = _smooth(_upBytesPerSecond, up.toDouble());
    _sampledAt = now;
    _supported = true;
    notifyListeners();
  }

  static int _smooth(int previous, double next) =>
      (previous == 0 ? next : previous * (1 - _smoothing) + next * _smoothing)
          .round();
}
