import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:hamstapp/l10n/app_strings.dart';
import 'package:hamstapp/models/apk_analysis.dart';
import 'package:hamstapp/models/app_info.dart';
import 'package:hamstapp/screens/apk_analyzer_screen.dart';
import 'package:hamstapp/screens/app_detail_screen.dart';
import 'package:hamstapp/services/storage.dart';
import 'package:hamstapp/state/app_state.dart';

const _channel = MethodChannel('hamstapp/apps');

class _MemStorage implements Storage {
  final Map<String, dynamic> _data = <String, dynamic>{};
  @override
  Future<dynamic> readJson(String name) async => _data[name];
  @override
  Future<void> writeJson(String name, dynamic data) async {
    _data[name] = data;
  }
}

AppInfo _ai(String pkg, String name, {String apkPath = ''}) => AppInfo(
  packageName: pkg,
  appName: name,
  versionName: '1.2.3',
  versionCode: 42,
  firstInstallTime: 0,
  lastUpdateTime: 0,
  isSystem: false,
  enabled: true,
  apkPath: apkPath,
  sizeBytes: 0,
  targetSdk: 34,
  minSdk: 21,
  uid: 0,
);

final Map<String, dynamic> _payload = <String, dynamic>{
  'path': '/tmp/app.apk',
  'fileName': 'app.apk',
  'size': 123456,
  'modified': 1700000000000,
  'sha256': 'AA:BB',
  'md5': 'CC:DD',
  'packageName': 'com.example.app',
  'appName': 'Example',
  'versionName': '1.2.3',
  'versionCode': 42,
  'minSdk': 21,
  'targetSdk': 34,
  'debuggable': false,
  'allowBackup': true,
  'testOnly': false,
  'usesCleartextTraffic': false,
  'extractNativeLibs': true,
  'permissions': ['android.permission.INTERNET', 'android.permission.CAMERA'],
  'features': ['android.hardware.camera'],
  'activityCount': 5,
  'serviceCount': 2,
  'receiverCount': 1,
  'providerCount': 0,
  'abis': ['arm64-v8a'],
  'nativeLibCount': 3,
  'dexCount': 2,
  'dexBytes': 4096,
  'apkEntryCount': 100,
  'apkUncompressedBytes': 500000,
  'apkCompressedBytes': 123456,
  'hasResourcesArsc': true,
  'hasManifest': true,
  'hasV1Signature': true,
  'hasMultipleSigners': false,
  'hasPastSigningCertificates': false,
  'signers': [
    {
      'sha256': 'DE:AD:BE:EF',
      'sha1': 'AB:CD',
      'subject': 'CN=Example',
      'issuer': 'CN=Example',
      'serialNumber': '1A2B',
      'signatureAlgorithm': 'SHA256withRSA',
      'notBefore': 1600000000000,
      'notAfter': 1900000000000,
      'selfSigned': true,
    },
  ],
  'installed': true,
  'installedVersionCode': 40,
  'installedVersionName': '1.2.2',
  'sameSignerAsInstalled': true,
  'icon': null,
};

Future<void> _drop(String path) async {
  const codec = StandardMethodCodec();
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
    'hamstapp/apps',
    codec.encodeMethodCall(MethodCall('apkDropped', {'path': path})),
    (_) {},
  );
}

void main() {
  setUp(() {
    AppStrings.current = const AppStrings('zh');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      if (call.method == 'analyzeApk') return _payload;
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  test('ApkAnalysis parses the native payload', () {
    final a = ApkAnalysis.fromMap(_payload);
    expect(a.packageName, 'com.example.app');
    expect(a.appName, 'Example');
    expect(a.versionCode, 42);
    expect(a.permissions, hasLength(2));
    expect(a.abis, ['arm64-v8a']);
    expect(a.signers, hasLength(1));
    expect(a.signers.first.sha256, 'DE:AD:BE:EF');
    expect(a.signers.first.selfSigned, isTrue);
    expect(a.installed, isTrue);
    expect(a.canUpdateInstalled, isTrue);
    expect(a.conflictsWithInstalled, isFalse);
  });

  test('conflicting signer flags an incompatible update', () {
    final a = ApkAnalysis.fromMap({
      ..._payload,
      'sameSignerAsInstalled': false,
    });
    expect(a.conflictsWithInstalled, isTrue);
    expect(a.canUpdateInstalled, isFalse);
  });

  testWidgets('analyzes an APK passed as initialPath', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: ApkAnalyzerScreen(initialPath: '/tmp/app.apk')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('APK 分析'), findsOneWidget);
    expect(find.text('Example'), findsWidgets);
    expect(find.textContaining('com.example.app'), findsWidgets);
    expect(find.textContaining('签名一致'), findsWidgets);
    expect(find.text('文件'), findsOneWidget);
    // Fixed-file mode: no way to open another file.
    expect(find.text('将 APK 拖到这里，或点击选择'), findsNothing);
    expect(find.text('选择另一个 APK'), findsNothing);
  });

  testWidgets('a dropped file is analyzed', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: ApkAnalyzerScreen()),
    );
    await tester.pump();

    expect(find.text('将 APK 拖到这里，或点击选择'), findsOneWidget);

    await _drop('/tmp/dropped.apk');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Example'), findsWidgets);
    expect(find.text('将 APK 拖到这里，或点击选择'), findsNothing);
  });

  testWidgets('installed app detail opens the analyzer for its APK', (
    tester,
  ) async {
    final state = AppState(_MemStorage())
      ..initialized = true
      ..apps = [_ai('com.example.app', 'Example', apkPath: '/tmp/app.apk')];

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(
          home: AppDetailScreen(packageName: 'com.example.app'),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byIcon(Icons.manage_search));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('APK 分析'), findsOneWidget);
    expect(find.text('Example'), findsWidgets);
    expect(find.textContaining('com.example.app'), findsWidgets);
  });
}
