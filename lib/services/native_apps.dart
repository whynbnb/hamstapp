import 'dart:async';

import 'package:flutter/services.dart';

import '../l10n/app_strings.dart';
import '../models/app_info.dart';
import '../models/apk_analysis.dart';
import 'app_log.dart';

/// Thin wrapper over the native `hamstapp/apps` MethodChannel.
/// One desktop entry of a package: something the system can start, with its own
/// label (a package like the AOSP Contacts app owns both 联系人 and 电话).
class LaunchEntry {
  const LaunchEntry({
    required this.name,
    required this.label,
    this.fromLauncher = true,
  });

  /// Activity class name, e.g. `com.android.dialer.DialtactsActivity`.
  final String name;

  /// The entry's own label, which can differ from the app's, e.g. 电话.
  final String label;

  /// Whether the system desktop shows this entry as an icon of its own.
  final bool fromLauncher;

  factory LaunchEntry.fromMap(Map<dynamic, dynamic> map) => LaunchEntry(
    name: map['name'] as String? ?? '',
    label: map['label'] as String? ?? '',
    fromLauncher: map['launcher'] as bool? ?? true,
  );
}

/// Result of asking the system to start an app.
///
/// Packages without a desktop entry look just like apps in the scan, so the
/// reason matters: telling the user "the system refused" is useless when the
/// real problem is that the package they picked is not the app on their
/// desktop.
enum LaunchOutcome {
  ok,

  /// No `MAIN`/`LAUNCHER` activity: a system component with no desktop icon.
  noEntry,

  /// Installed but disabled by the user or the ROM.
  disabled,

  /// Not installed any more (or hidden from us).
  missing,

  /// The activity exists but the system refused to start it.
  blocked,

  /// Could not be classified.
  unknown;

  bool get isOk => this == LaunchOutcome.ok;

  static LaunchOutcome byName(String? name) => switch (name) {
    'no_entry' => LaunchOutcome.noEntry,
    'disabled' => LaunchOutcome.disabled,
    'missing' => LaunchOutcome.missing,
    'blocked' => LaunchOutcome.blocked,
    _ => LaunchOutcome.unknown,
  };
}

/// Battery level, charging state, free space of the data volume, RAM and the
/// next alarm — one reading serves every device tile.
class DeviceStatus {
  const DeviceStatus({
    required this.level,
    required this.charging,
    required this.freeBytes,
    required this.totalBytes,
    this.memTotalBytes = 0,
    this.memAvailBytes = 0,
    this.memLow = false,
    this.alarmAt = 0,
    this.uptimeMillis = 0,
    this.batteryTempC = -1,
    this.torchOn = false,
  });

  /// 0-100, or -1 when the system did not report one.
  final int level;
  final bool charging;
  final int freeBytes;
  final int totalBytes;

  /// RAM, in bytes; 0 when unavailable.
  final int memTotalBytes;
  final int memAvailBytes;
  final bool memLow;

  /// When the next alarm fires (millis since epoch), 0 when none is set.
  final int alarmAt;

  /// Time since boot, in milliseconds.
  final int uptimeMillis;

  /// Battery temperature in °C, or -1 when unavailable.
  final double batteryTempC;

  /// Whether the camera torch is currently on.
  final bool torchOn;

  static const DeviceStatus unknown = DeviceStatus(
    level: -1,
    charging: false,
    freeBytes: 0,
    totalBytes: 0,
  );

  bool get hasLevel => level >= 0;
  bool get hasTemp => batteryTempC > 0;
  bool get hasUptime => uptimeMillis > 0;
  bool get hasStorage => totalBytes > 0;
  bool get hasMemory => memTotalBytes > 0;
  int get memUsedBytes =>
      memTotalBytes <= 0 ? 0 : (memTotalBytes - memAvailBytes).clamp(0, memTotalBytes);

  /// Used fraction of the data volume, 0..1.
  double get usedFraction =>
      totalBytes <= 0 ? 0 : ((totalBytes - freeBytes) / totalBytes).clamp(0.0, 1.0);

  /// Used fraction of RAM, 0..1.
  double get memUsedFraction =>
      memTotalBytes <= 0 ? 0 : (memUsedBytes / memTotalBytes).clamp(0.0, 1.0);

  factory DeviceStatus.fromMap(Map<dynamic, dynamic> map) => DeviceStatus(
    level: (map['level'] as num?)?.toInt() ?? -1,
    charging: map['charging'] as bool? ?? false,
    freeBytes: (map['freeBytes'] as num?)?.toInt() ?? 0,
    totalBytes: (map['totalBytes'] as num?)?.toInt() ?? 0,
    memTotalBytes: (map['memTotalBytes'] as num?)?.toInt() ?? 0,
    memAvailBytes: (map['memAvailBytes'] as num?)?.toInt() ?? 0,
    memLow: map['memLow'] as bool? ?? false,
    alarmAt: (map['alarmAt'] as num?)?.toInt() ?? 0,
    uptimeMillis: (map['uptimeMillis'] as num?)?.toInt() ?? 0,
    batteryTempC: (map['batteryTempC'] as num?)?.toDouble() ?? -1,
    torchOn: map['torchOn'] as bool? ?? false,
  );
}

