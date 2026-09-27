import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:hamstapp/models/app_info.dart';
import 'package:hamstapp/models/category.dart';
import 'package:hamstapp/models/tile.dart';
import 'package:hamstapp/models/tile_page.dart';
import 'package:hamstapp/screens/app_detail_screen.dart';
import 'package:hamstapp/screens/apps_screen.dart';
import 'package:hamstapp/screens/categories_tab.dart';
import 'package:hamstapp/screens/quick_launch_screen.dart';
import 'package:hamstapp/services/storage.dart';
import 'package:hamstapp/state/app_state.dart';
import 'package:hamstapp/widgets/app_icon.dart';
import 'package:hamstapp/widgets/category_editor.dart';
import 'package:hamstapp/widgets/chip_scroller.dart';

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
  testWidgets('dragging a tile moves it to a new cell', (tester) async {
    final state = AppState(_MemStorage())
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
      ..tileEditMode = true;

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: QuickLaunchScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    final tile = find.byKey(const ValueKey('t1'));
    expect(tile, findsOneWidget);

    final start = tester.getCenter(tile);
    final gesture = await tester.startGesture(start);
    // Hold past the 180ms long-press delay to start the move drag.
    await tester.pump(const Duration(milliseconds: 300));
    // Drag right by more than one cell (~122px at the default 800px width).
    await gesture.moveBy(const Offset(140, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      state.tileById('t1')!.col,
      greaterThan(0),
      reason: 'tile should have moved right',
    );
  });

  testWidgets('empty tile page can enter edit mode and pin an app', (
    tester,
  ) async {
    final state = AppState(_MemStorage())
      ..initialized = true
      ..apps = [_ai('com.a', 'A')]
      ..tilePages = [TilePage(id: 'p1', name: 'P1', createdAt: 0)]
      ..tiles = []
      ..currentTilePageIndex = 0;

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: QuickLaunchScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    // Browsing an empty page shows the hint, not a board.
    expect(find.textContaining('还没有磁贴'), findsOneWidget);

    // Tap the edit button in the AppBar.
    final editBtn = find.byIcon(Icons.edit_outlined);
    expect(editBtn, findsOneWidget);
    await tester.tap(editBtn);
    await tester.pump();

    expect(state.tileEditMode, isTrue);
    // Editing an empty page must render the board/grid (hint replaced) and
    // expose the pin action.
    expect(find.textContaining('还没有磁贴'), findsNothing);
    expect(find.byTooltip('置顶应用到磁贴'), findsOneWidget);

    // Pinning from the edit action actually adds a tile to the empty page.
    await tester.tap(find.byTooltip('置顶应用到磁贴'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.widgetWithText(ListTile, 'A'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(state.tiles.length, 1);
    expect(state.tiles.first.pageId, 'p1');
  });

  testWidgets('wide board keeps a far-right tile instead of re-packing it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final state = AppState(_MemStorage())
      ..initialized = true
      ..apps = [_ai('com.a', 'A')]
      ..tilePages = [TilePage(id: 'p1', name: 'P1', createdAt: 0)]
      ..tiles = [
        Tile(
          id: 't1',
          packageName: 'com.a',
          pageId: 'p1',
          col: 10,
          row: 0,
          w: 2,
          h: 2,
        ),
      ]
      ..currentTilePageIndex = 0;

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: QuickLaunchScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    // Column 10 only fits because the wide screen exposes more than 6 columns;
    // on a phone it would have been re-packed to the left.
    final tile = find.byKey(const ValueKey('t1'));
    expect(tile, findsOneWidget);
    expect(tester.getRect(tile).left, greaterThan(400));
  });

  testWidgets('tiles tab opens on the current page after being rebuilt', (
    tester,
  ) async {
    final state = AppState(_MemStorage())
      ..initialized = true
      ..apps = [_ai('com.a', 'A')]
      ..tilePages = [
        TilePage(id: 'p1', name: 'P1', createdAt: 0),
        TilePage(id: 'p2', name: 'P2', createdAt: 0),
      ]
      ..tiles = [
        Tile(
          id: 't2',
          packageName: 'com.a',
          pageId: 'p2',
          col: 0,
          row: 0,
          w: 2,
          h: 2,
        ),
      ]
      ..currentTilePageIndex = 1;

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: QuickLaunchScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    // The board and the page bar must agree: page 2's tile is the one shown.
    expect(find.byKey(const ValueKey('t2')), findsOneWidget);
  });

  testWidgets('tile style switches between solid and frosted glass', (
    tester,
  ) async {
    final state = AppState(_MemStorage())
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
      ..currentTilePageIndex = 0;

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: QuickLaunchScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    final tile = find.byKey(const ValueKey('t1'));
    expect(tile, findsOneWidget);
    // The classic style has no translucent glass surface.
    expect(find.byKey(const ValueKey('glass-tile')), findsNothing);

    await state.setTileStyle(TileStyle.glass);
    await tester.pump(const Duration(milliseconds: 50));

    // Glass renders a self-contained translucent surface...
    expect(find.byKey(const ValueKey('glass-tile')), findsOneWidget);
    // ...but must stay cheap: no per-tile backdrop blur (that janked swipes),
    // and no board-wide backdrop (that slid with the tab and changed the
    // background brightness while swiping).
    expect(
      find.descendant(of: tile, matching: find.byType(BackdropFilter)),
      findsNothing,
    );
  });

  testWidgets('a tile can hide its label and show the icon only', (
    tester,
  ) async {
    final state = AppState(_MemStorage())
      ..initialized = true
      ..apps = [_ai('com.a', 'Alpha')]
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
      ..currentTilePageIndex = 0;

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: QuickLaunchScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();

    final tile = find.byKey(const ValueKey('t1'));
    expect(tile, findsOneWidget);
    // A 2x2 tile is tall enough to show the full app name.
    expect(
      find.descendant(of: tile, matching: find.text('Alpha')),
      findsOneWidget,
    );

    await state.setTileShowLabel('t1', false);
    await tester.pump(const Duration(milliseconds: 50));

    // Label gone; the icon is still rendered so the tile is not empty.
    expect(
      find.descendant(of: tile, matching: find.text('Alpha')),
      findsNothing,
    );
    expect(
      find.descendant(of: tile, matching: find.byType(AppIcon)),
      findsOneWidget,
    );
  });

  testWidgets('turning off inner padding lets the icon fill the tile', (
    tester,
  ) async {
    final state = AppState(_MemStorage())
      ..initialized = true
      ..apps = [_ai('com.a', 'Alpha')]
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
      ..currentTilePageIndex = 0;

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: QuickLaunchScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    final tile = find.byKey(const ValueKey('t1'));
    final icon = find.descendant(of: tile, matching: find.byType(AppIcon));

    // Icon-only with the default inner margin keeps a tile frame.
    await state.setTileShowLabel('t1', false);
    await tester.pump();
    expect(find.byKey(const ValueKey('bare-tile')), findsNothing);
    final padded = tester.widget<AppIcon>(icon).size;

    // Dropping the margin makes the icon grow to fill the tile, still framed.
    await state.setTileInnerPadding('t1', false);
    await tester.pump();
    final full = tester.widget<AppIcon>(icon).size;
    expect(full, greaterThan(padded));
    expect(full, closeTo(tester.getSize(tile).shortestSide, 0.5));
    expect(find.byKey(const ValueKey('bare-tile')), findsNothing);
  });

  testWidgets('the border switch is independent of padding and label', (
    tester,
  ) async {
    final state = AppState(_MemStorage())
      ..initialized = true
      ..apps = [_ai('com.a', 'Alpha')]
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
      ..currentTilePageIndex = 0;

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: QuickLaunchScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    final tile = find.byKey(const ValueKey('t1'));
    expect(find.byKey(const ValueKey('bare-tile')), findsNothing);

    // Dropping just the border removes the backdrop while the name and the
    // inner margin keep their own settings.
    await state.setTileBorder('t1', false);
    await tester.pump();
    expect(find.byKey(const ValueKey('bare-tile')), findsOneWidget);
    expect(
      find.descendant(of: tile, matching: find.text('Alpha')),
      findsOneWidget,
    );
  });

  testWidgets('app detail can pin to any tile page', (tester) async {
    final state = AppState(_MemStorage())
      ..initialized = true
      ..apps = [_ai('com.a', 'A')]
      ..tilePages = [
        TilePage(id: 'p1', name: 'P1', createdAt: 0),
        TilePage(id: 'p2', name: 'P2', createdAt: 0),
      ]
      ..currentTilePageIndex = 0;

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(
          home: AppDetailScreen(packageName: 'com.a'),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(state.tiles, isEmpty);

    // Open the page picker and choose the page that is NOT the current one.
    await tester.tap(find.text('固定到磁贴页…'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.widgetWithText(ListTile, 'P2'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(state.tiles.length, 1);
    expect(state.tiles.first.pageId, 'p2');
  });

  testWidgets('category screen can add an app to the category', (tester) async {
    final cat = AppCategory(id: 'c1', name: '工具', emoji: '🛠');
    final state = AppState(_MemStorage())
      ..initialized = true
      ..apps = [_ai('com.a', 'A')]
      ..categories = [cat];

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          home: CategoryAppsScreen(state: state, category: cat),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('该分类下还没有应用'), findsOneWidget);

    await tester.tap(find.byTooltip('添加应用到该分类'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.widgetWithText(ListTile, 'A'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(state.metaFor('com.a').categoryIds, contains('c1'));

    // Close the picker sheet (tap the barrier above it).
    await tester.tapAt(const Offset(10, 10));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // Launch is the default action; removal moved into the "more" menu.
    expect(find.byTooltip('启动'), findsOneWidget);
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('移出分类'), findsOneWidget);
    await tester.tap(find.text('移出分类'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(state.metaFor('com.a').categoryIds, isNot(contains('c1')));
  });

  testWidgets('category picker keeps the search after toggling an app', (
    tester,
  ) async {
    final cat = AppCategory(id: 'c1', name: '工具', emoji: '🛠');
    final state = AppState(_MemStorage())
      ..initialized = true
      ..apps = [_ai('com.a', 'Alpha'), _ai('com.b', 'Beta')]
      ..categories = [cat];

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showCategoryPicker(context, state, cat),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.enterText(find.byType(TextField), 'Alpha');
    await tester.pump();
    expect(find.text('Beta'), findsNothing);

    // Toggling membership must not clear the query / reset the results.
    await tester.tap(find.widgetWithText(ListTile, 'Alpha'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Beta'), findsNothing);
    expect(state.metaFor('com.a').categoryIds, contains('c1'));
  });

  testWidgets('category picker search can be cleared in one tap', (
    tester,
  ) async {
    final cat = AppCategory(id: 'c1', name: '工具', emoji: '🛠');
    final state = AppState(_MemStorage())
      ..initialized = true
      ..apps = [_ai('com.a', 'Alpha'), _ai('com.b', 'Beta')]
      ..categories = [cat];

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showCategoryPicker(context, state, cat),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.enterText(find.byType(TextField), 'Alpha');
    await tester.pump();
    expect(find.text('Beta'), findsNothing);

    await tester.tap(find.byIcon(Icons.clear));
    await tester.pump();
    expect(find.text('Beta'), findsOneWidget);
  });

  testWidgets('category editor accepts a custom emoji', (tester) async {
    final state = AppState(_MemStorage())..initialized = true;

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showCategoryEditor(context, state, null),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(2)); // name + custom emoji
    await tester.enterText(fields.first, '测试');
    await tester.enterText(fields.at(1), '🦄');
    await tester.pump();

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(state.categories.single.name, '测试');
    expect(state.categories.single.emoji, '🦄');
  });

  testWidgets('filter panel toggles sort order and resets', (tester) async {
    final state = AppState(_MemStorage())
      ..initialized = true
      ..apps = [_ai('com.a', 'Alpha'), _ai('com.b', 'Beta')];

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: AppsScreen()),
      ),
    );
    await tester.pump();

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('筛选与排序'), findsOneWidget);

    // Direction toggle.
    await tester.tap(find.text('倒序'));
    await tester.pump();
    expect(state.sortAscending, isFalse);

    // Pick a sort field; it switches to its natural direction.
    await tester.tap(find.text('按大小'));
    await tester.pump();
    expect(state.sort, AppSort.size);
    expect(state.sortAscending, isFalse);

    // Choose a filter so the badge/reset activate.
    await tester.tap(find.text('用户'));
    await tester.pump();
    expect(state.scope, AppScope.user);

    await tester.tap(find.text('重置'));
    await tester.pump();
    expect(state.activeAppFilterCount, 0);
    expect(state.scope, AppScope.all);
  });

  testWidgets('long category list stays on one scrollable row', (
    tester,
  ) async {
    final state = AppState(_MemStorage())
      ..initialized = true
      ..apps = [_ai('com.a', 'Alpha')]
      ..categories = [
        for (var i = 0; i < 12; i++)
          AppCategory(id: 'c$i', name: '分类$i', emoji: '📁'),
      ];

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: AppsScreen()),
      ),
    );
    await tester.pump();

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final scroller = find.byType(ChipScroller);
    expect(scroller, findsOneWidget);
    expect(tester.getSize(scroller).height, 48);
    final list = tester.widget<ListView>(
      find.descendant(of: scroller, matching: find.byType(ListView)),
    );
    expect(list.scrollDirection, Axis.horizontal);
  });
}
