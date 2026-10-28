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

  Finder pageField() => find.descendant(
    of: find.byType(AppFinderScreen),
    matching: find.byType(TextField),
  );

  testWidgets('quick search filters as you type; 高级 keeps the rest', (
    tester,
  ) async {
    final state = stateWith();
    await pumpApps(tester, state);

    // The field is just labelled 快速搜索; the explanation lives in the
    // magnifier's long-press tooltip and no hint line is drawn.
    expect(find.text('快速搜索'), findsOneWidget);
    expect(
      tester
          .widgetList<Tooltip>(find.byType(Tooltip))
          .any(
            (t) =>
                t.message == '输入即筛选；组合范围、状态、分类与排序用「高级」',
          ),
      isTrue,
    );
    expect(
      find.text('输入即筛选；组合范围、状态、分类与排序用「高级」'),
      findsNothing,
    );
    expect(find.text('Big'), findsOneWidget);
    expect(find.text('Small'), findsOneWidget);

    // Typing filters straight away, no page involved.
    await tester.enterText(find.byType(TextField), 'size:>100m');
    await tester.pumpAndSettle();
    expect(state.query, 'size:>100m');
    expect(find.byType(AppFinderScreen), findsNothing);
    expect(find.text('Big'), findsOneWidget);
    expect(find.text('Small'), findsNothing);

    // 高级 opens the full page with the same search already in its field.
    await tester.tap(find.text('高级'));
    await tester.pumpAndSettle();
    expect(find.byType(AppFinderScreen), findsOneWidget);
    expect(tester.widget<TextField>(pageField()).controller?.text, 'size:>100m');
    expect(find.text('应用筛选 · 1 个'), findsOneWidget);

    // Leaving without applying changes nothing.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Big'), findsOneWidget);
    expect(find.text('Small'), findsNothing);

    // The field's own × clears just the quick search.
    await tester.tap(find.byIcon(Icons.clear));
    await tester.pumpAndSettle();
    expect(state.query, '');
    expect(find.text('Small'), findsOneWidget);
  });

  testWidgets('conditions chosen on the advanced page come back to the list', (
    tester,
  ) async {
    final state = stateWith();
    await pumpApps(tester, state);

    await tester.tap(find.text('高级'));
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

    // The condition is visible and 清除 drops it.
    expect(find.text('系统应用'), findsWidgets);
    await tester.tap(find.text('清除'));
    await tester.pumpAndSettle();
    expect(find.text('Big'), findsOneWidget);
    expect(find.text('Small'), findsOneWidget);
  });

  testWidgets('the advanced page X clears only its search', (tester) async {
    final state = stateWith();
    await pumpApps(tester, state);

    await tester.tap(find.text('高级'));
    await tester.pumpAndSettle();

    // Type a search and pick a scope: the two conditions combine.
    await tester.enterText(pageField(), 'Small');
    await tester.pumpAndSettle();
    await tester.tap(find.text('系统应用'));
    await tester.pumpAndSettle();
    expect(find.text('应用筛选 · 0 个'), findsOneWidget);

    // The X next to the field drops the search and leaves the scope alone.
    await tester.tap(find.byTooltip('清除搜索'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(pageField()).controller?.text, '');
    expect(find.text('应用筛选 · 1 个'), findsOneWidget);

    await tester.tap(find.text('应用筛选 · 1 个'));
    await tester.pumpAndSettle();
    expect(state.scope, AppScope.system);
    expect(state.query, '');
    expect(find.text('Sys'), findsOneWidget);
    expect(find.text('Big'), findsNothing);
  });
}
