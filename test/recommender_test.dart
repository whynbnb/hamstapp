import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:hamstapp/l10n/app_strings.dart';
import 'package:hamstapp/models/app_info.dart';
import 'package:hamstapp/models/launch_event.dart';
import 'package:hamstapp/models/tile_page.dart';
import 'package:hamstapp/screens/quick_launch_screen.dart';
import 'package:hamstapp/services/storage.dart';
import 'package:hamstapp/state/app_state.dart';
import 'package:hamstapp/utils/recommender.dart';

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

LaunchEvent _ev(String pkg, DateTime at) =>
    LaunchEvent(packageName: pkg, at: at.millisecondsSinceEpoch);

void _add(
  List<LaunchEvent> out,
  String pkg,
  List<DateTime> days,
  int hour,
  int minute,
) {
  for (final d in days) {
    out.add(_ev(pkg, DateTime(d.year, d.month, d.day, hour, minute)));
  }
}

void main() {
  // Some tests call init(), which applies the device language; pin Chinese so
  // the Recent-tab assertions below are stable.
  setUp(() => AppStrings.current = const AppStrings('zh'));

  // 2026-01-15 is a Thursday; 01-12/13/14 are Mon/Tue/Wed.
  final days = <DateTime>[
    DateTime(2026, 1, 12),
    DateTime(2026, 1, 13),
    DateTime(2026, 1, 14),
    DateTime(2026, 1, 15),
  ];
  final now8 = DateTime(2026, 1, 15, 8, 0);

  group('Recommender', () {
    test('smooths across a time boundary instead of bucketing', () {
      final events = <LaunchEvent>[];
      // 'a' is split 07:55 / 08:05, the classic "half and half" routine.
      _add(events, 'com.a', days.sublist(0, 4), 7, 55);
      _add(events, 'com.a', days.sublist(0, 3), 8, 5);
      // 'b' sits entirely in a single 08:30 slot.
      _add(events, 'com.b', days.sublist(0, 3), 8, 30);
      // 'c' is a different time of day and must not show up.
      _add(events, 'com.c', days.sublist(0, 4), 15, 0);

      final recs = Recommender.recommend(
        events,
        nowMillis: now8.millisecondsSinceEpoch,
      );
      final names = recs.map((r) => r.packageName).toList();
      expect(names.first, 'com.a');
      expect(names, contains('com.b'));
      expect(names, isNot(contains('com.c')));

      final a = recs.firstWhere((r) => r.packageName == 'com.a');
      final b = recs.firstWhere((r) => r.packageName == 'com.b');
      expect(a.score, greaterThan(b.score));
      // Representative time sits between the two halves.
      expect(a.typicalMinute, inInclusiveRange(7 * 60 + 50, 8 * 60 + 10));
    });

    test('ignores apps without enough history', () {
      final events = <LaunchEvent>[];
      _add(events, 'com.once', <DateTime>[DateTime(2026, 1, 14)], 8, 0);
      final recs = Recommender.recommend(
        events,
        nowMillis: now8.millisecondsSinceEpoch,
      );
      expect(recs, isEmpty);
    });

    test('same-day repeated launches can already be recommended', () {
      final events = <LaunchEvent>[
        _ev('com.a', DateTime(2026, 1, 15, 7, 55)),
        _ev('com.a', DateTime(2026, 1, 15, 7, 58)),
        _ev('com.a', DateTime(2026, 1, 15, 7, 59)),
      ];
      final recs = Recommender.recommend(
        events,
        nowMillis: now8.millisecondsSinceEpoch,
      );
      expect(recs.map((r) => r.packageName), contains('com.a'));
    });

    test('prefers recent habits over stale ones', () {
      final events = <LaunchEvent>[];
      _add(events, 'com.recent', days, 8, 0);
      _add(events, 'com.old', <DateTime>[
        DateTime(2025, 10, 7),
        DateTime(2025, 10, 11),
        DateTime(2025, 10, 15),
        DateTime(2025, 10, 19),
      ], 8, 0);

      final recs = Recommender.recommend(
        events,
        nowMillis: now8.millisecondsSinceEpoch,
      );
      expect(recs.first.packageName, 'com.recent');
    });

    test('caps the number of suggestions', () {
      final events = <LaunchEvent>[];
      for (var i = 0; i < 12; i++) {
        _add(events, 'com.app$i', days, 8, 0);
      }
      final recs = Recommender.recommend(
        events,
        nowMillis: now8.millisecondsSinceEpoch,
      );
      expect(recs.length, 8);
    });

    test('separates workday routines from weekend ones', () {
      final events = <LaunchEvent>[];
      _add(events, 'com.work', <DateTime>[
        DateTime(2026, 1, 12),
        DateTime(2026, 1, 13),
        DateTime(2026, 1, 14),
      ], 8, 0);
      _add(events, 'com.weekend', <DateTime>[
        DateTime(2026, 1, 3),
        DateTime(2026, 1, 4),
        DateTime(2026, 1, 10),
        DateTime(2026, 1, 11),
      ], 8, 0);

      final recs = Recommender.recommend(
        events,
        nowMillis: now8.millisecondsSinceEpoch,
      );
      expect(recs.first.packageName, 'com.work');
    });
  });

  group('AppState launch log', () {
    test('markLaunched records timestamped events and round-trips', () async {
      final storage = _MemStorage();
      final state = AppState(storage);
      final t = DateTime.now().subtract(const Duration(hours: 2));
      await state.markLaunched('com.a', at: t);
      await state.markLaunched('com.a', at: t.add(const Duration(minutes: 1)));

      expect(state.launchLog.length, 2);
      expect(state.launchLog.first.packageName, 'com.a');
      expect(state.launchLog.first.at, t.millisecondsSinceEpoch);
      expect(state.metaFor('com.a').launchCount, 2);

      final reloaded = AppState(storage);
      await reloaded.init();
      expect(reloaded.launchLog.length, 2);
    });

    test('recommendedApps only uses installed apps with enough history',
        () async {
      final now = DateTime.now();
      final minute = now.hour * 60 + now.minute;
      final state = AppState(_MemStorage())..apps = [_ai('com.a', 'A')];
      for (var d = 1; d <= 4; d++) {
        await state.markLaunched(
          'com.a',
          at: DateTime(now.year, now.month, now.day - d)
              .add(Duration(minutes: minute)),
        );
      }
      await state.markLaunched('com.ghost', at: now);

      final recs = state.recommendedApps(now: now);
      final names = recs.map((r) => r.packageName).toList();
      expect(names, contains('com.a'));
      expect(names, isNot(contains('com.ghost')));
    });

    test('recommendations can be turned off and persist', () async {
      final storage = _MemStorage();
      final state = AppState(storage);
      expect(state.recommendationsEnabled, isTrue);
      await state.setRecommendationsEnabled(false);
      expect(state.recommendationsEnabled, isFalse);

      final reloaded = AppState(storage);
      await reloaded.init();
      expect(reloaded.recommendationsEnabled, isFalse);
    });

    test('clearLaunchHistory empties the log and counts', () async {
      final state = AppState(_MemStorage());
      await state.markLaunched('com.a');
      expect(state.launchLog, isNotEmpty);
      await state.clearLaunchHistory();
      expect(state.launchLog, isEmpty);
      expect(state.metaFor('com.a').launchCount, 0);
      expect(state.metaFor('com.a').lastLaunchedAt, 0);
    });

    test('export/import carries the launch log', () async {
      final state = AppState(_MemStorage());
      await state.markLaunched(
        'com.a',
        at: DateTime.now().subtract(const Duration(hours: 1)),
      );
      final fresh = AppState(_MemStorage());
      await fresh.importPackage(state.exportPackage());
      expect(fresh.launchLog.length, 1);
      expect(fresh.launchLog.single.packageName, 'com.a');
    });
  });

  group('Recent tab', () {
    AppState buildState({required bool enabled}) {
      final now = DateTime.now();
      final minute = now.hour * 60 + now.minute;
      final log = <LaunchEvent>[
        for (var d = 1; d <= 4; d++)
          LaunchEvent(
            packageName: 'com.bike',
            at: DateTime(now.year, now.month, now.day - d)
                .add(Duration(minutes: minute))
                .millisecondsSinceEpoch,
          ),
      ];
      return AppState(_MemStorage())
        ..initialized = true
        ..apps = [_ai('com.bike', 'Bike')]
        ..launchLog = log
        ..tilePages = [TilePage(id: 'p1', name: 'P1', createdAt: 0)]
        ..currentTilePageIndex = 0
        ..settings = {
          'remember_position': true,
          'last_launch_tab': 3,
          'recent_recommendations': enabled,
        };
    }

    testWidgets('shows a recommendation section at the top', (tester) async {
      final state = buildState(enabled: true);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: const MaterialApp(home: QuickLaunchScreen()),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('推荐'), findsOneWidget);
      expect(find.textContaining('Bike'), findsWidgets);
    });

    testWidgets('hides the section when disabled', (tester) async {
      final state = buildState(enabled: false);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: const MaterialApp(home: QuickLaunchScreen()),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('推荐'), findsNothing);
    });
  });
}
