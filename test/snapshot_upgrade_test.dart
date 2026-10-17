import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:hamstapp/models/app_info.dart';
import 'package:hamstapp/models/snapshot.dart';
import 'package:hamstapp/screens/compare_screen.dart';
import 'package:hamstapp/models/snapshot_diff.dart';
import 'package:hamstapp/services/native_apps.dart';
import 'package:hamstapp/services/storage.dart';
import 'package:hamstapp/state/app_state.dart';
import 'package:hamstapp/utils/permissions.dart';
import 'package:hamstapp/widgets/app_facts.dart';

/// A 1x1 transparent PNG: enough for AppIcon to draw without asking the
/// platform, which would keep a spinner alive in a widget test.
final Uint8List _icon = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6'
  'kgAAAABJRU5ErkJggg==',
);

SnapshotEntry entry(
  String pkg, {
  String version = '1.0',
  int code = 1,
  List<String> permissions = const <String>[],
  String signature = '',
  int targetSdk = 34,
  String installer = '',
  bool external = false,
}) => SnapshotEntry(
  packageName: pkg,
  appName: pkg,
  versionName: version,
  versionCode: code,
  lastUpdateTime: 0,
  firstInstallTime: 0,
  isSystem: false,
  sizeBytes: 100,
  permissions: permissions,
  signature: signature,
  targetSdk: targetSdk,
  installer: installer,
  external: external,
  icon: _icon,
);

Snapshot snap(List<SnapshotEntry> entries) =>
    Snapshot(id: 's', name: 's', createdAt: 0, entries: entries);

class _MemStorage implements Storage {
  final Map<String, dynamic> _data = <String, dynamic>{};
  @override
  Future<dynamic> readJson(String name) async => _data[name];
  @override
  Future<void> writeJson(String name, dynamic data) async {
    _data[name] = data;
  }
}

