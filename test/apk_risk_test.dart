import 'package:flutter_test/flutter_test.dart';

import 'package:hamstapp/models/apk_analysis.dart';
import 'package:hamstapp/utils/apk_risk.dart';

ApkAnalysis apk({
  String packageName = 'com.example.app',
  String appName = 'Example',
  int targetSdk = 34,
  bool debuggable = false,
  bool allowBackup = false,
  bool testOnly = false,
  bool cleartext = false,
  List<String> permissions = const <String>[],
  bool accessibility = false,
  bool deviceAdmin = false,
  int exported = 0,
  bool installed = false,
  bool sameSigner = false,
  bool selfSigned = false,
  List<ApkSigner> signers = const <ApkSigner>[],
}) => ApkAnalysis(
  path: '/tmp/$packageName.apk',
  fileName: 'app.apk',
  size: 100,
  modified: 0,
  sha256: 'hash',
  md5: 'md5',
  packageName: packageName,
  appName: appName,
  versionName: '1.0',
  versionCode: 1,
  minSdk: 24,
  targetSdk: targetSdk,
  debuggable: debuggable,
  allowBackup: allowBackup,
  testOnly: testOnly,
  usesCleartextTraffic: cleartext,
  extractNativeLibs: false,
  permissions: permissions,
  features: const <String>[],
  activityCount: 0,
  serviceCount: 0,
  receiverCount: 0,
  providerCount: 0,
  abis: const <String>[],
  nativeLibCount: 0,
  dexCount: 1,
  dexBytes: 1,
  apkEntryCount: 1,
  apkUncompressedBytes: 1,
  apkCompressedBytes: 1,
  hasResourcesArsc: true,
  hasManifest: true,
  hasV1Signature: false,
  hasMultipleSigners: false,
  hasPastSigningCertificates: false,
  signers: signers,
  installed: installed,
  installedVersionCode: installed ? 1 : -1,
  installedVersionName: installed ? '1.0' : '',
  sameSignerAsInstalled: sameSigner,
  exportedActivities: exported,
  accessibilityService: accessibility,
  deviceAdminReceiver: deviceAdmin,
);

RiskLevel levelOf(ApkRiskReport r) => r.level;

List<String> labels(ApkRiskReport r) => [for (final f in r.findings) f.label];

