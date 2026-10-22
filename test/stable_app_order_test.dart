import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hamstapp/models/app_info.dart';
import 'package:hamstapp/widgets/stable_app_order.dart';

AppInfo _app(String pkg, String name) => AppInfo(
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
      targetSdk: 34,
      minSdk: 24,
      uid: 0,
    );

void main() {
  testWidgets('a launch does not reorder the apps already on screen', (
    tester,
  ) async {
    final a = _app('com.a', 'A');
    final b = _app('com.b', 'B');
    final c = _app('com.c', 'C');
    final d = _app('com.d', 'D');
    List<AppInfo>? shown;

    Widget build(List<AppInfo> apps, {int? limit}) => Directionality(
          textDirection: TextDirection.ltr,
          child: StableAppOrder(
            apps: apps,
            limit: limit,
            builder: (context, list) {
              shown = list;
              return const SizedBox.shrink();
            },
          ),
        );

    List<String> packages() =>
        [for (final app in shown!) app.packageName];

    await tester.pumpWidget(build([a, b, c]));
    expect(packages(), ['com.a', 'com.b', 'com.c']);

    // Using B would normally put it first; the visible order must not move.
    await tester.pumpWidget(build([b, a, c]));
    expect(packages(), ['com.a', 'com.b', 'com.c']);

    // A newly used app joins at the end, never in the middle.
    await tester.pumpWidget(build([d, b, a, c]));
    expect(packages(), ['com.a', 'com.b', 'com.c', 'com.d']);

    // Removing one keeps the others where they were.
    await tester.pumpWidget(build([b, c, d]));
    expect(packages(), ['com.b', 'com.c', 'com.d']);
  });

  testWidgets('the limit is applied after the stable order', (tester) async {
    final a = _app('com.a', 'A');
    final b = _app('com.b', 'B');
    final c = _app('com.c', 'C');
    final d = _app('com.d', 'D');
    List<AppInfo>? shown;

    Widget build(List<AppInfo> apps) => Directionality(
          textDirection: TextDirection.ltr,
          child: StableAppOrder(
            apps: apps,
            limit: 2,
            builder: (context, list) {
              shown = list;
              return const SizedBox.shrink();
            },
          ),
        );

    await tester.pumpWidget(build([a, b, c, d]));
    expect([for (final app in shown!) app.packageName], ['com.a', 'com.b']);

    // B is the newest now, but the two tiles on screen stay A and B.
    await tester.pumpWidget(build([b, a, c, d]));
    expect([for (final app in shown!) app.packageName], ['com.a', 'com.b']);
  });
}
