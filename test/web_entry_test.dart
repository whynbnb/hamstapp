import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:hamstapp/l10n/app_strings.dart';
import 'package:hamstapp/models/app_info.dart';
import 'package:hamstapp/models/tile.dart';
import 'package:hamstapp/models/tile_page.dart';
import 'package:hamstapp/models/web_app.dart';
import 'package:hamstapp/screens/app_detail_screen.dart';
import 'package:hamstapp/services/app_log.dart';
import 'package:hamstapp/services/storage.dart';
import 'package:hamstapp/state/app_state.dart';
import 'package:hamstapp/utils/actions.dart';

class _MemStorage implements Storage {
  final Map<String, dynamic> _data = <String, dynamic>{};
  @override
  Future<dynamic> readJson(String name) async => _data[name];
  @override
  Future<void> writeJson(String name, dynamic data) async {
    _data[name] = data;
  }
}

AppInfo _installed(String pkg, String name) => AppInfo(
  packageName: pkg,
  appName: name,
  versionName: '1',
  versionCode: 1,
  firstInstallTime: 0,
  lastUpdateTime: 0,
  isSystem: false,
  enabled: true,
  apkPath: '/data/app/$pkg/base.apk',
  sizeBytes: 1024,
  targetSdk: 33,
  minSdk: 21,
  uid: 0,
);

