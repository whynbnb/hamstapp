import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:hamstapp/models/app_info.dart';
import 'package:hamstapp/screens/quick_launch_screen.dart';
import 'package:hamstapp/services/storage.dart';
import 'package:hamstapp/state/app_state.dart';

// Launch sub-tab order: 最近(0) / 磁贴(1) / 分类(2) / 收藏(3).
const int kTiles = 1;
const int kCategories = 2;
const int kFavorites = 3;

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

AppState _state({int startTab = kTiles}) => AppState(_MemStorage())
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
    final pager = await _pump(tester, _state(startTab: kTiles)); // on 磁贴

    final before = pager.page!;
    expect(before % 4, kTiles);

    await tester.tap(_tab('收藏'));
    await tester.pump(); // kick off the animation
    await tester.pump(const Duration(milliseconds: 120)); // mid-flight

    expect(
      pager.page!,
      greaterThan(before),
      reason: '磁贴 → 收藏 should move forward, not jump back the short way',
    );

    await tester.pumpAndSettle();
    expect(pager.page!.round() % 4, kFavorites, reason: 'settles on 收藏');
  });

  testWidgets('tapping an earlier tab slides back, matching the tab bar', (
    tester,
  ) async {
    final pager = await _pump(tester, _state(startTab: kFavorites)); // 收藏

    final before = pager.page!;
    expect(before % 4, kFavorites);

    await tester.tap(_tab('磁贴'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      pager.page!,
      lessThan(before),
      reason: '收藏 → 磁贴 should slide back through 分类, not wrap the loop',
    );

    await tester.pumpAndSettle();
    expect(pager.page!.round() % 4, kTiles, reason: 'settles on 磁贴');
  });

  testWidgets('最近 sits to the left of 磁贴 in the tab bar', (tester) async {
    await _pump(tester, _state());

    final recentX = tester.getCenter(_tab('最近')).dx;
    final tilesX = tester.getCenter(_tab('磁贴')).dx;
    final categoriesX = tester.getCenter(_tab('分类')).dx;
    final favoritesX = tester.getCenter(_tab('收藏')).dx;

    expect(recentX, lessThan(tilesX));
    expect(tilesX, lessThan(categoriesX));
    expect(categoriesX, lessThan(favoritesX));
  });
}
