import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../l10n/app_strings.dart';
import '../models/app_info.dart';
import '../models/app_meta.dart';
import '../models/backup_list.dart';
import '../models/category.dart';
import '../models/remote_source.dart';
import '../models/snapshot.dart';
import '../models/tile.dart';
import '../models/tile_page.dart';
import '../services/native_apps.dart';
import '../services/storage.dart';
import '../utils/format.dart';
import '../utils/search.dart';
import '../utils/system_ui.dart';
import '../utils/tile_layout.dart';

/// Which apps are in scope by type. Kept separate from [AppFilter] so it does
/// not take part in the annotation filter radio group.
enum AppScope { all, user, system }

enum AppFilter {
  all,
  favorite,
  categorized,
  uncategorized,
  hasReason,
  unorganized,
  uninstalled,
}

enum AppSort { name, installTime, updateTime, size }

/// Ordering for the "recent" quick-launch tab.
enum RecentSort { recent, frequent }

/// Ordering for the category list on the launch screen.
enum CategorySort { manual, name, count }

/// How the app-level navigation is presented.
///
/// - [auto]: follow the device. Tablets in landscape get a side rail; phones
///   and tablets in portrait stay on the normal bottom bar.
/// - [bottom]: always the normal bottom navigation bar.
/// - [rail]: always a left side rail (best for tablets).
/// - [floating]: no persistent bar; a floating button reveals the navigation.
enum NavMode { auto, bottom, rail, floating }

/// Which color scheme the app follows.
///
/// - [system]: match the device light/dark setting.
/// - [light]: always light.
/// - [dark]: always dark.
enum AppThemeMode { system, light, dark }

/// Visual style of the tiles on the 磁贴 board.
///
/// - [colorful]: solid per-app color (the classic look).
/// - [glass]: frosted, translucent "通透" look.
enum TileStyle { colorful, glass }

/// Where a haptic tick may be triggered.
enum HapticTrigger { mainTabs, launchTabs, tilePages }

/// The kind of feedback produced.
///
/// - [selection]: subtle click, best for switching tabs.
/// - [impact]: an impact whose strength comes from [HapticLevel].
/// - [vibrate]: a longer buzz.
enum HapticEffect { selection, impact, vibrate }

/// Strength used when [HapticEffect.impact] is selected.
enum HapticLevel { light, medium, heavy }

/// Default seed color for the color scheme (囤囤 orange).
const int kDefaultThemeColor = 0xFFF0A030;

/// Seed colors offered as quick swatches in the appearance settings. The user
/// can still pick any color through the custom picker.
const List<int> kThemeColorPresets = <int>[
  0xFFF0A030,
  0xFFE53935,
  0xFFD81B60,
  0xFF8E24AA,
  0xFF5E35B1,
  0xFF3949AB,
  0xFF1E88E5,
  0xFF039BE5,
  0xFF00897B,
  0xFF43A047,
  0xFF7CB342,
  0xFFFB8C00,
  0xFF6D4C41,
  0xFF546E7A,
];

class AppState extends ChangeNotifier {
  final Storage storage;

  AppState(this.storage);

  List<AppInfo> apps = <AppInfo>[];
  Map<String, AppMeta> meta = <String, AppMeta>{};
  List<AppCategory> categories = <AppCategory>[];
  List<Snapshot> snapshots = <Snapshot>[];
  List<BackupList> backupLists = <BackupList>[];
  List<TilePage> tilePages = <TilePage>[];
  List<Tile> tiles = <Tile>[];
  Map<String, dynamic> settings = <String, dynamic>{};

  /// Apps detected as uninstalled during the most recent scan and that the
  /// user has not been asked about yet this session.
  List<AppMeta> pendingUninstalls = <AppMeta>[];

  bool initialized = false;
  bool scanning = false;
  String? scanError;
  int lastScanMs = 0;
  DateTime? lastScanAt;
  bool includeSystemInScan = true;

  String query = '';
  AppScope scope = AppScope.all;
  AppFilter filter = AppFilter.all;
  AppSort sort = AppSort.name;

  /// Whether [sort] is applied ascending (正序) or descending (倒序).
  bool sortAscending = true;
  String? filterCategoryId;

  final Random _rand = Random();

  /// Public wrapper so widgets can trigger a rebuild after mutating a
  /// filter/sort field directly.
  void refresh() => notifyListeners();

  /// Number of non-default filter/sort options, shown as a badge next to the
  /// filter button on the apps screen.
  int get activeAppFilterCount {
    var n = 0;
    if (scope != AppScope.all) n++;
    if (filter != AppFilter.all) n++;
    if (filterCategoryId != null) n++;
    if (sort != AppSort.name) n++;
    if (!sortAscending) n++;
    return n;
  }

  /// Natural direction for a freshly picked sort: names read A→Z, while time
  /// and size are most useful newest/largest first.
  static bool _defaultAscending(AppSort s) => s == AppSort.name;

  void setAppSort(AppSort value) {
    if (sort == value) return;
    sort = value;
    sortAscending = _defaultAscending(value);
    refresh();
  }

  void setSortAscending(bool value) {
    if (sortAscending == value) return;
    sortAscending = value;
    refresh();
  }

  void resetAppFilters() {
    scope = AppScope.all;
    filter = AppFilter.all;
    filterCategoryId = null;
    sort = AppSort.name;
    sortAscending = true;
    refresh();
  }

