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

    test('a custom icon is sent for the widget to draw', () {
      final state = _state();
      CustomIcons.instance.put('com.a', _tinyPng);
      addTearDown(() => CustomIcons.instance.remove('com.a'));

      final icons =
          state.buildHomeWidgetData()['icons'] as Map<String, dynamic>;
      expect(icons['com.a'], isNotEmpty);
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
    expect(find.text('显示个数'), findsOneWidget);
    expect(find.text('圆角图标'), findsOneWidget);

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

    // Round the icons.
    await tester.scrollUntilVisible(
      find.widgetWithText(SwitchListTile, '圆角图标'),
      200,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SwitchListTile, '圆角图标'));
    await tester.pumpAndSettle();
    expect(state.widgetRoundedIcons, isTrue);

    // The 4x1 strip's section is further down.
    await tester.scrollUntilVisible(find.text('磁贴页标签条'), 300);
    await tester.pumpAndSettle();
    expect(find.text('添加标签条到桌面'), findsOneWidget);
  });
}
