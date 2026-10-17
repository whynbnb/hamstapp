import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:hamstapp/l10n/app_strings.dart';
import 'package:hamstapp/models/app_info.dart';
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

AppInfo app(String pkg, String name, {int size = 0}) => AppInfo(
  packageName: pkg,
  appName: name,
  versionName: '1.0',
  versionCode: 1,
  firstInstallTime: 0,
  lastUpdateTime: 0,
  isSystem: false,
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
    ];

  testWidgets('a syntax chip stays open and filters the list', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final state = stateWith();
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: AppsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Big'), findsOneWidget);
    expect(find.text('Small'), findsOneWidget);

    // Focusing the field reveals the history/syntax panel.
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(find.text('筛选语法'), findsOneWidget);

    // Tapping a chip appends the filter and keeps the panel open, so a second
    // filter can be added without reopening the field.
    await tester.tap(find.text('size:>100m'));
    await tester.pumpAndSettle();
    expect(state.query, 'size:>100m');
    expect(find.text('筛选语法'), findsOneWidget);
    expect(find.text('Big'), findsOneWidget);
    expect(find.text('Small'), findsNothing);
  });

  testWidgets('a past search is one tap away', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final state = stateWith();
    await state.rememberQuery('Small');
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: AppsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(find.text('最近搜索'), findsOneWidget);

    // The app row is also called Small: tap the history chip itself.
    await tester.tap(find.widgetWithText(ActionChip, 'Small'));
    await tester.pumpAndSettle();
    expect(state.query, 'Small');
    expect(find.text('Big'), findsNothing);
  });
}