/// Today's screen-on time, from the system's usage statistics.
class SystemUsage {
  const SystemUsage({required this.permitted, required this.totalMillis});

  /// False when "usage access" has not been granted.
  final bool permitted;
  final int totalMillis;

  factory SystemUsage.fromMap(Map<dynamic, dynamic> map) => SystemUsage(
    permitted: map['permitted'] as bool? ?? false,
    totalMillis: (map['totalMillis'] as num?)?.toInt() ?? 0,
  );
}

/// Device-wide byte counters since boot (for a live speed reading).
class TrafficTotals {
  const TrafficTotals({
    required this.supported,
    this.rxBytes = 0,
    this.txBytes = 0,
  });

  /// False when the ROM does not expose the counters.
  final bool supported;
  final int rxBytes;
  final int txBytes;

  factory TrafficTotals.fromMap(Map<dynamic, dynamic> map) => TrafficTotals(
    supported: map['supported'] as bool? ?? false,
    rxBytes: (map['rx'] as num?)?.toInt() ?? 0,
    txBytes: (map['tx'] as num?)?.toInt() ?? 0,
  );
}

/// This month's traffic, split by network type.
class TrafficUsage {
  const TrafficUsage({
    required this.permitted,
    this.mobileBytes = 0,
    this.wifiBytes = 0,
  });

  final bool permitted;
  final int mobileBytes;
  final int wifiBytes;

  int get totalBytes => mobileBytes + wifiBytes;

  factory TrafficUsage.fromMap(Map<dynamic, dynamic> map) => TrafficUsage(
    permitted: map['permitted'] as bool? ?? false,
    mobileBytes: (map['mobileBytes'] as num?)?.toInt() ?? 0,
    wifiBytes: (map['wifiBytes'] as num?)?.toInt() ?? 0,
  );
}

/// APK / data / cache bytes of one installed app.
class AppStorageInfo {
  const AppStorageInfo({
    required this.ok,
    this.reason = '',
    this.apkBytes = 0,
    this.dataBytes = 0,
    this.cacheBytes = 0,
    this.totalBytes = 0,
  });

  final bool ok;

  /// Why it could not be read: `permission` (no usage access), `unsupported`
  /// (below API 26), `unavailable` (the system had no stats), `args`.
  final String reason;
  final int apkBytes;
  final int dataBytes;
  final int cacheBytes;
  final int totalBytes;

  bool get needsPermission => !ok && reason == 'permission';

  factory AppStorageInfo.fromMap(Map<dynamic, dynamic> map) => AppStorageInfo(
    ok: map['ok'] as bool? ?? false,
    reason: map['reason'] as String? ?? '',
    apkBytes: (map['apkBytes'] as num?)?.toInt() ?? 0,
    dataBytes: (map['dataBytes'] as num?)?.toInt() ?? 0,
    cacheBytes: (map['cacheBytes'] as num?)?.toInt() ?? 0,
    totalBytes: (map['totalBytes'] as num?)?.toInt() ?? 0,
  );
}

/// One row of the storage ranking.
class StorageRankEntry {
  const StorageRankEntry({
    required this.packageName,
    required this.appName,
    required this.isSystem,
    required this.apkBytes,
    required this.dataBytes,
    required this.cacheBytes,
    required this.totalBytes,
  });

  final String packageName;
  final String appName;
  final bool isSystem;
  final int apkBytes;
  final int dataBytes;
  final int cacheBytes;
  final int totalBytes;

  factory StorageRankEntry.fromMap(Map<dynamic, dynamic> map) => StorageRankEntry(
    packageName: map['packageName'] as String? ?? '',
    appName: map['appName'] as String? ?? '',
    isSystem: map['isSystem'] as bool? ?? false,
    apkBytes: (map['apkBytes'] as num?)?.toInt() ?? 0,
    dataBytes: (map['dataBytes'] as num?)?.toInt() ?? 0,
    cacheBytes: (map['cacheBytes'] as num?)?.toInt() ?? 0,
    totalBytes: (map['totalBytes'] as num?)?.toInt() ?? 0,
  );
}

/// Result of asking for the storage ranking; [permitted] is false when the
/// usage-access grant is missing, so the screen can ask instead of showing an
/// empty list.
class StorageRanking {
  const StorageRanking({
    required this.entries,
    required this.permitted,
    this.unsupported = false,
  });

  final List<StorageRankEntry> entries;
  final bool permitted;
  final bool unsupported;

  int get totalBytes =>
      entries.fold<int>(0, (sum, e) => sum + e.totalBytes);
}

