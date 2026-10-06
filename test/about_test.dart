import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:hamstapp/screens/settings_screen.dart';
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

void main() {
  testWidgets('about dialog shows version, MIT license and a GitHub link', (
    tester,
  ) async {
    const channel = MethodChannel('hamstapp/apps');
    final openedUrls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'openUrl') {
        openedUrls.add((call.arguments as Map)['url'] as String);
      }
      return null;
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    final state = AppState(_MemStorage())..initialized = true;
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // The old bottom "提示" section is gone.
    expect(find.textContaining('长按磁贴拖动'), findsNothing);

    // About is a tappable row that opens the info dialog.
    final about = find.text('囤囤 · Hamstapp');
    await tester.scrollUntilVisible(about, 300);
    await tester.pumpAndSettle();
    await tester.tap(about);
    await tester.pumpAndSettle();

    expect(find.text('版本 $kAppVersion'), findsOneWidget);
    expect(find.textContaining('MIT'), findsOneWidget);
    expect(find.text('github.com/whynbnb/hamstapp'), findsOneWidget);

    // The GitHub link is tappable and opens the project URL.
    await tester.tap(find.text('github.com/whynbnb/hamstapp'));
    await tester.pumpAndSettle();
    expect(openedUrls, [kProjectUrl]);
  });
}
