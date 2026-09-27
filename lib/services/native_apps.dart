import 'package:flutter/services.dart';

import '../l10n/app_strings.dart';
import '../models/app_info.dart';

/// Thin wrapper over the native `hamstapp/apps` MethodChannel.
class NativeApps {
  static const MethodChannel _channel = MethodChannel('hamstapp/apps');

  NativeApps._();

  static final Map<String, void Function(int received, int total)>
      _downloadProgress = {};
  static bool _progressHandlerSet = false;

  static void _ensureProgressHandler() {
    if (_progressHandlerSet) return;
    _progressHandlerSet = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'downloadProgress') {
        final m = (call.arguments as Map).cast<dynamic, dynamic>();
        final id = m['id'] as String?;
        final cb = id == null ? null : _downloadProgress[id];
        if (cb != null) {
          cb((m['received'] as num?)?.toInt() ?? 0,
              (m['total'] as num?)?.toInt() ?? -1);
        }
      }
      return null;
    });
  }

  static Future<List<AppInfo>> getInstalledApps({bool includeSystem = true}) async {
    final raw = await _channel.invokeMethod<List<dynamic>>(
      'getInstalledApps',
      {'includeSystem': includeSystem},
    );
    if (raw == null) return <AppInfo>[];
    return raw
        .map((e) => AppInfo.fromMap((e as Map).cast<dynamic, dynamic>()))
        .toList(growable: false);
  }

  static Future<Uint8List?> getAppIcon(String packageName, {int size = 144}) async {
    final bytes = await _channel.invokeMethod<Uint8List>(
      'getAppIcon',
      {'packageName': packageName, 'size': size},
    );
    return bytes;
  }

  static Future<bool> launchApp(String packageName) async {
    final ok = await _channel.invokeMethod<bool>(
      'launchApp',
      {'packageName': packageName},
    );
    return ok ?? false;
  }

  static Future<bool> openAppInfo(String packageName) async {
    final ok = await _channel.invokeMethod<bool>(
      'openAppInfo',
      {'packageName': packageName},
    );
    return ok ?? false;
  }

  static Future<bool> uninstallApp(String packageName) async {
    final ok = await _channel.invokeMethod<bool>(
      'uninstallApp',
      {'packageName': packageName},
    );
    return ok ?? false;
  }

  /// Plays a one-shot vibration. [amplitude] is 1..255 (<=0 = device default).
  static Future<void> vibrate(int durationMs, {int amplitude = -1}) async {
    await _channel.invokeMethod<bool>('vibrate', {
      'duration': durationMs,
      'amplitude': amplitude,
    });
  }

  static Future<Map<String, dynamic>> getDeviceInfo() async {
    final info = await _channel.invokeMethod<Map<dynamic, dynamic>>('getDeviceInfo');
    return (info ?? {}).cast<String, dynamic>();
  }

  /// Tests a remote APK source. Returns `{ok: bool, count: int, error: String?}`.
  static Future<Map<String, dynamic>> remoteTest(
      Map<String, dynamic> config) async {
    final r = await _channel
        .invokeMethod<Map<dynamic, dynamic>>('remoteTest', config);
    return (r ?? {}).cast<String, dynamic>();
  }

  /// Lists `.apk` files on a remote source, recursively. Each item has
  /// name/rel/size/path/modified.
  static Future<List<Map<String, dynamic>>> remoteList(
      Map<String, dynamic> config) async {
    final raw = await _channel.invokeMethod<List<dynamic>>('remoteList', config);
    if (raw == null) return <Map<String, dynamic>>[];
    return raw
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList(growable: false);
  }

  /// Downloads a remote file into the persistent cache; returns the local path.
  ///
  /// A cached copy with the same size is reused. When [onProgress] is given the
  /// native side reports throughput on the shared channel.
  static Future<String> remoteDownload(
    Map<String, dynamic> config, {
    required String sourceId,
    required String remotePath,
    required String name,
    required String rel,
    required int size,
    required int modified,
    bool force = false,
    bool keepAllVersions = false,
    void Function(int received, int total)? onProgress,
  }) async {
    _ensureProgressHandler();
    final id = 'dl_${DateTime.now().microsecondsSinceEpoch}';
    if (onProgress != null) _downloadProgress[id] = onProgress;
    try {
      final path = await _channel.invokeMethod<String>('remoteDownload', {
        ...config,
        'sourceId': sourceId,
        'remotePath': remotePath,
        'name': name,
        'rel': rel,
        'size': size,
        'modified': modified,
        'force': force,
        'keepAllVersions': keepAllVersions,
        'downloadId': id,
      });
      if (path == null || path.isEmpty) {
        throw StateError(AppStrings.current.t('下载失败'));
      }
      return path;
    } finally {
      _downloadProgress.remove(id);
    }
  }

  /// Reads name/package/version/sdk + icon from a downloaded APK.
  static Future<Map<String, dynamic>?> apkInfo(String path) async {
    final r = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'apkInfo',
      {'path': path},
    );
    return r?.cast<String, dynamic>();
  }

  /// Cache index for one source: `{entries: [...], totalBytes: n}`.
  static Future<Map<String, dynamic>> cacheIndex(String sourceId) async {
    final r = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'cacheIndex',
      {'sourceId': sourceId},
    );
    return (r ?? const {}).cast<String, dynamic>();
  }

  /// Cache index across all sources; each entry carries its `sourceId`.
  static Future<Map<String, dynamic>> cacheIndexAll() async {
    final r = await _channel.invokeMethod<Map<dynamic, dynamic>>('cacheIndexAll');
    return (r ?? const {}).cast<String, dynamic>();
  }

  /// Drops cached APKs whose remote file changed or disappeared. Returns freed bytes.
  static Future<int> cachePrune(
      String sourceId, List<Map<String, dynamic>> entries,
      {bool keepAllVersions = false}) async {
    final freed = await _channel.invokeMethod<num>('cachePrune', {
      'sourceId': sourceId,
      'entries': entries,
      'keepAllVersions': keepAllVersions,
    });
    return freed?.toInt() ?? 0;
  }

  /// Deletes one cached APK (source + remote path). Returns freed bytes.
  static Future<int> cacheDelete(String sourceId, String remotePath) async {
    final freed = await _channel.invokeMethod<num>('cacheDelete', {
      'sourceId': sourceId,
      'remotePath': remotePath,
    });
    return freed?.toInt() ?? 0;
  }

  /// Deletes one cache entry by its unique id. Returns freed bytes.
  static Future<int> cacheDeleteById(String id) async {
    final freed = await _channel.invokeMethod<num>('cacheDeleteById', {'id': id});
    return freed?.toInt() ?? 0;
  }

  /// Deletes the whole download cache. Returns freed bytes.
  static Future<int> cacheClear() async {
    final freed = await _channel.invokeMethod<num>('cacheClear');
    return freed?.toInt() ?? 0;
  }

  /// Hands a downloaded APK to the system package installer.
  static Future<bool> installApk(String path) async {
    final ok = await _channel.invokeMethod<bool>('installApk', {'path': path});
    return ok ?? false;
  }

  /// Whether this app is allowed to install unknown packages (API 26+).
  static Future<bool> canInstallPackages() async {
    final ok = await _channel.invokeMethod<bool>('canInstallPackages');
    return ok ?? true;
  }

  /// Opens the system "install unknown apps" screen for this app.
  static Future<bool> openInstallPermissionSettings() async {
    final ok = await _channel.invokeMethod<bool>(
      'openInstallPermissionSettings',
    );
    return ok ?? false;
  }

  /// Copies an installed APK into a temporary cache directory and opens the
  /// system share sheet so it can be sent to another app. [name] is the
  /// suggested file name (without extension). Returns false when the APK could
  /// not be read or shared.
  static Future<bool> shareApk(String path, {String name = ''}) async {
    final ok = await _channel.invokeMethod<bool>('shareApk', {
      'path': path,
      'name': name,
    });
    return ok ?? false;
  }
}