/// One permission an app requests.
class PermissionEntry {
  const PermissionEntry({
    required this.name,
    required this.granted,
    required this.dangerous,
    required this.group,
  });

  /// Full name, e.g. `android.permission.CAMERA`.
  final String name;
  final bool granted;

  /// A dangerous (runtime) permission, i.e. one the user had to allow.
  final bool dangerous;

  /// Platform group, e.g. `android.permission-group.CAMERA`; may be empty.
  final String group;

  /// Short label for display: `CAMERA` for `android.permission.CAMERA`.
  String get shortName {
    final dot = name.lastIndexOf('.');
    return dot < 0 ? name : name.substring(dot + 1);
  }

  factory PermissionEntry.fromMap(Map<dynamic, dynamic> map) => PermissionEntry(
    name: map['name'] as String? ?? '',
    granted: map['granted'] as bool? ?? false,
    dangerous: map['dangerous'] as bool? ?? false,
    group: map['group'] as String? ?? '',
  );
}

/// The certificate the installed app is signed with.
class SignatureInfo {
  const SignatureInfo({
    required this.packageName,
    required this.appName,
    required this.sha256,
    required this.sha1,
    required this.subject,
    required this.issuer,
    required this.system,
    required this.selfSigned,
    required this.multipleSigners,
    required this.rotated,
    required this.count,
    required this.notBefore,
    required this.notAfter,
  });

  final String packageName;
  final String appName;
  final String sha256;
  final String sha1;
  final String subject;
  final String issuer;
  final bool system;
  final bool selfSigned;
  final bool multipleSigners;

  /// Signed with a key that has since been rotated (past signing certs exist).
  final bool rotated;
  final int count;
  final int notBefore;
  final int notAfter;

  factory SignatureInfo.fromMap(Map<dynamic, dynamic> map) => SignatureInfo(
    packageName: map['packageName'] as String? ?? '',
    appName: map['appName'] as String? ?? '',
    sha256: map['sha256'] as String? ?? '',
    sha1: map['sha1'] as String? ?? '',
    subject: map['subject'] as String? ?? '',
    issuer: map['issuer'] as String? ?? '',
    system: map['system'] as bool? ?? false,
    selfSigned: map['selfSigned'] as bool? ?? false,
    multipleSigners: map['multipleSigners'] as bool? ?? false,
    rotated: map['rotated'] as bool? ?? false,
    count: (map['count'] as num?)?.toInt() ?? 0,
    notBefore: (map['notBefore'] as num?)?.toInt() ?? 0,
    notAfter: (map['notAfter'] as num?)?.toInt() ?? 0,
  );
}

/// The snapshot-time facts of one installed app: what it asks for, what it is
/// signed with and where it lives. Read in one native pass so a snapshot can
/// answer "what did this update change?" later on.
class AppFacts {
  const AppFacts({
    this.permissions = const <String>[],
    this.signature = '',
    this.targetSdk = 0,
    this.installer = '',
    this.external = false,
  });

  /// Declared (requested) permissions, full names, sorted.
  final List<String> permissions;

  /// SHA-256 of the signing certificate the app is installed with; '' when the
  /// system would not tell us.
  final String signature;

  final int targetSdk;

  /// The package that installed the app; '' when side-loaded / unknown.
  final String installer;

  /// Installed on adopted/removable storage rather than internal memory.
  final bool external;

  factory AppFacts.fromMap(Map<dynamic, dynamic> m) => AppFacts(
        permissions:
            (m['permissions'] as List?)?.map((e) => '$e').toList() ??
                const <String>[],
        signature: m['signature'] as String? ?? '',
        targetSdk: (m['targetSdk'] as num?)?.toInt() ?? 0,
        installer: m['installer'] as String? ?? '',
        external: m['external'] as bool? ?? false,
      );
}

/// Where an installed app came from, as the system reports it.
///
/// [installer] is the package that performed the install (a store, an installer
/// app), [initiating] the app whose UI started it and [originating] the app the
/// install is attributed to. The last two are only knowable on Android 11+, so
/// [detailed] is false there and both stay empty rather than being guessed.
class InstallSource {
  const InstallSource({
    this.installer = '',
    this.initiating = '',
    this.originating = '',
    this.detailed = false,
  });

  final String installer;
  final String initiating;
  final String originating;
  final bool detailed;

  bool get isEmpty =>
      installer.isEmpty && initiating.isEmpty && originating.isEmpty;

  factory InstallSource.fromMap(Map<dynamic, dynamic> m) => InstallSource(
        installer: m['installer'] as String? ?? '',
        initiating: m['initiating'] as String? ?? '',
        originating: m['originating'] as String? ?? '',
        detailed: m['detailed'] as bool? ?? false,
      );
}

/// One entry of the launcher's dynamic shortcut list: an app the user launched
/// recently, offered on a long press of 囤囤's own icon.
class RecentShortcut {
  const RecentShortcut({required this.packageName, required this.label});

  final String packageName;
  final String label;

