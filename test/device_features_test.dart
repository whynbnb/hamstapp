import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:hamstapp/screens/permission_audit_screen.dart';
import 'package:hamstapp/screens/storage_usage_screen.dart';
import 'package:hamstapp/services/storage.dart';
import 'package:hamstapp/state/app_state.dart';
import 'package:hamstapp/widgets/app_facts.dart';

class _MemStorage implements Storage {
  final Map<String, dynamic> _data = <String, dynamic>{};
  @override
  Future<dynamic> readJson(String name) async => _data[name];
  @override
  Future<void> writeJson(String name, dynamic data) async {
    _data[name] = data;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('hamstapp/apps');
  bool permitted = true;

  void mockChannel() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'getAppIcon':
          return null;
        case 'usageAccess':
          return {'granted': permitted};
        case 'storageRanking':
          return {
            'permission': permitted,
            'entries': [
              {
                'packageName': 'com.big',
                'appName': 'Big',
                'isSystem': false,
                'apkBytes': 40 * 1024 * 1024,
                'dataBytes': 200 * 1024 * 1024,
                'cacheBytes': 10 * 1024 * 1024,
                'totalBytes': 250 * 1024 * 1024,
              },
              {
                'packageName': 'com.small',
                'appName': 'Small',
                'isSystem': false,
                'apkBytes': 5 * 1024 * 1024,
                'dataBytes': 5 * 1024 * 1024,
                'cacheBytes': 0,
                'totalBytes': 10 * 1024 * 1024,
              },
            ],
          };
        case 'appStorage':
          if (!permitted) return {'ok': false, 'reason': 'permission'};
          return {
            'ok': true,
            'apkBytes': 40 * 1024 * 1024,
            'dataBytes': 200 * 1024 * 1024,
            'cacheBytes': 10 * 1024 * 1024,
            'totalBytes': 250 * 1024 * 1024,
          };
        case 'appPermissions':
          return [
            {
              'name': 'android.permission.CAMERA',
              'granted': true,
              'dangerous': true,
              'group': 'android.permission-group.CAMERA',
            },
            {
              'name': 'android.permission.INTERNET',
              'granted': true,
              'dangerous': false,
              'group': '',
            },
          ];
        case 'appSignature':
          return {
            'packageName': 'com.big',
            'appName': 'Big',
            'system': false,
            'count': 1,
            'multipleSigners': false,
            'rotated': false,
            'sha256': 'AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99',
            'sha1': 'AA:BB',
            'subject': 'CN=Big',
            'issuer': 'CN=Big',
            'selfSigned': true,
            'notBefore': 0,
            'notAfter': 0,
          };
        case 'permissionAudit':
          return {
            'capabilities': [
              {
                'id': 'microphone',
                'apps': [
                  {
                    'packageName': 'com.rec',
                    'appName': 'Recorder',
                    'isSystem': false,
                    'note': '',
                  },
                ],
              },
              {
                'id': 'accessibility',
                'apps': [
                  {
                    'packageName': 'com.click',
                    'appName': 'Clicker',
                    'isSystem': true,
                    'note': 'AutoService',
                  },
                ],
              },
            ],
          };
        default:
          return null;
      }
    });
  }

  setUp(() {
    permitted = true;
    mockChannel();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  AppState state() => AppState(_MemStorage())..initialized = true;

  Widget wrap(Widget child, AppState app) =>
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(home: Scaffold(body: child)),
      );

  testWidgets('the storage ranking lists apps biggest first', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(wrap(const StorageUsageScreen(), state()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Big'), findsOneWidget);
    expect(find.text('Small'), findsOneWidget);
    expect(find.text('250 MB'), findsOneWidget);
    expect(find.textContaining('2 个应用共'), findsOneWidget);
  });

  testWidgets('without usage access the ranking asks for it', (tester) async {
    permitted = false;
    await tester.pumpWidget(wrap(const StorageUsageScreen(), state()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('需要「使用情况访问」'), findsOneWidget);
    expect(find.text('去开启'), findsOneWidget);
    // The list is not shown at all rather than full of zeroes.
    expect(find.text('Big'), findsNothing);
  });

  testWidgets('the audit groups apps by capability', (tester) async {
    await tester.pumpWidget(wrap(const PermissionAuditScreen(), state()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('麦克风'), findsOneWidget);
    expect(find.text('Recorder'), findsOneWidget);
    expect(find.text('无障碍服务'), findsOneWidget);
    expect(find.text('Clicker'), findsOneWidget);
    // A component-based capability shows which service is enabled.
    expect(find.textContaining('AutoService'), findsOneWidget);
  });

  testWidgets('the detail storage card breaks the usage down', (tester) async {
    await tester.pumpWidget(
      wrap(const AppStorageCard(packageName: 'com.big'), state()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('存储占用'), findsOneWidget);
    expect(find.text('安装包'), findsOneWidget);
    expect(find.text('40.0 MB'), findsOneWidget);
    expect(find.text('数据'), findsOneWidget);
    expect(find.text('200 MB'), findsOneWidget);
    expect(find.text('合计'), findsOneWidget);
    expect(find.text('250 MB'), findsOneWidget);
  });

  testWidgets('the storage card offers the grant when it is missing', (
    tester,
  ) async {
    permitted = false;
    await tester.pumpWidget(
      wrap(const AppStorageCard(packageName: 'com.big'), state()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('开启「使用情况访问」'), findsOneWidget);
  });

  testWidgets('the permission card marks granted sensitive permissions', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(const AppPermissionsCard(packageName: 'com.big'), state()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('CAMERA'), findsWidgets);
    expect(find.text('INTERNET'), findsOneWidget);
    expect(find.textContaining('申请 2 项 · 敏感 1 项'), findsOneWidget);
    expect(find.text('已授予'), findsNWidgets(2));
  });

  testWidgets('the signature card shows the fingerprint and flags', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        const AppSignatureCard(packageName: 'com.big', appName: 'Big'),
        state(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('签名'), findsOneWidget);
    expect(find.text('自签名'), findsOneWidget);
    expect(find.textContaining('AA:BB:CC:DD'), findsOneWidget);
  });
}
