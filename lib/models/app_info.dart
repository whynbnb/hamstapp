class AppInfo {
  final String packageName;
  final String appName;
  final String versionName;
  final int versionCode;
  final int firstInstallTime;
  final int lastUpdateTime;
  final bool isSystem;
  final bool enabled;
  final String apkPath;
  final int sizeBytes;
  final int targetSdk;
  final int minSdk;
  final int uid;

  /// Whether this package is an installed web app (PWA): a WebAPK shell or a
  /// Trusted Web Activity. Such a package behaves like any other app — it can
  /// be launched, pinned to a tile or favorited — but it really is a website,
  /// so the UI labels it and can show [webUrl].
  final bool isWebApp;

  /// Which signal recognised it as a web app (`entry`, `package`, `metadata`),
  /// as the scan reported it. Kept for the log, not for the UI, and not
  /// persisted with the scan cache.
  final String webSignal;

  /// The site an installed web app stands for, or '' when the shell does not
  /// declare one (or when this is not a web app).
  final String webUrl;

  /// The package that installed this app (the store or installer), as the
  /// system reports it; '' when the app was side-loaded or unknown. It is a
  /// package name, not a label: the UI resolves it to a name when that package
  /// is itself installed.
  final String installer;

  /// Whether this is a web entry the user added by hand rather than an
  /// installed package. Such an entry has a synthetic package name
  /// ([WebApp.idPrefix]), no APK and nothing to uninstall — its "launch" opens
  /// [webUrl] in a browser.
  final bool isWebEntry;

  const AppInfo({
    required this.packageName,
    required this.appName,
    required this.versionName,
    required this.versionCode,
    required this.firstInstallTime,
    required this.lastUpdateTime,
    required this.isSystem,
    required this.enabled,
    required this.apkPath,
    required this.sizeBytes,
    required this.targetSdk,
    required this.minSdk,
    required this.uid,
    this.isWebApp = false,
    this.webUrl = '',
    this.webSignal = '',
    this.isWebEntry = false,
    this.installer = '',
  });

  factory AppInfo.fromMap(Map<dynamic, dynamic> map) {
    return AppInfo(
      packageName: map['packageName'] as String? ?? '',
      appName: map['appName'] as String? ?? '',
      versionName: map['versionName'] as String? ?? '',
      versionCode: (map['versionCode'] as num?)?.toInt() ?? 0,
      firstInstallTime: (map['firstInstallTime'] as num?)?.toInt() ?? 0,
      lastUpdateTime: (map['lastUpdateTime'] as num?)?.toInt() ?? 0,
      isSystem: map['isSystem'] as bool? ?? false,
      enabled: map['enabled'] as bool? ?? true,
      apkPath: map['apkPath'] as String? ?? '',
      sizeBytes: (map['sizeBytes'] as num?)?.toInt() ?? 0,
      targetSdk: (map['targetSdk'] as num?)?.toInt() ?? 0,
      minSdk: (map['minSdk'] as num?)?.toInt() ?? 0,
      uid: (map['uid'] as num?)?.toInt() ?? 0,
      isWebApp: map['isWebApp'] as bool? ?? false,
      webUrl: map['webUrl'] as String? ?? '',
      webSignal: map['webSignal'] as String? ?? '',
      isWebEntry: map['isWebEntry'] as bool? ?? false,
      installer: map['installer'] as String? ?? '',
    );
  }

  DateTime get firstInstallDate =>
      DateTime.fromMillisecondsSinceEpoch(firstInstallTime);
  DateTime get lastUpdateDate =>
      DateTime.fromMillisecondsSinceEpoch(lastUpdateTime);

  String get initial =>
      appName.trim().isEmpty ? '?' : appName.trim()[0].toUpperCase();

  Map<String, dynamic> toMap() => {
        'packageName': packageName,
        'appName': appName,
        'versionName': versionName,
        'versionCode': versionCode,
        'firstInstallTime': firstInstallTime,
        'lastUpdateTime': lastUpdateTime,
        'isSystem': isSystem,
        'enabled': enabled,
        'apkPath': apkPath,
        'sizeBytes': sizeBytes,
        'targetSdk': targetSdk,
        'minSdk': minSdk,
        'uid': uid,
        'isWebApp': isWebApp,
        'webUrl': webUrl,
        'isWebEntry': isWebEntry,
        'installer': installer,
      };
}
