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
  test('remembers the filter and sort by default', () async {
    final storage = _MemStorage();
    final state = AppState(storage)..initialized = true;

    expect(state.rememberAppFilters, isTrue);
    state.scope = AppScope.user;
    state.filter = AppFilter.favorite;
    state.setAppSort(AppSort.size);
    state.setSortAscending(false);
    state.refresh();
    // The write is fire-and-forget.
    await Future<void>.delayed(Duration.zero);

    final saved = await storage.readJson('settings') as Map;
    expect(saved['app_filter_remember'], isTrue);
    expect(saved['app_scope'], 'user');
    expect(saved['app_filter'], 'favorite');
    expect(saved['app_sort'], 'size');
    expect(saved['app_sort_asc'], isFalse);
  });

  test('restores what was stored, including the category', () async {
    final state = AppState(_MemStorage())..initialized = true;
    state.settings = <String, dynamic>{
      'app_scope': 'system',
      'app_filter': 'categorized',
      'app_filter_category': 'c1',
      'app_sort': 'updateTime',
      'app_sort_asc': false,
    };

    state.restoreAppFilters();

    expect(state.rememberAppFilters, isTrue);
    expect(state.scope, AppScope.system);
    expect(state.filter, AppFilter.categorized);
    expect(state.filterCategoryId, 'c1');
    expect(state.sort, AppSort.updateTime);
    expect(state.sortAscending, isFalse);
  });

  test('leaves the list alone when remembering is off', () async {
    final state = AppState(_MemStorage())..initialized = true;
    state.settings = <String, dynamic>{
      'app_filter_remember': false,
      'app_scope': 'system',
      'app_sort': 'size',
    };
    state.scope = AppScope.user;
    state.sort = AppSort.installTime;

    state.restoreAppFilters();

    expect(state.rememberAppFilters, isFalse);
    // The stored values are still there, just not applied.
    expect(state.scope, AppScope.user);
    expect(state.sort, AppSort.installTime);

    // And nothing new is written while it is off.
    state.scope = AppScope.all;
    state.refresh();
    await Future<void>.delayed(Duration.zero);
    expect(state.settings['app_scope'], 'system');
  });

  test('turning it on stores the current choice right away', () async {
    final storage = _MemStorage();
    final state = AppState(storage)..initialized = true;
    state.scope = AppScope.system;
    state.sort = AppSort.size;
    state.rememberAppFilters = false;

    await state.setRememberAppFilters(true);

    final saved = await storage.readJson('settings') as Map;
    expect(saved['app_filter_remember'], isTrue);
    expect(saved['app_scope'], 'system');
    expect(saved['app_sort'], 'size');

    // Turning it off persists the flag only.
    await state.setRememberAppFilters(false);
    final after = await storage.readJson('settings') as Map;
    expect(after['app_filter_remember'], isFalse);
  });

  test('unknown stored names fall back to the defaults', () {
    final state = AppState(_MemStorage())..initialized = true;
    state.settings = <String, dynamic>{
      'app_scope': 'nonsense',
      'app_filter': '',
      'app_sort': 42,
      'app_filter_category': 7,
    };

    state.restoreAppFilters();

    expect(state.scope, AppScope.all);
    expect(state.filter, AppFilter.all);
    expect(state.sort, AppSort.name);
    expect(state.filterCategoryId, isNull);
  });
}