AppInfo app(String pkg, String name) => AppInfo(
  packageName: pkg,
  appName: name,
  versionName: '1.0',
  versionCode: 1,
  firstInstallTime: 0,
  lastUpdateTime: 0,
  isSystem: false,
  enabled: true,
  apkPath: '/data/app/$pkg/base.apk',
  sizeBytes: 10,
  targetSdk: 34,
  minSdk: 24,
  uid: 1,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const camera = 'android.permission.CAMERA';
  const mic = 'android.permission.RECORD_AUDIO';
  const location = 'android.permission.ACCESS_FINE_LOCATION';

  group('Upgrade details', () {
    test('an update that asks for more says which permissions', () {
      final diff = SnapshotDiff.between(
        snap([entry('com.a', permissions: [camera], signature: 'AA')]),
        snap([
          entry(
            'com.a',
            version: '2.0',
            code: 2,
            permissions: [camera, mic, location],
            signature: 'AA',
          ),
        ]),
      );
      expect(diff.updated, hasLength(1));
      expect(diff.added, isEmpty);
      final item = diff.updated.single;
      // Sorted by full permission name, so the list is stable between runs.
      expect(item.addedPermissions, [location, mic]);
      expect(item.removedPermissions, isEmpty);
      expect(item.securityChanged, isTrue);
      expect(diff.appsWithNewPermissions, 1);
      expect(diff.securityUpdates, hasLength(1));
    });

    test('a dropped permission is reported as removed', () {
      final diff = SnapshotDiff.between(
        snap([entry('com.a', permissions: [camera, mic], signature: 'AA')]),
        snap([entry('com.a', permissions: [camera], signature: 'AA')]),
      );
      final item = diff.updated.single;
      expect(item.addedPermissions, isEmpty);
      expect(item.removedPermissions, [mic]);
      expect(item.securityChanged, isTrue);
    });

    test('a replaced signing certificate is flagged', () {
      final diff = SnapshotDiff.between(
        snap([entry('com.a', version: '1.0', code: 1, signature: 'AAAA')]),
        snap([entry('com.a', version: '2.0', code: 2, signature: 'BBBB')]),
      );
      final item = diff.updated.single;
      expect(item.signatureChanged, isTrue);
      expect(item.fromSignature, 'AAAA');
      expect(item.toSignature, 'BBBB');
      expect(diff.appsWithSignatureChange, 1);
    });

    test('an unknown certificate on either side is not a change', () {
      final diff = SnapshotDiff.between(
        snap([entry('com.a', version: '1.0', code: 1, signature: '')]),
        snap([entry('com.a', version: '2.0', code: 2, signature: 'BBBB')]),
      );
      expect(diff.updated.single.signatureChanged, isFalse);
      expect(diff.appsWithSignatureChange, 0);
    });

    test('targetSdk, install source and install location are tracked', () {
      final diff = SnapshotDiff.between(
        snap([
          entry(
            'com.a',
            version: '1.0',
            code: 1,
            targetSdk: 30,
            installer: 'com.store',
            signature: 'AA',
          ),
        ]),
        snap([
          entry(
            'com.a',
            version: '2.0',
            code: 2,
            targetSdk: 34,
            installer: '',
            external: true,
            signature: 'AA',
          ),
        ]),
      );
      final item = diff.updated.single;
      expect(item.fromTargetSdk, 30);
      expect(item.toTargetSdk, 34);
      expect(item.fromInstaller, 'com.store');
      expect(item.toInstaller, '');
      expect(item.fromExternal, isFalse);
      expect(item.toExternal, isTrue);
      expect(item.hasDetails, isTrue);
      // None of these is a permissions/certificate change.
      expect(item.securityChanged, isFalse);
      expect(item.fromInstaller != item.toInstaller, isTrue);
      expect(diff.appsWithInstallerChange, 1);
    });

    test('an app whose facts are identical is not reported as updated', () {
      final diff = SnapshotDiff.between(
        snap([entry('com.a', permissions: [camera], signature: 'AA')]),
        snap([entry('com.a', permissions: [camera], signature: 'AA')]),
      );
      expect(diff.updated, isEmpty);
      expect(diff.unchanged, hasLength(1));
    });

    test('snapshots from before fact recording produce no phantom changes', () {
      // Both sides know nothing: no permissions, no certificate.
      final diff = SnapshotDiff.between(
        snap([entry('com.a')]),
        snap([entry('com.a', signature: '', permissions: [])]),
      );
      expect(diff.updated, isEmpty);
      expect(diff.unchanged, hasLength(1));

      // An old snapshot read against a new one must not claim the new build
      // dropped nothing / added everything.
      final mixed = SnapshotDiff.between(
        snap([entry('com.a')]),
        snap([entry('com.a', permissions: [camera, mic], signature: 'AA')]),
      );
      expect(mixed.updated, isEmpty);
      expect(mixed.unchanged, hasLength(1));
    });

    test('security-relevant upgrades sort first', () {
      final diff = SnapshotDiff.between(
        snap([
          entry('com.a', version: '1.0', code: 1, signature: 'AA'),
          entry('com.b', version: '1.0', code: 1, signature: 'BB'),
        ]),
        snap([
          entry('com.a', version: '2.0', code: 2, signature: 'AA'),
          entry('com.b', version: '2.0', code: 2, signature: 'CC'),
        ]),
      );
      expect(diff.updated.first.packageName, 'com.b');
      expect(diff.securityUpdates.single.packageName, 'com.b');
    });
  });

  testWidgets('the comparison names the permissions an update added', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final state = AppState(_MemStorage())
      ..initialized = true
      ..apps = [app('com.a', 'A')];

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          home: CompareScreen(
            olderLabel: '旧',
            newerLabel: '新',
            older: [
              entry(
                'com.a',
                version: '1.0',
                code: 1,
                permissions: [camera],
                signature: 'AA',
              ),
            ],
            newer: [
              entry(
                'com.a',
                version: '2.0',
                code: 2,
                permissions: [camera, mic],
                signature: 'AA',
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('更新 1'));
    await tester.pumpAndSettle();

    expect(find.text('新增权限'), findsOneWidget);
    expect(find.text('麦克风'), findsOneWidget);
  });

  group('Snapshot facts flag', () {
    test('a snapshot knows whether it carries facts', () {
      expect(snap([entry('com.a')]).hasFacts, isFalse);
      expect(snap([entry('com.a', permissions: [camera])]).hasFacts, isTrue);
      expect(snap([entry('com.a', signature: 'AA')]).hasFacts, isTrue);
    });

    test('the new fields survive a round trip and old data still loads', () {
      final restored = SnapshotEntry.fromMap(
        entry(
          'com.a',
          permissions: [camera],
          signature: 'AA',
          targetSdk: 33,
          installer: 'com.store',
          external: true,
        ).toMap(),
      );
      expect(restored.permissions, [camera]);
      expect(restored.signature, 'AA');
      expect(restored.targetSdk, 33);
      expect(restored.installer, 'com.store');
      expect(restored.external, isTrue);

      final old = SnapshotEntry.fromMap({
        'packageName': 'com.old',
        'appName': 'Old',
        'versionName': '1.0',
        'versionCode': 1,
        'lastUpdateTime': 0,
        'firstInstallTime': 0,
        'isSystem': false,
        'sizeBytes': 0,
      });
      expect(old.permissions, isEmpty);
      expect(old.signature, isEmpty);
      expect(old.external, isFalse);
    });
  });

  group('Permission labels', () {
    test('a permission name is short, labelled and classified', () {
      expect(permissionShortName(camera), 'CAMERA');
      expect(permissionLabel(camera), '相机');
      expect(permissionLabel('android.permission.CAMERA'), '相机');
      expect(permissionLabel('android.permission.ACCESS_FINE_LOCATION'), '精确位置');
      // Unknown permissions keep the platform name rather than disappearing.
      expect(
        permissionLabel('android.permission.SOMETHING_NEW'),
        'SOMETHING_NEW',
      );
      expect(isSensitivePermission(camera), isTrue);
      expect(isSensitivePermission('android.permission.VIBRATE'), isFalse);
    });
  });

  group('Install source', () {
    test('the model reads the map the native side sends', () {
      const full = InstallSource(
        installer: 'com.store',
        initiating: 'com.filemanager',
        originating: 'com.filemanager',
        detailed: true,
      );
      expect(full.isEmpty, isFalse);
      expect(const InstallSource().isEmpty, isTrue);
      final parsed = InstallSource.fromMap(<dynamic, dynamic>{
        'installer': 'com.store',
        'initiating': '',
        'originating': '',
        'detailed': false,
      });
      expect(parsed.installer, 'com.store');
      expect(parsed.detailed, isFalse);
    });

    test('AppInfo carries the installer through the cache', () {
      final a = AppInfo.fromMap(<dynamic, dynamic>{
        'packageName': 'com.a',
        'appName': 'A',
        'installer': 'com.store',
      });
      expect(a.installer, 'com.store');
      expect(AppInfo.fromMap(a.toMap()).installer, 'com.store');
    });

    testWidgets('the card names the installer when that app is installed', (
      tester,
    ) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('hamstapp/apps'), (
            call,
          ) async {
            if (call.method == 'installSource') {
              return <String, dynamic>{
                'installer': 'com.store',
                'initiating': '',
                'originating': '',
                'detailed': true,
              };
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(const MethodChannel('hamstapp/apps'), null);
      });

      final state = AppState(_MemStorage())
        ..initialized = true
        ..apps = [app('com.app', 'App'), app('com.store', '应用商店')];

      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: const MaterialApp(
            home: Scaffold(body: AppInstallSourceCard(packageName: 'com.app')),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('安装来源'), findsOneWidget);
      expect(find.text('应用商店（com.store）'), findsOneWidget);
    });

    testWidgets('an unknown installer is explained, not left blank', (
      tester,
    ) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('hamstapp/apps'),
            (call) async => call.method == 'installSource'
                ? <String, dynamic>{'installer': '', 'detailed': true}
                : null,
          );
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(const MethodChannel('hamstapp/apps'), null);
      });

      final state = AppState(_MemStorage())
        ..initialized = true
        ..apps = [app('com.app', 'App')];

      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: const MaterialApp(
            home: Scaffold(body: AppInstallSourceCard(packageName: 'com.app')),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('系统没有记录安装者'), findsOneWidget);
    });
  });
}
