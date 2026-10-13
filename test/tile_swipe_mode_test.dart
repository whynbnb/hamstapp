import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:hamstapp/models/app_info.dart';
import 'package:hamstapp/models/tile_page.dart';
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

AppState _state(TileSwipeMode mode) => AppState(_MemStorage())
  ..initialized = true
  ..apps = [_ai('com.a', 'A')]
  ..tilePages = [
    TilePage(id: 'p1', name: 'P1', createdAt: 0),
    TilePage(id: 'p2', name: 'P2', createdAt: 1),
    TilePage(id: 'p3', name: 'P3', createdAt: 2),
  ]
  ..currentTilePageIndex = 0
  ..settings['tile_swipe_mode'] = mode.name;

Future<void> _pump(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const MaterialApp(home: QuickLaunchScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('tile swipe mode defaults and round-trips through settings', () async {
    final state = AppState(_MemStorage());
    expect(state.tileSwipeMode, TileSwipeMode.holdDrag);

    await state.setTileSwipeMode(TileSwipeMode.bottomLaunch);
    expect(state.settings['tile_swipe_mode'], 'bottomLaunch');
    expect(state.tileSwipeMode, TileSwipeMode.bottomLaunch);

    state.settings['tile_swipe_mode'] = 'nonsense';
    expect(state.tileSwipeMode, TileSwipeMode.holdDrag);
  });

  testWidgets('topLaunch: bottom half swipes tile pages, top half launch tabs', (
    tester,
  ) async {
    final state = _state(TileSwipeMode.topLaunch);
    await _pump(tester, state);

    Rect board() => tester.getRect(find.byType(PageView).last);

    // Bottom half -> tile pages (0 -> 1), launch sub-tab unchanged.
    await tester.dragFrom(
      Offset(board().center.dx, board().bottom - 30),
      const Offset(-320, 0),
    );
    await tester.pumpAndSettle();
    expect(state.currentTilePageIndex, 1);
    expect(state.lastLaunchTab, 1, reason: 'still on 磁贴');

    // Top half -> launch sub-tabs (磁贴 -> 分类).
    await tester.dragFrom(
      Offset(board().center.dx, board().top + 30),
      const Offset(-320, 0),
    );
    await tester.pumpAndSettle();
    expect(state.lastLaunchTab, 2);
  });

  testWidgets('bottomLaunch: top half swipes tile pages, bottom half launch', (
    tester,
  ) async {
    final state = _state(TileSwipeMode.bottomLaunch);
    await _pump(tester, state);

    Rect board() => tester.getRect(find.byType(PageView).last);

    // Top half -> tile pages.
    await tester.dragFrom(
      Offset(board().center.dx, board().top + 30),
      const Offset(-320, 0),
    );
    await tester.pumpAndSettle();
    expect(state.currentTilePageIndex, 1);
    expect(state.lastLaunchTab, 1);

    // Bottom half -> launch sub-tabs.
    await tester.dragFrom(
      Offset(board().center.dx, board().bottom - 30),
      const Offset(-320, 0),
    );
    await tester.pumpAndSettle();
    expect(state.lastLaunchTab, 2);
  });

  testWidgets('holdDrag (default) keeps the plain swipe on the tile pages', (
    tester,
  ) async {
    final state = _state(TileSwipeMode.holdDrag);
    await _pump(tester, state);

    final board = tester.getRect(find.byType(PageView).last);
    await tester.dragFrom(
      Offset(board.center.dx, board.center.dy),
      const Offset(-600, 0),
    );
    await tester.pumpAndSettle();

    expect(state.currentTilePageIndex, 1);
    expect(state.lastLaunchTab, 1, reason: 'a plain swipe must not change tabs');
  });
}