  String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch}_${_rand.nextInt(1 << 32)}';

  // ---------------------------------------------------------------- lifecycle

  Future<void> init() async {
    meta = await _loadMeta();
    categories = await _loadCategories();
    snapshots = await _loadSnapshots();
    backupLists = await _loadBackupLists();
    settings = await _loadSettings();
    _applyLanguage();
    _applyLanguage();
    tilePages = await _loadTilePages();
    if (tilePages.isEmpty) {
      tilePages.add(
        TilePage(
          id: _newId(),
          name: '页面 1',
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      await _persistTilePages();
    }
    // Restore the last viewed tile page when position memory is enabled.
    if (rememberPosition) {
      final saved = (settings['last_tile_page'] as num?)?.toInt() ?? 0;
      currentTilePageIndex = saved.clamp(0, tilePages.length - 1);
    }
    // Tiles are independent of apps; load them and migrate legacy pins
    // (stored on AppMeta as a single `pinned` flag) into concrete tile entries.
    final firstPageId = tilePages.first.id;
    final validPageIds = tilePages.map((p) => p.id).toSet();
    tiles = await _loadTiles();
    if (tiles.isEmpty) {
      for (final m in meta.values) {
        if (!m.pinned) continue;
        tiles.add(
          Tile(
            id: _newId(),
            packageName: m.packageName,
            pageId: validPageIds.contains(m.tilePageId)
                ? m.tilePageId
                : firstPageId,
            col: m.tileCol,
            row: m.tileRow,
            w: m.tileW,
            h: m.tileH,
          ),
        );
      }
      if (tiles.isNotEmpty) await _persistTiles();
    }
    for (final t in tiles) {
      if (!validPageIds.contains(t.pageId)) t.pageId = firstPageId;
    }
    // Keep the derived `pinned` flag on each AppMeta in sync with the tiles so
    // snapshots and the app detail switch keep working.
    final tiledPackages = tiles.map((t) => t.packageName).toSet();
    var metaChanged = false;
    for (final m in meta.values) {
      final shouldPin = tiledPackages.contains(m.packageName);
      if (m.pinned != shouldPin) {
        m.pinned = shouldPin;
        metaChanged = true;
      }
    }
    if (metaChanged) await _persistMeta();
    apps = _parseApps(await storage.readJson(_kAppsCache));
    initialized = true;
    notifyListeners();
  }

  Map<String, AppMeta> _parseMeta(dynamic raw) {
    if (raw is Map) {
      return raw.map(
        (k, v) => MapEntry(
          k as String,
          AppMeta.fromMap((v as Map).cast<String, dynamic>()),
        ),
      );
    }
    return <String, AppMeta>{};
  }

  List<AppCategory> _parseCategories(dynamic raw) {
    if (raw is List) {
      return raw
          .map((e) => AppCategory.fromMap((e as Map).cast<String, dynamic>()))
          .toList();
    }
    return <AppCategory>[];
  }

  List<Snapshot> _parseSnapshots(dynamic raw) {
    if (raw is List) {
      return raw
          .map((e) => Snapshot.fromMap((e as Map).cast<String, dynamic>()))
          .toList();
    }
    return <Snapshot>[];
  }

  List<BackupList> _parseBackupLists(dynamic raw) {
    if (raw is List) {
      return raw
          .map((e) => BackupList.fromMap((e as Map).cast<String, dynamic>()))
          .toList();
    }
    return <BackupList>[];
  }

  List<Tile> _parseTiles(dynamic raw) {
    if (raw is List) {
      return raw
          .map((e) => Tile.fromMap((e as Map).cast<String, dynamic>()))
          .toList();
    }
    return <Tile>[];
  }

  List<TilePage> _parseTilePages(dynamic raw) {
    if (raw is List) {
      return raw
          .map((e) => TilePage.fromMap((e as Map).cast<String, dynamic>()))
          .toList();
    }
    return <TilePage>[];
  }

  List<AppInfo> _parseApps(dynamic raw) {
    if (raw is List) {
      return raw
          .map((e) => AppInfo.fromMap((e as Map).cast<dynamic, dynamic>()))
          .toList();
    }
    return <AppInfo>[];
  }

  Map<String, dynamic> _parseSettings(dynamic raw) {
    if (raw is Map) return raw.cast<String, dynamic>();
    return <String, dynamic>{};
  }

  Future<Map<String, AppMeta>> _loadMeta() async =>
      _parseMeta(await storage.readJson(_kMeta));

  Future<List<AppCategory>> _loadCategories() async =>
      _parseCategories(await storage.readJson(_kCategories));

  Future<List<Snapshot>> _loadSnapshots() async =>
      _parseSnapshots(await storage.readJson(_kSnapshots));

  Future<List<BackupList>> _loadBackupLists() async =>
      _parseBackupLists(await storage.readJson(_kBackupLists));

  // ---------------------------------------------------------------- scanning

  Future<void> scan() async {
    if (scanning) return;
    scanning = true;
    scanError = null;
    pendingUninstalls = <AppMeta>[];
    notifyListeners();

    // Baseline used to detect removals: the most recent snapshot if one
    // exists ("当前 vs 上次快照"), otherwise the previous scan result.
    final baseline = _baseline();

    final sw = Stopwatch()..start();
    try {
      final result = await NativeApps.getInstalledApps(
        includeSystem: includeSystemInScan,
      );
      result.sort(
        (a, b) => a.appName.toLowerCase().compareTo(b.appName.toLowerCase()),
      );

      final now = DateTime.now();
      final current = <String>{};
      for (final app in result) {
        current.add(app.packageName);
        final m = meta.putIfAbsent(
          app.packageName,
          () => AppMeta(
            packageName: app.packageName,
            firstSeenAt: now.millisecondsSinceEpoch,
          ),
        );
        m.packageName = app.packageName;
        m.lastKnownName = app.appName;
        if (m.uninstalledAt != 0) {
          // App came back -> clear the previous uninstall record.
          m.uninstalledAt = 0;
          m.uninstallReason = '';
        }
      }

      // Detect apps that were present in the baseline but are gone now.
      final pending = <AppMeta>[];
      for (final entry in baseline.entries) {
        final pkg = entry.key;
        if (current.contains(pkg)) continue;
        final m = meta.putIfAbsent(
          pkg,
          () => AppMeta(
            packageName: pkg,
            firstSeenAt: now.millisecondsSinceEpoch,
          ),
        );
        if (m.lastKnownName.isEmpty) m.lastKnownName = entry.value;
        if (m.uninstalledAt == 0) {
          m.uninstalledAt = now.millisecondsSinceEpoch;
          m.uninstallReason = '';
          pending.add(m);
        }
      }
      pendingUninstalls = pending;

      apps = result;
      await storage.writeJson(_kAppsCache, apps.map((e) => e.toMap()).toList());
      await _persistMeta();

      sw.stop();
      lastScanMs = sw.elapsedMilliseconds;
      lastScanAt = now;
    } catch (e) {
      sw.stop();
      lastScanMs = sw.elapsedMilliseconds;
      scanError = e.toString();
    } finally {
      scanning = false;
      notifyListeners();
    }
  }

  Map<String, String> _baseline() {
    if (snapshots.isNotEmpty) {
      final latest = snapshots.reduce(
        (a, b) => a.createdAt >= b.createdAt ? a : b,
      );
      if (latest.entries.isNotEmpty) {
        return {for (final e in latest.entries) e.packageName: e.appName};
      }
    }
    return {for (final a in apps) a.packageName: a.appName};
  }

  void clearPendingUninstalls() {
    if (pendingUninstalls.isEmpty) return;
    pendingUninstalls = <AppMeta>[];
    notifyListeners();
  }

  /// All apps ever seen that are currently uninstalled, newest first.
  List<AppMeta> get uninstalledApps {
    final list = meta.values.where((m) => m.isUninstalled).toList()
      ..sort((a, b) => b.uninstalledAt.compareTo(a.uninstalledAt));
    return list;
  }

  // ---------------------------------------------------------------- meta

  AppMeta metaFor(String packageName) {
    return meta.putIfAbsent(
      packageName,
      () => AppMeta(
        packageName: packageName,
        firstSeenAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  Future<void> updateMeta(
    String packageName, {
    String? reason,
    String? note,
    bool? favorite,
    List<String>? categoryIds,
    String? uninstallReason,
  }) async {
    final m = metaFor(packageName);
    if (reason != null) m.reason = reason;
    if (note != null) m.note = note;
    if (favorite != null) m.favorite = favorite;
    if (categoryIds != null) m.categoryIds = categoryIds;
    if (uninstallReason != null) m.uninstallReason = uninstallReason;
    await _persistMeta();
    notifyListeners();
  }

  Future<void> clearMeta(String packageName) async {
    meta.remove(packageName);
    await _persistMeta();
    notifyListeners();
  }

  /// Persist in-memory metadata changes (e.g. debounced text field edits).
  Future<void> persistMeta() => _persistMeta();

  Future<void> _persistMeta() =>
      storage.writeJson(_kMeta, meta.map((k, v) => MapEntry(k, v.toMap())));

  // ---------------------------------------------------------------- categories

  Future<AppCategory> addCategory(
    String name, {
    int colorValue = 0xFF6C8CFF,
    String emoji = '📦',
  }) async {
    final c = AppCategory(
      id: _newId(),
      name: name,
      colorValue: colorValue,
      emoji: emoji,
    );
    categories.add(c);
    await _persistCategories();
    notifyListeners();
    return c;
  }

  Future<void> updateCategory(
    AppCategory c, {
    String? name,
    int? colorValue,
    String? emoji,
  }) async {
    if (name != null) c.name = name;
    if (colorValue != null) c.colorValue = colorValue;
    if (emoji != null) c.emoji = emoji;
    await _persistCategories();
    notifyListeners();
  }

  Future<void> deleteCategory(String id) async {
    categories.removeWhere((c) => c.id == id);
    for (final m in meta.values) {
      m.categoryIds.remove(id);
    }
    await _persistCategories();
    await _persistMeta();
    if (filterCategoryId == id) filterCategoryId = null;
    notifyListeners();
  }

  Future<void> _persistCategories() async {
    await storage.writeJson(
      _kCategories,
      categories.map((c) => c.toMap()).toList(),
    );
  }

  /// How many installed apps belong to category [id].
  int categoryAppCount(String id) =>
      apps.where((a) => metaFor(a.packageName).categoryIds.contains(id)).length;

  /// User-selected ordering for the category list. Defaults to manual (the
  /// stored order).
  CategorySort get categorySort {
    final raw = settings['category_sort'] as String?;
    return CategorySort.values.firstWhere(
      (s) => s.name == raw,
      orElse: () => CategorySort.manual,
    );
  }

  Future<void> setCategorySort(CategorySort sort) async {
    settings['category_sort'] = sort.name;
    await _persistSettings();
    notifyListeners();
  }

  /// Categories ordered according to [categorySort] (the stored order is never
  /// mutated by sorting).
  List<AppCategory> get sortedCategories {
    final list = List<AppCategory>.from(categories);
    switch (categorySort) {
      case CategorySort.manual:
        break;
      case CategorySort.name:
        list.sort(
          (a, b) =>
              AppSearch.pinyinKey(a.name)
                  .compareTo(AppSearch.pinyinKey(b.name)),
        );
      case CategorySort.count:
        list.sort((a, b) {
          final c = categoryAppCount(b.id).compareTo(categoryAppCount(a.id));
          if (c != 0) return c;
          return AppSearch.pinyinKey(a.name)
              .compareTo(AppSearch.pinyinKey(b.name));
        });
    }
    return list;
  }

  /// Move a category while in manual sort mode (drag to reorder).
  ///
  /// [newIndex] is the final insertion index *after* the item has been removed
  /// (matching `ReorderableListView.onReorderItem`).
  Future<void> moveCategory(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= categories.length) return;
    final c = categories.removeAt(oldIndex);
    final target = newIndex.clamp(0, categories.length);
    categories.insert(target, c);
    await _persistCategories();
    notifyListeners();
  }

  // ---------------------------------------------------------------- snapshots

  Future<Snapshot> createSnapshot(String name, {String note = ''}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final entries = <SnapshotEntry>[];
    final seen = <String>{};

    // Currently installed apps, together with their annotations.
    for (final a in apps) {
      final m = metaFor(a.packageName);
      seen.add(a.packageName);
      entries.add(
        SnapshotEntry(
          packageName: a.packageName,
          appName: a.appName,
          versionName: a.versionName,
          versionCode: a.versionCode,
          lastUpdateTime: a.lastUpdateTime,
          firstInstallTime: a.firstInstallTime,
          isSystem: a.isSystem,
          sizeBytes: a.sizeBytes,
          reason: m.reason,
          note: m.note,
          categoryIds: List<String>.from(m.categoryIds),
          favorite: m.favorite,
          pinned: m.pinned,
        ),
      );
    }

    // Apps we've seen before that are currently uninstalled: keep their
    // uninstall record (including the reason) so the next snapshot can
    // restore it.
    for (final m in meta.values) {
      if (!m.isUninstalled || seen.contains(m.packageName)) continue;
      entries.add(
        SnapshotEntry(
          packageName: m.packageName,
          appName: m.lastKnownName.isEmpty ? m.packageName : m.lastKnownName,
          versionName: '',
          versionCode: 0,
          lastUpdateTime: 0,
          firstInstallTime: 0,
          isSystem: false,
          sizeBytes: 0,
          reason: m.reason,
          note: m.note,
          categoryIds: List<String>.from(m.categoryIds),
          favorite: m.favorite,
          pinned: m.pinned,
          uninstallReason: m.uninstallReason,
          uninstalledAt: m.uninstalledAt,
        ),
      );
    }

    final snapshot = Snapshot(
      id: _newId(),
      name: name.isEmpty
          ? AppStrings.current.t('快照 {n}', {'n': snapshots.length + 1})
          : name,
      createdAt: now,
      note: note,
      entries: entries,
      categories: categories
          .map(
            (c) => AppCategory(
              id: c.id,
              name: c.name,
              colorValue: c.colorValue,
              emoji: c.emoji,
            ),
          )
          .toList(),
    );
    snapshots.add(snapshot);
    await _persistSnapshots();
    notifyListeners();
    return snapshot;
  }

  /// Restore the app annotations (reason, note, categories, favorite) and
  /// uninstall records stored in [snapshot]. Categories referenced by the
  /// snapshot are recreated if missing. Returns the number of apps updated.
  Future<int> restoreSnapshot(String snapshotId) async {
    final snapshot = snapshots.firstWhere((s) => s.id == snapshotId);

    // Recreate categories that no longer exist.
    final existingCatIds = categories.map((c) => c.id).toSet();
    for (final c in snapshot.categories) {
      if (existingCatIds.contains(c.id)) continue;
      categories.add(
        AppCategory(
          id: c.id,
          name: c.name,
          colorValue: c.colorValue,
          emoji: c.emoji,
        ),
      );
      existingCatIds.add(c.id);
    }

    final installed = {for (final a in apps) a.packageName};

    final firstPageId = tilePages.isEmpty ? '' : tilePages.first.id;
    var tilesChanged = false;

    for (final e in snapshot.entries) {
      final m = metaFor(e.packageName);
      m.reason = e.reason;
      m.note = e.note;
      m.favorite = e.favorite;
      m.categoryIds = e.categoryIds
          .where(existingCatIds.contains)
          .toList(growable: true);
      if (e.appName.isNotEmpty) m.lastKnownName = e.appName;

      if (e.uninstalledAt != 0 && !installed.contains(e.packageName)) {
        // Keep it as an uninstall record with its reason.
        m.uninstallReason = e.uninstallReason;
        m.uninstalledAt = e.uninstalledAt;
      } else {
        // Installed (or reinstalled) now -> clear the uninstall record.
        m.uninstallReason = '';
        m.uninstalledAt = 0;
      }

      // Reconcile the tile board with the snapshot's pinned flag: add one tile
      // when pinned and none exist, drop all tiles when no longer pinned.
      final hasTiles = tiles.any((t) => t.packageName == e.packageName);
      if (e.pinned && !hasTiles && firstPageId.isNotEmpty) {
        tiles.add(
          Tile(id: _newId(), packageName: e.packageName, pageId: firstPageId),
        );
        tilesChanged = true;
      } else if (!e.pinned && hasTiles) {
        tiles.removeWhere((t) => t.packageName == e.packageName);
        tilesChanged = true;
      }
      m.pinned = e.pinned;
    }

    if (tilesChanged) await _persistTiles();
    await _persistCategories();
    await _persistMeta();
    notifyListeners();
    return snapshot.entries.length;
  }

  Future<void> deleteSnapshot(String id) async {
    snapshots.removeWhere((s) => s.id == id);
    await _persistSnapshots();
    notifyListeners();
  }

  Future<void> renameSnapshot(String id, String name) async {
    final s = snapshots.firstWhere((e) => e.id == id);
    s.name = name;
    await _persistSnapshots();
    notifyListeners();
  }

  Future<void> _persistSnapshots() async {
    await storage.writeJson(
      _kSnapshots,
      snapshots.map((s) => s.toMap()).toList(),
    );
  }

  // ---------------------------------------------------------------- backups

  Future<BackupList> addBackupList(
    String name, {
    String description = '',
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final b = BackupList(
      id: _newId(),
      name: name.isEmpty
          ? AppStrings.current.t('备份列表 {n}', {'n': backupLists.length + 1})
          : name,
      description: description,
      createdAt: now,
      updatedAt: now,
    );
    backupLists.add(b);
    await _persistBackupLists();
    notifyListeners();
    return b;
  }

  Future<void> deleteBackupList(String id) async {
    backupLists.removeWhere((b) => b.id == id);
    await _persistBackupLists();
    notifyListeners();
  }

  Future<void> updateBackupList(
    BackupList list, {
    String? name,
    String? description,
  }) async {
    if (name != null) list.name = name;
    if (description != null) list.description = description;
    list.updatedAt = DateTime.now().millisecondsSinceEpoch;
    await _persistBackupLists();
    notifyListeners();
  }

  Future<void> toggleBackupMember(String listId, String packageName) async {
    final list = backupLists.firstWhere((b) => b.id == listId);
    if (list.packageNames.contains(packageName)) {
      list.packageNames.remove(packageName);
    } else {
      list.packageNames.add(packageName);
    }
    list.updatedAt = DateTime.now().millisecondsSinceEpoch;
    await _persistBackupLists();
    notifyListeners();
  }

  Future<void> backupCurrentApps(String listId) async {
    final list = backupLists.firstWhere((b) => b.id == listId);
    list.packageNames = apps.map((a) => a.packageName).toList();
    list.updatedAt = DateTime.now().millisecondsSinceEpoch;
    await _persistBackupLists();
    notifyListeners();
  }

  Future<void> _persistBackupLists() async {
    await storage.writeJson(
      _kBackupLists,
      backupLists.map((b) => b.toMap()).toList(),
    );
  }

  // ---------------------------------------------------------------- tile pages

  Future<List<TilePage>> _loadTilePages() async =>
      _parseTilePages(await storage.readJson(_kTilePages));

  Future<void> _persistTilePages() async {
    await storage.writeJson(
      _kTilePages,
      tilePages.map((p) => p.toMap()).toList(),
    );
  }

  Future<List<Tile>> _loadTiles() async =>
      _parseTiles(await storage.readJson(_kTiles));

  Future<void> _persistTiles() async {
    await storage.writeJson(_kTiles, tiles.map((t) => t.toMap()).toList());
  }

  Tile? tileById(String id) {
    for (final t in tiles) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// Tiles shown on [page], in stable display order. Tiles whose page no longer
  /// exists fall back to the first page; tiles whose app is gone are skipped.
  List<Tile> tilesOnPage(TilePage page) {
    if (tilePages.isEmpty) return const <Tile>[];
    final firstId = tilePages.first.id;
    final validIds = tilePages.map((p) => p.id).toSet();
    final result = tiles.where((t) {
      if (appByPackage(t.packageName) == null) return false;
      final pid = validIds.contains(t.pageId) ? t.pageId : firstId;
      return pid == page.id;
    }).toList();
    result.sort((a, b) {
      final ar = a.row < 0 ? 1 << 20 : a.row;
      final br = b.row < 0 ? 1 << 20 : b.row;
      if (ar != br) return ar.compareTo(br);
      final ac = a.col < 0 ? 1 << 20 : a.col;
      final bc = b.col < 0 ? 1 << 20 : b.col;
      if (ac != bc) return ac.compareTo(bc);
      return a.id.compareTo(b.id);
    });
    return result;
  }

  int pinCountOnPage(TilePage page) => tilesOnPage(page).length;

  /// Normalised page id for a tile (invalid/missing ids fall back to page 1).
  String _normalizedPageId(Tile tile) {
    final firstId = tilePages.isEmpty ? '' : tilePages.first.id;
    final validIds = tilePages.map((p) => p.id).toSet();
    return validIds.contains(tile.pageId) ? tile.pageId : firstId;
  }

  /// Number of tiles for [packageName] on the currently visible page only.
  int pinCountOnCurrentPage(String packageName) {
    if (tilePages.isEmpty) return 0;
    final currentId = currentTilePageId;
    return tiles
        .where(
          (t) =>
              t.packageName == packageName && _normalizedPageId(t) == currentId,
        )
        .length;
  }

  /// Removes a single tile for [packageName] from the current page.
  /// Returns false when the app is not pinned on this page.
  Future<bool> removeOneTileOnCurrentPage(String packageName) async {
    if (tilePages.isEmpty) return false;
    final currentId = currentTilePageId;
    final index = tiles.indexWhere(
      (t) => t.packageName == packageName && _normalizedPageId(t) == currentId,
    );
    if (index < 0) return false;
    tiles.removeAt(index);
    _syncPinned(packageName);
    await _persistTiles();
    await _persistMeta();
    notifyListeners();
    return true;
  }

  /// Every page where [packageName] is pinned, with the tile count per page,
  /// in page order. Used to show all pin locations from other screens.
  List<(TilePage, int)> pinLocationsFor(String packageName) {
    final out = <(TilePage, int)>[];
    for (final page in tilePages) {
      final count = tilesOnPage(page)
          .where((t) => t.packageName == packageName)
          .length;
      if (count > 0) out.add((page, count));
    }
    return out;
  }

  /// Removes every tile for [packageName] from [pageId].
  Future<void> removeTilesOnPage(String packageName, String pageId) async {
    final before = tiles.length;
    tiles.removeWhere(
      (t) => t.packageName == packageName && _normalizedPageId(t) == pageId,
    );
    if (tiles.length == before) return;
    _syncPinned(packageName);
    await _persistTiles();
    await _persistMeta();
    notifyListeners();
  }

  /// Removes every tile for [packageName] from the currently visible page.
  Future<void> removeTilesOnCurrentPage(String packageName) async {
    final currentId = currentTilePageId;
    if (currentId == null) return;
    await removeTilesOnPage(packageName, currentId);
  }

  /// Add a tile for [packageName] on [pageId] (defaults to the current page).
  /// Duplicates are allowed: the same app can be added any number of times.
  Future<Tile> addTile(String packageName, {String? pageId}) async {
    final target =
        pageId ??
        currentTilePageId ??
        (tilePages.isEmpty ? '' : tilePages.first.id);
    final size = tileDefaultSize;
    final tile = Tile(
      id: _newId(),
      packageName: packageName,
      pageId: target,
      w: size,
      h: size,
    );
    tiles.add(tile);
    metaFor(packageName).pinned = true;
    await _persistTiles();
    await _persistMeta();
    notifyListeners();
    return tile;
  }

  Future<void> removeTile(String tileId) async {
    final tile = tileById(tileId);
    if (tile == null) return;
    tiles.removeWhere((t) => t.id == tileId);
    _syncPinned(tile.packageName);
    await _persistTiles();
    await _persistMeta();
    notifyListeners();
  }

  /// Remove every tile for [packageName].
  Future<void> removeTilesFor(String packageName) async {
    final before = tiles.length;
    tiles.removeWhere((t) => t.packageName == packageName);
    if (tiles.length == before) return;
    _syncPinned(packageName);
    await _persistTiles();
    await _persistMeta();
    notifyListeners();
  }

  void _syncPinned(String packageName) {
    metaFor(packageName).pinned = tiles.any(
      (t) => t.packageName == packageName,
    );
  }

  /// Add a tile for [packageName] when [value] is true (on [pageId], defaulting
  /// to the current page), otherwise remove all of its tiles.
  Future<void> setPinned(
    String packageName,
    bool value, {
    String? pageId,
  }) async {
    final has = tiles.any((t) => t.packageName == packageName);
    if (value) {
      if (has) return;
      await addTile(packageName, pageId: pageId);
    } else {
      await removeTilesFor(packageName);
    }
  }

  /// Flip pinning for [packageName]: drop all tiles if any exist, otherwise add
  /// one (to [pageId] or the current page).
  Future<void> togglePinned(String packageName, {String? pageId}) async {
    final has = tiles.any((t) => t.packageName == packageName);
    if (has) {
      await removeTilesFor(packageName);
    } else {
      await addTile(packageName, pageId: pageId);
    }
  }

  Future<TilePage> addTilePage(String name) async {
    final page = TilePage(
      id: _newId(),
      name: name.isEmpty
          ? AppStrings.current.t('页面 {n}', {'n': tilePages.length + 1})
          : name,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    tilePages.add(page);
    currentTilePageIndex = tilePages.length - 1;
    _rememberTilePage();
    await _persistTilePages();
    notifyListeners();
    return page;
  }

  Future<void> renameTilePage(String id, String name) async {
    final page = tilePages.firstWhere((p) => p.id == id);
    page.name = name;
    await _persistTilePages();
    notifyListeners();
  }

  Future<void> deleteTilePage(String id) async {
    if (tilePages.length <= 1) return;
    final removed = tilePages.indexWhere((p) => p.id == id);
    if (removed < 0) return;
    tilePages.removeAt(removed);
    final firstId = tilePages.first.id;
    for (final t in tiles) {
      if (t.pageId == id) t.pageId = firstId;
    }
    // Keep the same logical page in view: if an earlier page disappeared the
    // current index shifts down by one; otherwise clamp to the new range.
    if (currentTilePageIndex > removed) {
      currentTilePageIndex--;
    }
    if (currentTilePageIndex >= tilePages.length) {
      currentTilePageIndex = tilePages.length - 1;
    }
    if (currentTilePageIndex < 0) currentTilePageIndex = 0;
    _rememberTilePage();
    await _persistTilePages();
    await _persistTiles();
    notifyListeners();
  }

  Future<void> assignTileToPage(String tileId, String pageId) async {
    final tile = tileById(tileId);
    if (tile == null) return;
    tile.pageId = pageId;
    await _persistTiles();
    notifyListeners();
  }

  /// Currently visible tile page. Held in memory; mirrored to settings so it
  /// can be restored on the next launch when position memory is on.
  int currentTilePageIndex = 0;

  void setCurrentTilePage(int i) {
    if (i == currentTilePageIndex) return;
    currentTilePageIndex = i;
    _rememberTilePage();
    notifyListeners();
  }

  TilePage _pageForTile(Tile tile) {
    if (tilePages.isEmpty) {
      return TilePage(
        id: '',
        name: AppStrings.current.t('页面 1'),
        createdAt: 0,
      );
    }
    return tilePages.firstWhere(
      (p) => p.id == tile.pageId,
      orElse: () => tilePages.first,
    );
  }

  List<TileSpec> _specsForPage(TilePage page, {required String exclude}) {
    final specs = <TileSpec>[];
    for (final t in tilesOnPage(page)) {
      if (t.id == exclude) continue;
      specs.add(TileSpec(id: t.id, w: t.w, h: t.h, col: t.col, row: t.row));
    }
    return specs;
  }

  /// Move a tile to the given grid cell (finds the nearest free spot on
  /// collision). [cols] is the board's current column count (wider on tablets).
  Future<void> moveTile(
    String tileId,
    int col,
    int row, {
    int cols = kTileCols,
  }) async {
    final tile = tileById(tileId);
    if (tile == null) return;
    final page = _pageForTile(tile);
    final others = _specsForPage(page, exclude: tileId);
    final p = resolveMove(others, tileId, col, row, tile.w, tile.h, cols: cols);
    tile.col = p.col;
    tile.row = p.row;
    await _persistTiles();
    notifyListeners();
  }

  /// Toggle whether a tile shows the app name under its icon.
  Future<void> setTileShowLabel(String tileId, bool value) async {
    final tile = tileById(tileId);
    if (tile == null || tile.showLabel == value) return;
    tile.showLabel = value;
    await _persistTiles();
    notifyListeners();
  }

  /// Toggle whether a tile keeps an inner margin around its content.
  Future<void> setTileInnerPadding(String tileId, bool value) async {
    final tile = tileById(tileId);
    if (tile == null || tile.innerPadding == value) return;
    tile.innerPadding = value;
    await _persistTiles();
    notifyListeners();
  }

  /// Toggle whether a tile draws its backdrop/border.
  Future<void> setTileBorder(String tileId, bool value) async {
    final tile = tileById(tileId);
    if (tile == null || tile.border == value) return;
    tile.border = value;
    await _persistTiles();
    notifyListeners();
  }

  /// Change a tile's size (width 1..kTileCols, height 1..kTileMaxH), relocating
  /// if needed. [cols] is the board's current column count.
  Future<void> setTileSize(
    String tileId,
    int w,
    int h, {
    int cols = kTileCols,
  }) async {
    final tile = tileById(tileId);
    if (tile == null) return;
    final cw = w.clamp(1, kTileCols);
    final ch = h.clamp(1, kTileMaxH);
    final page = _pageForTile(tile);
    final others = _specsForPage(page, exclude: tileId);
    final p = resolveMove(
      others,
      tileId,
      tile.col < 0 ? 0 : tile.col,
      tile.row < 0 ? 0 : tile.row,
      cw,
      ch,
      cols: cols,
    );
    tile.w = cw;
    tile.h = ch;
    tile.col = p.col;
    tile.row = p.row;
    await _persistTiles();
    notifyListeners();
  }

  // ---------------------------------------------------------------- settings

  Future<Map<String, dynamic>> _loadSettings() async =>
      _parseSettings(await storage.readJson(_kSettings));

  Future<void> _persistSettings() async {
    await storage.writeJson(_kSettings, settings);
  }

  bool get showSystemStatusBar =>
      settings['show_system_status_bar'] as bool? ?? true;

  Future<void> setShowSystemStatusBar(bool value) async {
    settings['show_system_status_bar'] = value;
    await _persistSettings();
    await applyStatusBarVisibility(value);
    notifyListeners();
  }

  /// Default side length (in grid cells) for newly added tiles. Defaults to 2,
  /// i.e. a 2x2 tile.
  int get tileDefaultSize =>
      (settings['tile_default_size'] as num?)?.toInt() ?? 2;

  Future<void> setTileDefaultSize(int value) async {
    settings['tile_default_size'] = value.clamp(1, kTileMaxH);
    await _persistSettings();
    notifyListeners();
  }

  // ---- position memory

  /// Whether the last visited position (nav destination, launch sub-tab and
  /// tile page) is restored on the next launch. Defaults to true.
  bool get rememberPosition => settings['remember_position'] as bool? ?? true;

  Future<void> setRememberPosition(bool value) async {
    settings['remember_position'] = value;
    await _persistSettings();
    notifyListeners();
  }

  /// Last top-level destination (启动/应用/快照/设置).
  int get lastHomeIndex {
    if (!rememberPosition) return 0;
    return (settings['last_home_index'] as num?)?.toInt() ?? 0;
  }

  Future<void> setLastHomeIndex(int value) async {
    if (!rememberPosition || lastHomeIndex == value) return;
    settings['last_home_index'] = value;
    await _persistSettings();
  }

  /// Last launch sub-tab (磁贴/分类/收藏/最近).
  int get lastLaunchTab {
    if (!rememberPosition) return 0;
    return (settings['last_launch_tab'] as num?)?.toInt() ?? 0;
  }

  Future<void> setLastLaunchTab(int value) async {
    if (!rememberPosition || lastLaunchTab == value) return;
    settings['last_launch_tab'] = value;
    await _persistSettings();
  }

  void _rememberTilePage() {
    if (!rememberPosition) return;
    settings['last_tile_page'] = currentTilePageIndex;
    unawaited(_persistSettings());
  }

  // ---- haptics

  bool get hapticsEnabled => settings['haptics_enabled'] as bool? ?? true;

  bool get hapticsMainTabs => settings['haptics_main_tabs'] as bool? ?? true;

  bool get hapticsLaunchTabs =>
      settings['haptics_launch_tabs'] as bool? ?? true;

  bool get hapticsTilePages => settings['haptics_tile_pages'] as bool? ?? true;

  HapticEffect get hapticEffect {
    final raw = settings['haptic_effect'] as String?;
    return HapticEffect.values.firstWhere(
      (e) => e.name == raw,
      orElse: () => HapticEffect.selection,
    );
  }

  HapticLevel get hapticLevel {
    final raw = settings['haptic_level'] as String?;
    return HapticLevel.values.firstWhere(
      (l) => l.name == raw,
      orElse: () => HapticLevel.light,
    );
  }

  Future<void> _setHaptic(String key, Object value) async {
    settings[key] = value;
    await _persistSettings();
    notifyListeners();
  }

  Future<void> setHapticsEnabled(bool value) =>
      _setHaptic('haptics_enabled', value);

  Future<void> setHapticsMainTabs(bool value) =>
      _setHaptic('haptics_main_tabs', value);

  Future<void> setHapticsLaunchTabs(bool value) =>
      _setHaptic('haptics_launch_tabs', value);

  Future<void> setHapticsTilePages(bool value) =>
      _setHaptic('haptics_tile_pages', value);

  Future<void> setHapticEffect(HapticEffect value) =>
      _setHaptic('haptic_effect', value.name);

  Future<void> setHapticLevel(HapticLevel value) =>
      _setHaptic('haptic_level', value.name);

  /// Plays a tick for [trigger] if haptics and that trigger are enabled.
  Future<void> haptic(HapticTrigger trigger) async {
    if (!hapticsEnabled) return;
    final allowed = switch (trigger) {
      HapticTrigger.mainTabs => hapticsMainTabs,
      HapticTrigger.launchTabs => hapticsLaunchTabs,
      HapticTrigger.tilePages => hapticsTilePages,
    };
    if (!allowed) return;
    await _emitHaptic();
  }

  /// Plays the configured feedback once, ignoring the per-trigger switches.
  /// Used by the settings preview.
  Future<void> previewHaptic() async {
    if (!hapticsEnabled) return;
    await _emitHaptic();
  }

  /// Duration (ms) and amplitude (1..255) for the current effect/level.
  ///
  /// Flutter's built-in HapticFeedback maps to a handful of system constants
  /// whose strength is fixed by the OS, so the effects were nearly identical
  /// (and `selectionClick` was imperceptible). Driving the vibrator directly
  /// gives real control; duration also carries the strength on devices that
  /// lack amplitude control.
  (int, int) get _hapticPulse {
    switch (hapticEffect) {
      case HapticEffect.selection:
        return (25, 90);
      case HapticEffect.vibrate:
        return (300, 200);
      case HapticEffect.impact:
        switch (hapticLevel) {
          case HapticLevel.light:
            return (30, 140);
          case HapticLevel.medium:
            return (55, 210);
          case HapticLevel.heavy:
            return (95, 255);
        }
    }
  }

  Future<void> _emitHaptic() async {
    final (duration, amplitude) = _hapticPulse;
    try {
      await NativeApps.vibrate(duration, amplitude: amplitude);
    } catch (_) {
      // Haptics are best-effort; ignore devices/platforms without support.
    }
  }

  /// Visual style of the tiles on the 磁贴 board. Defaults to
  /// [TileStyle.colorful].
  TileStyle get tileStyle {
    final raw = settings['tile_style'] as String?;
    return TileStyle.values.firstWhere(
      (s) => s.name == raw,
      orElse: () => TileStyle.colorful,
    );
  }

  Future<void> setTileStyle(TileStyle value) async {
    settings['tile_style'] = value.name;
    await _persistSettings();
    notifyListeners();
  }

  /// User-selected navigation presentation. Defaults to [NavMode.auto].
  NavMode get navMode {
    final raw = settings['nav_mode'] as String?;
    return NavMode.values.firstWhere(
      (m) => m.name == raw,
      orElse: () => NavMode.auto,
    );
  }

  Future<void> setNavMode(NavMode mode) async {
    settings['nav_mode'] = mode.name;
    await _persistSettings();
    notifyListeners();
  }

  /// Resolves [navMode] into a concrete mode for the given screen [size].
  ///
  /// Only [NavMode.auto] depends on the device: a tablet (shortest side >= 600)
  /// held in landscape uses the side rail, everything else uses the bottom bar.
  NavMode resolvedNavMode(double width, double height) {
    final pref = navMode;
    if (pref != NavMode.auto) return pref;
    final isTablet = (width < height ? width : height) >= 600;
    return (isTablet && width > height) ? NavMode.rail : NavMode.bottom;
  }

  /// Light/dark preference. Defaults to [AppThemeMode.system].
  AppThemeMode get themeMode {
    final raw = settings['theme_mode'] as String?;
    return AppThemeMode.values.firstWhere(
      (m) => m.name == raw,
      orElse: () => AppThemeMode.system,
    );
  }

  Future<void> setThemeMode(AppThemeMode mode) async {
    settings['theme_mode'] = mode.name;
    await _persistSettings();
    notifyListeners();
  }

  /// Seed color (ARGB int) used to build the color scheme. Defaults to
  /// [kDefaultThemeColor].
  int get themeColor =>
      (settings['theme_color'] as num?)?.toInt() ?? kDefaultThemeColor;

  Future<void> setThemeColor(int value) async {
    settings['theme_color'] = value;
    await _persistSettings();
    notifyListeners();
  }

  /// UI language preference. Defaults to [AppLanguage.system].
  AppLanguage get language {
    final raw = settings['language'] as String?;
    return AppLanguage.values.firstWhere(
      (l) => l.name == raw,
      orElse: () => AppLanguage.system,
    );
  }

  Future<void> setLanguage(AppLanguage value) async {
    settings['language'] = value.name;
    _applyLanguage();
    await _persistSettings();
    notifyListeners();
  }

  /// The concrete language code (`'zh'` / `'en'`) after resolving
  /// [AppLanguage.system] against the device locale.
  String get resolvedLanguageCode {
    switch (language) {
      case AppLanguage.zh:
        return 'zh';
      case AppLanguage.en:
        return 'en';
      case AppLanguage.system:
        final code = ui.PlatformDispatcher.instance.locale.languageCode;
        return code == 'zh' ? 'zh' : 'en';
    }
  }

  ui.Locale get locale => ui.Locale(resolvedLanguageCode);

  void _applyLanguage() {
    AppStrings.current = AppStrings(resolvedLanguageCode);
  }

  // ---------------------------------------------------------------- sync

  /// All configured remote APK sources (FTP / SMB / WebDAV), in tab order.
  List<RemoteSource> get syncSources {
    final raw = settings['sync_sources'];
    if (raw is List) {
      return raw
          .whereType<Map>()
          .map((m) => RemoteSource.fromMap(m.cast<String, dynamic>()))
          .toList();
    }
    // Migrate the legacy single-source config into the list. The id is derived
    // deterministically so repeated reads stay stable until it is persisted.
    final old = settings['remote_source'];
    if (old is Map) {
      final s = RemoteSource.fromMap(old.cast<String, dynamic>());
      if (s.configured) {
        s.id = _legacySourceId(s);
        if (s.name.trim().isEmpty) s.name = s.protocolLabel;
        return [s];
      }
    }
    return <RemoteSource>[];
  }

  static String _legacySourceId(RemoteSource s) =>
      'src_${s.protocol}_${s.host}_${s.path}'.replaceAll(
        RegExp(r'[^A-Za-z0-9_]+'),
        '_',
      );

  static String newSyncSourceId() =>
      'src_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

  String get activeSyncSourceId => settings['sync_active'] as String? ?? '';

  Future<void> _persistSyncSources(List<RemoteSource> list) async {
    settings['sync_sources'] = list.map((s) => s.toMap()).toList();
    await _persistSettings();
    notifyListeners();
  }

  Future<RemoteSource> addSyncSource(RemoteSource source) async {
    final list = syncSources;
    if (source.id.isEmpty) source.id = newSyncSourceId();
    if (source.name.trim().isEmpty) source.name = source.protocolLabel;
    list.add(source);
    settings['sync_active'] = source.id;
    await _persistSyncSources(list);
    return source;
  }

  Future<void> updateSyncSource(RemoteSource source) async {
    final list = syncSources;
    final i = list.indexWhere((s) => s.id == source.id);
    if (i < 0) {
      await addSyncSource(source);
      return;
    }
    if (source.name.trim().isEmpty) source.name = source.protocolLabel;
    list[i] = source;
    await _persistSyncSources(list);
  }

  Future<void> removeSyncSource(String id) async {
    final list = syncSources..removeWhere((s) => s.id == id);
    if (activeSyncSourceId == id) {
      settings['sync_active'] = list.isEmpty ? '' : list.first.id;
    }
    await _persistSyncSources(list);
  }

  Future<void> setActiveSyncSource(String id) async {
    settings['sync_active'] = id;
    await _persistSettings();
    notifyListeners();
  }

  /// Remembered remote APK source (the active one, or the first configured).
  RemoteSource get remoteSource {
    final list = syncSources;
    if (list.isEmpty) return RemoteSource();
    final id = activeSyncSourceId;
    return list.firstWhere((s) => s.id == id, orElse: () => list.first);
  }

  Future<void> setRemoteSource(RemoteSource source) async {
    final list = syncSources;
    final i = list.indexWhere((s) => s.id == activeSyncSourceId);
    if (i < 0) {
      await addSyncSource(source);
      return;
    }
    source.id = list[i].id;
    if (source.name.trim().isEmpty) source.name = list[i].name;
    list[i] = source;
    await _persistSyncSources(list);
  }

  // ---------------------------------------------------------------- backup

  static const int backupVersion = 1;

  /// Full data package: meta, categories, snapshots, backup lists, tiles,
  /// tile pages, app cache and settings.
  Map<String, dynamic> exportPackage() {
    return <String, dynamic>{
      'app': 'hamstapp',
      'version': backupVersion,
      'exportedAt': DateTime.now().millisecondsSinceEpoch,
      'data': <String, dynamic>{
        'meta': meta.map((k, v) => MapEntry(k, v.toMap())),
        'categories': categories.map((c) => c.toMap()).toList(),
        'snapshots': snapshots.map((s) => s.toMap()).toList(),
        'backup_lists': backupLists.map((b) => b.toMap()).toList(),
        'tiles': tiles.map((t) => t.toMap()).toList(),
        'tile_pages': tilePages.map((p) => p.toMap()).toList(),
        'apps': apps.map((a) => a.toMap()).toList(),
        'settings': settings,
      },
    };
  }

  /// Counts of the main sections inside an [exportPackage], for a summary.
  Map<String, int> packageCounts(Map<String, dynamic> pkg) {
    final data = pkg['data'];
    if (data is! Map) return const <String, int>{};
    int len(Object? v) => v is List ? v.length : (v is Map ? v.length : 0);
    final s = AppStrings.current;
    return <String, int>{
      s.t('应用'): len(data['apps']),
      s.t('分组'): len(data['categories']),
      s.t('快照'): len(data['snapshots']),
      s.t('备份列表'): len(data['backup_lists']),
      s.t('磁贴'): len(data['tiles']),
    };
  }

  /// Replace ALL local data with the contents of [pkg].
  ///
  /// All-or-nothing: the whole package is parsed and validated before any
  /// existing data is touched, so a malformed package cannot partially apply.
  Future<void> importPackage(Map<String, dynamic> pkg) async {
    if (pkg['app'] != 'hamstapp') {
      throw FormatException(AppStrings.current.t('不是囤囤的数据包'));
    }
    final data = pkg['data'];
    if (data is! Map) {
      throw FormatException(AppStrings.current.t('数据包缺少 data 内容'));
    }
    final d = data.cast<String, dynamic>();

    // Parse everything up front.
    final newMeta = _parseMeta(d['meta']);
    final newCategories = _parseCategories(d['categories']);
    final newSnapshots = _parseSnapshots(d['snapshots']);
    final newBackupLists = _parseBackupLists(d['backup_lists']);
    final newTiles = _parseTiles(d['tiles']);
    var newPages = _parseTilePages(d['tile_pages']);
    final newApps = _parseApps(d['apps']);
    final newSettings = _parseSettings(d['settings']);

    if (newPages.isEmpty) {
      newPages = [
        TilePage(
          id: _newId(),
          name: '页面 1',
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ),
      ];
    }
    final validPageIds = newPages.map((p) => p.id).toSet();
    for (final t in newTiles) {
      if (!validPageIds.contains(t.pageId)) t.pageId = newPages.first.id;
    }
    final tiledPackages = newTiles.map((t) => t.packageName).toSet();
    for (final m in newMeta.values) {
      m.pinned = tiledPackages.contains(m.packageName);
    }

    // Commit (all parsed successfully).
    meta = newMeta;
    categories = newCategories;
    snapshots = newSnapshots;
    backupLists = newBackupLists;
    tiles = newTiles;
    tilePages = newPages;
    apps = newApps;
    settings = newSettings;
    // Don't carry the exporter's position memory into this device.
    settings.remove('last_home_index');
    settings.remove('last_launch_tab');
    settings.remove('last_tile_page');
    pendingUninstalls = <AppMeta>[];
    currentTilePageIndex = 0;
    tileEditMode = false;
    query = '';
    await _persistAll();
    await applyStatusBarVisibility(showSystemStatusBar);
    notifyListeners();
  }

  /// Wipe all local data and start fresh.
  Future<void> clearAllData() async {
    meta = <String, AppMeta>{};
    categories = <AppCategory>[];
    snapshots = <Snapshot>[];
    backupLists = <BackupList>[];
    tiles = <Tile>[];
    tilePages = [
        TilePage(
          id: _newId(),
          name: AppStrings.current.t('页面 1'),
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ),
    ];
    apps = <AppInfo>[];
    settings = <String, dynamic>{};
    pendingUninstalls = <AppMeta>[];
    currentTilePageIndex = 0;
    tileEditMode = false;
    query = '';
    lastScanAt = null;
    lastScanMs = 0;
    await _persistAll();
    await applyStatusBarVisibility(true);
    notifyListeners();
  }

  Future<void> _persistAll() async {
    await _persistMeta();
    await _persistCategories();
    await _persistSnapshots();
    await _persistBackupLists();
    await _persistTiles();
    await _persistTilePages();
    await _persistSettings();
    await storage.writeJson(_kAppsCache, apps.map((a) => a.toMap()).toList());
  }

  /// Transient, board-wide edit mode. While on, tiles can be moved/resized and
  /// navigation is blocked until the user finishes editing.
  bool tileEditMode = false;

  void setTileEditMode(bool value) {
    if (tileEditMode == value) return;
    tileEditMode = value;
    notifyListeners();
  }

  /// Manually move a tile page (sub-tab) left/right by [delta].
  Future<void> moveTilePage(int index, int delta) async {
    final target = index + delta;
    if (index < 0 || index >= tilePages.length) return;
    if (target < 0 || target >= tilePages.length) return;
    final page = tilePages.removeAt(index);
    tilePages.insert(target, page);
    currentTilePageIndex = target;
    _rememberTilePage();
    await _persistTilePages();
    notifyListeners();
  }

  // ---------------------------------------------------------------- filtering

  List<AppInfo> get visibleApps {
    final q = query.trim();
    final scores = <String, int>{};
    final list = apps.where((app) {
      switch (scope) {
        case AppScope.user:
          if (app.isSystem) return false;
          break;
        case AppScope.system:
          if (!app.isSystem) return false;
          break;
        case AppScope.all:
          break;
      }
      switch (filter) {
        case AppFilter.favorite:
          if (!metaFor(app.packageName).favorite) return false;
          break;
        case AppFilter.categorized:
          if (metaFor(app.packageName).categoryIds.isEmpty) return false;
          break;
        case AppFilter.uncategorized:
          if (metaFor(app.packageName).categoryIds.isNotEmpty) return false;
          break;
        case AppFilter.hasReason:
          if (metaFor(app.packageName).reason.isEmpty) return false;
          break;
        case AppFilter.unorganized:
          // "Organized" covers anything the user has already invested in from
          // the launch tab: categories, reasons/notes, favorites and tiles.
          final m = metaFor(app.packageName);
          if (m.categoryIds.isNotEmpty ||
              m.reason.isNotEmpty ||
              m.note.isNotEmpty ||
              m.favorite ||
              m.pinned) {
            return false;
          }
          break;
        case AppFilter.uninstalled:
          // Handled separately via [uninstalledApps].
          return false;
        case AppFilter.all:
          break;
      }
      if (filterCategoryId != null) {
        if (!metaFor(app.packageName).categoryIds.contains(filterCategoryId)) {
          return false;
        }
      }
      final score = AppSearch.score(app.packageName, app.appName, q);
      if (score == null) return false;
      if (q.isNotEmpty) scores[app.packageName] = score;
      return true;
    }).toList();

    // While searching, rank by relevance rather than the selected sort order.
    if (q.isNotEmpty) {
      list.sort((a, b) {
        final c = (scores[b.packageName] ?? 0).compareTo(
          scores[a.packageName] ?? 0,
        );
        if (c != 0) return c;
        return a.appName.toLowerCase().compareTo(b.appName.toLowerCase());
      });
      return list;
    }

    late final Comparator<AppInfo> cmp;
    switch (sort) {
      case AppSort.name:
        cmp = (a, b) =>
            a.appName.toLowerCase().compareTo(b.appName.toLowerCase());
        break;
      case AppSort.installTime:
        cmp = (a, b) => a.firstInstallTime.compareTo(b.firstInstallTime);
        break;
      case AppSort.updateTime:
        cmp = (a, b) => a.lastUpdateTime.compareTo(b.lastUpdateTime);
        break;
      case AppSort.size:
        cmp = (a, b) => a.sizeBytes.compareTo(b.sizeBytes);
        break;
    }
    list.sort(sortAscending ? cmp : (a, b) => cmp(b, a));
    return list;
  }

  List<AppInfo> get favorites =>
      apps.where((a) => metaFor(a.packageName).favorite).toList()..sort(
        (a, b) => a.appName.toLowerCase().compareTo(b.appName.toLowerCase()),
      );

  /// Apps launched from this app, most recent first.
  List<AppInfo> get recentApps => recentAppsBy(RecentSort.recent);

  /// Apps launched from this app, optionally filtered to launches at/after
  /// [sinceMillis] and sorted by recency or launch frequency.
  List<AppInfo> recentAppsBy(RecentSort sort, {int sinceMillis = 0}) {
    final list = apps.where((a) {
      final m = metaFor(a.packageName);
      if (m.lastLaunchedAt <= 0) return false;
      if (sinceMillis > 0 && m.lastLaunchedAt < sinceMillis) return false;
      return true;
    }).toList();

    int lastAt(String pkg) => metaFor(pkg).lastLaunchedAt;
    int count(String pkg) => metaFor(pkg).launchCount;

    switch (sort) {
      case RecentSort.recent:
        list.sort(
          (a, b) => lastAt(b.packageName).compareTo(lastAt(a.packageName)),
        );
      case RecentSort.frequent:
        list.sort((a, b) {
          final c = count(b.packageName).compareTo(count(a.packageName));
          if (c != 0) return c;
          return lastAt(b.packageName).compareTo(lastAt(a.packageName));
        });
    }
    return list;
  }

  Future<void> markLaunched(String packageName) async {
    final m = metaFor(packageName);
    m.lastLaunchedAt = DateTime.now().millisecondsSinceEpoch;
    m.launchCount += 1;
    await _persistMeta();
    notifyListeners();
  }

  /// Id of the currently visible tile page, or null when none exist.
  String? get currentTilePageId {
    if (tilePages.isEmpty) return null;
    final i = currentTilePageIndex.clamp(0, tilePages.length - 1);
    return tilePages[i].id;
  }

  AppInfo? appByPackage(String packageName) {
    for (final a in apps) {
      if (a.packageName == packageName) return a;
    }
    return null;
  }

  int get userAppCount => apps.where((a) => !a.isSystem).length;
  int get systemAppCount => apps.where((a) => a.isSystem).length;

  /// Human readable summary shown as a hint in the app bar (long-press).
  String get appsStatsText {
    final s = AppStrings.current;
    if (scanning) return s.t('正在扫描…');
    final last = lastScanAt;
    if (last == null) return s.t('尚未扫描，点击右上角刷新');
    final ago = Fmt.relative(last.millisecondsSinceEpoch);
    if (filter == AppFilter.uninstalled) {
      return s.t('卸载记录 {n} 条 · 上次扫描 {ago}', {
        'n': uninstalledApps.length,
        'ago': ago,
      });
    }
    return s.t('共 {n} 个应用（用户 {user} / 系统 {system}）', {
          'n': apps.length,
          'user': userAppCount,
          'system': systemAppCount,
        }) +
        s.t(' · 显示 {visible} · 用时 {ms} ms · {ago}', {
          'visible': visibleApps.length,
          'ms': lastScanMs,
          'ago': ago,
        });
  }

  static const _kMeta = 'meta';
  static const _kCategories = 'categories';
  static const _kSnapshots = 'snapshots';
  static const _kBackupLists = 'backup_lists';
  static const _kAppsCache = 'apps_cache';
  static const _kTilePages = 'tile_pages';
  static const _kTiles = 'tiles';
  static const _kSettings = 'settings';
}
