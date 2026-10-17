import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:hamstapp/l10n/app_strings.dart';
import 'package:hamstapp/models/app_info.dart';
import 'package:hamstapp/models/app_meta.dart';
import 'package:hamstapp/models/backup_list.dart';
import 'package:hamstapp/models/snapshot.dart';
import 'package:hamstapp/models/snapshot_diff.dart';
import 'package:hamstapp/models/tile.dart';
import 'package:hamstapp/models/tile_page.dart';
import 'package:hamstapp/screens/quick_launch_screen.dart';
import 'package:hamstapp/services/device_status.dart';
import 'package:hamstapp/services/storage.dart';
import 'package:hamstapp/state/app_state.dart';
import 'package:hamstapp/widgets/info_tile.dart';
import 'package:hamstapp/widgets/info_tile_sheets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Tile kinds', () {
    test('an unknown or missing kind means an app tile', () {
      final tile = Tile.fromMap({
        'id': 't1',
        'packageName': 'com.example',
        'pageId': 'p1',
      });
      expect(tile.kind, TileKind.app);
      expect(tile.isInfo, isFalse);
    });

    test('info tiles round-trip through the stored map', () {
      for (final kind in kTestInfoKinds) {
        final tile = Tile(
          id: 't-${kind.name}',
          packageName: '',
          pageId: 'p1',
          kind: kind,
        );
        final restored = Tile.fromMap(tile.toMap());
        expect(restored.kind, kind);
        expect(restored.isInfo, isTrue);
      }
    });

    test('per-tile options round-trip through the stored map', () {
      final tile = Tile(
        id: 'f1',
        packageName: '',
        pageId: 'p1',
        kind: TileKind.folder,
        options: {
          'category': 'c1',
          'apps': ['com.a', 'com.b'],
          'days': 30,
        },
      );
      final restored = Tile.fromMap(tile.toMap());
      expect(restored.optionString('category'), 'c1');
      expect(restored.optionList('apps'), ['com.a', 'com.b']);
      expect(restored.optionInt('days', 7), 30);
      expect(restored.optionInt('missing', 7), 7);
    });

    test('every info kind has a title, an icon and a size', () {
      for (final kind in kTestInfoKinds) {
        expect(infoTileTitle(kind), isNotEmpty);
        expect(infoTileSubtitle(kind), isNotEmpty);
        expect(infoTileIcon(kind), isNotNull);
        final (w, h) = kind.defaultSize;
        expect(w, greaterThanOrEqualTo(1));
        expect(h, greaterThanOrEqualTo(1));
      }
    });

    test('every action has a title and an icon', () {
      for (final action in kInfoTileActions) {
        expect(actionTitle(action), isNotEmpty);
        expect(actionIcon(action), isNotNull);
      }
    });

    test('a folder tile resolves a category or a hand-picked list', () {
      final state = AppState(_MemStorage())
        ..initialized = true
        ..apps = [
          AppInfo(
            packageName: 'com.a',
            appName: 'A',
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
          ),
          AppInfo(
            packageName: 'com.b',
            appName: 'B',
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
          ),
        ];
      final picked = Tile(
        id: 'f1',
        packageName: '',
        pageId: 'p1',
        kind: TileKind.folder,
        options: {
          'apps': ['com.b', 'com.gone'],
        },
      );
      // Only apps that are actually installed make it in.
      expect(folderApps(state, picked).map((a) => a.packageName), ['com.b']);
      expect(folderName(state, picked, const AppStrings('zh')), '自选应用');

      final byCategory = Tile(
        id: 'f2',
        packageName: '',
        pageId: 'p1',
        kind: TileKind.folder,
        options: {'category': 'c1'},
      );
      expect(folderApps(state, byCategory), isEmpty);
    });

    test('a tile of an unknown kind is kept and marked unsupported', () {
      final stored = Tile.fromMap({
        'id': 'gone',
        'packageName': '',
        'pageId': 'p1',
        'kind': 'update', // a kind this build no longer has
      });
      expect(stored.kind, TileKind.unknown);
      expect(stored.isInfo, isTrue, reason: 'it has no app behind it');

      // A legacy tile with no kind at all is still an app tile...
      final legacy = Tile.fromMap({
        'id': 't1',
        'packageName': 'com.a',
        'pageId': 'p1',
      });
      expect(legacy.kind, TileKind.app);

      // ...but an app tile that lost its package cannot show anything either.
      final empty = Tile.fromMap({
        'id': 't2',
        'packageName': '',
        'pageId': 'p1',
      });
      expect(empty.kind, TileKind.unknown);
    });

    test('the unorganized rule skips anything the user touched', () {
      expect(AppState.isUnorganized(AppMeta(packageName: 'a')), isTrue);
      expect(
        AppState.isUnorganized(
          AppMeta(packageName: 'a', categoryIds: const ['c1']),
        ),
        isFalse,
      );
      expect(
        AppState.isUnorganized(AppMeta(packageName: 'a', reason: 'r')),
        isFalse,
      );
      expect(
        AppState.isUnorganized(AppMeta(packageName: 'a', note: 'n')),
        isFalse,
      );
      expect(
        AppState.isUnorganized(AppMeta(packageName: 'a', favorite: true)),
        isFalse,
      );
      expect(
        AppState.isUnorganized(AppMeta(packageName: 'a', pinned: true)),
        isFalse,
      );
    });

    test('world clock labels fall back to the raw offset', () {
      expect(worldClockLabel(480), 'UTC+8');
      expect(worldClockLabel(-300), 'UTC-5');
      expect(worldClockLabel(330), 'UTC+5:30');
      expect(worldClockLabel(75), 'UTC+1:15');
    });

    test('the snapshot tile diffs the newest snapshot against now', () {
      final state = AppState(_MemStorage())
        ..initialized = true
        ..apps = [appOf('com.a', name: 'A', versionCode: 2),
          appOf('com.b', name: 'B'),];
      // One snapshot, taken before com.a was updated and com.b installed.
      state.snapshots = [
        Snapshot(
          id: 's1',
          name: '旧的',
          createdAt: DateTime.now()
              .subtract(const Duration(days: 3))
              .millisecondsSinceEpoch,
          entries: [
            SnapshotEntry(
              packageName: 'com.a',
              appName: 'A',
              versionName: '1.0',
              versionCode: 1,
              lastUpdateTime: 0,
              firstInstallTime: 0,
              isSystem: false,
              sizeBytes: 0,
            ),
          ],
        ),
      ];
      expect(state.latestSnapshot?.id, 's1');
      final diff = SnapshotDiff.between(
        state.latestSnapshot!,
        state.currentDeviceSnapshot(),
      );
      expect(diff.updated.map((d) => d.packageName), ['com.a']);
      expect(diff.added.map((d) => d.packageName), ['com.b']);
      expect(diff.removed, isEmpty);
    });

    test('a backup list reports what is installed and what is missing', () {
      final state = AppState(_MemStorage())
        ..initialized = true
        ..apps = [appOf('com.a', name: 'A')]
        ..backupLists = [
          BackupList(
            id: 'l1',
            name: '常用',
            createdAt: 0,
            updatedAt: 0,
          )..packageNames = ['com.a', 'com.gone'],
        ];
      expect(state.backupListCounts('l1'), (1, 1));
      expect(state.backupListCounts('nope'), (0, 0));
    });

    test('every info kind has a usable default size', () {
      for (final kind in kTestInfoKinds) {
        final (w, h) = kind.defaultSize;
        expect(w, greaterThanOrEqualTo(1));
        expect(h, greaterThanOrEqualTo(1));
      }
    });
  });

  test('a shortcut asks for a launch sub-tab exactly once', () {
    final state = AppState(_MemStorage())..initialized = true;
    expect(state.pendingLaunchTab, isNull);
    state.requestLaunchTab(1);
    expect(state.pendingLaunchTab, 1);
    expect(state.consumePendingLaunchTab(), 1);
    expect(state.consumePendingLaunchTab(), isNull);
  });

  group('Info tiles on the board', () {
    AppInfo app(String pkg, String name) => AppInfo(
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

    AppState board() => AppState(_MemStorage())
      ..initialized = true
      ..apps = [app('com.a', 'A')]
      ..tilePages = [TilePage(id: 'p1', name: 'P1', createdAt: 0)]
      ..currentTilePageIndex = 0;

    test('a page keeps its info tiles even though they have no app', () {
      final state = board();
      state.tiles.add(
        Tile(id: 'i1', packageName: '', pageId: 'p1', kind: TileKind.clock),
      );
      // An app tile whose app is gone is hidden...
      state.tiles.add(
        Tile(id: 't1', packageName: 'com.gone', pageId: 'p1'),
      );
      final shown = state.tilesOnPage(state.tilePages.first);
      expect(shown.map((t) => t.id), ['i1']);
    });

    testWidgets('an unsupported tile stays visible and can be removed', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('hamstapp/apps'),
        (call) async => null,
      );

      final state = board();
      state.tiles.add(
        Tile(
          id: 'gone',
          packageName: '',
          pageId: 'p1',
          kind: TileKind.unknown,
          col: 0,
          row: 0,
          w: 2,
          h: 1,
        ),
      );
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: const MaterialApp(home: QuickLaunchScreen()),
        ),
      );
      await tester.pumpAndSettle();

      // It keeps its place and says what it is, rather than disappearing.
      expect(find.text('不支持的小组件'), findsOneWidget);
      await tester.tap(find.text('不支持的小组件'));
      await tester.pumpAndSettle();
      expect(find.textContaining('已经不支持了'), findsOneWidget);

      // Removing is the user's decision, taken from the dialog.
      await tester.tap(find.text('移除'));
      await tester.pumpAndSettle();
      expect(state.tiles.where((t) => t.id == 'gone'), isEmpty);
      expect(find.text('不支持的小组件'), findsNothing);
    });

    testWidgets('adding one from the pin sheet shows it on the board', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('hamstapp/apps'),
        (call) async => null,
      );

      final state = board();
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: const MaterialApp(home: QuickLaunchScreen()),
        ),
      );
      await tester.pumpAndSettle();

      // Edit mode -> the pin sheet -> the info tile picker.
      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('置顶应用到磁贴'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加信息磁贴'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('时钟'));
      await tester.pumpAndSettle();

      final now = DateTime.now();
      final time = '${now.hour.toString().padLeft(2, '0')}:'
          '${now.minute.toString().padLeft(2, '0')}';
      expect(state.tilesOnPage(state.tilePages.first).single.kind,
          TileKind.clock);
      expect(find.byType(InfoTileContent), findsOneWidget);
      expect(find.text(time), findsOneWidget);
    });
  });

  group('Info tile content', () {
    const channel = MethodChannel('hamstapp/apps');

    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'deviceStatus') {
          return {
            'level': 42,
            'charging': true,
            'freeBytes': 25 * 1024 * 1024 * 1024,
            'totalBytes': 100 * 1024 * 1024 * 1024,
            'memTotalBytes': 16 * 1024 * 1024 * 1024,
            'memAvailBytes': 8 * 1024 * 1024 * 1024,
            'memLow': false,
            // 07:30 local time, tomorrow: the tile only shows the clock time.
            'alarmAt': DateTime(2026, 1, 2, 7, 30).millisecondsSinceEpoch,
          };
        }
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    Future<void> pumpTile(WidgetTester tester, TileKind kind) async {
      await DeviceStatusService.instance.refresh(force: true);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 200,
                height: 200,
                child: ColoredBox(
                  color: Colors.black,
                  child: InfoTileContent(
                    tile: Tile(
                      id: 'i1',
                      packageName: '',
                      pageId: 'p1',
                      kind: kind,
                    ),
                    foreground: Colors.white,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('the clock tile shows the current time', (tester) async {
      await pumpTile(tester, TileKind.clock);
      final now = DateTime.now();
      final hh = now.hour.toString().padLeft(2, '0');
      final mm = now.minute.toString().padLeft(2, '0');
      expect(find.text('$hh:$mm'), findsOneWidget);
    });

    testWidgets('the date tile shows the day of the month', (tester) async {
      await pumpTile(tester, TileKind.date);
      expect(find.text('${DateTime.now().day}'), findsOneWidget);
    });

    testWidgets('the battery tile reads the native status', (tester) async {
      await pumpTile(tester, TileKind.battery);
      expect(find.text('42%'), findsOneWidget);
      expect(find.byIcon(Icons.bolt), findsOneWidget);
    });

    testWidgets('the storage tile shows the used percentage', (tester) async {
      await pumpTile(tester, TileKind.storage);
      expect(find.text('75%'), findsOneWidget);
    });

    testWidgets('the unread tile shows the total and no-apps state', (
      tester,
    ) async {
      await pumpTile(tester, TileKind.unread);
      expect(find.text('0'), findsOneWidget);
      expect(find.text('没有未读'), findsOneWidget);
    });

    testWidgets('the memory tile reads the native status', (tester) async {
      await pumpTile(tester, TileKind.memory);
      // 8 of 16 GiB used.
      expect(find.text('50%'), findsOneWidget);
    });

    testWidgets('the alarm tile shows the next alarm time', (tester) async {
      await pumpTile(tester, TileKind.alarm);
      expect(find.text('07:30'), findsOneWidget);
    });

    testWidgets('an unsupported tile says so instead of vanishing', (
      tester,
    ) async {
      await pumpTile(tester, TileKind.unknown);
      expect(find.text('不支持的小组件'), findsOneWidget);
      expect(find.text('点一下可移除'), findsOneWidget);
    });

    testWidgets('every info kind renders without throwing', (tester) async {
      for (final kind in kTestInfoKinds) {
        await pumpTile(tester, kind);
        expect(
          tester.takeException(),
          isNull,
          reason: 'rendering ${kind.name} must not throw',
        );
        expect(find.byType(InfoTileContent), findsOneWidget);
      }
    });
  });
}

/// A minimal installed app for the tile tests.
AppInfo appOf(String pkg, {String name = '', int versionCode = 1}) => AppInfo(
  packageName: pkg,
  appName: name.isEmpty ? pkg : name,
  versionName: '$versionCode.0',
  versionCode: versionCode,
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

/// The info kinds, spelled out so a new one cannot be forgotten by the tests.
const List<TileKind> kTestInfoKinds = <TileKind>[
  TileKind.clock,
  TileKind.date,
  TileKind.battery,
  TileKind.storage,
  TileKind.memory,
  TileKind.screenTime,
  TileKind.traffic,
  TileKind.alarm,
  TileKind.unread,
  TileKind.recent,
  TileKind.frequent,
  TileKind.newApps,
  TileKind.neglected,
  TileKind.folder,
  TileKind.action,
];

class _MemStorage implements Storage {
  final Map<String, dynamic> _data = <String, dynamic>{};
  @override
  Future<dynamic> readJson(String name) async => _data[name];
  @override
  Future<void> writeJson(String name, dynamic data) async {
    _data[name] = data;
  }
}
