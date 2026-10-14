import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:hamstapp/models/app_info.dart';
import 'package:hamstapp/models/tile.dart';
import 'package:hamstapp/models/tile_page.dart';
import 'package:hamstapp/screens/app_detail_screen.dart';
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

AppState _state({required bool editMode}) => AppState(_MemStorage())
  ..initialized = true
  ..apps = [_ai('com.a', 'A')]
  ..tilePages = [TilePage(id: 'p1', name: 'P1', createdAt: 0)]
  ..tiles = [
    Tile(
      id: 't1',
      packageName: 'com.a',
      pageId: 'p1',
      col: 0,
      row: 0,
      w: 2,
      h: 2,
    ),
  ]
  ..currentTilePageIndex = 0
  ..tileEditMode = editMode;

Future<void> _pump(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const MaterialApp(home: QuickLaunchScreen()),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('long pressing a tile opens the app detail page', (tester) async {
    final state = _state(editMode: false);
    await _pump(tester, state);

    expect(find.byType(AppDetailScreen), findsNothing);
    await tester.longPress(find.byKey(const ValueKey('t1')));
    // The board keeps animating, so settle by hand instead of pumpAndSettle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(AppDetailScreen), findsOneWidget);
    // It opens the details of that tile's app.
    expect(
      tester
          .widget<AppDetailScreen>(find.byType(AppDetailScreen))
          .packageName,
      'com.a',
    );
  });

  testWidgets('in edit mode a long press drags instead of opening details', (
    tester,
  ) async {
    final state = _state(editMode: true);
    await _pump(tester, state);

    await tester.longPress(find.byKey(const ValueKey('t1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(AppDetailScreen), findsNothing);
    expect(state.tileEditMode, isTrue);
  });
}