  Map<String, dynamic> toMap() => {
        'packageName': packageName,
        'label': label,
      };
}

/// One app holding a sensitive capability.
class AuditEntry {
  const AuditEntry({
    required this.packageName,
    required this.appName,
    required this.isSystem,
    this.note = '',
  });

  final String packageName;
  final String appName;
  final bool isSystem;

  /// Extra detail: the enabled component's class name for the accessibility and
  /// notification-listener lists.
  final String note;

  factory AuditEntry.fromMap(Map<dynamic, dynamic> map) => AuditEntry(
    packageName: map['packageName'] as String? ?? '',
    appName: map['appName'] as String? ?? '',
    isSystem: map['isSystem'] as bool? ?? false,
    note: map['note'] as String? ?? '',
  );
}

/// One section of the permission audit: a capability and who holds it.
class AuditCapability {
  const AuditCapability({required this.id, required this.entries});

  /// Stable id (see the native side): `microphone`, `camera`, `overlay`,
  /// `accessibility`, `batteryUnrestricted`, ...
  final String id;
  final List<AuditEntry> entries;
}

class NativeApps {
  static const MethodChannel _channel = MethodChannel('hamstapp/apps');
  NativeApps._();

  static final Map<String, void Function(int received, int total)>
      _downloadProgress = {};
  static bool _handlerSet = false;

  static final StreamController<String> _dropped =
      StreamController<String>.broadcast();
  static final StreamController<bool> _dragging =
      StreamController<bool>.broadcast();
  static final StreamController<Map<String, int>> _notifCounts =
      StreamController<Map<String, int>>.broadcast();
  static final StreamController<String> _shortcuts =
      StreamController<String>.broadcast();

  /// Paths of APK files dragged onto the window (copied into the app cache).
  static Stream<String> get droppedApks => _dropped.stream;

  /// Whether an external file drag is currently hovering over the window.
  static Stream<bool> get apkDragging => _dragging.stream;

  /// Active-notification counts per package pushed by the native listener.
  static Stream<Map<String, int>> get notificationCounts =>
      _notifCounts.stream;

  /// Launcher long-press shortcuts tapped while the app is already running
  /// (`scan`, `recent`, `tiles`).
  static Stream<String> get shortcuts => _shortcuts.stream;

  /// The shortcut that started this process, if the app was launched from one.
  /// Pulled once at startup; later taps arrive on [shortcuts].
  static Future<String?> consumeShortcut() async {
    try {
      final id = await _channel.invokeMethod<String>('consumeShortcut');
      return (id == null || id.isEmpty) ? null : id;
    } catch (_) {
      return null;
    }
  }

  /// Registers the shared method-call handler. Safe to call multiple times and
  /// when no Flutter binding exists yet (e.g. pure-Dart tests); a later call
  /// retries.
  static void startListening() {
    try {
      _ensureHandler();
    } catch (_) {
      // No binary messenger yet.
    }
  }

