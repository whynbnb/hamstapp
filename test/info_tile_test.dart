import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:hamstapp/models/app_info.dart';
import 'package:hamstapp/models/tile.dart';
import 'package:hamstapp/models/tile_page.dart';
import 'package:hamstapp/screens/quick_launch_screen.dart';
import 'package:hamstapp/services/device_status.dart';
import 'package:hamstapp/services/storage.dart';
import 'package:hamstapp/state/app_state.dart';
import 'package:hamstapp/widgets/info_tile.dart';

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
  });
}

/// The info kinds, spelled out so a new one cannot be forgotten by the tests.
const List<TileKind> kTestInfoKinds = <TileKind>[
  TileKind.clock,
  TileKind.date,
  TileKind.battery,
  TileKind.storage,
  TileKind.unread,
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
