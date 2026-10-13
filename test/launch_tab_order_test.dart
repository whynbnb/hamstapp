import 'package:flutter_test/flutter_test.dart';

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
  // Kept in its own file: init() touches the global AppStrings language, which
  // would leak into the Chinese-label widget tests.
  test('a launch tab saved in the old order is migrated once', () async {
    final storage = _MemStorage();
    // The old order was 磁贴(0) / 分类(1) / 收藏(2) / 最近(3), so 3 meant 最近.
    await storage.writeJson('settings', <String, dynamic>{'last_launch_tab': 3});

    final state = AppState(storage);
    await state.init();

    expect(state.lastLaunchTab, 0, reason: 'old 最近(3) is now index 0');

    final saved =
        (await storage.readJson('settings') as Map).cast<String, dynamic>();
    expect(saved['last_launch_tab'], 0);
    expect(saved['launch_tab_order'], 'recent-left');
  });

  test('the migration is not applied twice', () async {
    final storage = _MemStorage();
    await storage.writeJson('settings', <String, dynamic>{
      'last_launch_tab': 0,
      'launch_tab_order': 'recent-left',
    });

    final state = AppState(storage);
    await state.init();

    // Already migrated: 0 stays 0 (最近), it is not shifted again.
    expect(state.lastLaunchTab, 0);
  });
}
