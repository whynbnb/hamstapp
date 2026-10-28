import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:hamstapp/l10n/app_strings.dart';
import 'package:hamstapp/models/app_info.dart';
import 'package:hamstapp/screens/app_detail_screen.dart';
import 'package:hamstapp/services/storage.dart';
import 'package:hamstapp/state/app_state.dart';

class _MemStorage implements Storage {
  final Map<String, dynamic> _data = <String, dynamic>{};
  @override
  Future<dynamic> readJson(String name) async => _data[name];
  @override
  Future<void> writeJson(String name, dynamic data) async {
    _data[name] = data;
  }
}

AppInfo _app(String pkg, String name) => AppInfo(
  packageName: pkg,
  appName: name,
  versionName: '1',
  versionCode: 1,
  firstInstallTime: 0,
  lastUpdateTime: 0,
  isSystem: false,
  enabled: true,
  apkPath: '/data/app/$pkg/base.apk',
  sizeBytes: 1024,
  targetSdk: 33,
  minSdk: 21,
  uid: 0,
);

void main() {
  setUp(() => AppStrings.current = const AppStrings('zh'));
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('hamstapp/apps'), null),
  );

  testWidgets('the app detail menu force-refreshes the icon', (tester) async {
    var refreshes = 0;
    Uint8List? reply;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('hamstapp/apps'), (
          call,
        ) async {
          switch (call.method) {
            case 'getAppIcon':
              if (call.arguments is Map &&
                  (call.arguments as Map)['refresh'] == true) {
                refreshes++;
              }
              return reply;
            case 'getLaunchActivities':
              return <dynamic>[];
          }
          return null;
        });

    final state = AppState(_MemStorage())
      ..initialized = true
      ..apps = [_app('com.a', 'A')];

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: AppDetailScreen(packageName: 'com.a')),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('强制刷新图标'), findsOneWidget);

    await tester.tap(find.text('强制刷新图标'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // The system had no icon to give: the failure is reported, not hidden.
    expect(refreshes, greaterThanOrEqualTo(2));
    expect(find.text('刷新失败，系统没有返回图标'), findsOneWidget);
  });
}
