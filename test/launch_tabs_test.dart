import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:hamstapp/models/app_info.dart';
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
  testWidgets('switching to a "behind" tab slides forward through the loop', (
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
    await tester.pumpAndSettle();

    // The launch pager is the outer PageView (the tile board's own pager is
    // nested inside it, so it comes later in the tree).
    PageController pager() =>
        tester.widget<PageView>(find.byType(PageView).first).controller!;

    final before = pager().page!;
    expect(before % 4, 0, reason: 'starts on 磁贴');

    // 最近 sits three tabs "behind" 磁贴; it must glide forward through 分类
    // and 收藏 instead of jumping back the short way.
    await tester.tap(
      find.descendant(of: find.byType(TabBar), matching: find.text('最近')),
    );
    await tester.pump(); // kick off the animation
    await tester.pump(const Duration(milliseconds: 120)); // mid-flight

    expect(
      pager().page!,
      greaterThan(before),
      reason: 'the pager should move forward, not backwards to the nearest tab',
    );

    await tester.pumpAndSettle();
    expect(pager().page!.round() % 4, 3, reason: 'settles on 最近');
  });
}
