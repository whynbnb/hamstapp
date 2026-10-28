import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:hamstapp/models/app_info.dart';
import 'package:hamstapp/screens/home_screen.dart';
import 'package:hamstapp/screens/sync_screen.dart';
import 'package:hamstapp/services/storage.dart';
import 'package:hamstapp/state/app_state.dart';
import 'package:hamstapp/widgets/collapsed_nav.dart';

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

/// A collapsed-mode HomeScreen with [action] configured for the long press.
Future<AppState> _pumpCollapsed(
  WidgetTester tester,
  CollapsedNavLongPress action, {
  int lastLaunchTab = 1,
}) async {
  const channel = MethodChannel('hamstapp/apps');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async => null);
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  final state = AppState(_MemStorage())
    ..initialized = true
    ..apps = [_ai('com.a', 'A')]
    ..settings['nav_mode'] = 'collapsed'
    ..settings['collapsed_nav_long_press'] = action.name
    ..settings['last_launch_tab'] = lastLaunchTab;
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const MaterialApp(home: HomeScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return state;
}

Widget _harness({
  required bool active,
  required VoidCallback onOpen,
  required VoidCallback? onLongPress,
}) => MaterialApp(
  home: Scaffold(
    appBar: AppBar(
      leading: CollapsedNavScope(
        active: active,
        onOpen: onOpen,
        onLongPress: onLongPress,
        child: const CollapsedNavButton(),
      ),
    ),
    body: const SizedBox.shrink(),
  ),
);

void main() {
  test('legacy "floating" preference migrates to NavMode.collapsed', () async {
    final state = AppState(_MemStorage())..settings['nav_mode'] = 'floating';
    expect(state.navMode, NavMode.collapsed);

    // The new name round-trips through persistence.
    await state.setNavMode(NavMode.collapsed);
    expect(state.settings['nav_mode'], 'collapsed');
    expect(state.navMode, NavMode.collapsed);
  });

  test('resolvedNavMode keeps an explicit collapsed choice on any size', () {
    final state = AppState(_MemStorage())..settings['nav_mode'] = 'collapsed';
    expect(state.resolvedNavMode(400, 800), NavMode.collapsed);
    expect(state.resolvedNavMode(1200, 800), NavMode.collapsed);
  });

  testWidgets('collapsed nav button opens the panel on tap', (tester) async {
    var opened = 0;
    var longPressed = 0;
    await tester.pumpWidget(_harness(
      active: true,
      onOpen: () => opened++,
      onLongPress: () => longPressed++,
    ));

    await tester.tap(find.byType(CollapsedNavButton));
    await tester.pump();

    expect(opened, 1);
    expect(longPressed, 0);
  });

  testWidgets('long-pressing the collapsed nav button fires onLongPress', (
    tester,
  ) async {
    var opened = 0;
    var longPressed = 0;
    await tester.pumpWidget(_harness(
      active: true,
      onOpen: () => opened++,
      onLongPress: () => longPressed++,
    ));

    await tester.longPress(find.byType(CollapsedNavButton));
    await tester.pump();

    expect(longPressed, 1);
    expect(opened, 0);
  });

  testWidgets('the button is hidden when collapsed mode is inactive', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(
      active: false,
      onOpen: () {},
      onLongPress: () {},
    ));

    expect(find.byType(IconButton), findsNothing);
  });

  test('the collapsed long-press action defaults to Launch and persists', () async {
    final storage = _MemStorage();
    final state = AppState(storage);
    expect(state.collapsedNavLongPress, CollapsedNavLongPress.launch);

    await state.setCollapsedNavLongPress(CollapsedNavLongPress.appsSync);
    expect(state.settings['collapsed_nav_long_press'], 'appsSync');
    final saved = await storage.readJson('settings') as Map;
    expect(saved['collapsed_nav_long_press'], 'appsSync');
  });

  testWidgets('无 disables the collapsed long press', (tester) async {
    final state = await _pumpCollapsed(tester, CollapsedNavLongPress.none);

    await tester.longPress(find.byType(CollapsedNavButton).first);
    await tester.pumpAndSettle();

    expect(find.byType(SyncScreen), findsNothing);
    expect(state.lastHomeIndex, 0);
  });

  testWidgets('应用 and 设置 long presses switch tabs', (tester) async {
    var state = await _pumpCollapsed(tester, CollapsedNavLongPress.apps);
    await tester.longPress(find.byType(CollapsedNavButton).first);
    await tester.pumpAndSettle();
    expect(state.lastHomeIndex, 1);

    state = await _pumpCollapsed(tester, CollapsedNavLongPress.settings);
    await tester.longPress(find.byType(CollapsedNavButton).first);
    await tester.pumpAndSettle();
    expect(state.lastHomeIndex, 3);
  });

  testWidgets('应用-同步 opens the sync screen', (tester) async {
    final state = await _pumpCollapsed(
      tester,
      CollapsedNavLongPress.appsSync,
    );

    await tester.longPress(find.byType(CollapsedNavButton).first);
    await tester.pumpAndSettle();

    expect(state.lastHomeIndex, 1);
    expect(find.byType(SyncScreen), findsOneWidget);
  });

  testWidgets('启动-最近 and 启动-磁贴 pick that sub-tab', (tester) async {
    var state = await _pumpCollapsed(
      tester,
      CollapsedNavLongPress.launchRecent,
      lastLaunchTab: 1,
    );
    await tester.longPress(find.byType(CollapsedNavButton).first);
    await tester.pumpAndSettle();
    expect(state.lastHomeIndex, 0);
    expect(state.lastLaunchTab, 0);

    state = await _pumpCollapsed(
      tester,
      CollapsedNavLongPress.launchTiles,
      lastLaunchTab: 0,
    );
    await tester.longPress(find.byType(CollapsedNavButton).first);
    await tester.pumpAndSettle();
    expect(state.lastHomeIndex, 0);
    expect(state.lastLaunchTab, 1);
  });
}
