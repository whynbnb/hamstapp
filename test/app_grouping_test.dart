import 'package:flutter_test/flutter_test.dart';

import 'package:hamstapp/models/app_info.dart';
import 'package:hamstapp/models/category.dart';
import 'package:hamstapp/services/storage.dart';
import 'package:hamstapp/state/app_state.dart';
import 'package:hamstapp/utils/app_grouping.dart';

class _MemStorage implements Storage {
  final Map<String, dynamic> _data = <String, dynamic>{};
  @override
  Future<dynamic> readJson(String name) async => _data[name];
  @override
  Future<void> writeJson(String name, dynamic data) async {
    _data[name] = data;
  }
}

AppInfo app(String pkg, String name) => AppInfo(
  packageName: pkg,
  appName: name,
  versionName: '1.0',
  versionCode: 1,
  firstInstallTime: 0,
  lastUpdateTime: 0,
  isSystem: false,
  enabled: true,
  apkPath: '',
  sizeBytes: 0,
  targetSdk: 34,
  minSdk: 24,
  uid: 1,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Grouping', () {
    test('by letter, using the pinyin of a Chinese name', () {
      final apps = [
        app('com.mm', '微信'), // w
        app('com.ali', '支付宝'), // z
        app('com.a', 'Alipay'),
        app('com.d', '1Password'),
      ];
      final groups = groupApps(
        apps,
        AppGroupMode.initial,
        nameOf: (a) => a.appName,
        categoriesOf: (a) => const <String>[],
        uncategorizedLabel: '未分类',
      );
      expect(groups.map((g) => g.label), ['A', 'W', 'Z', '#']);
      expect(groups.first.apps.single.appName, 'Alipay');
      expect(groups[1].apps.single.appName, '微信');
      // Digits and symbols land in one bucket, which sorts last.
      expect(groups.last.apps.single.appName, '1Password');
    });

    test('by category, in the user order, ungrouped last', () {
      final apps = [
        app('com.a', 'A'),
        app('com.b', 'B'),
        app('com.c', 'C'),
      ];
      final groups = groupApps(
        apps,
        AppGroupMode.category,
        nameOf: (a) => a.appName,
        categoriesOf: (a) => switch (a.packageName) {
          'com.a' => const ['游戏'],
          'com.b' => const <String>[],
          _ => const ['工具'],
        },
        uncategorizedLabel: '未分类',
        categoryOrder: const ['工具', '游戏'],
      );
      expect(groups.map((g) => g.label), ['工具', '游戏', '未分类']);
      expect(groups[1].apps.single.appName, 'A');
    });

    test('no grouping keeps one unnamed section in the given order', () {
      final apps = [app('com.b', 'B'), app('com.a', 'A')];
      final groups = groupApps(
        apps,
        AppGroupMode.none,
        nameOf: (a) => a.appName,
        categoriesOf: (a) => const <String>[],
        uncategorizedLabel: '未分类',
      );
      expect(groups, hasLength(1));
      expect(groups.single.label, '');
      expect(groups.single.apps.map((a) => a.appName), ['B', 'A']);
    });
  });

  group('Grouping in the app list', () {
    AppState stateWith() {
      final state = AppState(_MemStorage())
        ..initialized = true
        ..apps = [
          app('com.mm', '微信'),
          app('com.ali', '支付宝'),
          app('com.ng', 'Notebook'),
        ]
        ..categories = [
          AppCategory(id: 'c1', name: '聊天', colorValue: 0, emoji: '💬'),
        ];
      state.metaFor('com.mm').categoryIds = ['c1'];
      return state;
    }

    test('the mode is respected and grouped apps come from the filter', () {
      final state = stateWith();
      expect(state.groupMode, AppGroupMode.none);

      state.setAppGroupMode(AppGroupMode.initial);
      expect(state.groupedApps.map((g) => g.label), ['N', 'W', 'Z']);

      state.setAppGroupMode(AppGroupMode.category);
      expect(state.groupedApps.map((g) => g.label), ['聊天', '未分类']);

      // A filter still applies inside the sections.
      state.filter = AppFilter.categorized;
      state.setAppGroupMode(AppGroupMode.initial);
      expect(state.groupedApps.single.apps.single.appName, '微信');
    });

    test('a non-default grouping counts as an active list option', () {
      final state = stateWith();
      final before = state.activeAppFilterCount;
      state.setAppGroupMode(AppGroupMode.initial);
      expect(state.activeAppFilterCount, before + 1);
    });

    test('the grouping survives a restart', () async {
      final storage = _MemStorage();
      final state = AppState(storage)..initialized = true;
      await state.setAppGroupMode(AppGroupMode.category);

      final restored = AppState(storage)
        ..initialized = true
        ..settings = (await storage.readJson('settings') as Map)
            .cast<String, dynamic>();
      expect(restored.groupMode, AppGroupMode.category);
    });
  });
}
