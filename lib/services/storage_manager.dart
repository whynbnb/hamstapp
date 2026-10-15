import 'dart:io';

import 'icon_cache.dart';
import 'native_apps.dart';
import 'storage.dart';

/// What one category of local storage holds right now.
enum StorageCategory {
  /// App icons, kept both in memory and in `icons.json`.
  icons,

  /// The last scan's app list (`apps_cache_v2.json`).
  scan,

  /// APKs downloaded from a sync source and kept for offline install.
  apk,

  /// Scratch files: APKs dragged onto the window, shared copies, the WebView
  /// cache. Android may wipe these on its own at any time.
  temp,

  /// Everything the user made or configured: settings, tiles, categories,
  /// snapshots, backup lists, web entries. Never cleared from here.
  data,
}

/// One line of the storage report.
class StorageUsage {
  const StorageUsage({
    required this.category,
    required this.bytes,
    required this.items,
  });

  final StorageCategory category;

  /// Bytes held, 0 when it could not be measured.
  final int bytes;

  /// Files (or icons) held, 0 when unknown.
  final int items;

  /// Whether clearing it frees space without losing anything the user made.
  bool get clearable => category != StorageCategory.data;
}

/// Measures what 囤囤 occupies on the device, and clears the parts that are
/// only caches.
///
/// Everything here is best effort: a category that cannot be read reports zero
/// instead of throwing, because the screen is informational and must not break
/// when a platform channel is unavailable.
class StorageManager {
  const StorageManager._();

  /// The report, in the order the storage screen lists the categories.
  ///
  /// [tempDir] overrides the app's cache directory; tests use it because there
  /// is no native side to ask.
  static Future<List<StorageUsage>> measure({Directory? tempDir}) async {
    final sizes = Storage.fileSizes();
    final iconFileBytes = sizes[Storage.iconsFile] ?? 0;

    final apk = await _apkCache();

    var dataBytes = 0;
    var dataFiles = 0;
    for (final e in sizes.entries) {
      if (e.key == Storage.iconsFile || e.key == Storage.scanCacheFile) {
        continue;
      }
      dataBytes += e.value;
      dataFiles++;
    }

    final temp = _usage(tempDir ?? _directory(await NativeApps.tempDir()));

    return [
      // Fall back to what is in memory when the file has not been written yet.
      StorageUsage(
        category: StorageCategory.icons,
        bytes: iconFileBytes > 0 ? iconFileBytes : IconCache.instance.byteCount,
        items: IconCache.instance.length,
      ),
      StorageUsage(
        category: StorageCategory.scan,
        bytes: sizes[Storage.scanCacheFile] ?? 0,
        items: 0,
      ),
      StorageUsage(
        category: StorageCategory.apk,
        bytes: apk.bytes,
        items: apk.items,
      ),
      StorageUsage(
        category: StorageCategory.temp,
        bytes: temp.bytes,
        items: temp.items,
      ),
      StorageUsage(
        category: StorageCategory.data,
        bytes: dataBytes,
        items: dataFiles,
      ),
    ];
  }

  /// Deletes the scratch directory's contents; returns the bytes freed. Safe:
  /// Android treats it as disposable and may clear it by itself.
  static Future<int> clearTemp({Directory? tempDir}) async {
    final dir = tempDir ?? _directory(await NativeApps.tempDir());
    return dir == null ? 0 : _deleteContents(dir);
  }

  static Future<({int bytes, int items})> _apkCache() async {
    try {
      final index = await NativeApps.cacheIndexAll();
      return (
        bytes: (index['totalBytes'] as num?)?.toInt() ?? 0,
        items: (index['entries'] as List?)?.length ?? 0,
      );
    } catch (_) {
      // No native side (or the call failed): report nothing for this row.
      return (bytes: 0, items: 0);
    }
  }

  static Directory? _directory(String? path) =>
      path == null || path.isEmpty ? null : Directory(path);

  /// Size and file count of a directory tree. Synchronous: it only walks the
  /// app's own cache directory, on a screen the user opened on purpose.
  static ({int bytes, int items}) _usage(Directory? dir) {
    if (dir == null) return (bytes: 0, items: 0);
    var bytes = 0;
    var items = 0;
    for (final e in _list(dir)) {
      try {
        if (e is File) {
          bytes += e.lengthSync();
          items++;
        } else if (e is Directory) {
          final sub = _usage(e);
          bytes += sub.bytes;
          items += sub.items;
        }
      } catch (_) {
        // An entry that vanished mid-walk simply does not count.
      }
    }
    return (bytes: bytes, items: items);
  }

  static int _deleteContents(Directory dir) {
    var freed = 0;
    for (final e in _list(dir)) {
      try {
        if (e is File) {
          freed += e.lengthSync();
          e.deleteSync();
        } else if (e is Directory) {
          freed += _deleteContents(e);
          e.deleteSync();
        }
      } catch (_) {
        // In use or already gone: leave it and keep going.
      }
    }
    return freed;
  }

  /// Snapshot of a directory's entries. A listing is collected first because
  /// the callers delete as they go.
  static List<FileSystemEntity> _list(Directory dir) {
    try {
      return dir.listSync(followLinks: false);
    } catch (_) {
      return const [];
    }
  }
}
