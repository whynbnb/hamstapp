import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:hamstapp/models/app_info.dart';
import 'package:hamstapp/screens/quick_launch_screen.dart';
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

AppState _state({int startTab = 0}) => AppState(_MemStorage())
  ..initialized = true
  ..apps = [_ai('com.a', 'A')]
  ..settings['last_launch_tab'] = startTab;

Future<PageController> _pump(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const MaterialApp(home: QuickLaunchScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return tester.widget<PageView>(find.byType(PageView).first).controller!;
}

Finder _tab(String label) =>
    find.descendant(of: find.byType(TabBar), matching: find.text(label));

void main() {
  testWidgets('tapping a later tab slides forward through the tabs between', (
    tester,
  ) async {
    final pager = await _pump(tester, _state(startTab: 0)); // on 磁贴

    final before = pager.page!;
    expect(before % 4, 0);

    await tester.tap(_tab('最近'));
    await tester.pump(); // kick off the animation
    await tester.pump(const Duration(milliseconds: 120)); // mid-flight

    expect(
      pager.page!,
      greaterThan(before),
      reason: '磁贴 → 最近 should move forward, not jump back the short way',
    );

    await tester.pumpAndSettle();
    expect(pager.page!.round() % 4, 3, reason: 'settles on 最近');
  });

  testWidgets('tapping an earlier tab slides back, matching the tab bar', (
    tester,
  ) async {
    final pager = await _pump(tester, _state(startTab: 3)); // on 最近

    final before = pager.page!;
    expect(before % 4, 3);

    await tester.tap(_tab('分类'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      pager.page!,
      lessThan(before),
      reason: '最近 → 分类 should slide back through 收藏, not wrap the loop',
    );

    await tester.pumpAndSettle();
    expect(pager.page!.round() % 4, 1, reason: 'settles on 分类');
  });
}
