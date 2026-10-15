import 'dart:async';

import 'package:flutter/foundation.dart';

import 'native_apps.dart';

/// Shared battery + storage reading for the info tiles.
///
/// One poll serves every tile: [refresh] is throttled, so several tiles waking
/// up together still cause a single native call. Nothing polls on its own —
/// tiles ask while they are on screen.
class DeviceStatusService extends ChangeNotifier {
  DeviceStatusService._();

  static final DeviceStatusService instance = DeviceStatusService._();

  /// How long a reading is reused before another is taken.
  static const Duration _fresh = Duration(seconds: 30);

  DeviceStatus _status = DeviceStatus.unknown;
  DeviceStatus get status => _status;

  DateTime? _at;
  Future<void>? _inflight;

  /// Reads the battery/storage state, unless the last read is still fresh.
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
      final next = await NativeApps.deviceStatus();
      _status = next;
      _at = DateTime.now();
      notifyListeners();
    } catch (_) {
      // Keep the previous reading; the tiles just stay as they are.
    } finally {
      _inflight = null;
    }
  }
}
