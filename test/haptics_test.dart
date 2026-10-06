import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:hamstapp/models/app_info.dart';
import 'package:hamstapp/models/tile_page.dart';
import 'package:hamstapp/screens/quick_launch_screen.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('hamstapp/apps');
  var vibrates = 0;

  setUp(() {
    vibrates = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'vibrate') vibrates++;
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('swiping launch sub-tabs vibrates while dragging', (tester) async {
    final state = AppState(_MemStorage())
      ..initialized = true
      ..apps = [_ai('com.a', 'A')];

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: QuickLaunchScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(vibrates, 0);

    // Drag the pager from the first sub-tab to the next one.
    await tester.drag(find.byType(TabBarView), const Offset(-500, 0));
    await tester.pump();

    expect(
      vibrates,
      greaterThan(0),
      reason: 'a sub-tab swipe should tick while dragging',
    );
  });

  testWidgets('tapping launch sub-tabs vibrates', (tester) async {
    final state = AppState(_MemStorage())
      ..initialized = true
      ..apps = [_ai('com.a', 'A')];

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: QuickLaunchScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.text('分类'));
    await tester.pump();

    expect(vibrates, greaterThan(0));
  });

  testWidgets('tapping a distant tile page chip vibrates only once', (
    tester,
  ) async {
    final state = AppState(_MemStorage())
      ..initialized = true
      ..apps = [_ai('com.a', 'A')]
      ..tilePages = [
        TilePage(id: 'p1', name: 'P1', createdAt: 0),
        TilePage(id: 'p2', name: 'P2', createdAt: 0),
        TilePage(id: 'p3', name: 'P3', createdAt: 0),
      ]
      ..currentTilePageIndex = 0;

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: QuickLaunchScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    vibrates = 0;
    // Jump from page 1 to page 3; the animation glides across page 2 but the
    // haptic must fire once, not once per page passed.
    await tester.tap(find.text('P3'));
    await tester.pumpAndSettle();

    expect(vibrates, 1);
    expect(state.currentTilePageIndex, 2);
  });

  testWidgets('swiping tile pages vibrates while dragging', (tester) async {
    final state = AppState(_MemStorage())
      ..initialized = true
      ..apps = [_ai('com.a', 'A')]
      ..tilePages = [
        TilePage(id: 'p1', name: 'P1', createdAt: 0),
        TilePage(id: 'p2', name: 'P2', createdAt: 0),
      ]
      ..currentTilePageIndex = 0;

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: QuickLaunchScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    // Swipe the tile board (the inner pager, the last PageView) to page 2.
    await tester.drag(find.byType(PageView).last, const Offset(-500, 0));
    await tester.pump();

    expect(vibrates, greaterThan(0));
  });

  testWidgets('a fast fling across several tile pages vibrates only once', (
    tester,
  ) async {
    final state = AppState(_MemStorage())
      ..initialized = true
      ..apps = [_ai('com.a', 'A')]
      ..tilePages = [
        TilePage(id: 'p1', name: 'P1', createdAt: 0),
        TilePage(id: 'p2', name: 'P2', createdAt: 0),
        TilePage(id: 'p3', name: 'P3', createdAt: 0),
        TilePage(id: 'p4', name: 'P4', createdAt: 0),
      ]
      ..currentTilePageIndex = 0;

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: QuickLaunchScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    vibrates = 0;
    // Fling hard enough to glide across several pages before it settles: the
    // whole action (drag + its fling) must buzz exactly once.
    await tester.fling(
      find.byType(PageView).last,
      const Offset(-2000, 0),
      8000,
    );
    await tester.pumpAndSettle();

    expect(vibrates, 1);
    expect(state.currentTilePageIndex, 3);
  });

  testWidgets('a fast fling across several launch sub-tabs vibrates once', (
    tester,
  ) async {
    final state = AppState(_MemStorage())
      ..initialized = true
      ..apps = [_ai('com.a', 'A')];

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: QuickLaunchScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    vibrates = 0;
    await tester.fling(find.byType(TabBarView), const Offset(-2000, 0), 8000);
    await tester.pumpAndSettle();

    expect(vibrates, 1);
  });

  testWidgets('a quick flick between launch sub-tabs ticks before settling', (
    tester,
  ) async {
    final state = AppState(_MemStorage())
      ..initialized = true
      ..apps = [_ai('com.a', 'A')];

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: QuickLaunchScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    vibrates = 0;
    await tester.fling(find.byType(TabBarView), const Offset(-400, 0), 2000);
    // A few frames in, while the settling animation is still running, the tick
    // must already have fired (over-half of the swipe should not wait for the
    // animation to finish).
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(vibrates, 1, reason: 'the flick should tick before the settle ends');

    await tester.pumpAndSettle();
    expect(vibrates, 1); // and never a second time
  });
}
