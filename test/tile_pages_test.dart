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
  test('the page bar alignment is remembered', () async {
    final storage = _MemStorage();
    final state = AppState(storage)..initialized = true;
    expect(state.tileBarAlign, TileBarAlign.center);

    await state.setTileBarAlign(TileBarAlign.right);

    final restored = AppState(storage)
      ..initialized = true
      ..settings = (await storage.readJson('settings') as Map)
          .cast<String, dynamic>();
    expect(restored.tileBarAlign, TileBarAlign.right);
  });

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

  testWidgets('the page bar centres its chips by default', (tester) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final state = _state();
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: QuickLaunchScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(state.tileBarAlign, TileBarAlign.center);
    final centered = tester.getCenter(find.text('P1')).dx;

    await state.setTileBarAlign(TileBarAlign.left);
    await tester.pump();
    final left = tester.getCenter(find.text('P1')).dx;

    await state.setTileBarAlign(TileBarAlign.right);
    await tester.pump();
    final right = tester.getCenter(find.text('P1')).dx;

    expect(left, lessThan(centered));
    expect(centered, lessThan(right));
    // Centred: the first chip is well past the left padding, but not at the
    // right edge either.
    expect(centered, greaterThan(left + 20));
    expect(right, greaterThan(centered + 20));
  });

  testWidgets('the page menu offers the alignment and applies it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
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

    expect(find.text('内容不足时的位置'), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, '居右'));
    await tester.pumpAndSettle();

    expect(state.tileBarAlign, TileBarAlign.right);
    // Choosing closes the menu.
    expect(find.text('内容不足时的位置'), findsNothing);
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
