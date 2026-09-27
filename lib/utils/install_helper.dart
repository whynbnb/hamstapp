import '../services/native_apps.dart';

/// Outcome of handing an APK to the system installer.
enum InstallOutcome {
  /// The installer activity was launched successfully.
  handedOff,

  /// The app is not allowed to install packages; the user was sent to the
  /// corresponding system setting.
  permissionNeeded,

  /// The installer could not be launched.
  failed,
}

/// Hands a local APK to the system package installer, requesting the
/// "install unknown apps" permission first when it has not been granted.
Future<InstallOutcome> installLocalApk(String path) async {
  if (!await NativeApps.canInstallPackages()) {
    await NativeApps.openInstallPermissionSettings();
    return InstallOutcome.permissionNeeded;
  }
  final ok = await NativeApps.installApk(path);
  return ok ? InstallOutcome.handedOff : InstallOutcome.failed;
}
