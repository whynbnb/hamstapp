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
    expect(find.text('显示应用名称'), findsOneWidget);

    await tester.tap(find.text('添加到桌面'));
    await tester.pumpAndSettle();
    expect(calls, contains('requestPinWidget'));

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(state.widgetShowLabels, isFalse);
  });
}
