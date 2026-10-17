import '../models/apk_analysis.dart';
import 'permissions.dart';

/// How worrying an APK is. The level is the worst finding it produced.
enum RiskLevel { low, medium, high }

/// One reason an APK was flagged. [label] and [detail] are Chinese source
/// strings, so `AppStrings.t` translates them.
class RiskFinding {
  const RiskFinding(this.level, this.label, this.detail);

  final RiskLevel level;
  final String label;
  final String detail;
}

/// The result of the red-flag check: a level, the findings behind it, and the
/// installed apps whose name or package this APK imitates.
class ApkRiskReport {
  const ApkRiskReport({
    required this.level,
    required this.findings,
    required this.spoofCandidates,
  });

  final RiskLevel level;
  final List<RiskFinding> findings;

  /// Installed apps this APK looks like. Whether that is a problem depends on
  /// the certificate, which is checked separately (see [SpoofVerdict]).
  final List<SpoofCandidate> spoofCandidates;

  bool get clean => findings.isEmpty;
}

/// An installed app whose name or package this APK resembles.
class SpoofCandidate {
  const SpoofCandidate({
    required this.packageName,
    required this.name,
    required this.reason,
    required this.packageDistance,
  });

  final String packageName;
  final String name;

  /// `sameName` (identical display name, different package) or
  /// `similarPackage` (package name a keystroke or two away).
  final String reason;

  /// Edit distance between the two package names (0 for a name match).
  final int packageDistance;
}

/// The verdict once the certificates are compared.
enum SpoofVerdict { differentSigner, sameSigner, unknown }

/// An installed app this APK appears to imitate, with the verdict.
class SpoofMatch {
  const SpoofMatch({
    required this.candidate,
    required this.verdict,
    this.installedSigner = '',
  });

  final SpoofCandidate candidate;
  final SpoofVerdict verdict;
  final String installedSigner;
}

/// A minimal view of an installed app, so the check needs no AppState.
class InstalledAppRef {
  const InstalledAppRef({
    required this.packageName,
    required this.name,
    this.signature = '',
  });

  final String packageName;
  final String name;
  final String signature;
}

/// The permission an app needs to install other apps: a red flag when it has no
/// business being an installer.
const String _installPackages = 'android.permission.REQUEST_INSTALL_PACKAGES';

/// Flags worth calling out even when they are common.
const List<String> _watchPermissions = <String>[
  'android.permission.SYSTEM_ALERT_WINDOW',
  'android.permission.PACKAGE_USAGE_STATS',
  'android.permission.QUERY_ALL_PACKAGES',
  'android.permission.ACCESS_BACKGROUND_LOCATION',
  'android.permission.READ_SMS',
  'android.permission.BIND_NOTIFICATION_LISTENER_SERVICE',
];

