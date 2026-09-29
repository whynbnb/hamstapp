import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:hamstapp/l10n/app_strings.dart';
import 'package:hamstapp/models/app_info.dart';
import 'package:hamstapp/models/launch_event.dart';
import 'package:hamstapp/screens/usage_stats_screen.dart';
import 'package:hamstapp/services/storage.dart';
import 'package:hamstapp/state/app_state.dart';
import 'package:hamstapp/utils/usage_stats.dart';

class _MemStorage implements Storage {
  final Map<String, dynamic> _data = <String, dynamic>{};
  @override
  Future<dynamic> readJson(String name) async => _data[name];
  @override
  Future<void> writeJson(String name, dynamic data) async {
    _data[name] = data;
  }
}

AppInfo _ai(String pkg, String name, {int installedAt = 0, bool system = false}) =>
    AppInfo(
      packageName: pkg,
      appName: name,
      versionName: '1',
      versionCode: 1,
      firstInstallTime: installedAt,
      lastUpdateTime: 0,
      isSystem: system,
      enabled: true,
      apkPath: '',
      sizeBytes: 0,
      targetSdk: 33,
      minSdk: 21,
      uid: 0,
    );

const int _day = Duration.millisecondsPerDay;

void main() {
  setUp(() => AppStrings.current = const AppStrings('zh'));

  // Fixed "now": 2026-01-15 12:00 UTC-ish; use a plain epoch so math is clear.
  final now = DateTime(2026, 1, 15, 12).millisecondsSinceEpoch;
  final installed = <String>{'com.a', 'com.b', 'com.c'};

  LaunchEvent ev(String pkg, int daysAgo) =>
      LaunchEvent(packageName: pkg, at: now - daysAgo * _day);

  group('UsageStats', () {
    test('mostUsed only counts the window and installed apps', () {
      final events = [
        ev('com.a', 1),
        ev('com.a', 2),
        ev('com.a', 40), // outside a 30-day window
        ev('com.ghost', 1), // not installed
      ];
      final most = UsageStats.mostUsed(
        events,
        installed: installed,
        sinceMillis: now - 30 * _day,
      );
      expect(most.length, 1);
      expect(most.single.packageName, 'com.a');
      expect(most.single.count, 2);
    });

    test('rank ties break by most recent launch', () {
      final events = [
        ev('com.a', 3),
        ev('com.b', 1),
      ];
      final most = UsageStats.mostUsed(
        events,
        installed: installed,
        sinceMillis: now - 30 * _day,
      );
      expect(most.map((e) => e.packageName).toList(), ['com.b', 'com.a']);
    });

    test('neglected means used before, silent in the window', () {
      final events = [
        ev('com.a', 1), // still used -> not neglected
        ev('com.a', 40),
        ev('com.b', 40), // used twice before -> neglected
        ev('com.b', 50),
        ev('com.c', 40), // only once before -> one-off, filtered out
      ];
      final list = UsageStats.neglected(
        events,
        installed: installed,
        sinceMillis: now - 30 * _day,
      );
      expect(list.map((e) => e.packageName).toList(), ['com.b']);
      expect(list.single.pastCount, 2);
    });

    test('neglected ignores uninstalled packages', () {
      final events = [
        ev('com.gone', 40),
        ev('com.gone', 45),
      ];
      final list = UsageStats.neglected(
        events,
        installed: installed,
        sinceMillis: now - 30 * _day,
      );
      expect(list, isEmpty);
    });

    test('neverLaunched is the candidate set minus anything ever recorded', () {
      final events = [ev('com.a', 200)];
      final never = UsageStats.neverLaunched(
        events,
        candidates: installed,
      );
      expect(never, {'com.b', 'com.c'});
    });

    test('range aggregates count only installed apps in the window', () {
      final events = [
        ev('com.a', 1),
        ev('com.a', 2),
        ev('com.b', 50),
        ev('com.ghost', 1),
      ];
      expect(
        UsageStats.launchesInRange(
          events,
          installed: installed,
          sinceMillis: now - 30 * _day,
        ),
        2,
      );
      expect(
        UsageStats.activeAppsInRange(
          events,
          installed: installed,
          sinceMillis: now - 30 * _day,
        ),
        1,
      );
      expect(
        UsageStats.neglectedCount(
          events,
          installed: installed,
          sinceMillis: now - 30 * _day,
        ),
        0,
      );
    });
  });

  group('AppState usage trends', () {
    AppState build() {
      final state = AppState(_MemStorage())
        ..initialized = true
        ..apps = [
          _ai('com.a', 'A', installedAt: 100),
          _ai('com.b', 'B', installedAt: 200),
          _ai('com.c', 'C', installedAt: 300),
        ];
      final t = DateTime.now();
      state.launchLog = [
        for (var i = 0; i < 5; i++)
          LaunchEvent(
            packageName: 'com.a',
            at: t.subtract(Duration(days: i + 1)).millisecondsSinceEpoch,
          ),
        for (var i = 0; i < 3; i++)
          LaunchEvent(
            packageName: 'com.b',
            at: t.subtract(Duration(days: 40 + i)).millisecondsSinceEpoch,
          ),
      ];
      return state;
    }

    test('mostUsedApps, neglectedApps and neverLaunchedApps', () {
      final state = build();
      expect(state.mostUsedApps(days: 30).single.packageName, 'com.a');
      expect(state.neglectedApps(days: 30).single.packageName, 'com.b');
      expect(
        state.neverLaunchedApps().map((a) => a.packageName).toList(),
        ['com.c'],
      );
      expect(state.launchesInDays(30), 5);
      expect(state.activeAppsInDays(30), 1);
      expect(state.neglectedCountInDays(30), 1);
    });

    test('neverLaunchedApps can include system apps', () {
      final state = AppState(_MemStorage())
        ..initialized = true
        ..apps = [
          _ai('com.sys', 'Sys', system: true),
          _ai('com.user', 'User'),
        ];
      expect(state.neverLaunchedApps().length, 1);
      expect(state.neverLaunchedApps(includeSystem: true).length, 2);
    });
  });

  group('UsageStatsScreen', () {
    testWidgets('renders the three trend sections', (tester) async {
      final state = AppState(_MemStorage())
        ..initialized = true
        ..apps = [
          _ai('com.a', 'A'),
          _ai('com.b', 'B'),
          _ai('com.c', 'C'),
        ];
      final t = DateTime.now();
      state.launchLog = [
        for (var i = 0; i < 5; i++)
          LaunchEvent(
            packageName: 'com.a',
            at: t.subtract(Duration(days: i + 1)).millisecondsSinceEpoch,
          ),
        for (var i = 0; i < 3; i++)
          LaunchEvent(
            packageName: 'com.b',
            at: t.subtract(Duration(days: 40 + i)).millisecondsSinceEpoch,
          ),
      ];

      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: const MaterialApp(home: UsageStatsScreen()),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('使用趋势'), findsOneWidget);
      expect(find.text('最常用'), findsOneWidget);
      expect(find.text('被冷落'), findsOneWidget);
      expect(find.text('从未启动'), findsOneWidget);
      expect(find.text('A'), findsWidgets);
      expect(find.text('C'), findsWidgets);
    });

    testWidgets('shows an empty hint without launch history', (tester) async {
      final state = AppState(_MemStorage())..initialized = true;
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: const MaterialApp(home: UsageStatsScreen()),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.textContaining('还没有启动记录'), findsOneWidget);
    });
  });
}