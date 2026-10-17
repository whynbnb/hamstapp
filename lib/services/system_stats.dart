import 'dart:async';

import 'package:flutter/foundation.dart';

import 'native_apps.dart';

/// Today's screen time and this month's traffic.
///
/// Both come from the system's usage statistics, so they need the same "usage
/// access" grant the storage screen asks for; without it [permitted] is false
/// and the tiles say so instead of showing zeros. One reading serves every
/// tile, and it is only re-read every few minutes (the system's own numbers
/// only change that often).
class SystemStatsService extends ChangeNotifier {
  SystemStatsService._();

  static final SystemStatsService instance = SystemStatsService._();

  /// How long a reading is reused before another is taken.
  static const Duration _fresh = Duration(minutes: 5);

  SystemUsage _screenTime = const SystemUsage(permitted: true, totalMillis: 0);
  TrafficUsage _traffic = const TrafficUsage(permitted: true);

  SystemUsage get screenTime => _screenTime;
  TrafficUsage get traffic => _traffic;

  DateTime? _at;
  Future<void>? _inflight;

  Future<void> refresh({bool force = false}) {
    final at = _at;
    if (!force && at != null && DateTime.now().difference(at) < _fresh) {
      return Future<void>.value();
    }
    final running = _inflight;
    if (running != null) return running;
    final run = _read();
    _inflight = run;
    return run;
  }

  Future<void> _read() async {
    try {
      final results = await Future.wait<Object>([
        NativeApps.screenTimeToday(),
        NativeApps.trafficSummary(),
      ]);
      _screenTime = results[0] as SystemUsage;
      _traffic = results[1] as TrafficUsage;
      _at = DateTime.now();
      notifyListeners();
    } catch (_) {
      // Keep the previous reading.
    } finally {
      _inflight = null;
    }
  }
}
