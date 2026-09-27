import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:hamstapp/models/app_info.dart';
import 'package:hamstapp/models/remote_source.dart';
import 'package:hamstapp/screens/orphan_cache_screen.dart';
import 'package:hamstapp/screens/remote_apk_detail_screen.dart';
import 'package:hamstapp/screens/sync_screen.dart';
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

RemoteSource _source() => RemoteSource(
  id: 's1',
  protocol: 'webdav',
  host: 'nas',
  port: 80,
  path: '/apks',
  anonymous: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('hamstapp/apps');

  void mock(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('orphan cache lists cached packages that are not installed', (
    tester,
  ) async {
    mock((call) async {
      if (call.method == 'cacheIndexAll') {
        return {
          'entries': [
            {
              'sourceId': 's1',
              'path': '/gone.apk',
              'packageName': 'com.gone',
              'appName': 'Gone',
              'versionName': '1.0',
              'versionCode': 1,
              'size': 10,
              'localPath': '/c/gone.apk',
            },
            {
              'sourceId': 's1',
              'path': '/kept.apk',
              'packageName': 'com.kept',
              'appName': 'Kept',
              'versionName': '2.0',
              'versionCode': 2,
              'size': 20,
              'localPath': '/c/kept.apk',
            },
          ],
          'totalBytes': 30,
        };
      }
      if (call.method == 'cacheDelete') return 10;
      return null;
    });

    final state = AppState(_MemStorage())
      ..initialized = true
      ..apps = [_ai('com.kept', 'Kept')];

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: OrphanCacheScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Gone'), findsOneWidget);
    expect(find.text('Kept'), findsNothing);
    expect(find.textContaining('孤包'), findsWidgets);
  });

  testWidgets('remote APK detail groups sibling files into version history', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    mock((call) async {
      if (call.method == 'cacheIndex') {
        return {
          'entries': [
            {
              'path': '/v1.apk',
              'packageName': 'com.a',
              'appName': 'Alpha',
              'versionName': '1.0',
              'versionCode': 1,
              'size': 10,
              'localPath': '/c/v1.apk',
            },
            {
              'path': '/v2.apk',
              'packageName': 'com.a',
              'appName': 'Alpha',
              'versionName': '2.0',
              'versionCode': 2,
              'size': 20,
              'localPath': '/c/v2.apk',
            },
          ],
          'totalBytes': 30,
        };
      }
      return null;
    });

    final entry = {'name': 'v2.apk', 'path': '/v2.apk', 'size': 20, 'modified': 1};
    final siblings = [
      entry,
      {'name': 'v1.apk', 'path': '/v1.apk', 'size': 10, 'modified': 1},
    ];

    final state = AppState(_MemStorage())..initialized = true;

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          home: RemoteApkDetailScreen(
            source: _source(),
            entry: entry,
            siblings: siblings,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('历史版本'), findsOneWidget);
    expect(find.text('v2.0 (2)'), findsOneWidget);
    expect(find.text('v1.0 (1)'), findsOneWidget);
    expect(find.text('包名'), findsOneWidget);
  });

  testWidgets('tapping a remote APK row opens the detail page, not install', (
    tester,
  ) async {
    var downloads = 0;
    mock((call) async {
      switch (call.method) {
        case 'remoteList':
          return [
            {
              'name': 'app.apk',
              'rel': 'app.apk',
              'path': '/apks/app.apk',
              'size': 10,
              'modified': 1,
            },
          ];
        case 'cacheIndex':
          return {'entries': [], 'totalBytes': 0};
        case 'cachePrune':
          return 0;
        case 'remoteDownload':
          downloads++;
          return '/cache/app.apk';
      }
      return null;
    });

    final source = RemoteSource(
      id: 's1',
      protocol: 'ftp',
      host: 'nas',
      port: 21,
      path: '/apks',
      anonymous: true,
    );
    final state = AppState(_MemStorage())..initialized = true;
    state.settings = {
      'sync_sources': [source.toMap()],
      'sync_active': source.id,
    };

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: SyncScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('app.apk'), findsOneWidget);
    await tester.tap(find.text('app.apk'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(RemoteApkDetailScreen), findsOneWidget);
    expect(downloads, 0, reason: 'row tap must not start an install/download');
  });
}
