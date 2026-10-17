import 'package:flutter_test/flutter_test.dart';

import 'package:hamstapp/models/app_info.dart';
import 'package:hamstapp/services/storage.dart';
import 'package:hamstapp/state/app_state.dart';
import 'package:hamstapp/utils/search.dart';

const mb = 1024 * 1024;

class _MemStorage implements Storage {
  final Map<String, dynamic> _data = <String, dynamic>{};
  @override
  Future<dynamic> readJson(String name) async => _data[name];
  @override
  Future<void> writeJson(String name, dynamic data) async {
    _data[name] = data;
  }
}

AppInfo app(
  String pkg,
  String name, {
  int size = 0,
  int installed = 0,
  int updated = 0,
  bool system = false,
}) => AppInfo(
  packageName: pkg,
  appName: name,
  versionName: '1.0',
  versionCode: 1,
  firstInstallTime: installed,
  lastUpdateTime: updated,
  isSystem: system,
  enabled: true,
  apkPath: '',
  sizeBytes: size,
  targetSdk: 34,
  minSdk: 24,
  uid: 1,
);

void main() {
  // A fixed instant so relative dates in the syntax are deterministic:
  // 2024-06-15 12:00 UTC.
  const now = 1718452800000;

  group('Query parsing', () {
    test('free text is left alone', () {
      final q = AppQuery.parse('微信 wx', now: now);
      expect(q.text, '微信 wx');
      expect(q.hasFilters, isFalse);
      expect(q.isEmpty, isFalse);
      expect(AppQuery.parse('   ', now: now).isEmpty, isTrue);
    });

    test('size takes a bound, a range and units', () {
      expect(AppQuery.parse('size:>100m', now: now).sizeOver, 100 * mb);
      expect(AppQuery.parse('size:<500k', now: now).sizeUnder, 500 * 1024);
      expect(AppQuery.parse('size:2g', now: now).sizeOver, isNull);
      final range = AppQuery.parse('size:10m-2g', now: now);
      expect(range.sizeOver, 10 * mb);
      expect(range.sizeUnder, 2 * 1024 * mb);
      // A bare number counts as megabytes.
      expect(AppQuery.parse('size:>50', now: now).sizeOver, 50 * mb);
      // Something unparsable is text, not a filter.
      final odd = AppQuery.parse('size:big', now: now);
      expect(odd.hasFilters, isFalse);
      expect(odd.text, 'size:big');
    });

    test('installed / updated accept relative and absolute dates', () {
      // "<7d" is "within the last 7 days", so it is a lower bound.
      final week = AppQuery.parse('installed:<7d', now: now);
      expect(week.installedAfter, now - const Duration(days: 7).inMilliseconds);
      expect(week.installedBefore, isNull);
      final since = AppQuery.parse('installed:>2024-01-01', now: now);
      expect(
        since.installedAfter,
        DateTime(2024, 1, 1).millisecondsSinceEpoch,
      );
      final month = AppQuery.parse('updated:<30d', now: now);
      expect(month.updatedAfter, now - const Duration(days: 30).inMilliseconds);
    });

    test('category, reason, source and type are read', () {
      final q = AppQuery.parse(
        'cat:游戏 reason:工作 source:com.store type:system',
        now: now,
      );
      expect(q.category, '游戏');
      expect(q.reason, '工作');
      expect(q.source, 'com.store');
      expect(q.systemOnly, isTrue);
      expect(q.text, '');

      expect(AppQuery.parse('reason:', now: now).hasReason, isTrue);
      expect(AppQuery.parse('source:none', now: now).onlySideloaded, isTrue);
      expect(AppQuery.parse('type:user', now: now).userOnly, isTrue);
      // The bare forms the syntax chips insert mean "has one".
      expect(AppQuery.parse('cat:', now: now).hasCategory, isTrue);
      expect(AppQuery.parse('source:', now: now).hasInstaller, isTrue);
    });

    test('an unknown key:value stays free text', () {
      final q = AppQuery.parse('foo:bar 相机', now: now);
      expect(q.text, 'foo:bar 相机');
      expect(q.hasFilters, isFalse);
    });
  });

  group('Query matching', () {
    bool matches(
      String query, {
      int size = 10 * mb,
      int installed = 0,
      int updated = 0,
      bool system = false,
      String categories = '',
      String reason = '',
      String installer = '',
      bool sideloaded = true,
    }) => AppQuery.parse(query, now: now).matches(
      sizeBytes: size,
      firstInstallTime: installed,
      lastUpdateTime: updated,
      isSystem: system,
      categoryNames: categories,
      reason: reason,
      installerLabel: installer,
      sideloaded: sideloaded,
    );

    test('size filters by bytes', () {
      expect(matches('size:>100m', size: 200 * mb), isTrue);
      expect(matches('size:>100m', size: 50 * mb), isFalse);
      expect(matches('size:<100m', size: 50 * mb), isTrue);
      expect(matches('size:10m-100m', size: 50 * mb), isTrue);
      expect(matches('size:10m-100m', size: 200 * mb), isFalse);
    });

    test('an app never installed this week fails installed:<7d', () {
      expect(matches('installed:<7d', installed: now - 1000), isTrue);
      expect(
        matches('installed:<7d', installed: now - 30 * 24 * 3600 * 1000),
        isFalse,
      );
      // An install time the system did not report is not "in the window".
      expect(matches('installed:<7d', installed: 0), isFalse);
      // "Older than a week" is the other side of the same filter.
      expect(
        matches('installed:>7d', installed: now - 30 * 24 * 3600 * 1000),
        isTrue,
      );
    });

    test('category, reason, source and type are checked', () {
      expect(matches('cat:游戏', categories: '游戏 工具'), isTrue);
      expect(matches('cat:游戏', categories: '工具'), isFalse);
      expect(matches('reason:工作', reason: '工作时用'), isTrue);
      expect(matches('reason:', reason: 'x'), isTrue);
      expect(matches('reason:', reason: ''), isFalse);
      expect(matches('type:system', system: true), isTrue);
      expect(matches('type:user', system: true), isFalse);
      // Bare filters: a category on record / an installer on record.
      expect(matches('cat:', categories: '工具'), isTrue);
      expect(matches('cat:', categories: ' '), isFalse);
      expect(
        matches('source:', installer: 'com.store', sideloaded: false),
        isTrue,
      );
      expect(matches('source:', installer: '', sideloaded: true), isFalse);
    });

    test('source matches the installer, and none means side-loaded', () {
      expect(
        matches('source:com.store', installer: '应用商店 com.store', sideloaded: false),
        isTrue,
      );
      expect(
        matches('source:商店', installer: '应用商店 com.store', sideloaded: false),
        isTrue,
      );
      expect(
        matches('source:com.store', installer: '', sideloaded: true),
        isFalse,
      );
      expect(matches('source:none', installer: '', sideloaded: true), isTrue);
      expect(
        matches('source:none', installer: 'com.store', sideloaded: false),
        isFalse,
      );
    });
  });

  group('Search in the app list and its history', () {
    AppState stateWith() {
      final state = AppState(_MemStorage())
        ..initialized = true
        ..apps = [
          app('com.big', 'Big', size: 300 * mb),
          app('com.small', 'Small', size: 1 * mb),
          app('com.new', 'New', size: 5 * mb, installed: now - 1000),
          app('com.sys', 'Sys', system: true),
        ];
      state.metaFor('com.big').reason = '工作用';
      return state;
    }

    test('filters narrow the list, and text still matches names', () {
      final state = stateWith();
      state.query = 'size:>100m';
      expect(state.visibleApps.map((a) => a.appName), ['Big']);

      state.query = 'type:system';
      expect(state.visibleApps.map((a) => a.appName), ['Sys']);

      state.query = 'size:<10m 名';
      expect(state.visibleApps, isEmpty);

      state.query = 'size:<10m new';
      expect(state.visibleApps.map((a) => a.appName), ['New']);
    });

    test('history keeps the newest first, without duplicates', () async {
      final state = stateWith();
      expect(state.searchHistory, isEmpty);
      await state.rememberQuery('相机');
      await state.rememberQuery('微信');
      await state.rememberQuery('相机');
      expect(state.searchHistory, ['相机', '微信']);
      await state.rememberQuery('   ');
      expect(state.searchHistory, ['相机', '微信']);
      await state.clearSearchHistory();
      expect(state.searchHistory, isEmpty);
    });

    test('history is capped', () async {
      final state = stateWith();
      for (var i = 0; i < AppState.kSearchHistoryMax + 4; i++) {
        await state.rememberQuery('q$i');
      }
      expect(state.searchHistory, hasLength(AppState.kSearchHistoryMax));
      expect(state.searchHistory.first, 'q${AppState.kSearchHistoryMax + 3}');
    });
  });
}
