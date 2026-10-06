import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:hamstapp/models/app_info.dart';
import 'package:hamstapp/models/tile_page.dart';
import 'package:hamstapp/screens/quick_launch_screen.dart';
import 'package:hamstapp/screens/tile_pages_screen.dart';
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
  testWidgets('long press a page tab does nothing outside edit mode', (
    tester,
  ) async {
    final state = _state();
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: QuickLaunchScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    await tester.longPress(find.text('P2'));
    await tester.pumpAndSettle();

    // The page menu (rename / move / delete) must not pop up.
    expect(find.text('重命名页面'), findsNothing);
    expect(find.text('删除页面'), findsNothing);
    expect(state.tilePages.length, 3);
  });

  testWidgets('long press a page tab opens the menu while editing', (
    tester,
  ) async {
    final state = _state()..tileEditMode = true;
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: QuickLaunchScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    await tester.longPress(find.text('P2'));
    await tester.pumpAndSettle();

    expect(find.text('重命名页面'), findsOneWidget);
  });

  testWidgets('deleting a page from the manager asks for confirmation', (
    tester,
  ) async {
    final state = _state();
    await tester.pumpWidget(
      MaterialApp(home: TilePagesScreen(state: state)),
    );
    await tester.pump();

    // All three pages are listed.
    expect(find.text('P1'), findsOneWidget);
    expect(find.text('P2'), findsOneWidget);
    expect(find.text('P3'), findsOneWidget);

    final deleteButtons = find.widgetWithIcon(
      IconButton,
      Icons.delete_outline,
    );
    expect(deleteButtons, findsNWidgets(3));

    // First tap only asks; cancelling keeps the page.
    await tester.tap(deleteButtons.first);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(state.tilePages.length, 3);

    // Confirming actually deletes it.
    await tester.tap(deleteButtons.first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(state.tilePages.length, 2);
    expect(find.text('P1'), findsNothing);
  });

  testWidgets('renaming a page from the manager updates it', (tester) async {
    final state = _state();
    await tester.pumpWidget(
      MaterialApp(home: TilePagesScreen(state: state)),
    );
    await tester.pump();

    await tester.tap(find.widgetWithIcon(
      IconButton,
      Icons.drive_file_rename_outline,
    ).first);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '工具页');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(state.tilePages.first.name, '工具页');
    expect(find.text('工具页'), findsOneWidget);
  });
}
