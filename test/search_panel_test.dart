import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:hamstapp/l10n/app_strings.dart';
import 'package:hamstapp/models/app_info.dart';
import 'package:hamstapp/screens/app_finder_screen.dart';
import 'package:hamstapp/screens/apps_screen.dart';
import 'package:hamstapp/services/storage.dart';
import 'package:hamstapp/state/app_state.dart';

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
  bool system = false,
}) => AppInfo(
  packageName: pkg,
  appName: name,
  versionName: '1.0',
  versionCode: 1,
  firstInstallTime: 0,
  lastUpdateTime: 0,
  isSystem: system,
  enabled: true,
  apkPath: '',
  sizeBytes: size,
  targetSdk: 34,
  minSdk: 24,
  uid: 1,
);

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('hamstapp/apps'),
          (call) async => null,
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('hamstapp/apps'), null);
    AppStrings.current = const AppStrings('zh');
  });

  AppState stateWith() => AppState(_MemStorage())
    ..initialized = true
    ..apps = [
      app('com.big', 'Big', size: 300 * mb),
      app('com.small', 'Small', size: 1 * mb),
      app('com.sys', 'Sys', system: true),
    ];

  Future<void> pumpApps(WidgetTester tester, AppState state) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: AppsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a search applies to the list instead of living apart', (
    tester,
  ) async {
    final state = stateWith();
    await pumpApps(tester, state);
    expect(find.text('Big'), findsOneWidget);
    expect(find.text('Small'), findsOneWidget);

    await tester.tap(find.text('搜索应用名 / 包名 / 拼音首字母'));
    await tester.pumpAndSettle();
    expect(find.byType(AppFinderScreen), findsOneWidget);

    // Typing only updates the live count; the list is untouched so far.
    await tester.enterText(find.byType(TextField), 'size:>100m');
    await tester.pumpAndSettle();
    expect(find.text('应用筛选 · 1 个'), findsOneWidget);
    expect(state.query, '');

    await tester.tap(find.text('应用筛选 · 1 个'));
    await tester.pumpAndSettle();

    // Back on the list: the search is applied and visible in the bar.
    expect(find.byType(AppFinderScreen), findsNothing);
    expect(find.text('size:>100m'), findsOneWidget);
    expect(find.text('Big'), findsOneWidget);
    expect(find.text('Small'), findsNothing);

    // One tap on the bar's clear button restores the whole list.
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(state.query, '');
    expect(find.text('Small'), findsOneWidget);
    expect(find.text('Sys'), findsOneWidget);
  });

  testWidgets('the X clears only the search, 重置 clears everything', (
    tester,
  ) async {
    final state = stateWith();
    await pumpApps(tester, state);

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();

    // Type a search and pick a scope: the two conditions combine.
    await tester.enterText(find.byType(TextField), 'Small');
    await tester.pumpAndSettle();
    await tester.tap(find.text('系统应用'));
    await tester.pumpAndSettle();
    expect(find.text('应用筛选 · 0 个'), findsOneWidget);

    // The X next to the field drops the search and leaves the scope alone.
    await tester.tap(find.byTooltip('清除搜索'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '',
    );
    expect(find.text('应用筛选 · 1 个'), findsOneWidget);

    await tester.tap(find.text('应用筛选 · 1 个'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(state.scope, AppScope.system);
    expect(state.query, '');
    expect(find.text('Sys'), findsOneWidget);
    expect(find.text('Big'), findsNothing);
  });

  testWidgets('scope and filters sit on the same page as the search', (
    tester,
  ) async {
    final state = stateWith();
    await pumpApps(tester, state);

    // The filter button opens the same page, without focusing the field.
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.byType(AppFinderScreen), findsOneWidget);

    await tester.tap(find.text('系统应用'));
    await tester.pumpAndSettle();
    expect(find.text('应用筛选 · 1 个'), findsOneWidget);

    await tester.tap(find.text('应用筛选 · 1 个'));
    await tester.pumpAndSettle();
    expect(find.text('Sys'), findsOneWidget);
    expect(find.text('Big'), findsNothing);
    expect(find.text('Small'), findsNothing);

    // The active condition is shown, and 清除 removes it.
    expect(find.text('系统应用'), findsWidgets);
    await tester.tap(find.text('清除'));
    await tester.pumpAndSettle();
    expect(find.text('Big'), findsOneWidget);
    expect(find.text('Small'), findsOneWidget);
  });
}
