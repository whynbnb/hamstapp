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

AppState _state() => AppState(_MemStorage())
  ..initialized = true
  ..apps = [_ai('com.a', 'A')]
  ..tilePages = [
    TilePage(id: 'p1', name: 'P1', createdAt: 0),
    TilePage(id: 'p2', name: 'P2', createdAt: 1),
    TilePage(id: 'p3', name: 'P3', createdAt: 2),
  ]
  ..currentTilePageIndex = 0;

void main() {
  testWidgets('entering edit mode keeps the current tile page', (tester) async {
    final state = _state();
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: QuickLaunchScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // The tile-page pager is the inner PageView (the launch sub-tab pager is
    // its ancestor, so it comes first in the tree).
    PageController pager() =>
        tester.widget<PageView>(find.byType(PageView).last).controller!;

    expect(pager().page!.round() % 1000, 0, reason: 'starts on P1');

    // Switch to P3 through its page tab.
    await tester.tap(find.text('P3'));
    await tester.pumpAndSettle();
    expect(state.currentTilePageIndex, 2);
    expect(pager().page!.round() % 1000, 2);

    // Entering edit mode must not snap the board back to the page the
    // controller was first created on.
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();

    expect(
      pager().page!.round() % 1000,
      2,
      reason: 'edit mode must stay on the tile page that was showing',
    );
    expect(state.currentTilePageIndex, 2);
  });
}
