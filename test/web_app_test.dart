import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:hamstapp/l10n/app_strings.dart';
import 'package:hamstapp/models/app_info.dart';
import 'package:hamstapp/screens/app_detail_screen.dart';
import 'package:hamstapp/screens/web_app_check_screen.dart';
import 'package:hamstapp/services/storage.dart';
import 'package:hamstapp/state/app_state.dart';
import 'package:hamstapp/widgets/app_tile.dart';

class _MemStorage implements Storage {
  final Map<String, dynamic> _data = <String, dynamic>{};
  @override
  Future<dynamic> readJson(String name) async => _data[name];
  @override
  Future<void> writeJson(String name, dynamic data) async {
    _data[name] = data;
  }
}

/// An installed web app is a normal package (a WebAPK shell or a Trusted Web
/// Activity), so it is modelled as one — only the two extra fields say it is
/// really a website.
const String _kWebPkg = 'org.chromium.webapk.a1b2c3';

AppInfo _app(String pkg, String name, {bool web = false, String url = ''}) =>
    AppInfo(
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
      isWebApp: web,
      webUrl: url,
    );

AppState _state(List<AppInfo> apps) => AppState(_MemStorage())
  ..initialized = true
  ..apps = apps;

void main() {
  test('keeps the site of an installed web app', () {
    final app = _app(
      _kWebPkg,
      'Photos',
      web: true,
      url: 'https://photos.example/',
    );
    final back = AppInfo.fromMap(app.toMap());
    expect(back.isWebApp, isTrue);
    expect(back.webUrl, 'https://photos.example/');
  });

  test('ordinary apps stay ordinary, including old cached scans', () {
    final plain = _app('com.a', 'A');
    expect(plain.isWebApp, isFalse);
    expect(plain.webUrl, '');

    // Caches written before the field existed must not turn apps into web apps.
    final map = plain.toMap()
      ..remove('isWebApp')
      ..remove('webUrl');
    final back = AppInfo.fromMap(map);
    expect(back.isWebApp, isFalse);
    expect(back.webUrl, '');
  });

  test('counts installed web apps for the scan summary', () {
    final state = _state([
      _app('com.a', 'Notes'),
      _app(_kWebPkg, 'Photos', web: true, url: 'https://photos.example/'),
    ]);
    expect(state.webAppCount, 1);
    expect(_state([_app('com.a', 'Notes')]).webAppCount, 0);
  });

  testWidgets('the app list tags an installed web app', (tester) async {    final state = _state([
      _app('com.a', 'Notes'),
      _app(_kWebPkg, 'Photos', web: true, url: 'https://photos.example/'),
    ]);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                for (final a in state.apps) AppListTile(app: a, state: state),
              ],
            ),
          ),
        ),
      ),
    );

    final tag = AppStrings.current.t('网页');
    expect(find.textContaining(tag), findsOneWidget);
    expect(find.byIcon(Icons.public), findsOneWidget);
    expect(find.text('Photos'), findsOneWidget);
  });

  testWidgets('the detail page explains the web app and links its site', (
    tester,
  ) async {
    final state = _state([
      _app(_kWebPkg, 'Photos', web: true, url: 'https://photos.example/'),
    ]);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(
          home: AppDetailScreen(packageName: _kWebPkg),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    // Chip next to the name + the card that explains what it is.
    expect(find.text(AppStrings.current.t('网页应用')), findsWidgets);
    expect(find.text('https://photos.example/'), findsOneWidget);
    expect(find.text(AppStrings.current.t('用浏览器打开')), findsOneWidget);
  });

  testWidgets('a normal app has no web app block', (tester) async {
    final state = _state([_app('com.a', 'Notes')]);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: AppDetailScreen(packageName: 'com.a')),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text(AppStrings.current.t('网页应用')), findsNothing);
    expect(find.text(AppStrings.current.t('用浏览器打开')), findsNothing);
  });

  testWidgets('the check-up screen renders the report', (tester) async {
    const channel = MethodChannel('hamstapp/apps');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method != 'webAppReport') return null;
      return <String, dynamic>{
        'total': 10,
        'user': 7,
        'system': 3,
        'metaReadable': 9,
        'launcherEntries': 5,
        'shells': 1,
        'webApps': [
          {
            'packageName': _kWebPkg,
            'appName': 'Photos',
            'activity': 'org.chromium.webapk.shell_apk.MainActivity',
            'sizeBytes': 40960,
            'isSystem': false,
            'webUrl': 'https://photos.example/',
          },
        ],
        'candidates': [
          {
            'packageName': 'com.a.notes',
            'appName': 'Notes',
            'activity': 'com.a.notes.MainActivity',
            'sizeBytes': 204800,
            'isSystem': false,
            'webUrl': '',
            'signal': 'small',
          },
        ],
      };
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );

    await tester.pumpWidget(const MaterialApp(home: WebAppCheckScreen()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final s = AppStrings.current;
    expect(find.text('${s.t('已识别网页应用')} · 1'), findsOneWidget);
    expect(find.text('${s.t('疑似网页应用（未确认）')} · 1'), findsOneWidget);
    expect(find.text('Photos'), findsOneWidget);
    expect(find.text('Notes'), findsOneWidget);
    expect(find.text(s.t('APK 很小')), findsOneWidget);
  });

  testWidgets('the check-up screen gives up when the bridge stays silent', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: WebAppCheckScreen()));
    await tester.pump();
    // No plugin in a test binding: the call never answers.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pump(const Duration(seconds: 11));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text(AppStrings.current.t('读取失败')), findsOneWidget);
    expect(find.text(AppStrings.current.t('网页应用检测')), findsOneWidget);
  });
}
