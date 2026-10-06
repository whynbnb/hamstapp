import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:hamstapp/l10n/app_strings.dart';
import 'package:hamstapp/models/app_info.dart';
import 'package:hamstapp/models/app_meta.dart';
import 'package:hamstapp/models/remote_source.dart';
import 'package:hamstapp/models/category.dart';
import 'package:hamstapp/models/snapshot.dart';
import 'package:hamstapp/models/snapshot_diff.dart';
import 'package:hamstapp/models/tile.dart';
import 'package:hamstapp/models/tile_page.dart';
import 'package:hamstapp/services/remote_client.dart';
import 'package:hamstapp/services/storage.dart';
import 'package:hamstapp/state/app_state.dart';
import 'package:hamstapp/utils/search.dart';
import 'package:hamstapp/utils/tile_layout.dart';

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

SnapshotEntry _e(String pkg, String ver, int code) => SnapshotEntry(
  packageName: pkg,
  appName: pkg,
  versionName: ver,
  versionCode: code,
  lastUpdateTime: 0,
  firstInstallTime: 0,
  isSystem: false,
  sizeBytes: 0,
);

void main() {
  test('snapshot diff detects added, removed and updated apps', () {
    final older = Snapshot(
      id: 'a',
      name: 'older',
      createdAt: 0,
      entries: [
        _e('com.a', '1.0', 1),
        _e('com.b', '1.0', 1),
        _e('com.c', '1.0', 1),
      ],
    );
    final newer = Snapshot(
      id: 'b',
      name: 'newer',
      createdAt: 1,
      entries: [
        _e('com.a', '1.0', 1),
        _e('com.b', '2.0', 2),
        _e('com.d', '1.0', 1),
      ],
    );

    final diff = SnapshotDiff.between(older, newer);

    expect(diff.added.map((e) => e.packageName), contains('com.d'));
    expect(diff.removed.map((e) => e.packageName), contains('com.c'));
    expect(diff.updated.map((e) => e.packageName), contains('com.b'));
    expect(diff.unchanged.map((e) => e.packageName), contains('com.a'));
    expect(diff.changedCount, 3);
  });

  test('AppMeta round-trips uninstall fields', () {
    final meta = AppMeta(
      packageName: 'com.example',
      lastKnownName: '示例',
      uninstallReason: '太占空间',
      uninstalledAt: 123456789,
      lastLaunchedAt: 999,
      tilePageId: 'page-1',
    );
    final restored = AppMeta.fromMap(meta.toMap());
    expect(restored.isUninstalled, isTrue);
    expect(restored.lastKnownName, '示例');
    expect(restored.uninstallReason, '太占空间');
    expect(restored.uninstalledAt, 123456789);
    expect(restored.lastLaunchedAt, 999);
    expect(restored.tilePageId, 'page-1');
    expect(restored.hasUserData, isTrue);
  });

  test('snapshot round-trips full annotation data', () {
    final snapshot = Snapshot(
      id: 's1',
      name: '完整快照',
      createdAt: 1000,
      categories: [AppCategory(id: 'c1', name: '工具', emoji: '🛠️')],
      entries: [
        const SnapshotEntry(
          packageName: 'com.a',
          appName: 'A',
          versionName: '1.0',
          versionCode: 1,
          lastUpdateTime: 0,
          firstInstallTime: 0,
          isSystem: false,
          sizeBytes: 0,
          reason: '薅羊毛',
          note: '备注内容',
          categoryIds: ['c1'],
          favorite: true,
          pinned: true,
        ),
        const SnapshotEntry(
          packageName: 'com.gone',
          appName: 'Gone',
          versionName: '',
          versionCode: 0,
          lastUpdateTime: 0,
          firstInstallTime: 0,
          isSystem: false,
          sizeBytes: 0,
          uninstallReason: '不好用',
          uninstalledAt: 2000,
        ),
      ],
    );

    final restored = Snapshot.fromMap(snapshot.toMap());
    final a = restored.entries.firstWhere((e) => e.packageName == 'com.a');
    expect(a.reason, '薅羊毛');
    expect(a.note, '备注内容');
    expect(a.categoryIds, ['c1']);
    expect(a.favorite, isTrue);
    expect(a.isInstalled, isTrue);

    final gone = restored.entries.firstWhere(
      (e) => e.packageName == 'com.gone',
    );
    expect(gone.uninstallReason, '不好用');
    expect(gone.isInstalled, isFalse);
    expect(restored.installedCount, 1);
    expect(restored.uninstalledCount, 1);
    expect(restored.categories.single.name, '工具');
  });

  test('uninstalled snapshot entries are not treated as removed again', () {
    final older = Snapshot(
      id: 'a',
      name: 'older',
      createdAt: 0,
      entries: [_e('com.a', '1.0', 1)],
    );
    // com.a is now recorded as uninstalled in the newer snapshot.
    final newer = Snapshot(
      id: 'b',
      name: 'newer',
      createdAt: 1,
      entries: [
        const SnapshotEntry(
          packageName: 'com.a',
          appName: 'A',
          versionName: '1.0',
          versionCode: 1,
          lastUpdateTime: 0,
          firstInstallTime: 0,
          isSystem: false,
          sizeBytes: 0,
          uninstallReason: '不好用',
          uninstalledAt: 5,
        ),
      ],
    );

    final diff = SnapshotDiff.between(older, newer);
    expect(diff.removed.map((e) => e.packageName), contains('com.a'));
    expect(diff.added, isEmpty);
  });

  test('tile layout packs six per row', () {
    final specs = List.generate(7, (i) => TileSpec(id: 'a$i'));
    final res = resolveTileLayout(specs);
    expect(res.rows, 2);
    expect(res.placements['a0']!.col, 0);
    expect(res.placements['a5']!.col, 5);
    expect(res.placements['a6']!.row, 1);
    expect(res.placements['a6']!.col, 0);
  });

  test('tile layout honours stored positions', () {
    final res = resolveTileLayout([
      const TileSpec(id: 'x', col: 3, row: 2, w: 2, h: 2),
      const TileSpec(id: 'y'),
    ]);
    expect(res.placements['x']!.col, 3);
    expect(res.placements['x']!.row, 2);
    expect(res.rows, 4);
    expect(res.placements['y']!.col, 0);
    expect(res.placements['y']!.row, 0);
  });

  test('tile layout supports 4x4 and 1x3 sizes', () {
    final res = resolveTileLayout([
      const TileSpec(id: 'big', w: 4, h: 4),
      const TileSpec(id: 'tall', w: 1, h: 3),
    ]);
    expect(res.placements['big']!.w, 4);
    expect(res.placements['big']!.h, 4);
    expect(res.rows, 4);
    expect(res.placements['tall']!.col, 4);
    expect(res.placements['tall']!.row, 0);
  });

  test('resolveMove finds nearest free spot on collision', () {
    final others = [const TileSpec(id: 'o', col: 0, row: 0, w: 2, h: 2)];
    final p = resolveMove(others, 'n', 0, 0, 2, 2);
    expect(p.col, 2);
    expect(p.row, 0);
  });

  test('tile columns adapt to screen width', () {
    expect(tileColumnsForWidth(360), 6); // phone: unchanged
    expect(tileColumnsForWidth(411), 6);
    expect(tileColumnsForWidth(600), 8); // tablet portrait
    expect(tileColumnsForWidth(800), 11);
    expect(tileColumnsForWidth(1280), kTileMaxCols); // capped
    expect(tileColumnsForWidth(2000), kTileMaxCols);
    expect(tileColumnsForWidth(0), 6);
  });

  test('rotating to fewer columns re-packs without losing the stored spot', () {
    const specs = [TileSpec(id: 'a', w: 2, h: 2, col: 10, row: 0)];
    // Wide (tablet landscape): stored spot fits.
    expect(resolveTileLayout(specs, cols: 12).placements['a']!.col, 10);
    // Narrow (tablet portrait / phone): does not fit, so it is auto-packed.
    expect(resolveTileLayout(specs, cols: 6).placements['a']!.col, 0);
    // The original spec is untouched, so rotating back restores the spot.
    expect(resolveTileLayout(specs, cols: 12).placements['a']!.col, 10);
  });

  test('moveTile respects the adaptive column count', () async {
    final state = AppState(_MemStorage());
    state.tilePages = [TilePage(id: 'p1', name: 'P1', createdAt: 0)];
    state.apps = [_ai('com.x', 'X')];
    final t = await state.addTile('com.x');

    // A wide board allows far-right placement...
    await state.moveTile(t.id, 10, 0, cols: 12);
    expect(state.tileById(t.id)!.col, 10);
    // ...while a narrow board clamps it into the visible range.
    await state.moveTile(t.id, 10, 0, cols: 6);
    expect(state.tileById(t.id)!.col, 4);
  });

  test('unorganized filter also excludes favorites and tiled apps', () async {
    final state = AppState(_MemStorage());
    state.tilePages = [TilePage(id: 'p1', name: 'P1', createdAt: 0)];
    state.apps = [
      _ai('com.plain', 'Plain'),
      _ai('com.fav', 'Fav'),
      _ai('com.tiled', 'Tiled'),
      _ai('com.cat', 'Cat'),
      _ai('com.reason', 'Reason'),
    ];
    state.metaFor('com.fav').favorite = true;
    state.metaFor('com.cat').categoryIds = ['c1'];
    state.metaFor('com.reason').reason = 'because';
    await state.addTile('com.tiled'); // pins it to a tile

    state.filter = AppFilter.unorganized;
    final remaining = state.visibleApps.map((a) => a.packageName).toSet();
    expect(remaining, {'com.plain'});
  });

  test('category list can be sorted by name or app count', () async {
    final state = AppState(_MemStorage());
    state.apps = [_ai('com.1', 'A'), _ai('com.2', 'B'), _ai('com.3', 'C')];
    final tools = await state.addCategory('工具');
    final games = await state.addCategory('游戏');
    await state.addCategory('阅读'); // no apps

    state.metaFor('com.1').categoryIds = [tools.id];
    state.metaFor('com.2').categoryIds = [games.id];
    state.metaFor('com.3').categoryIds = [games.id];

    await state.setCategorySort(CategorySort.name);
    expect(
      state.sortedCategories.map((c) => c.name).toList(),
      ['工具', '游戏', '阅读'], // gongju < youxi < yuedu
    );

    await state.setCategorySort(CategorySort.count);
    expect(
      state.sortedCategories.map((c) => c.name).toList(),
      ['游戏', '工具', '阅读'], // 2, 1, 0 apps
    );
  });

  test('moveCategory reorders in manual mode', () async {
    final state = AppState(_MemStorage());
    await state.addCategory('A');
    await state.addCategory('B');
    await state.addCategory('C');

    // onReorderItem semantics: newIndex is already adjusted after removal.
    await state.moveCategory(0, 2);
    expect(state.categories.map((c) => c.name).toList(), ['B', 'C', 'A']);

    await state.moveCategory(2, 0);
    expect(state.categories.map((c) => c.name).toList(), ['A', 'B', 'C']);
  });

  test('addTile pins to the current page and allows duplicates', () async {
    final state = AppState(_MemStorage());
    state.tilePages = [
      TilePage(id: 'p1', name: 'P1', createdAt: 0),
      TilePage(id: 'p2', name: 'P2', createdAt: 0),
    ];
    state.apps = [_ai('com.x', 'X')];
    state.currentTilePageIndex = 1;

    final t1 = await state.addTile('com.x');
    final t2 = await state.addTile('com.x');

    expect(t1.pageId, 'p2');
    expect(t2.pageId, 'p2');
    expect(t1.id, isNot(t2.id));
    expect(state.metaFor('com.x').pinned, isTrue);
    expect(state.pinCountOnPage(state.tilePages[0]), 0);
    expect(state.pinCountOnPage(state.tilePages[1]), 2);
  });

  test('new tiles default to 2x2 and follow the setting', () async {
    final state = AppState(_MemStorage());
    state.tilePages = [TilePage(id: 'p1', name: 'P1', createdAt: 0)];
    state.apps = [_ai('com.x', 'X')];

    final t = await state.addTile('com.x');
    expect(t.w, 2);
    expect(t.h, 2);

    await state.setTileDefaultSize(3);
    final t2 = await state.addTile('com.x');
    expect(t2.w, 3);
    expect(t2.h, 3);
  });

  test('nav mode auto picks rail on tablet landscape only', () async {
    final state = AppState(_MemStorage());
    expect(state.navMode, NavMode.auto);
    // Phone portrait / landscape and tablet portrait -> bottom bar.
    expect(state.resolvedNavMode(400, 800), NavMode.bottom);
    expect(state.resolvedNavMode(800, 400), NavMode.bottom);
    expect(state.resolvedNavMode(800, 1200), NavMode.bottom);
    // Tablet landscape -> side rail.
    expect(state.resolvedNavMode(1200, 800), NavMode.rail);

    // An explicit choice overrides the device, including forcing bottom on a
    // tablet landscape.
    await state.setNavMode(NavMode.bottom);
    expect(state.resolvedNavMode(1200, 800), NavMode.bottom);
    await state.setNavMode(NavMode.rail);
    expect(state.resolvedNavMode(400, 800), NavMode.rail);
    expect(state.navMode, NavMode.rail);
  });

  test('app sort supports ascending and descending order', () async {
    AppInfo mk(String pkg, String name, int size, int time) => AppInfo(
      packageName: pkg,
      appName: name,
      versionName: '1',
      versionCode: 1,
      firstInstallTime: time,
      lastUpdateTime: time,
      isSystem: false,
      enabled: true,
      apkPath: '',
      sizeBytes: size,
      targetSdk: 33,
      minSdk: 21,
      uid: 0,
    );
    final state = AppState(_MemStorage())
      ..apps = [
        mk('com.b', 'Bravo', 100, 200),
        mk('com.a', 'Alpha', 300, 100),
      ];

    // Name defaults to ascending (A→Z).
    expect(state.sort, AppSort.name);
    expect(state.sortAscending, isTrue);
    expect(state.visibleApps.map((a) => a.appName), ['Alpha', 'Bravo']);

    // Flip direction.
    state.setSortAscending(false);
    expect(state.visibleApps.map((a) => a.appName), ['Bravo', 'Alpha']);

    // Switching field picks the field's natural direction: time/size show the
    // newest/largest first, so 倒序 is selected automatically.
    state.setAppSort(AppSort.size);
    expect(state.sortAscending, isFalse);
    expect(state.visibleApps.map((a) => a.appName), ['Alpha', 'Bravo']);

    // Explicit ascending overrides the natural default.
    state.setSortAscending(true);
    expect(state.visibleApps.map((a) => a.appName), ['Bravo', 'Alpha']);

    // Reset returns to name ascending and clears the badge count.
    state.scope = AppScope.system;
    state.filter = AppFilter.favorite;
    expect(state.activeAppFilterCount, 3);
    state.resetAppFilters();
    expect(state.activeAppFilterCount, 0);
    expect(state.sort, AppSort.name);
    expect(state.sortAscending, isTrue);
  });

  test('theme mode and seed color persist through settings', () async {
    final state = AppState(_MemStorage());
    expect(state.themeMode, AppThemeMode.system);
    expect(state.themeColor, kDefaultThemeColor);

    await state.setThemeMode(AppThemeMode.dark);
    await state.setThemeColor(kThemeColorPresets[4]);
    expect(state.themeMode, AppThemeMode.dark);
    expect(state.themeColor, kThemeColorPresets[4]);

    // Round-trips through a fresh state backed by the same storage.
    final reopened = AppState(state.storage);
    await reopened.init();
    expect(reopened.themeMode, AppThemeMode.dark);
    expect(reopened.themeColor, kThemeColorPresets[4]);
  });

  test('tile style persists through settings', () async {
    final state = AppState(_MemStorage());
    expect(state.tileStyle, TileStyle.colorful);

    await state.setTileStyle(TileStyle.glass);
    expect(state.tileStyle, TileStyle.glass);

    // Round-trips through a fresh state backed by the same storage.
    final reopened = AppState(state.storage);
    await reopened.init();
    expect(reopened.tileStyle, TileStyle.glass);
  });

  test('tile display flags default and round-trip through the model', () {
    final t = Tile(
      id: 't1',
      packageName: 'com.a',
      pageId: 'p1',
      showLabel: false,
      innerPadding: false,
      border: false,
    );
    final back = Tile.fromMap(t.toMap());
    expect(back.showLabel, isFalse);
    expect(back.innerPadding, isFalse);
    expect(back.border, isFalse);

    // Missing keys (older backups) default to the classic labelled/padded tile.
    final legacy = Tile.fromMap({
      'id': 't2',
      'packageName': 'com.a',
      'pageId': 'p1',
    });
    expect(legacy.showLabel, isTrue);
    expect(legacy.innerPadding, isTrue);
    expect(legacy.border, isTrue);
  });

  test('haptics settings default on and persist', () async {
    final state = AppState(_MemStorage());
    expect(state.hapticsEnabled, isTrue);
    expect(state.hapticsMainTabs, isTrue);
    expect(state.hapticsLaunchTabs, isTrue);
    expect(state.hapticsTilePages, isTrue);
    expect(state.hapticEffect, HapticEffect.selection);
    expect(state.hapticLevel, HapticLevel.light);

    // Triggering haptics must never throw even without a platform channel.
    await state.haptic(HapticTrigger.mainTabs);

    await state.setHapticsEnabled(false);
    await state.setHapticsMainTabs(false);
    await state.setHapticEffect(HapticEffect.impact);
    await state.setHapticLevel(HapticLevel.heavy);

    final reopened = AppState(state.storage);
    await reopened.init();
    expect(reopened.hapticsEnabled, isFalse);
    expect(reopened.hapticsMainTabs, isFalse);
    expect(reopened.hapticEffect, HapticEffect.impact);
    expect(reopened.hapticLevel, HapticLevel.heavy);
  });

  test('position memory restores nav, launch tab and tile page', () async {
    final state = AppState(_MemStorage());
    await state.init();
    await state.addTilePage('P2');
    await state.addTilePage('P3');
    expect(state.currentTilePageIndex, 2);

    await state.setLastHomeIndex(2);
    await state.setLastLaunchTab(3);

    final reopened = AppState(state.storage);
    await reopened.init();
    expect(reopened.rememberPosition, isTrue);
    expect(reopened.lastHomeIndex, 2);
    expect(reopened.lastLaunchTab, 3);
    expect(reopened.currentTilePageIndex, 2);

    // Turning the switch off ignores the saved position on the next launch.
    await state.setRememberPosition(false);
    final fresh = AppState(state.storage);
    await fresh.init();
    expect(fresh.rememberPosition, isFalse);
    expect(fresh.lastHomeIndex, 0);
    expect(fresh.lastLaunchTab, 0);
    expect(fresh.currentTilePageIndex, 0);
  });

  test('language setting resolves and translates', () async {
    addTearDown(() => AppStrings.current = const AppStrings('zh'));
    final state = AppState(_MemStorage());
    expect(state.language, AppLanguage.system);
    // Explicit languages ignore the device locale.
    await state.setLanguage(AppLanguage.zh);
    expect(state.resolvedLanguageCode, 'zh');
    await state.setLanguage(AppLanguage.en);
    expect(state.resolvedLanguageCode, 'en');
    expect(AppStrings.current.t('取消'), 'Cancel');
    expect(
      AppStrings.current.t('已恢复 {count} 条应用的标注数据', {'count': 3}),
      'Restored annotations for 3 apps',
    );
    expect(AppStrings.current.t('快照'), 'Snapshots');

    // Round-trips through a fresh state backed by the same storage.
    final reopened = AppState(state.storage);
    await reopened.init();
    expect(reopened.language, AppLanguage.en);
  });

  test('removing one duplicate keeps the others', () async {
    final state = AppState(_MemStorage());
    state.tilePages = [TilePage(id: 'p1', name: 'P1', createdAt: 0)];
    state.apps = [_ai('com.x', 'X')];

    final t1 = await state.addTile('com.x');
    await state.addTile('com.x');
    await state.removeTile(t1.id);

    expect(state.tiles.length, 1);
    expect(state.metaFor('com.x').pinned, isTrue);
  });

  test('reordering a page keeps its tiles with it', () async {
    final state = AppState(_MemStorage());
    state.tilePages = [
      TilePage(id: 'p1', name: 'P1', createdAt: 0),
      TilePage(id: 'p2', name: 'P2', createdAt: 0),
    ];
    state.apps = [_ai('com.a', 'A'), _ai('com.b', 'B')];
    state.tiles = [
      Tile(id: 't1', packageName: 'com.a', pageId: 'p1'),
      Tile(id: 't2', packageName: 'com.b', pageId: 'p2'),
    ];

    // Move P2 to the front; its tile must follow to index 0.
    await state.moveTilePage(1, -1);

    expect(state.tilePages.first.id, 'p2');
    expect(state.currentTilePageIndex, 0);
    final onFirst = state
        .tilesOnPage(state.tilePages[0])
        .map((t) => t.packageName);
    expect(onFirst, contains('com.b'));
    expect(onFirst, isNot(contains('com.a')));
  });

  test('adding a page makes it the current one', () async {
    final state = AppState(_MemStorage());
    state.tilePages = [TilePage(id: 'p1', name: 'P1', createdAt: 0)];
    state.currentTilePageIndex = 0;

    final page = await state.addTilePage('P2');

    expect(state.tilePages.length, 2);
    expect(state.tilePages.last.id, page.id);
    expect(state.currentTilePageId, page.id);
    expect(state.currentTilePageIndex, 1);
  });

  test('deleting an earlier page keeps the same logical page in view', () async {
    final state = AppState(_MemStorage());
    state.tilePages = [
      TilePage(id: 'p1', name: 'P1', createdAt: 0),
      TilePage(id: 'p2', name: 'P2', createdAt: 0),
      TilePage(id: 'p3', name: 'P3', createdAt: 0),
    ];
    // Viewing P2, delete P1 -> P2 shifts to index 0 and must stay visible.
    state.currentTilePageIndex = 1;
    expect(state.currentTilePageId, 'p2');

    await state.deleteTilePage('p1');

    expect(state.currentTilePageId, 'p2');
    expect(state.currentTilePageIndex, 0);

    // Deleting the current page falls back to a valid page.
    await state.deleteTilePage('p2');
    expect(state.currentTilePageIndex, lessThan(state.tilePages.length));
    expect(state.currentTilePageId, isNotNull);
  });

  test('reorderTilePage moves a page and keeps the viewed page in view', () async {
    final state = AppState(_MemStorage());
    state.tilePages = [
      TilePage(id: 'p1', name: 'P1', createdAt: 0),
      TilePage(id: 'p2', name: 'P2', createdAt: 0),
      TilePage(id: 'p3', name: 'P3', createdAt: 0),
    ];
    state.currentTilePageIndex = 1; // viewing P2

    await state.reorderTilePage(0, 2); // move P1 to the end

    expect(state.tilePages.map((p) => p.id).toList(), ['p2', 'p3', 'p1']);
    expect(state.currentTilePageId, 'p2'); // still viewing P2
    expect(state.currentTilePageIndex, 0);
  });

  test('search matches pinyin initials and full pinyin', () {
    expect(AppSearch.score('com.tencent.mm', '微信', 'wx'), isNotNull);
    expect(AppSearch.score('com.tencent.mm', '微信', 'weixin'), isNotNull);
    expect(AppSearch.score('com.tencent.mm', '微信', 'w'), isNotNull);
    expect(AppSearch.score('com.tencent.mm', '微信', 'zzz'), isNull);
  });

  test('search falls back to fuzzy subsequence', () {
    // "gmap" should fuzzily match "Google Maps".
    expect(
      AppSearch.score('com.google.maps', 'Google Maps', 'gmap'),
      isNotNull,
    );
    // Contiguous prefix should outrank a scattered subsequence.
    final prefix = AppSearch.score('a', 'Maps', 'map')!;
    final fuzzy = AppSearch.score('a', 'Maps', 'mps')!;
    expect(prefix, greaterThan(fuzzy));
  });

  test('search supports multi-token queries and empty query', () {
    expect(AppSearch.score('com.a', 'Google Maps', 'google maps'), isNotNull);
    expect(AppSearch.score('com.a', 'Google Maps', 'maps google'), isNotNull);
    expect(AppSearch.score('com.a', 'Google Maps', 'google zzz'), isNull);
    expect(AppSearch.score('com.a', '任意', ''), 0);
  });

  test('rank orders the best match first', () {
    final apps = [
      _ai('com.x', '支付宝'),
      _ai('com.y', '微信'),
      _ai('com.z', 'Wechat'),
    ];
    final ranked = AppSearch.rank(apps, 'wx');
    expect(ranked.first.packageName, 'com.y');
  });

  test('export/import round-trips all data', () async {
    final state = AppState(_MemStorage());
    state.tilePages = [TilePage(id: 'p1', name: 'P1', createdAt: 0)];
    state.apps = [_ai('com.x', 'X')];
    state.metaFor('com.x')
      ..reason = 'because'
      ..favorite = true;
    state.categories = [AppCategory(id: 'c1', name: '工具', emoji: '🛠️')];
    state.tiles = [
      Tile(id: 't1', packageName: 'com.x', pageId: 'p1', w: 2, h: 2),
    ];
    state.settings['tile_default_size'] = 3;

    // Must be JSON-serialisable and re-parse cleanly.
    final pkg =
        jsonDecode(jsonEncode(state.exportPackage())) as Map<String, dynamic>;

    await state.clearAllData();
    expect(state.tiles, isEmpty);
    expect(state.categories, isEmpty);
    expect(state.meta, isEmpty);

    await state.importPackage(pkg);
    expect(state.categories.single.name, '工具');
    expect(state.tiles.single.packageName, 'com.x');
    expect(state.tiles.single.w, 2);
    expect(state.metaFor('com.x').reason, 'because');
    expect(state.metaFor('com.x').pinned, isTrue);
    expect(state.tileDefaultSize, 3);
  });

  test('remote source config round-trips through settings', () async {
    final state = AppState(_MemStorage());
    expect(state.remoteSource.configured, isFalse);
    expect(state.remoteSource.anonymous, isTrue);

    await state.setRemoteSource(
      RemoteSource(
        protocol: 'smb',
        host: 'nas.local',
        port: 445,
        path: 'share/apks',
        username: 'u',
        password: 'p',
        anonymous: false,
      ),
    );

    final s = state.remoteSource;
    expect(s.isSmb, isTrue);
    expect(s.host, 'nas.local');
    expect(s.path, 'share/apks');
    expect(s.username, 'u');
    expect(s.configured, isTrue);

    // Survives an export/import cycle too.
    final pkg = state.exportPackage();
    final fresh = AppState(_MemStorage());
    await fresh.importPackage(pkg);
    expect(fresh.remoteSource.path, 'share/apks');
    expect(fresh.remoteSource.anonymous, isFalse);
  });

  test('webdav listing parses apk entries', () {
    const xml = '''
<?xml version="1.0"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/apks/</D:href>
    <D:propstat><D:prop>
      <D:resourcetype><D:collection/></D:resourcetype>
    </D:prop></D:propstat>
  </D:response>
  <D:response>
    <D:href>/apks/com.example.app-1.2.3.apk</D:href>
    <D:propstat><D:prop>
      <D:getcontentlength>123456</D:getcontentlength>
      <D:getlastmodified>Wed, 21 Oct 2015 07:28:00 GMT</D:getlastmodified>
    </D:prop></D:propstat>
  </D:response>
  <D:response>
    <D:href>/apks/notes.txt</D:href>
    <D:propstat><D:prop>
      <D:getcontentlength>10</D:getcontentlength>
    </D:prop></D:propstat>
  </D:response>
</D:multistatus>
''';
    final list = RemoteClient.parseWebdavListing(xml);
    expect(list.length, 1);
    expect(list.single['name'], 'com.example.app-1.2.3.apk');
    expect(list.single['size'], 123456);
    expect(list.single['modified'], isNot(0));
  });

  test('webdav listing handles namespace-less hrefs', () {
    const xml =
        '<multistatus><response>'
        '<href>/dav/%E5%BA%94%E7%94%A8.apk</href>'
        '<getcontentlength>5</getcontentlength>'
        '</response></multistatus>';
    final list = RemoteClient.parseWebdavListing(xml);
    expect(list.single['name'], '应用.apk');
    expect(list.single['size'], 5);
  });

  test('RemoteSource.fromMap defaults are sane', () {
    final s = RemoteSource.fromMap(<String, dynamic>{});
    expect(s.protocol, 'ftp');
    expect(s.port, 21);
    expect(s.anonymous, isTrue);
    expect(RemoteSource.defaultPort('smb'), 445);
    expect(RemoteSource.defaultPort('ftp'), 21);
  });

  test('import rejects a malformed package without touching data', () async {
    final state = AppState(_MemStorage());
    state.tilePages = [TilePage(id: 'p1', name: 'P1', createdAt: 0)];
    state.categories = [AppCategory(id: 'c1', name: 'keep', emoji: 'x')];

    await expectLater(
      state.importPackage(<String, dynamic>{'app': 'other'}),
      throwsA(isA<FormatException>()),
    );
    expect(state.categories.single.name, 'keep');
  });

  test('legacy pinned meta migrates into a tile on load', () async {
    final storage = _MemStorage();
    storage._data['tile_pages'] = [
      TilePage(id: 'p1', name: 'P1', createdAt: 0).toMap(),
      TilePage(id: 'p2', name: 'P2', createdAt: 0).toMap(),
    ];
    storage._data['meta'] = {
      'com.legacy': AppMeta(
        packageName: 'com.legacy',
        pinned: true,
        tilePageId: 'p2',
      ).toMap(),
    };

    final state = AppState(storage);
    await state.init();

    expect(state.tiles.length, 1);
    expect(state.tiles.single.packageName, 'com.legacy');
    expect(state.tiles.single.pageId, 'p2');

    state.apps = [_ai('com.legacy', 'L')];
    expect(state.pinCountOnPage(state.tilePages[1]), 1);
  });

  test('webdav entries expose collections for recursion', () {
    const xml = '''
<D:multistatus xmlns:D="DAV:">
  <D:response><D:href>/apks/</D:href>
    <D:resourcetype><D:collection/></D:resourcetype></D:response>
  <D:response><D:href>/apks/sub/</D:href>
    <D:resourcetype><D:collection/></D:resourcetype></D:response>
  <D:response><D:href>/apks/.hidden.apk</D:href>
    <D:getcontentlength>9</D:getcontentlength></D:response>
  <D:response><D:href>/apks/sub/App.apk</D:href>
    <D:getcontentlength>42</D:getcontentlength></D:response>
  <D:response><D:href>/apks/readme.txt</D:href>
    <D:getcontentlength>1</D:getcontentlength></D:response>
</D:multistatus>
''';
    final entries = RemoteClient.parseWebdavEntries(xml);
    final dirs = entries.where((e) => e['isDir'] == true).map((e) => e['name']);
    expect(dirs, containsAll(['apks', 'sub']));

    // The files-only view keeps real APKs and drops hidden/non-apk entries.
    final files = RemoteClient.parseWebdavListing(xml);
    expect(files.map((f) => f['name']), ['App.apk']);
    expect(files.single['name'], 'App.apk');
    expect(files.single['size'], 42);
  });

  test('multiple sync sources add / switch / remove', () async {
    final state = AppState(_MemStorage());
    expect(state.syncSources, isEmpty);

    final a = await state.addSyncSource(
      RemoteSource(name: 'NAS', protocol: 'smb', host: 'nas', path: 'apks'),
    );
    final b = await state.addSyncSource(
      RemoteSource(name: 'FTP', protocol: 'ftp', host: 'ftp', path: '/apks'),
    );

    expect(state.syncSources.length, 2);
    expect(state.activeSyncSourceId, b.id); // newest becomes active
    expect(a.name, 'NAS');
    expect(b.name, 'FTP');

    await state.setActiveSyncSource(a.id);
    expect(state.remoteSource.host, 'nas');

    await state.updateSyncSource(a.copyWith(name: 'NAS2', path: 'apks/sub'));
    expect(state.remoteSource.name, 'NAS2');
    expect(state.remoteSource.path, 'apks/sub');

    await state.removeSyncSource(a.id);
    expect(state.syncSources.length, 1);
    expect(state.activeSyncSourceId, b.id);
  });

  test('pin count / unpin are scoped to the current page', () async {
    final state = AppState(_MemStorage());
    state.tilePages = [
      TilePage(id: 'p1', name: 'P1', createdAt: 0),
      TilePage(id: 'p2', name: 'P2', createdAt: 0),
    ];
    state.apps = [_ai('com.x', 'X')];

    state.currentTilePageIndex = 1;
    await state.addTile('com.x', pageId: 'p1');
    // Pinned on p1, but the current page is p2 -> not shown as pinned.
    expect(state.pinCountOnCurrentPage('com.x'), 0);

    state.currentTilePageIndex = 0;
    expect(state.pinCountOnCurrentPage('com.x'), 1);

    // Long-press adds another copy on the same page.
    await state.addTile('com.x', pageId: 'p1');
    expect(state.pinCountOnCurrentPage('com.x'), 2);

    // Tap unpins one at a time.
    expect(await state.removeOneTileOnCurrentPage('com.x'), isTrue);
    expect(state.pinCountOnCurrentPage('com.x'), 1);
    expect(await state.removeOneTileOnCurrentPage('com.x'), isTrue);
    expect(state.pinCountOnCurrentPage('com.x'), 0);
    expect(await state.removeOneTileOnCurrentPage('com.x'), isFalse);
  });

  test('pin locations list every page with counts', () async {
    final state = AppState(_MemStorage());
    state.tilePages = [
      TilePage(id: 'p1', name: 'P1', createdAt: 0),
      TilePage(id: 'p2', name: 'P2', createdAt: 0),
    ];
    state.apps = [_ai('com.x', 'X')];
    state.currentTilePageIndex = 0;

    await state.addTile('com.x', pageId: 'p1');
    await state.addTile('com.x', pageId: 'p1');
    await state.addTile('com.x', pageId: 'p2');

    final locs = state.pinLocationsFor('com.x');
    expect(locs.length, 2);
    expect(locs[0].$1.id, 'p1');
    expect(locs[0].$2, 2);
    expect(locs[1].$1.id, 'p2');
    expect(locs[1].$2, 1);

    await state.removeTilesOnPage('com.x', 'p1');
    final after = state.pinLocationsFor('com.x');
    expect(after.length, 1);
    expect(after.single.$1.id, 'p2');
  });

  test('recent apps track launch count and can sort by frequency', () async {
    final state = AppState(_MemStorage());
    state.apps = [_ai('com.a', 'A'), _ai('com.b', 'B')];
    await state.markLaunched('com.a');
    await state.markLaunched('com.b');
    await state.markLaunched('com.b');

    expect(state.metaFor('com.b').launchCount, 2);
    expect(state.recentAppsBy(RecentSort.recent).length, 2);
    // Frequency ordering is deterministic (2 launches vs 1).
    expect(state.recentAppsBy(RecentSort.frequent).first.packageName, 'com.b');

    final none = state.recentAppsBy(
      RecentSort.recent,
      sinceMillis: DateTime.now().millisecondsSinceEpoch + 1000,
    );
    expect(none, isEmpty);
  });

  test('legacy single remote source migrates to a sync source', () async {
    final storage = _MemStorage();
    storage._data['settings'] = {
      'remote_source': RemoteSource(
        protocol: 'smb',
        host: 'nas.local',
        path: 'share/apks',
        anonymous: false,
      ).toMap(),
    };
    final state = AppState(storage);
    await state.init();

    expect(state.syncSources.length, 1);
    final s = state.syncSources.single;
    expect(s.host, 'nas.local');
    expect(s.path, 'share/apks');
    expect(s.id, isNotEmpty);
    expect(s.name, isNotEmpty); // falls back to the protocol label
  });
}