void main() {
  group('Risk findings', () {
    test('a plain APK is low and explains that low is not "safe"', () {
      final report = assessApk(apk(), installed: const []);
      expect(report.level, RiskLevel.low);
      expect(report.clean, isTrue);
      expect(report.findings, isEmpty);
    });

    test('debuggable is high', () {
      final report = assessApk(apk(debuggable: true), installed: const []);
      expect(report.level, RiskLevel.high);
      expect(labels(report), contains('调试版本'));
    });

    test('accessibility service and device admin are high', () {
      expect(
        assessApk(apk(accessibility: true), installed: const []).level,
        RiskLevel.high,
      );
      expect(
        labels(assessApk(apk(accessibility: true), installed: const [])),
        contains('无障碍服务'),
      );
      expect(
        assessApk(apk(deviceAdmin: true), installed: const []).level,
        RiskLevel.high,
      );
    });

    test('a different signature than the installed app is high', () {
      final report = assessApk(
        apk(installed: true, sameSigner: false),
        installed: const [],
      );
      expect(report.level, RiskLevel.high);
      expect(labels(report), contains('签名与已安装版本不一致'));
      // The same package with the same signer is not flagged.
      final fine = assessApk(
        apk(installed: true, sameSigner: true),
        installed: const [],
      );
      expect(labels(fine), isNot(contains('签名与已安装版本不一致')));
    });

    test('the install-other-apps permission and testOnly are medium', () {
      final report = assessApk(
        apk(
          permissions: const ['android.permission.REQUEST_INSTALL_PACKAGES'],
          testOnly: true,
        ),
        installed: const [],
      );
      expect(report.level, RiskLevel.medium);
      expect(labels(report), contains('可以安装其它应用'));
      expect(labels(report), contains('仅供测试'));
    });

    test('an old targetSdk is medium, a slightly old one is low', () {
      final old = assessApk(apk(targetSdk: 22), installed: const []);
      expect(old.level, RiskLevel.medium);
      expect(labels(old), contains('targetSdk 太低'));

      final behind = assessApk(
        apk(targetSdk: 30),
        installed: const [],
        deviceTargetSdk: 34,
      );
      expect(behind.level, RiskLevel.low);
      expect(labels(behind), contains('targetSdk 偏低'));
    });

    test('cleartext, exported components, backup and self-signing are noted', () {
      final report = assessApk(
        apk(
          cleartext: true,
          allowBackup: true,
          exported: 2,
          signers: const [ApkSigner(sha256: 'AA', selfSigned: true)],
        ),
        installed: const [],
      );
      expect(labels(report), contains('允许明文流量'));
      expect(labels(report), contains('有对外暴露的组件'));
      expect(labels(report), contains('允许备份'));
      expect(labels(report), contains('自签名证书'));
      expect(report.level, RiskLevel.medium);
    });

    test('watched permissions become findings', () {
      final report = assessApk(
        apk(
          permissions: const [
            'android.permission.SYSTEM_ALERT_WINDOW',
            'android.permission.READ_SMS',
          ],
        ),
        installed: const [],
      );
      expect(labels(report), contains('敏感权限：悬浮窗'));
      expect(labels(report), contains('敏感权限：短信'));
    });

    test('the level is the worst finding', () {
      final report = assessApk(
        apk(
          debuggable: true,
          cleartext: true,
          allowBackup: true,
        ),
        installed: const [],
      );
      expect(report.level, RiskLevel.high);
      expect(
        report.findings.map((f) => f.level),
        contains(RiskLevel.medium),
      );
    });
  });

  group('Look-alike detection', () {
    const installed = [
      InstalledAppRef(packageName: 'com.tencent.mm', name: '微信'),
      InstalledAppRef(packageName: 'com.example.notes', name: 'Notes'),
      InstalledAppRef(packageName: 'com.other.app', name: 'Other'),
    ];

    test('the same name under another package is a candidate', () {
      final c = spoofCandidates(
        apk(packageName: 'com.evil.wechat', appName: '微信'),
        installed,
      );
      expect(c, hasLength(1));
      expect(c.single.packageName, 'com.tencent.mm');
      expect(c.single.reason, 'sameName');
    });

    test('a package name one or two characters off is a candidate', () {
      final c = spoofCandidates(
        apk(packageName: 'com.tencent.mm1', appName: 'WeChat'),
        installed,
      );
      expect(c, hasLength(1));
      expect(c.single.reason, 'similarPackage');
      expect(c.single.packageDistance, 1);
    });

    test('the same package is not compared with itself', () {
      final c = spoofCandidates(
        apk(packageName: 'com.tencent.mm', appName: '微信'),
        installed,
      );
      expect(c, isEmpty);
    });

    test('a clearly different name and package is ignored', () {
      final c = spoofCandidates(
        apk(packageName: 'org.something.else', appName: 'Calendar'),
        installed,
      );
      expect(c, isEmpty);
    });
  });

  group('Look-alike verdicts', () {
    final candidates = spoofCandidates(
      apk(packageName: 'com.tencent.mm1', appName: '微信'),
      const [InstalledAppRef(packageName: 'com.tencent.mm', name: '微信')],
    );

    test('a different certificate is the dangerous case', () {
      final matches = spoofMatches(
        candidates,
        const [
          InstalledAppRef(
            packageName: 'com.tencent.mm',
            name: '微信',
            signature: 'AA',
          ),
        ],
        apkSignature: 'BB',
      );
      expect(matches.single.verdict, SpoofVerdict.differentSigner);
      expect(matches.single.installedSigner, 'AA');
    });

    test('the same certificate means a sibling app, not a fake', () {
      final matches = spoofMatches(
        candidates,
        const [
          InstalledAppRef(
            packageName: 'com.tencent.mm',
            name: '微信',
            signature: 'AA',
          ),
        ],
        apkSignature: 'AA',
      );
      expect(matches.single.verdict, SpoofVerdict.sameSigner);
    });

    test('a missing certificate gives no verdict instead of guessing', () {
      final matches = spoofMatches(
        candidates,
        const [InstalledAppRef(packageName: 'com.tencent.mm', name: '微信')],
        apkSignature: '',
      );
      expect(matches.single.verdict, SpoofVerdict.unknown);
    });
  });

  test('the new manifest fields are read from the native map', () {
    final a = ApkAnalysis.fromMap(<String, dynamic>{
      'path': '/tmp/a.apk',
      'packageName': 'com.a',
      'activityCount': 5,
      'exportedActivities': 2,
      'exportedServices': 1,
      'exportedReceivers': 3,
      'exportedProviders': 0,
      'accessibilityService': true,
      'deviceAdminReceiver': false,
    });
    expect(a.exportedActivities, 2);
    expect(a.exportedServices, 1);
    expect(a.exportedReceivers, 3);
    expect(a.exportedCount, 6);
    expect(a.accessibilityService, isTrue);
    expect(a.deviceAdminReceiver, isFalse);
  });
}
