import 'dart:async';

import 'package:flutter/foundation.dart';

import 'native_apps.dart';
import 'remote_client.dart';

/// The downloaded-APK cache, for the 缓存占用 tile.
///
/// One reading serves the tile and the sheets that follow from it; it is only
/// re-read when it is stale or the user asks. The cache changes when APKs are
/// fetched or installed, which is a slow-moving thing.
class CacheStatsService extends ChangeNotifier {
  CacheStatsService._();

  static final CacheStatsService instance = CacheStatsService._();

  static const Duration _fresh = Duration(minutes: 5);

  int _count = 0;
  int _bytes = 0;
  int get count => _count;
  int get bytes => _bytes;

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
      final index = await RemoteClient.cacheIndexAll();
      _count = index.length;
      _bytes = index.fold<int>(
        0,
        (sum, e) => sum + ((e['size'] as num?)?.toInt() ?? 0),
      );
      _at = DateTime.now();
      notifyListeners();
    } catch (_) {
      // Keep the previous reading.
    } finally {
      _inflight = null;
    }
  }
}

/// Per-app storage, biggest first, for the 占用最大 tile's "with data" mode.
///
/// Needs usage access; without it [permitted] is false and the tile falls back
/// to APK sizes, which need no permission.
class BigAppsService extends ChangeNotifier {
  BigAppsService._();

  static final BigAppsService instance = BigAppsService._();

  static const Duration _fresh = Duration(minutes: 5);

  List<StorageRankEntry> _entries = const [];
  List<StorageRankEntry> get entries => _entries;
  bool _permitted = true;
  bool get permitted => _permitted;

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
      final ranking = await NativeApps.storageRanking();
      _entries = ranking.entries;
      _permitted = ranking.permitted;
      _at = DateTime.now();
      notifyListeners();
    } catch (_) {
      // Keep the previous reading.
    } finally {
      _inflight = null;
    }
  }
}
