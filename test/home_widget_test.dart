import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:hamstapp/l10n/app_strings.dart';
import 'package:hamstapp/models/app_info.dart';
import 'package:hamstapp/models/launch_event.dart';
import 'package:hamstapp/models/tile.dart';
import 'package:hamstapp/models/tile_page.dart';
import 'package:hamstapp/screens/home_widget_screen.dart';
import 'package:hamstapp/services/custom_icons.dart';
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

AppInfo _app(String pkg, String name) => AppInfo(
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
      targetSdk: 34,
      minSdk: 24,
      uid: 0,
    );

/// A 1x1 transparent PNG, enough for a custom-icon payload.
final _tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6'
  'kgAAAABJRU5ErkJggg==',
);

AppState _state() => AppState(_MemStorage())
  ..initialized = true
  ..apps = [_app('com.a', 'A'), _app('com.b', 'B')]
  ..tilePages = [TilePage(id: 'p1', name: 'P1', createdAt: 0)]
  ..tiles = [
    Tile(id: 't1', packageName: 'com.a', pageId: 'p1', col: 0, row: 0),
  ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => AppStrings.current = const AppStrings('zh'));

  group('home widget data', () {
    test('one slot per hour, with labels and a pinned fallback', () {
      final state = _state();
      final data = state.buildHomeWidgetData();
      final slots = (data['slots'] as List).cast<Map<String, dynamic>>();

      expect(slots, hasLength(24));
      expect([for (final s in slots) s['h']], [for (var h = 0; h < 24; h++) h]);

      // Nothing launched yet: the tile the user pinned is the best guess.
      final first = slots.first;
      expect(first['title'], '常用应用');
      final apps = (first['apps'] as List).cast<Map<String, dynamic>>();
      expect(apps.single['p'], 'com.a');
      expect(apps.single['n'], 'A');
      expect(data['showLabels'], isTrue);
      expect((data['fallback'] as List), hasLength(1));
    });

    test('hidden apps never reach the widget', () {
      final state = _state();
      state.metaFor('com.a').hidden = true;
      state.metaFor('com.b').hidden = true;

      final data = state.buildHomeWidgetData();
      for (final slot in (data['slots'] as List).cast<Map<String, dynamic>>()) {
        expect((slot['apps'] as List), isEmpty);
      }
      expect((data['fallback'] as List), isEmpty);
    });

    test('the current hour keeps its order when an app is used', () {
      final state = _state();
      state.metaFor('com.a').lastLaunchedAt = 1000;
      state.metaFor('com.b').lastLaunchedAt = 2000;

      List<String> currentPackages() {
        final hour = DateTime.now().hour;
        final slot =
            (state.buildHomeWidgetData()['slots'] as List)[hour] as Map;
        return [
          for (final a in slot['apps'] as List) (a as Map)['p'] as String,
        ];
      }

      // No launch log yet: the fallback is 最近常用, newest first.
      expect(currentPackages(), ['com.b', 'com.a']);

      // Using A now would normally move it to the front. The hour's pick must
      // stay put so the widget does not look like it registered a wrong tap.
      state.metaFor('com.a').lastLaunchedAt = 3000;
      expect(currentPackages(), ['com.b', 'com.a']);
    });

    test('hiding an app drops it from the frozen hour, keeping the rest', () {
      final state = _state();
      state.metaFor('com.a').lastLaunchedAt = 1000;
      state.metaFor('com.b').lastLaunchedAt = 2000;

      Map slot() {
        final hour = DateTime.now().hour;
        return (state.buildHomeWidgetData()['slots'] as List)[hour] as Map;
      }

      expect(
        [for (final a in slot()['apps'] as List) (a as Map)['p']],
        ['com.b', 'com.a'],
      );
      state.metaFor('com.b').hidden = true;
      expect(
        [for (final a in slot()['apps'] as List) (a as Map)['p']],
        ['com.a'],
      );
    });

    test('a time-of-day habit becomes a recommendation', () {
      final state = _state();
      final now = DateTime.now();
      state.launchLog = [
        for (var d = 1; d <= 6; d++)
          LaunchEvent(
            packageName: 'com.b',
            at: DateTime(
              now.year,
              now.month,
              now.day,
              9,
            ).subtract(Duration(days: d)).millisecondsSinceEpoch,
          ),
      ];

      final nine = state.homeWidgetSuggestionForHour(9);
      expect(nine.kind, 'recommend');
      expect(nine.apps.first.packageName, 'com.b');
      // Recommendations are shown as-is (like 最近 → 推荐); they are not
      // padded with pinned or frequent apps.
      expect(nine.apps, hasLength(1));
      expect(state.homeWidgetTitleFor('recommend'), '推荐');

      // An hour with no habit still shows something useful.
      final three = state.homeWidgetSuggestionForHour(3);
      expect(three.kind, isNot('empty'));
      expect(three.apps, isNotEmpty);
    });

    test('launches recorded by the widget join the statistics once', () async {
      final channel = const MethodChannel('hamstapp/apps');
      final calls = <String>[];
      // Recent enough to survive the launch log's age limit.
      final at = DateTime.now().millisecondsSinceEpoch - 60000;
      var pending = <Map<String, Object?>>[
        {'p': 'com.a', 't': at},
        {'p': 'com.missing', 't': at + 1},
      ];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        switch (call.method) {
          case 'consumeWidgetLaunches':
            final out = pending;
            pending = [];
            return out;
          case 'updateHomeWidget':
            return true;
          case 'updateShortcuts':
            return true;
        }
        return null;
      });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      final state = _state();
      await state.consumeHomeWidgetLaunches();
      // The refreshed document is pushed in the background.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(state.metaFor('com.a').launchCount, 1);
      expect(state.metaFor('com.a').lastLaunchedAt, at);
      expect(state.launchLog, hasLength(1));
      expect(state.launchLog.single.packageName, 'com.a');
      expect(calls, contains('updateHomeWidget'));

      // The native queue was drained; a second call must not add anything.
      await state.consumeHomeWidgetLaunches();
      expect(state.metaFor('com.a').launchCount, 1);
      expect(state.launchLog, hasLength(1));
    });

    test('a pinned launcher entry travels with the app', () async {
      final state = _state();
      state.metaFor('com.a').launchActivity = 'com.a.DialtactsActivity';

      final slots = state.buildHomeWidgetData()['slots'] as List;
      final apps = (slots.first as Map<String, dynamic>)['apps'] as List;
      final entry = apps
          .cast<Map<String, dynamic>>()
          .firstWhere((m) => m['p'] == 'com.a');
      expect(entry['a'], 'com.a.DialtactsActivity');
    });

    test('a hand-added web app reaches the widget with its config', () async {
      final state = _state();
      await state.addWebApp(url: 'https://example.com', name: 'Example');
      final web = state.webApps.single;
      // Pinned like any other app, so it is the fallback the widget shows.
      state.tiles = [
        ...state.tiles,
        Tile(id: 't2', packageName: web.id, pageId: 'p1', col: 1, row: 0),
      ];

      final slots = state.buildHomeWidgetData()['slots'] as List;
      final apps = (slots.first as Map<String, dynamic>)['apps'] as List;
      final entry = apps
          .cast<Map<String, dynamic>>()
          .firstWhere((m) => m['p'] == web.id);

      final config = entry['w'] as Map<String, dynamic>;
      expect(config['url'], 'https://example.com');
      expect(config['mode'], 'standalone');
      expect(config['name'], 'Example');
      expect(config['display'], 'standalone');
    });

    testWidgets('the preview marks a web app with a globe badge', (
      tester,
    ) async {
      // Without native handlers the widget push awaits a reply that never
      // comes inside the test zone.
      final channel = const MethodChannel('hamstapp/apps');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'updateHomeWidget':
          case 'updateShortcuts':
            return true;
          case 'widgetStatus':
            return {'count': 0, 'supported': true, 'canPin': true};
        }
        return null;
      });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      final state = _state();
      await state.addWebApp(url: 'https://example.com', name: 'Example');
      final web = state.webApps.single;
      state.tiles = [
        ...state.tiles,
        Tile(id: 't2', packageName: web.id, pageId: 'p1', col: 1, row: 0),
      ];
      // Pinning a tile re-picks the hour's suggestion in the app; do the same
      // here so the preview is not still showing the earlier lock.
      await state.refreshHomeWidgetNow();

      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: const MaterialApp(home: HomeWidgetScreen()),
        ),
      );
      // Not pumpAndSettle: the web icon keeps its loading spinner running
      // because its icon channel is not mocked here.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byIcon(Icons.public), findsWidgets);
    });

    test('a custom icon is sent for the widget to draw', () {
      final state = _state();
      CustomIcons.instance.put('com.a', _tinyPng);
      addTearDown(() => CustomIcons.instance.remove('com.a'));

      final icons =
          state.buildHomeWidgetData()['icons'] as Map<String, dynamic>;
      expect(icons['com.a'], isNotEmpty);
    });

    test('collections carry favorites and each category in its own order', () async {
      final state = _state();
      final category = await state.addCategory('工具');
      await state.updateMeta('com.a', categoryIds: [category.id]);
      await state.updateMeta('com.a', favorite: true);
      await state.updateMeta('com.b', favorite: true);
      await state.setFavoritesSort(AppSort.name, false);

      final data = state.buildHomeWidgetData();
      final collections =
          (data['collections'] as List).cast<Map<String, dynamic>>();
      expect(collections, hasLength(2));

      final favorites = collections.first;
      expect(favorites['key'], 'fav');
      expect(favorites['title'], '收藏');
      expect(
        [
          for (final a
              in (favorites['apps'] as List).cast<Map<String, dynamic>>())
            a['p'],
        ],
        ['com.b', 'com.a'],
        reason: 'names descending is what favorites is set to',
      );

      final categoryData = collections.last;
      expect(categoryData['key'], 'c:${category.id}');
      expect(categoryData['title'], contains('工具'));
      expect(
        [
          for (final a
              in (categoryData['apps'] as List).cast<Map<String, dynamic>>())
            a['p'],
        ],
        ['com.a'],
      );
    });

    test('a collection keeps at most the eight apps a widget can show', () async {
      final state = AppState(_MemStorage())
        ..initialized = true
        ..apps = [for (var i = 0; i < 12; i++) _app('com.$i', 'App$i')];
      final category = await state.addCategory('全部');
      for (var i = 0; i < 12; i++) {
        await state.updateMeta('com.$i', categoryIds: [category.id]);
      }

      final collections =
          (state.buildHomeWidgetData()['collections'] as List)
              .cast<Map<String, dynamic>>();
      final data = collections.singleWhere(
        (c) => c['key'] == 'c:${category.id}',
      );
      expect((data['apps'] as List), hasLength(8));
    });

    test('sortApps orders by the visible name, dates and size', () {
      AppInfo app(String pkg, String name, int install, int update, int size) =>
          AppInfo(
            packageName: pkg,
            appName: name,
            versionName: '1',
            versionCode: 1,
            firstInstallTime: install,
            lastUpdateTime: update,
            isSystem: false,
            enabled: true,
            apkPath: '',
            sizeBytes: size,
            targetSdk: 34,
            minSdk: 24,
            uid: 0,
          );
      final state = AppState(_MemStorage())..initialized = true;
      final apps = [
        app('com.a', 'Alpha', 10, 100, 300),
        app('com.b', 'Beta', 30, 300, 100),
        app('com.c', 'Gamma', 20, 200, 200),
      ];

      List<String> names(AppSort sort, bool ascending) => [
        for (final a in state.sortApps(apps, sort, ascending)) a.appName,
      ];

      expect(names(AppSort.name, true), ['Alpha', 'Beta', 'Gamma']);
      expect(names(AppSort.name, false), ['Gamma', 'Beta', 'Alpha']);
      expect(names(AppSort.updateTime, false), ['Beta', 'Gamma', 'Alpha']);
      expect(names(AppSort.installTime, true), ['Alpha', 'Gamma', 'Beta']);
      expect(names(AppSort.size, false), ['Alpha', 'Gamma', 'Beta']);
    });

    test('favorites can be ordered by hand; the widget follows', () async {
      final state = _state();
      await state.updateMeta('com.a', favorite: true);
      await state.updateMeta('com.b', favorite: true);

      await state.setFavoritesManual(true);
      expect(state.favoritesManual, isTrue);
      expect(state.favorites.map((a) => a.packageName), ['com.a', 'com.b']);

      await state.moveFavorite(0, 1);
      expect(state.favorites.map((a) => a.packageName), ['com.b', 'com.a']);
      expect(state.settings['favorites_order'], ['com.b', 'com.a']);

      final collections =
          (state.buildHomeWidgetData()['collections'] as List)
              .cast<Map<String, dynamic>>();
      final favorites = collections.singleWhere((c) => c['key'] == 'fav');
      expect(
        [
          for (final a
              in (favorites['apps'] as List).cast<Map<String, dynamic>>())
            a['p'],
        ],
        ['com.b', 'com.a'],
        reason: 'the widget shows the hand-picked order too',
      );

      // Picking a field order leaves manual mode behind.
      await state.setFavoritesSort(AppSort.name, true);
      expect(state.favoritesManual, isFalse);
      expect(state.favorites.map((a) => a.packageName), ['com.a', 'com.b']);
    });

    test('favorites and category views start at their old layout and persist', () async {
      final state = _state();
      expect(state.favoritesView, AppViewMode.grid);
      expect(state.categoryListView, AppViewMode.list);
      expect(state.categoryAppsView('c1'), AppViewMode.list);

      await state.setFavoritesView(AppViewMode.list);
      await state.setCategoryListView(AppViewMode.grid);
      await state.setCategoryAppsView('c1', AppViewMode.grid);
      expect(state.favoritesView, AppViewMode.list);
      expect(state.categoryListView, AppViewMode.grid);
      expect(state.categoryAppsView('c1'), AppViewMode.grid);
      expect(state.settings['favorites_view'], 'list');
      expect(state.settings['category_list_view'], 'grid');
      expect(state.settings['category_apps_view_c1'], 'grid');
    });

    test('a category sort choice is stored and can be read back', () async {
      final state = _state();
      final category = await state.addCategory('工具');
      await state.setCategoryAppsSort(category.id, AppSort.size, false);
      expect(state.categoryAppsSort(category.id), AppSort.size);
      expect(state.categoryAppsSortAscending(category.id), isFalse);

      await state.setFavoritesSort(AppSort.updateTime, true);
      expect(state.favoritesSort, AppSort.updateTime);
      expect(state.favoritesSortAscending, isTrue);
    });

    test('the 4x1 strip carries the pages and the current one', () {
      final state = _state();
      state.currentTilePageIndex = 0;

      final data = state.buildPageWidgetData();
      final pages = (data['pages'] as List).cast<Map<String, dynamic>>();
      expect(pages.single['id'], 'p1');
      expect(pages.single['n'], 'P1');
      expect(data['current'], 0);
    });

    test('the count limit and rounded flag reach the widget', () {
      final state = AppState(_MemStorage())
        ..initialized = true
        ..apps = [for (var i = 0; i < 8; i++) _app('com.$i', 'App$i')]
        ..tilePages = [TilePage(id: 'p1', name: 'P1', createdAt: 0)]
        ..tiles = [
          for (var i = 0; i < 8; i++)
            Tile(
              id: 't$i',
              packageName: 'com.$i',
              pageId: 'p1',
              col: i % 4,
              row: i ~/ 4,
            ),
        ]
        ..settings = {
          'widget_max_apps': 4,
          'widget_rounded_icons': true,
        };

      final data = state.buildHomeWidgetData();
      expect(data['showLabels'], isTrue);
      expect(data['roundedIcons'], isTrue);
      expect(data['fallback'] as List, hasLength(4));

      final slots = (data['slots'] as List).cast<Map<String, dynamic>>();
      for (final slot in slots) {
        expect((slot['apps'] as List).length, lessThanOrEqualTo(4));
      }
      expect((slots[DateTime.now().hour]['apps'] as List), hasLength(4));
    });

    test('the widget options are stored', () async {
      final storage = _MemStorage();
      final state = AppState(storage)..initialized = true;
      expect(state.widgetMaxApps, 8);
      expect(state.widgetRoundedIcons, isFalse);

      await state.setWidgetMaxApps(4);
      await state.setWidgetRoundedIcons(true);
      expect(state.widgetMaxApps, 4);
      expect(state.widgetRoundedIcons, isTrue);

      final restored = AppState(storage)
        ..initialized = true
        ..settings = (await storage.readJson('settings') as Map)
            .cast<String, dynamic>();
      expect(restored.widgetMaxApps, 4);
      expect(restored.widgetRoundedIcons, isTrue);
    });

    test('the layout and marker settings reach the widgets', () async {
      final state = AppState(_MemStorage())..initialized = true;
      expect(state.widgetLayout, 'spread');
      expect(state.pageBarMarker, 'pill');

      await state.setWidgetLayout('edges');
      await state.setPageBarMarker('dot');

      expect(state.buildHomeWidgetData()['layout'], 'edges');
      expect(state.buildPageWidgetData()['marker'], 'dot');
    });

    test('the layout and marker settings are stored', () async {
      final storage = _MemStorage();
      final state = AppState(storage)..initialized = true;
      await state.setWidgetLayout('left');
      await state.setPageBarMarker('dot');

      final restored = AppState(storage)
        ..initialized = true
        ..settings = (await storage.readJson('settings') as Map)
            .cast<String, dynamic>();
      expect(restored.widgetLayout, 'left');
      expect(restored.pageBarMarker, 'dot');
    });

    test('the label setting is stored', () async {
      final storage = _MemStorage();
      final state = AppState(storage)..initialized = true;
      expect(state.widgetShowLabels, isTrue);

      await state.setWidgetShowLabels(false);

      final restored = AppState(storage)
        ..initialized = true
        ..settings =
            (await storage.readJson('settings') as Map).cast<String, dynamic>();
      expect(restored.widgetShowLabels, isFalse);
    });
  });

  testWidgets('the widget settings screen previews and pins', (tester) async {
    final channel = const MethodChannel('hamstapp/apps');
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'widgetStatus':
          return {'count': 0, 'supported': true, 'canPin': true};
        case 'requestPinWidget':
          return true;
        case 'updateHomeWidget':
          return true;
        case 'getAppIcon':
          return null;
        case 'updateShortcuts':
          return true;
      }
      return null;
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    final state = _state();
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: HomeWidgetScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('还没有添加到桌面'), findsOneWidget);
    expect(find.text('添加到桌面'), findsOneWidget);
    expect(find.text('小组件选项'), findsOneWidget);
    expect(find.text('显示应用名称'), findsOneWidget);

    // Pin from the top of the page.
    await tester.scrollUntilVisible(find.text('添加到桌面'), 120);
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加到桌面'));
    await tester.pumpAndSettle();
    expect(calls, contains('requestPinWidget'));

    // Hide the names.
    await tester.scrollUntilVisible(
      find.widgetWithText(SwitchListTile, '显示应用名称'),
      200,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SwitchListTile, '显示应用名称'));
    await tester.pumpAndSettle();
    expect(state.widgetShowLabels, isFalse);

    // Limit the number of apps to four.
    await tester.scrollUntilVisible(
      find.byType(SegmentedButton<int>),
      200,
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(SegmentedButton<int>),
        matching: find.text('4'),
      ),
    );
    await tester.pumpAndSettle();
    expect(state.widgetMaxApps, 4);

    // Pick the two-ends row style.
    await tester.scrollUntilVisible(find.text('布局风格'), 200);
    await tester.pumpAndSettle();
    await tester.tap(find.text('两端'));
    await tester.pumpAndSettle();
    expect(state.widgetLayout, 'edges');

    // Round the icons.
    await tester.scrollUntilVisible(
      find.widgetWithText(SwitchListTile, '圆角图标'),
      200,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SwitchListTile, '圆角图标'));
    await tester.pumpAndSettle();
    expect(state.widgetRoundedIcons, isTrue);

    // The 4x1 strip marks its current page with a dot.
    await tester.scrollUntilVisible(find.text('选中样式'), 300);
    await tester.pumpAndSettle();
    await tester.tap(find.text('小圆点'));
    await tester.pumpAndSettle();
    expect(state.pageBarMarker, 'dot');

    // The 4x1 strip's section is further down.
    await tester.scrollUntilVisible(find.text('磁贴页标签条'), 300);
    await tester.pumpAndSettle();
    expect(find.text('添加标签条到桌面'), findsOneWidget);
  });
}
