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
    find.descendant(of: find.byType(LaunchTabBar), matching: find.text(label));

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

  testWidgets('swiping past an edge wraps one page to the other side', (
    tester,
  ) async {
    // Backwards from 最近 lands on 收藏 (one page, not a three-page detour).
    final pager = await _pump(tester, _state(startTab: 0));
    // The strip paints from the pager's position, so a scroll must notify it.
    var updates = 0;
    pager.addListener(() => updates++);
    await tester.timedDrag(
      find.byType(PageView).first,
      const Offset(480, 0),
      const Duration(milliseconds: 260),
    );
    await tester.pumpAndSettle();
    expect(updates, greaterThan(1), reason: 'the strip follows the pager');
    // The index is folded back into the base cycle once at rest, so repeated
    // wraps cannot drift further and further away (which used to freeze the
    // underline on the wrong end).
    expect(pager.page!.round(), 4003);
    expect(
      tester.widget<LaunchTabBar>(find.byType(LaunchTabBar)).controller.index,
      kFavorites,
    );

    // Forwards from 收藏 lands on 最近 again.
    await tester.timedDrag(
      find.byType(PageView).first,
      const Offset(-480, 0),
      const Duration(milliseconds: 260),
    );
    await tester.pumpAndSettle();
    expect(pager.page!.round(), 4000);
    expect(
      tester.widget<LaunchTabBar>(find.byType(LaunchTabBar)).controller.index,
      0,
    );
  });

  testWidgets('a gesture wrap moves the pager with the hand, one page', (
    tester,
  ) async {
    // Split swipe mode drives the launch tabs by gesture. From 收藏, swiping
    // forward must slide to 最近 (the next page), not back through 分类/磁贴.
    final state = _state(startTab: kFavorites);
    state.settings['tile_swipe_mode'] = 'topLaunch';
    final pager = await _pump(tester, state);
    final start = pager.page!;

    final body = tester.getRect(find.byType(PageView).first);
    await tester.timedDragFrom(
      Offset(body.center.dx + 150, body.center.dy),
      const Offset(-380, 0),
      const Duration(milliseconds: 240),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(
      pager.page!,
      greaterThan(start),
      reason: 'the content must follow the finger, not take the loop\'s long way',
    );

    await tester.pumpAndSettle();
    expect(
      pager.page!.round(),
      4000,
      reason: 'folded back into the base cycle after the wrap',
    );
  });

  testWidgets('repeated swipes stay on the base cycle', (tester) async {
    final state = _state(startTab: 0);
    final pager = await _pump(tester, state);

    // Walking all the way round must not push the virtual page further away
    // from the base: that drift is what used to freeze the underline.
    for (var i = 0; i < 6; i++) {
      await tester.timedDrag(
        find.byType(PageView).first,
        const Offset(-480, 0),
        const Duration(milliseconds: 260),
      );
      await tester.pumpAndSettle();
      final page = pager.page!.round();
      expect(page, inInclusiveRange(4000, 4003));
      expect(page % 4, state.lastLaunchTab);
    }
  });

  testWidgets('最近 sits to the left of 磁贴 in the tab bar', (tester) async {
    await _pump(tester, _state());

    // The strip fills the header, so the four tabs split it evenly.
    expect(
      tester.getSize(find.byType(LaunchTabBar)).width,
      greaterThan(250),
    );

    final recentX = tester.getCenter(_tab('最近')).dx;
    final tilesX = tester.getCenter(_tab('磁贴')).dx;
    final categoriesX = tester.getCenter(_tab('分类')).dx;
    final favoritesX = tester.getCenter(_tab('收藏')).dx;

    expect(recentX, lessThan(tilesX));
    expect(tilesX, lessThan(categoriesX));
    expect(categoriesX, lessThan(favoritesX));
  });
}
