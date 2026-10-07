import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:hamstapp/models/app_info.dart';
import 'package:hamstapp/screens/home_screen.dart';
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

AppInfo _ai(String pkg, String name) => AppInfo(
  packageName: pkg,
  appName: name,
  versionName: '1',
  versionCode: 1,
  firstInstallTime: 0,
  lastUpdateTime: 0,
  isSystem: false,
  enabled: true,
  apkPath: '',
  sizeBytes: 0,
  targetSdk: 33,
  minSdk: 21,
  uid: 0,
);

void main() {
  testWidgets('system back on Settings returns to the previous tab', (
    tester,
  ) async {
    const channel = MethodChannel('hamstapp/apps');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    final state = AppState(_MemStorage())
      ..initialized = true
      ..apps = [_ai('com.a', 'A')];

    // A phone-sized surface uses the rail in this landscape shape, which keeps
    // all four destinations on screen for the test.
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pumpAndSettle();

    Finder railItem(String label) => find.descendant(
      of: find.byType(NavigationRail),
      matching: find.text(label),
    );

    // Visit 应用 first, then 设置.
    await tester.tap(railItem('应用'));
    await tester.pumpAndSettle();
    expect(state.lastHomeIndex, 1);

    await tester.tap(railItem('设置'));
    await tester.pumpAndSettle();
    expect(state.lastHomeIndex, 3);

    // System back should return to 应用, not exit.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      state.lastHomeIndex,
      1,
      reason: 'back from Settings should return to the previous tab',
    );
  });
}