  static void _ensureHandler() {
    if (_handlerSet) return;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'downloadProgress':
          final m = (call.arguments as Map).cast<dynamic, dynamic>();
          final id = m['id'] as String?;
          final cb = id == null ? null : _downloadProgress[id];
          if (cb != null) {
            cb((m['received'] as num?)?.toInt() ?? 0,
                (m['total'] as num?)?.toInt() ?? -1);
          }
        case 'apkDropped':
          final m = (call.arguments as Map?)?.cast<dynamic, dynamic>();
          final path = m?['path'] as String?;
          if (path != null && path.isNotEmpty && !_dropped.isClosed) {
            _dropped.add(path);
          }
        case 'apkDragEntered':
          if (!_dragging.isClosed) _dragging.add(true);
        case 'apkDragEnded':
          if (!_dragging.isClosed) _dragging.add(false);
        case 'notificationsChanged':
          final m = (call.arguments as Map?)?.cast<dynamic, dynamic>();
          if (!_notifCounts.isClosed) _notifCounts.add(_countsFrom(m?['counts']));
        case 'shortcut':
          final m = (call.arguments as Map?)?.cast<dynamic, dynamic>();
          final id = m?['id'] as String?;
          if (id != null && id.isNotEmpty && !_shortcuts.isClosed) {
            _shortcuts.add(id);
          }
        case 'nativeLog':
          final m = (call.arguments as Map?)?.cast<dynamic, dynamic>();
          final text = m?['text'] as String?;
          if (text != null && text.isNotEmpty) {
            AppLog.instance.log(
              LogModule.byName(m?['module'] as String?),
              text,
              level: _levelByName(m?['level'] as String?),
            );
          }
      }
      return null;
    });
    _handlerSet = true;
  }

  static LogLevel _levelByName(String? name) => switch (name) {
    'warn' => LogLevel.warn,
    'error' => LogLevel.error,
    _ => LogLevel.info,
  };

  /// Turns native-side log forwarding on or off (only useful while the in-app
  /// log is enabled).
  static Future<void> setLoggingEnabled(bool enabled) async {
    await _channel.invokeMethod<bool>('setLoggingEnabled', enabled);
  }

  /// Coerces a native `{package: count}` map into a typed int map.
  static Map<String, int> _countsFrom(Object? raw) {
    final out = <String, int>{};
    if (raw is Map) {
      raw.forEach((key, value) {
        if (value is num) out['$key'] = value.toInt();
      });
    }
    return out;
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

  /// Opens a web entry in the app's own window: no browser UI, the manifest's
  /// `theme_color` on the status bar and `background_color` behind the launch
  /// icon, and links that leave the manifest's `scope` handed to the browser.
  /// False when the host could not be started, so callers can fall back.
  static Future<bool> openWebApp({
    required String url,
    required String name,
    required String display,
    required String scope,
    required int themeColor,
    required int backgroundColor,
    bool hideStatusBar = false,
    String browserPackage = '',
    Uint8List? icon,
  }) async {
    try {
      final ok = await _channel.invokeMethod<bool>('openWebApp', {
        'url': url,
        'name': name,
        'display': display,
        'scope': scope,
        'themeColor': themeColor,
        'backgroundColor': backgroundColor,
        'hideStatusBar': hideStatusBar,
        if (browserPackage.isNotEmpty) 'browserPackage': browserPackage,
        if (icon != null && icon.isNotEmpty) 'icon': icon,
      });
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Live report of what the scan makes of installed web apps: totals, the
  /// web apps found, and the packages that look suspicious without being
  /// confirmed. Best effort — null when the native side cannot answer.
  static Future<Map<String, dynamic>?> webAppReport() async {
    try {
      final raw = await _channel.invokeMethod<Map>('webAppReport');
      return raw?.cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  /// Icon bytes for a package. When [activity] is given, the icon of that
  /// launcher entry is returned instead of the application's own (entries of
  /// one package can look different — the dialer and contacts tabs, say).
  static Future<Uint8List?> getAppIcon(
    String packageName, {
    int size = 144,
    String? activity,
  }) async {
    final bytes = await _channel.invokeMethod<Uint8List>('getAppIcon', {
      'packageName': packageName,
      'size': size,
      if (activity != null && activity.isNotEmpty) 'activity': activity,
    });
    return bytes;
  }

  /// Starts an app, optionally pinning one of its desktop entries ([activity]
  /// as reported by [launchActivities]). [LaunchOutcome.ok] means it worked;
  /// every other value carries the reason so the UI can explain the failure.
  static Future<LaunchOutcome> launchApp(
    String packageName, {
    String? activity,
  }) async {
    final r = await _channel.invokeMethod<Map<dynamic, dynamic>>('launchApp', {
      'packageName': packageName,
      if (activity != null && activity.isNotEmpty) 'activity': activity,
    });
    final m = r?.cast<dynamic, dynamic>();
    final outcome = m?['ok'] == true
        ? LaunchOutcome.ok
        : LaunchOutcome.byName(m?['reason'] as String?);
    AppLog.instance.log(
      LogModule.launch,
      outcome.isOk
          ? '启动 $packageName${activity == null ? '' : ' · $activity'}'
          : '启动失败 · ${outcome.name} · $packageName',
      level: outcome.isOk ? LogLevel.info : LogLevel.warn,
    );
    return outcome;
  }

  /// The entries a package can be started through — its desktop icons plus any
  /// activity reachable through a standard intent (the dialer sometimes has no
  /// icon of its own). Each carries its own label.
  ///
  /// Results are cached in memory for the session: a package's entries only
  /// change when it is installed or updated (which triggers a rescan that drops
  /// the cache), so the two package-manager queries are paid once per app
  /// instead of once per launch. Pass [refresh] to bypass the cache — the app
  /// detail page does, so opening it always shows the live picture. Empty when
  /// the native side cannot answer, in which case callers fall back to a plain
  /// launch.
  static Future<List<LaunchEntry>> launchActivities(
    String packageName, {
    bool refresh = false,
  }) async {
    if (!refresh) {
      final cached = _entryCache[packageName];
      if (cached != null) return cached;
    }
    List<dynamic>? raw;
    try {
      raw = await _channel.invokeMethod<List<dynamic>>(
        'getLaunchActivities',
        {'packageName': packageName},
      );
    } catch (_) {
      // No native side (e.g. widget tests): callers fall back.
      return const <LaunchEntry>[];
    }
    if (raw == null) return const <LaunchEntry>[];
    final entries = raw
        .map((e) => LaunchEntry.fromMap((e as Map).cast<dynamic, dynamic>()))
        .where((e) => e.name.isNotEmpty)
        .toList(growable: false);
    _entryCache[packageName] = entries;
    AppLog.instance.log(
      LogModule.launch,
      '桌面入口 · $packageName · ${entries.length} 个'
          '${entries.isEmpty ? '' : ' · ${entries.map((e) => e.label).join(' / ')}'}',
    );
    return entries;
  }

  /// Forgets the cached entry lists (after a scan, which sees installs and
  /// updates).
  static void clearLaunchEntryCache() => _entryCache.clear();

  static final Map<String, List<LaunchEntry>> _entryCache = {};

  /// Forgets every unread mark of one package, clearing its badge.
  static Future<void> clearNotificationMark(String packageName) async {
    await _channel.invokeMethod<bool>('clearNotificationMark', {
      'packageName': packageName,
    });
  }

  /// Forgets every unread mark, clearing all badges.
  static Future<void> clearAllNotificationMarks() async {
    await _channel.invokeMethod<bool>('clearAllNotificationMarks');
  }

  static Future<bool> openAppInfo(String packageName) async {
    final ok = await _channel.invokeMethod<bool>(
      'openAppInfo',
      {'packageName': packageName},
    );
    return ok ?? false;
  }

  /// Opens an http(s) URL (e.g. the project's GitHub page) in a browser.
  static Future<bool> openUrl(String url, {String? package}) async {
    final ok = await _channel.invokeMethod<bool>('openUrl', {
      'url': url,
      if (package != null && package.isNotEmpty) 'package': package,
    });
    return ok ?? false;
  }

  /// Apps that can open an http(s) address, for the "use this browser" choice.
  static Future<List<BrowserApp>> browsers() async {
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('browsers');
      if (raw == null) return const [];
      return raw
          .whereType<Map>()
          .map(
            (e) => BrowserApp(
              packageName: '${e['packageName']}',
              label: '${e['label']}',
            ),
          )
          .where((b) => b.packageName.isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  /// Who would open [url] on this device, or null when nothing would. Used to
  /// tell whether a site has a real web app installed (which opens in the
  /// browser's own standalone window) or would just become a browser tab.
  static Future<WebAppHandler?> webAppHandler(String url) async {
    try {
      final raw = await _channel.invokeMethod<Map>('webAppHandler', {
        'url': url,
      });
      if (raw == null) return null;
      final map = raw.cast<String, dynamic>();
      final packageName = '${map['packageName']}';
      if (packageName.isEmpty) return null;
      return WebAppHandler(
        packageName: packageName,
        label: '${map['label']}',
        browser: map['browser'] == true,
      );
    } catch (_) {
      return null;
    }
  }

  /// Keeps the system status bar hidden (`hidden: true`) or visible.
  ///
  /// The native side re-applies this whenever the window regains focus, so the
  /// bar stays hidden even after the notification shade is pulled down.
  static Future<void> setStatusBarHidden(bool hidden) async {
    await _channel.invokeMethod<bool>('setStatusBarHidden', hidden);
  }

  /// Whether the user granted this app notification-listener access.
  static Future<bool> hasNotificationAccess() async {
    final ok = await _channel.invokeMethod<bool>('hasNotificationAccess');
    return ok ?? false;
  }

  /// Opens the system "notification access" list.
  static Future<bool> openNotificationAccessSettings() async {
    final ok =
        await _channel.invokeMethod<bool>('openNotificationAccessSettings');
    return ok ?? false;
  }

  /// Active per-package notification counts (empty until the listener connects).
  static Future<Map<String, int>> getNotificationCounts() async {
    final raw = await _channel
        .invokeMethod<Map<dynamic, dynamic>>('getNotificationCounts');
    return _countsFrom(raw);
  }

  /// Asks the system to re-bind the listener, e.g. right after access is granted.
  static Future<void> requestNotificationRebind() async {
    await _channel.invokeMethod<bool>('requestNotificationRebind');
  }

  /// Live state of the native notification listener, for the settings screen.
  static Future<Map<String, dynamic>> notificationDiagnostics() async {
    final raw = await _channel
        .invokeMethod<Map<dynamic, dynamic>>('notificationDiagnostics');
    return (raw ?? const {}).cast<String, dynamic>();
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

  /// Battery level, charging state and the data volume's free/total bytes.
  static Future<DeviceStatus> deviceStatus() async {
    try {
      final r = await _channel.invokeMethod<Map<dynamic, dynamic>>('deviceStatus');
      return DeviceStatus.fromMap((r ?? {}).cast<dynamic, dynamic>());
    } catch (_) {
      return DeviceStatus.unknown;
    }
  }

  /// Today's total foreground time. `permitted` is false without usage access.
  static Future<SystemUsage> screenTimeToday() async {
    try {
      final r = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('screenTimeToday');
      return SystemUsage.fromMap((r ?? {}).cast<dynamic, dynamic>());
    } catch (_) {
      return const SystemUsage(permitted: false, totalMillis: 0);
    }
  }

  /// This month's traffic, split by network type.
  static Future<TrafficUsage> trafficSummary() async {
    try {
      final r = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('trafficSummary');
      return TrafficUsage.fromMap((r ?? {}).cast<dynamic, dynamic>());
    } catch (_) {
      return const TrafficUsage(permitted: false);
    }
  }

  /// Turns the camera torch on/off. False when there is no torch.
  static Future<bool> setTorch(bool on) async {
    try {
      return await _channel.invokeMethod<bool>('setTorch', {'on': on}) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Device-wide bytes since boot, for a live throughput reading.
  static Future<TrafficTotals> trafficTotals() async {
    try {
      final r = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('trafficTotals');
      return TrafficTotals.fromMap((r ?? {}).cast<dynamic, dynamic>());
    } catch (_) {
      return const TrafficTotals(supported: false);
    }
  }

  /// Opens the clock app for the next alarm. False when none is set.
  static Future<bool> openNextAlarm() async {
    try {
      return await _channel.invokeMethod<bool>('openNextAlarm') ?? false;
    } catch (_) {
      return false;
    }
  }

  // -------------------------------------------------- storage / privacy / ...

  /// Whether the user granted "usage access". Needed before any per-app size
  /// can be read; the screens ask for it instead of showing wrong numbers.
  static Future<bool> hasUsageAccess() async {
    try {
      final r = await _channel.invokeMethod<Map<dynamic, dynamic>>('usageAccess');
      return (r?['granted'] as bool?) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens the system "usage access" screen (our own row when the ROM allows).
  static Future<bool> openUsageAccessSettings() async {
    try {
      return await _channel.invokeMethod<bool>('openUsageAccessSettings') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// APK / data / cache bytes of one installed app.
  static Future<AppStorageInfo> appStorage(String packageName) async {
    try {
      final r = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'appStorage',
        {'packageName': packageName},
      );
      return AppStorageInfo.fromMap((r ?? {}).cast<dynamic, dynamic>());
    } catch (_) {
      return const AppStorageInfo(ok: false, reason: 'unavailable');
    }
  }

  /// Every visible app's storage, biggest first.
  static Future<StorageRanking> storageRanking() async {
    try {
      final r = await _channel.invokeMethod<Map<dynamic, dynamic>>('storageRanking');
      final m = (r ?? {}).cast<dynamic, dynamic>();
      final entries = <StorageRankEntry>[];
      for (final e in (m['entries'] as List?) ?? const []) {
        entries.add(
          StorageRankEntry.fromMap((e as Map).cast<dynamic, dynamic>()),
        );
      }
      return StorageRanking(
        entries: entries,
        permitted: (m['permission'] as bool?) ?? false,
        unsupported: (m['unsupported'] as bool?) ?? false,
      );
    } catch (_) {
      return const StorageRanking(entries: [], permitted: false);
    }
  }

  /// Permissions the app requests, dangerous and granted ones first.
  static Future<List<PermissionEntry>> appPermissions(String packageName) async {
    try {
      final list = await _channel.invokeMethod<List<dynamic>>(
        'appPermissions',
        {'packageName': packageName},
      );
      return [
        for (final e in list ?? const [])
          PermissionEntry.fromMap((e as Map).cast<dynamic, dynamic>()),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// The certificate the installed app is signed with.
  static Future<SignatureInfo?> appSignature(String packageName) async {
    try {
      final r = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'appSignature',
        {'packageName': packageName},
      );
      if (r == null) return null;
      return SignatureInfo.fromMap(r.cast<dynamic, dynamic>());
    } catch (_) {
      return null;
    }
  }

  /// The wallpaper's own colours (primary first), which is as close to the
  /// launcher's Material You seed as the public API gets. Empty when the
  /// platform will not say (Android 8.0 or older).
  static Future<List<int>> wallpaperColors() async {
    try {
      final r = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'wallpaperColors',
      );
      final colors = (r?['colors'] as List?) ?? const [];
      return colors
          // The colour is used as a seed, so it must be fully opaque: some
          // wallpapers report a translucent primary colour.
          .map((e) => (e as num).toInt() | 0xFF000000)
          .where((c) => c != 0xFF000000)
          .toList(growable: false);
    } catch (_) {
      return const <int>[];
    }
  }

  /// Publishes (replacing) the dynamic launcher shortcuts: the recent apps a
  /// long press on 囤囤's own icon should offer. Returns false when the platform
  /// or the launcher refuses.
  static Future<bool> setRecentShortcuts(List<RecentShortcut> shortcuts) async {
    if (shortcuts.isEmpty) {
      // Clearing on purpose, so the list does not go stale.
      try {
        await _channel.invokeMethod<bool>('updateShortcuts', {
          'shortcuts': const <Map<String, dynamic>>[],
        });
      } catch (_) {}
      return true;
    }
    try {
      return await _channel.invokeMethod<bool>('updateShortcuts', {
            'shortcuts': [for (final s in shortcuts) s.toMap()],
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Snapshot-time facts of every installed package, keyed by package name.
  static Future<Map<String, AppFacts>> appFacts() async {
    try {
      final r = await _channel.invokeMethod<Map<dynamic, dynamic>>('appFacts');
      if (r == null) return const <String, AppFacts>{};
      return {
        for (final e in r.entries)
          '${e.key}': AppFacts.fromMap(
            (e.value as Map).cast<dynamic, dynamic>(),
          ),
      };
    } catch (_) {
      return const <String, AppFacts>{};
    }
  }

  /// The full install chain of [packageName] (empty when unknown).
  static Future<InstallSource> installSource(String packageName) async {
    try {
      final r = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'installSource',
        {'packageName': packageName},
      );
      if (r == null) return const InstallSource();
      return InstallSource.fromMap(r);
    } catch (_) {
      return const InstallSource();
    }
  }

  /// Who holds the sensitive permissions and special access.
  static Future<List<AuditCapability>> permissionAudit() async {
    try {
      final r = await _channel.invokeMethod<Map<dynamic, dynamic>>('permissionAudit');
      final caps = <AuditCapability>[];
      for (final c in (r?['capabilities'] as List?) ?? const []) {
        final m = (c as Map).cast<dynamic, dynamic>();
        caps.add(
          AuditCapability(
            id: (m['id'] as String?) ?? '',
            entries: [
              for (final e in (m['apps'] as List?) ?? const [])
                AuditEntry.fromMap((e as Map).cast<dynamic, dynamic>()),
            ],
          ),
        );
      }
      return caps;
    } catch (_) {
      return const [];
    }
  }

  /// Tests a remote APK source. Returns `{ok: bool, count: int, error: String?}`.
  static Future<Map<String, dynamic>> remoteTest(
      Map<String, dynamic> config) async {
    final r = await _channel
        .invokeMethod<Map<dynamic, dynamic>>('remoteTest', config);
    final out = (r ?? {}).cast<String, dynamic>();
    final ok = out['ok'] == true;
    AppLog.instance.log(
      LogModule.sync,
      ok
          ? '测试远程源成功 · ${out['count'] ?? 0} 个文件'
          : '测试远程源失败 · ${out['error'] ?? '未知错误'}',
      level: ok ? LogLevel.info : LogLevel.warn,
    );
    return out;
  }

  /// Lists `.apk` files on a remote source, recursively. Each item has
  /// name/rel/size/path/modified.
  static Future<List<Map<String, dynamic>>> remoteList(
      Map<String, dynamic> config) async {
    final raw = await _channel.invokeMethod<List<dynamic>>('remoteList', config);
    if (raw == null) return <Map<String, dynamic>>[];
    final list = raw
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList(growable: false);
    AppLog.instance.log(LogModule.sync, '列出远程文件 · ${list.length} 个');
    return list;
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
    _ensureHandler();
    final id = 'dl_${DateTime.now().microsecondsSinceEpoch}';
    if (onProgress != null) _downloadProgress[id] = onProgress;
    AppLog.instance.log(LogModule.sync, '开始下载 · $name');
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
      AppLog.instance.log(LogModule.sync, '下载完成 · $name');
      return path;
    } catch (e) {
      AppLog.instance.error(LogModule.sync, '下载失败 · $name — $e');
      rethrow;
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

  /// Deep analysis of an APK file on disk. Throws [PlatformException] when the
  /// file is missing or not a valid APK.
  static Future<ApkAnalysis> analyzeApk(String path) async {
    final r = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'analyzeApk',
      {'path': path},
    );
    if (r == null) {
      throw StateError(AppStrings.current.t('分析失败：无法读取该文件'));
    }
    return ApkAnalysis.fromMap(r.cast<String, dynamic>());
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

  /// The app's own scratch directory, where dragged-in APKs and shared copies
  /// are written. Android may clear it at any time, so its contents are always
  /// disposable. Null when the native side cannot say.
  static Future<String?> tempDir() async {
    try {
      return await _channel.invokeMethod<String>('tempDir');
    } catch (_) {
      return null;
    }
  }

  /// Hands a downloaded APK to the system package installer.
  static Future<bool> installApk(String path) async {
    final ok = await _channel.invokeMethod<bool>('installApk', {'path': path});
    AppLog.instance.log(
      LogModule.install,
      ok == true ? '交给系统安装器: $path' : '无法拉起系统安装器: $path',
      level: ok == true ? LogLevel.info : LogLevel.warn,
    );
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

/// One app that can open an http(s) address: an option for "use this browser".
class BrowserApp {
  const BrowserApp({required this.packageName, required this.label});

  final String packageName;
  final String label;
}

/// Who would open a web address on this device.
///
/// [browser] true means a general-purpose browser (so the site opens as a tab);
/// false means an app installed for that site — a real web app — which shows it
/// in the browser's own standalone window.
class WebAppHandler {
  const WebAppHandler({
    required this.packageName,
    required this.label,
    required this.browser,
  });

  final String packageName;
  final String label;
  final bool browser;
}
