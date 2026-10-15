import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Simple JSON-file backed persistence inside the app documents directory.
class Storage {
  Storage._(this._dir);

  final Directory _dir;

  static Storage? _instance;

  /// Folder this app keeps its files in, under the platform documents
  /// directory. Public so code that only needs to look at the layout — the
  /// storage screen — does not have to guess it.
  static const String dirName = 'hamstapp';

  /// Stored file names (without `.json`) whose contents are pure caches: they
  /// can be deleted and are simply rebuilt, losing nothing the user made.
  static const String iconsFile = 'icons';
  static const String scanCacheFile = 'apps_cache_v2';

  static Future<Directory> _resolveDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/$dirName');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<Storage> instance() async {
    if (_instance != null) return _instance!;
    _instance = Storage._(await _resolveDir());
    return _instance!;
  }

  /// Sizes of the stored files, keyed by name (without the `.json` suffix).
  ///
  /// Synchronous on purpose: it is a handful of tiny files, read only when the
  /// storage screen opens, and sync I/O keeps it usable off the platform
  /// directory lookup. Reports nothing when no instance has been created yet.
  static Map<String, int> fileSizes() {
    final dir = _instance?._dir;
    if (dir == null) return const <String, int>{};
    final out = <String, int>{};
    try {
      for (final e in dir.listSync()) {
        if (e is! File || !e.path.endsWith('.json')) continue;
        final name = e.uri.pathSegments.last;
        out[name.substring(0, name.length - '.json'.length)] = e.lengthSync();
      }
    } catch (_) {
      // Measuring is advisory: a failure just reports nothing.
    }
    return out;
  }

  /// Deletes one stored file, for a cache the app can rebuild (never used for
  /// anything the user made from scratch).
  static void deleteFile(String name) {
    final dir = _instance?._dir;
    if (dir == null) return;
    try {
      final f = File('${dir.path}/$name.json');
      if (f.existsSync()) f.deleteSync();
    } catch (_) {
      // Nothing to delete, or the directory is unreachable.
    }
  }

  File _file(String name) => File('${_dir.path}/$name.json');

  Future<dynamic> readJson(String name) async {
    try {
      final f = _file(name);
      if (!await f.exists()) return null;
      final content = await f.readAsString();
      if (content.trim().isEmpty) return null;
      return jsonDecode(content);
    } catch (_) {
      return null;
    }
  }

  Future<void> writeJson(String name, dynamic data) async {
    final f = _file(name);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(data), flush: true);
    if (await f.exists()) await f.delete();
    await tmp.rename(f.path);
  }
}