/// Answers "is this APK worth being careful about?" from its manifest alone.
///
/// [installedSigner] is the SHA-256 of the installed app with the same package
/// ('' when it is not installed), which is what makes "signed by someone else"
/// detectable. [deviceTargetSdk] is the device's own API level, used to judge
/// how far behind the APK's target is.
ApkRiskReport assessApk(
  ApkAnalysis apk, {
  required List<InstalledAppRef> installed,
  int deviceTargetSdk = 0,
}) {
  final findings = <RiskFinding>[];

  void flag(RiskLevel level, String label, String detail) =>
      findings.add(RiskFinding(level, label, detail));

  if (apk.debuggable) {
    flag(
      RiskLevel.high,
      '调试版本',
      '清单里写着 debuggable：任何应用都能读取它的数据、附加调试器，正式发布的应用不该是这样。',
    );
  }
  if (apk.accessibilityService) {
    flag(
      RiskLevel.high,
      '无障碍服务',
      '它可以读取屏幕内容并代替你操作，是权限里最危险的一种，只有确实需要（读屏、自动点击）的应用才应声明。',
    );
  }
  if (apk.deviceAdminReceiver) {
    flag(
      RiskLevel.high,
      '设备管理',
      '申请成为设备管理员：可以锁定设备、清除数据。除了找回类应用，一般不该出现。',
    );
  }
  if (apk.conflictsWithInstalled) {
    flag(
      RiskLevel.high,
      '签名与已安装版本不一致',
      '同包名的应用已经装着，但签名不同。正常升级不会换签名，这通常意味着它被重新打包过。',
    );
  }
  if (apk.permissions.contains(_installPackages)) {
    flag(
      RiskLevel.medium,
      '可以安装其它应用',
      '声明了「安装未知应用」权限：它能在你不知情时弹出安装界面。',
    );
  }
  if (apk.testOnly) {
    flag(
      RiskLevel.medium,
      '仅供测试',
      '清单里写着 testOnly，是调试用的安装包，不应该拿来长期使用。',
    );
  }
  if (apk.targetSdk > 0 && apk.targetSdk < 23) {
    flag(
      RiskLevel.medium,
      'targetSdk 太低',
      '目标版本低于 Android 6.0，运行时的权限检查等新限制都不会生效。',
    );
  } else if (deviceTargetSdk > 0 &&
      apk.targetSdk > 0 &&
      deviceTargetSdk - apk.targetSdk >= 4) {
    flag(
      RiskLevel.low,
      'targetSdk 偏低',
      '比这台设备的版本低了好几个大版本，系统会给它开一些兼容性口子。',
    );
  }
  if (apk.usesCleartextTraffic) {
    flag(
      RiskLevel.medium,
      '允许明文流量',
      '网络请求可以用 http:// 明文发送，内容包括密码都可能被同网络的人看到。',
    );
  }
  for (final permission in apk.permissions) {
    if (!_watchPermissions.contains(permission)) continue;
    flag(
      RiskLevel.medium,
      '敏感权限：${permissionLabel(permission)}',
      '这条权限能做的事超出普通应用的需要，装之前想清楚它为什么要。',
    );
  }
  if (apk.exportedCount > 0) {
    flag(
      RiskLevel.low,
      '有对外暴露的组件',
      '${apk.exportedCount} 个组件可以被其它应用调起，其中活动 '
          '${apk.exportedActivities}、服务 ${apk.exportedServices}、'
          '广播 ${apk.exportedReceivers}、内容提供者 ${apk.exportedProviders}。',
    );
  }
  if (apk.allowBackup) {
    flag(
      RiskLevel.low,
      '允许备份',
      '它的数据可以被 adb backup 之类的方式导出，聊天记录类的应用常常会关掉这个开关。',
    );
  }
  final selfSigned = apk.signers.where((s) => s.selfSigned).length;
  if (apk.signers.isNotEmpty && selfSigned == apk.signers.length) {
    flag(
      RiskLevel.low,
      '自签名证书',
      '不是由应用商店签发。侧载应用大多如此，本身不算问题，但也就没人替它的来源背书。',
    );
  }
  if (apk.hasV1Signature && apk.signers.isEmpty) {
    flag(
      RiskLevel.medium,
      '只有旧版签名',
      '只找到 v1（jar）签名，Android 7 以上会更严格地校验，重打包也更容易。',
    );
  }

  final level = findings.isEmpty
      ? RiskLevel.low
      : findings
            .map((f) => f.level)
            .reduce((a, b) => a.index > b.index ? a : b);

  return ApkRiskReport(
    level: level,
    findings: findings,
    spoofCandidates: spoofCandidates(apk, installed),
  );
}

/// Installed apps this APK looks like: the same display name under another
/// package, or a package name a keystroke or two away. A candidate is only a
/// problem when the certificates differ, which [spoofMatches] decides.
List<SpoofCandidate> spoofCandidates(
  ApkAnalysis apk,
  List<InstalledAppRef> installed, {
  int maxPackageDistance = 2,
}) {
  final out = <SpoofCandidate>[];
  final name = apk.appName.trim().toLowerCase();
  final package = apk.packageName.toLowerCase();
  for (final app in installed) {
    if (app.packageName == apk.packageName) continue;
    final sameName = name.isNotEmpty && app.name.trim().toLowerCase() == name;
    final distance = _editDistance(package, app.packageName.toLowerCase());
    final similar = !sameName && distance <= maxPackageDistance;
    if (!sameName && !similar) continue;
    out.add(
      SpoofCandidate(
        packageName: app.packageName,
        name: app.name,
        reason: sameName ? 'sameName' : 'similarPackage',
        packageDistance: distance,
      ),
    );
  }
  // Name matches first, then the closest package names.
  out.sort((a, b) {
    if (a.reason != b.reason) return a.reason == 'sameName' ? -1 : 1;
    return a.packageDistance.compareTo(b.packageDistance);
  });
  return out.take(3).toList();
}

/// Decides each candidate after comparing certificates.
List<SpoofMatch> spoofMatches(
  List<SpoofCandidate> candidates,
  List<InstalledAppRef> installed, {
  required String apkSignature,
}) {
  return [
    for (final c in candidates)
      () {
        final app = installed.firstWhere(
          (a) => a.packageName == c.packageName,
          orElse: () => InstalledAppRef(packageName: c.packageName, name: c.name),
        );
        final SpoofVerdict verdict;
        if (app.signature.isEmpty || apkSignature.isEmpty) {
          verdict = SpoofVerdict.unknown;
        } else if (app.signature == apkSignature) {
          verdict = SpoofVerdict.sameSigner;
        } else {
          verdict = SpoofVerdict.differentSigner;
        }
        return SpoofMatch(
          candidate: c,
          verdict: verdict,
          installedSigner: app.signature,
        );
      }(),
  ];
}

/// Levenshtein distance, capped for the short package names we compare.
int _editDistance(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  var previous = List<int>.generate(b.length + 1, (i) => i);
  var current = List<int>.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    current[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      final deletion = previous[j] + 1;
      final insertion = current[j - 1] + 1;
      final substitution = previous[j - 1] + cost;
      current[j] = deletion < insertion
          ? (deletion < substitution ? deletion : substitution)
          : (insertion < substitution ? insertion : substitution);
    }
    final swap = previous;
    previous = current;
    current = swap;
  }
  return previous[b.length];
}
