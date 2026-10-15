import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:hamstapp/screens/storage_manager_screen.dart';
import 'package:hamstapp/services/icon_cache.dart';
import 'package:hamstapp/services/storage.dart';
import 'package:hamstapp/services/storage_manager.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('hamstapp/apps');
  final calls = <MethodCall>[];
  var cacheCleared = false;

  void mockChannel() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'cacheIndexAll':
          return cacheCleared
              ? {'entries': <Object?>[], 'totalBytes': 0}
              : {
                  'entries': [
                    {'size': 10},
                    {'size': 20},
                  ],
                  'totalBytes': 30,
                };
        case 'cacheClear':
          cacheCleared = true;
          return 30;
        default:
          return null;
      }
    });
  }

  setUp(() {
    calls.clear();
    cacheCleared = false;
    mockChannel();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    IconCache.instance.replaceAll(<String, Uint8List>{});
  });

  test('reports the APK cache from the native index', () async {
    final report = await StorageManager.measure();
    expect(report.map((u) => u.category), [
      StorageCategory.icons,
      StorageCategory.scan,
      StorageCategory.apk,
      StorageCategory.temp,
      StorageCategory.data,
    ]);

    final apk = report.firstWhere((u) => u.category == StorageCategory.apk);
    expect(apk.bytes, 30);
    expect(apk.items, 2);
    expect(apk.clearable, isTrue);
  });

  test('other data is reported but never cleared as a cache', () async {
    final report = await StorageManager.measure();
    final data = report.firstWhere((u) => u.category == StorageCategory.data);
    expect(data.clearable, isFalse);
  });

  test('falls back to the icons held in memory', () async {
    IconCache.instance.put('com.a', Uint8List(64));
    final report = await StorageManager.measure();
    final icons = report.firstWhere(
      (u) => u.category == StorageCategory.icons,
    );
    expect(icons.items, 1);
    expect(icons.bytes, 64);
  });

  test('clearing the temp directory frees everything inside it', () async {
    final dir = await Directory.systemTemp.createTemp('hamstapp-store');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final nested = Directory('${dir.path}/share')..createSync();
    File('${nested.path}/copy.apk').writeAsBytesSync(List<int>.filled(120, 7));
    File('${dir.path}/dropped.apk').writeAsBytesSync(List<int>.filled(80, 1));

    final report = await StorageManager.measure(tempDir: dir);
    final temp = report.firstWhere((u) => u.category == StorageCategory.temp);
    expect(temp.bytes, 200);
    expect(temp.items, 2);

    expect(await StorageManager.clearTemp(tempDir: dir), 200);
    expect(dir.listSync(), isEmpty);
  });

  testWidgets('the screen lists the categories and clears the APK cache', (
    tester,
  ) async {
    final state = AppState(_MemStorage())..initialized = true;
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: StorageManagerScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('存储管理'), findsOneWidget);
    expect(find.text('图标缓存'), findsOneWidget);
    expect(find.text('应用扫描缓存'), findsOneWidget);
    expect(find.text('APK 缓存'), findsOneWidget);
    expect(find.text('临时文件'), findsOneWidget);
    expect(find.text('其它数据'), findsOneWidget);
    expect(find.textContaining('2 个安装包'), findsOneWidget);

    // Clearing a cache the user cannot rebuild costs a re-download, so the APK
    // row asks first.
    final apkRow = find.ancestor(
      of: find.text('APK 缓存'),
      matching: find.byType(ListTile),
    );
    await tester.tap(
      find.descendant(of: apkRow, matching: find.byTooltip('清理')),
    );
    await tester.pumpAndSettle();
    expect(find.text('删除 2 个已缓存的安装包（30 B）？下次安装会重新下载。'), findsOneWidget);

    await tester.tap(find.text('清理'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(calls.map((c) => c.method), contains('cacheClear'));
    expect(find.text('已清理 30 B'), findsOneWidget);
    expect(find.textContaining('0 个安装包'), findsOneWidget);
  });
}
