import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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

Widget _harness({
  required bool active,
  required VoidCallback onOpen,
  required VoidCallback onLongPress,
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
}