void main() {
  group('WebApp', () {
    test('accepts what people type and rejects what cannot be opened', () {
      expect(WebApp.normalizeUrl(' zhihu.com '), 'https://zhihu.com');
      expect(
        WebApp.normalizeUrl('http://example.com/a'),
        'http://example.com/a',
      );
      expect(WebApp.isValidUrl('https://zhihu.com'), isTrue);
      expect(WebApp.isValidUrl('http://example.com/a?b=1'), isTrue);
      expect(WebApp.isValidUrl('zhihu.com'), isFalse);
      expect(WebApp.isValidUrl('https://'), isFalse);
      expect(WebApp.isValidUrl(''), isFalse);
    });

    test('persists and comes back as an app-shaped entry', () {
      final entry = WebApp(
        id: WebApp.newId(DateTime.fromMillisecondsSinceEpoch(1)),
        name: 'Photos',
        url: 'https://photos.example/',
        createdAt: 42,
      );
      final back = WebApp.fromMap(entry.toMap());
      expect(back.id, entry.id);
      expect(back.name, 'Photos');
      expect(back.url, 'https://photos.example/');
      expect(back.createdAt, 42);

      final app = back.toAppInfo();
      expect(app.packageName, entry.id);
      expect(app.appName, 'Photos');
      expect(app.webUrl, 'https://photos.example/');
      expect(app.isWebApp, isTrue);
      expect(app.isWebEntry, isTrue);
      expect(app.apkPath, isEmpty);
      expect(WebApp.isWebId(app.packageName), isTrue);
      expect(WebApp.isWebId('com.android.chrome'), isFalse);
    });
  });

  group('web entries in the state', () {
    test('are merged into the app list but never into the scan', () async {
      final state = AppState(_MemStorage())
        ..initialized = true
        ..apps = [_installed('com.a', 'Notes')];
      await state.addWebApp(name: 'Photos', url: 'https://photos.example/');
      final id = state.webApps.single.id;

      // Everything app-shaped sees it...
      expect(state.appByPackage(id), isNotNull);
      expect(state.displayNameFor(id), 'Photos');
      expect(state.visibleApps.map((a) => a.packageName), contains(id));
      // ...the scan (and the uninstall diff) does not.
      expect(state.installedApps.length, 1);
      expect(state.webAppCount, 1);
    });

    test('are found by name and by address', () async {
      final state = AppState(_MemStorage())..initialized = true;
      await state.addWebApp(name: '相册', url: 'https://photos.example/gallery');
      final id = state.webApps.single.id;

      state.query = '相册';
      expect(state.visibleApps.map((a) => a.packageName), contains(id));
      state.query = 'photos.example';
      expect(state.visibleApps.map((a) => a.packageName), contains(id));
      state.query = 'nothing-here';
      expect(state.visibleApps, isEmpty);
    });

    test('can be favorited, tiled and categorized like an app', () async {
      final state = AppState(_MemStorage())
        ..initialized = true
        ..tilePages = [TilePage(id: 'p1', name: 'P1', createdAt: 0)];
      await state.addWebApp(name: 'Photos', url: 'https://photos.example/');
      final id = state.webApps.single.id;

      await state.updateMeta(id, favorite: true);
      expect(state.favorites.map((a) => a.packageName), contains(id));

      state.tiles.add(
        Tile(
          id: 't1',
          packageName: id,
          pageId: 'p1',
          col: 0,
          row: 0,
          w: 2,
          h: 2,
        ),
      );
      // tilesOnPage drops tiles whose app is unknown — a web entry must not be.
      expect(
        state.tilesOnPage(state.tilePages.single).map((t) => t.packageName),
        contains(id),
      );
    });

    test('are saved on their own so a scan cannot wipe them', () async {
      final storage = _MemStorage();
      final state = AppState(storage)..initialized = true;
      await state.addWebApp(name: 'Photos', url: 'https://photos.example/');
      final id = state.webApps.single.id;

      final saved = await storage.readJson('web_apps') as List<dynamic>;
      expect(saved.length, 1);
      expect((saved.single as Map)['id'], id);

      // A scan replaces the installed list only.
      state.apps = [_installed('com.a', 'Notes')];
      expect(state.appByPackage(id), isNotNull);
      expect(state.installedApps.length, 1);
    });

    test('editing keeps the id, removing takes its tiles and metadata', () async {
      final state = AppState(_MemStorage())
        ..initialized = true
        ..tilePages = [TilePage(id: 'p1', name: 'P1', createdAt: 0)];
      await state.addWebApp(name: 'Photos', url: 'https://photos.example/');
      final id = state.webApps.single.id;
      state.tiles.add(
        Tile(id: 't1', packageName: id, pageId: 'p1', col: 0, row: 0),
      );
      await state.updateMeta(id, favorite: true);

      await state.updateWebApp(id, name: '相册', url: 'https://photos.example/v2');
      expect(state.displayNameFor(id), '相册');
      expect(state.appByPackage(id)!.webUrl, 'https://photos.example/v2');

      await state.removeWebApp(id);
      expect(state.webApps, isEmpty);
      expect(state.appByPackage(id), isNull);
      expect(state.tiles, isEmpty);
      expect(state.meta.containsKey(id), isFalse);
    });
  });

  testWidgets('launching a web entry opens its address in the app window', (
    tester,
  ) async {
    const channel = MethodChannel('hamstapp/apps');
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return true;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );

    final state = AppState(_MemStorage())..initialized = true;
    await state.addWebApp(name: 'Photos', url: 'https://photos.example/');
    final id = state.webApps.single.id;

    late BuildContext ctx;
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          home: Builder(
            builder: (c) {
              ctx = c;
              return const SizedBox();
            },
          ),
        ),
      ),
    );

    await launchApp(ctx, id);

    // Every entry opens in its own window by default, manifest or not.
    expect(calls.map((c) => c.method), isNot(contains('openUrl')));
    final open = calls.singleWhere((c) => c.method == 'openWebApp');
    expect((open.arguments as Map)['url'], 'https://photos.example/');
    // Opening it counts as a launch, like any app.
    expect(state.metaFor(id).launchCount, 1);
    expect(state.metaFor(id).lastLaunchedAt > 0, isTrue);
  });

  testWidgets('a web entry that cannot open leaves the reason in the log', (
    tester,
  ) async {
    const channel = MethodChannel('hamstapp/apps');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      switch (call.method) {
        case 'openWebApp':
          throw PlatformException(code: 'webview', message: 'missing webview');
        case 'openUrl':
          return false;
      }
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );

    final log = AppLog.instance
      ..setEnabled(true)
      ..clear();
    addTearDown(() {
      log.setEnabled(false);
      log.clear();
    });

    final state = AppState(_MemStorage())..initialized = true;
    await state.addWebApp(name: 'Photos', url: 'https://photos.example/');
    final id = state.webApps.single.id;

    late BuildContext ctx;
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (c) {
                ctx = c;
                return const SizedBox();
              },
            ),
          ),
        ),
      ),
    );

    await launchApp(ctx, id);
    await tester.pump();

    // The user still gets told, and the log carries what was tried.
    expect(find.textContaining('设备上没有能处理它的应用'), findsOneWidget);
    final lines = log.entries.map((e) => e.text).join('\n');
    expect(lines, contains('网页入口 · 打开独立窗口 · Photos'));
    expect(lines, contains('打开独立窗口异常'));
    expect(lines, contains('独立窗口启动失败，改用浏览器'));
    expect(lines, contains('网页入口 · 打不开'));
    expect(lines, contains('https://photos.example/'));
    expect(log.countFor(LogModule.launch), greaterThanOrEqualTo(4));
  });

  testWidgets('the detail page of a web entry drops the APK-side rows', (
    tester,
  ) async {
    final state = AppState(_MemStorage())..initialized = true;
    await state.addWebApp(name: 'Photos', url: 'https://photos.example/');
    final id = state.webApps.single.id;

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(home: AppDetailScreen(packageName: id)),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final s = AppStrings.current;
    expect(find.text('https://photos.example/'), findsOneWidget);
    expect(find.text(s.t('用浏览器打开')), findsOneWidget);
    expect(find.text(s.t('编辑')), findsOneWidget);
    // The synthetic id is an implementation detail, not something to show.
    expect(find.text(id), findsNothing);
    expect(find.text(s.t('安装时间')), findsNothing);
    expect(find.text(s.t('APK 路径')), findsNothing);

    // The overflow menu offers web actions instead of APK ones.
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text(s.t('编辑名称 / 网址')), findsOneWidget);
    expect(find.text(s.t('删除网页入口')), findsOneWidget);
    expect(find.text(s.t('导出 APK（分享）')), findsNothing);
    expect(find.text(s.t('卸载')), findsNothing);
  });

  testWidgets('the detail page says where a tap will actually go', (
    tester,
  ) async {
    const channel = MethodChannel('hamstapp/apps');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      switch (call.method) {
        case 'getLaunchActivities':
          return <dynamic>[];
        case 'webAppHandler':
          return <String, dynamic>{
            'packageName': 'org.chromium.webapk.abc',
            'label': '大盘云图',
            'browser': false,
          };
      }
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );

    final state = AppState(_MemStorage())..initialized = true;
    await state.addWebApp(url: 'https://52etf.site/', name: '大盘云图');
    final id = state.webApps.single.id;

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(home: AppDetailScreen(packageName: id)),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final s = AppStrings.current;
    expect(find.text(s.t('已安装的网页应用')), findsOneWidget);
    // An installed web app is named, so the user knows taps land there.
    expect(find.textContaining('大盘云图 · 点开会交给它'), findsOneWidget);
  });

  testWidgets('the detail page explains when only a browser would take it', (
    tester,
  ) async {
    const channel = MethodChannel('hamstapp/apps');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      switch (call.method) {
        case 'getLaunchActivities':
          return <dynamic>[];
        case 'webAppHandler':
          return <String, dynamic>{
            'packageName': 'com.android.chrome',
            'label': 'Chrome',
            'browser': true,
          };
      }
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );

    final state = AppState(_MemStorage())..initialized = true;
    await state.addWebApp(url: 'https://52etf.site/', name: '大盘云图');
    final id = state.webApps.single.id;

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(home: AppDetailScreen(packageName: id)),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      find.textContaining(
        AppStrings.current.t('没有安装：点开只会交给浏览器开一个标签页'),
      ),
      findsOneWidget,
    );
  });
}
