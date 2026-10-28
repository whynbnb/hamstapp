import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../l10n/app_strings.dart';
import '../models/app_info.dart';
import '../models/app_meta.dart';
import '../models/backup_list.dart';
import '../models/category.dart';
import '../models/launch_event.dart';
import '../models/remote_source.dart';
import '../models/snapshot.dart';
import '../models/snapshot_diff.dart';
import '../models/tile.dart';
import '../models/tile_page.dart';
import '../models/web_app.dart';
import '../services/native_apps.dart';
import '../services/notification_badges.dart';
import '../services/app_log.dart';
import '../services/custom_icons.dart';
import '../services/pwa.dart';
import '../services/storage.dart';
import '../services/icon_cache.dart';
import '../utils/app_grouping.dart';
import '../utils/format.dart';
import '../utils/permissions.dart';
import '../utils/recommender.dart';
import '../utils/search.dart';
import '../utils/system_ui.dart';
import '../utils/tile_layout.dart';
import '../utils/usage_stats.dart';

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
  hidden,
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
/// - [collapsed]: no persistent bar; a button in the app bar reveals the
///   navigation (long-press it to jump back to Launch).
enum NavMode { auto, bottom, rail, collapsed }

/// Where the page chips sit on the bottom bar when the pages do not fill its
/// width. [center] is the default; [left] is how a plain list behaves.
enum TileBarAlign { center, left, right }

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

/// How a horizontal swipe on the 磁贴 board is split between switching the
/// launch sub-tabs (磁贴/分类/收藏/最近) and the board's own tile pages (磁贴页).
///
/// - [holdDrag]: long-press the board and slide to change the launch sub-tab;
///   a plain swipe always moves the tile pages (the original behaviour).
/// - [topLaunch]: a swipe on the top half changes the launch sub-tab, while the
///   bottom half moves the tile pages.
/// - [bottomLaunch]: a swipe on the bottom half changes the launch sub-tab,
///   while the top half moves the tile pages.
enum TileSwipeMode { holdDrag, topLaunch, bottomLaunch }

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

  AppState(this.storage) {
    // Let the shared cache persist icons fetched on demand by widgets.
    IconCache.instance.onDirty = _persistIcons;
  }

  List<AppInfo> _apps = <AppInfo>[];

  /// Installed apps, plus the user's web entries, sorted as the last scan left
  /// them. Web entries are merged in here so that every app-shaped surface —
  /// the list, search, tiles, categories, favorites, the usage log — treats
  /// them like any other app.
  List<AppInfo> get apps => _mergedApps;

  /// Sets the installed apps (a scan result, an import or a reset).
  set apps(List<AppInfo> value) {
    _apps = value;
    _rebuildApps();
  }

  /// Installed apps only: what the scan wrote, what the uninstall diff compares
  /// against, and what the scan cache holds.
  List<AppInfo> get installedApps => _apps;

  List<AppInfo> _mergedApps = <AppInfo>[];

  /// Websites the user added by hand. They are not packages, so they live
  /// beside the scan instead of inside it — a scan must never wipe them.
  List<WebApp> webApps = <WebApp>[];

  void _rebuildApps() {
    _mergedApps = webApps.isEmpty
        ? _apps
        : <AppInfo>[..._apps, ...webApps.map((w) => w.toAppInfo())];
    // The lookup index below is derived from the merged list.
    _appIndex = null;
  }

  Map<String, AppInfo>? _appIndex;

  Map<String, AppMeta> meta = <String, AppMeta>{};
  List<AppCategory> categories = <AppCategory>[];
  List<Snapshot> snapshots = <Snapshot>[];
  List<BackupList> backupLists = <BackupList>[];
  List<TilePage> tilePages = <TilePage>[];
  List<Tile> tiles = <Tile>[];
  Map<String, dynamic> settings = <String, dynamic>{};

  // ---- date/time format

  /// How dates are written across the app.
  DateStyle get dateStyle =>
      DateStyle.byName(settings['date_style'] as String?);

  /// Whether times are written 24-hour.
  bool get clock24h => settings['clock_24h'] as bool? ?? true;

  Future<void> setDateStyle(DateStyle value) async {
    Fmt.dateStyle = value;
    settings['date_style'] = value.name;
    await _persistSettings();
    notifyListeners();
  }

  Future<void> setClock24h(bool value) async {
    Fmt.clock24h = value;
    settings['clock_24h'] = value;
    await _persistSettings();
    notifyListeners();
  }

  /// Pushes the stored format into [Fmt], which every screen formats with.
  void _applyFormat() {
    Fmt.dateStyle = dateStyle;
    Fmt.clock24h = clock24h;
  }

  /// Timestamped launches used for time-of-day recommendations. Bounded by
  /// [_kLaunchLogCap] / [_kLaunchLogMaxAge].
  List<LaunchEvent> launchLog = <LaunchEvent>[];

  /// Apps detected as uninstalled during the most recent scan and that the
  /// user has not been asked about yet this session.
  List<AppMeta> pendingUninstalls = <AppMeta>[];

  bool initialized = false;
  bool scanning = false;
  String? scanError;
  int lastScanMs = 0;
  DateTime? lastScanAt;
  bool includeSystemInScan = true;

  /// Subscription to the native notification-count stream (lives for the
  /// lifetime of the state).
  StreamSubscription<Map<String, int>>? _notificationSub;

  /// Per-app snapshot facts (requested permissions, signing certificate,
  /// target SDK, install source), read in one native pass and cached. Cleared
  /// on every scan, because an install or an update can change all of it.
  Map<String, AppFacts> appFacts = <String, AppFacts>{};

  Future<void>? _factsFuture;

  /// Whether the fact cache has been filled at least once.
  bool get factsLoaded => appFacts.isNotEmpty;

  /// Reads (and caches) the facts of every installed app. Shared by snapshot
  /// creation and the comparison against the current device, so the native pass
  /// runs once even when both are triggered.
  Future<void> ensureAppFacts() async {
    if (appFacts.isNotEmpty) return;
    final pending = _factsFuture;
    if (pending != null) return pending;
    final future = _loadFacts();
    _factsFuture = future;
    try {
      await future;
    } finally {
      _factsFuture = null;
    }
  }

  Future<void> _loadFacts() async {
    final sw = Stopwatch()..start();
    try {
      final facts = await NativeApps.appFacts();
      appFacts = facts;
      AppLog.instance.log(
        LogModule.apps,
        '读取应用事实 · ${facts.length} 个 · ${sw.elapsedMilliseconds}ms',
      );
    } catch (e) {
      AppLog.instance.error(LogModule.apps, '读取应用事实失败 · $e');
    }
  }

  /// One snapshot entry per installed app, with annotations and facts attached.
  /// The 当前设备 side of a comparison is built from this, so an upgrade's
  /// permission and signature changes show up there too.
  List<SnapshotEntry> deviceEntries() => [
        for (final a in apps)
          SnapshotEntry(
            packageName: a.packageName,
            appName: a.appName,
            versionName: a.versionName,
            versionCode: a.versionCode,
            lastUpdateTime: a.lastUpdateTime,
            firstInstallTime: a.firstInstallTime,
            isSystem: a.isSystem,
            sizeBytes: a.sizeBytes,
            permissions: appFacts[a.packageName]?.permissions ?? const <String>[],
            signature: appFacts[a.packageName]?.signature ?? '',
            targetSdk: appFacts[a.packageName]?.targetSdk ?? a.targetSdk,
            installer: appFacts[a.packageName]?.installer ?? a.installer,
            external: appFacts[a.packageName]?.external ?? false,
            icon: iconFor(a.packageName),
          ),
      ];

  String query = '';
  AppScope scope = AppScope.all;
  AppFilter filter = AppFilter.all;
  AppSort sort = AppSort.name;

  /// Whether [sort] is applied ascending (正序) or descending (倒序).
  bool sortAscending = true;
  String? filterCategoryId;

  /// Whether the choices above survive a restart. The apps list is often used
  /// the same way every time ("only user apps, newest first"), so remembering is
  /// the default; the switch at the bottom of the filter sheet turns it off.
  bool rememberAppFilters = true;

  final Random _rand = Random();

  /// Public wrapper so widgets can trigger a rebuild after mutating a
  /// filter/sort field directly.
  void refresh() {
    // The sheet mutates the fields directly and calls this, so this is where the
    // remembered choice is kept up to date.
    _saveAppFilters();
    notifyListeners();
  }

  /// Applies the stored filter/sort choices, when remembering is on. Called at
  /// startup; also callable on its own (tests, and anything that wants to undo
  /// a session's changes).
  void restoreAppFilters() {
    rememberAppFilters = settings['app_filter_remember'] as bool? ?? true;
    if (!rememberAppFilters) return;
    scope = _enumByName(AppScope.values, settings['app_scope']) ?? AppScope.all;
    filter =
        _enumByName(AppFilter.values, settings['app_filter']) ?? AppFilter.all;
    sort = _enumByName(AppSort.values, settings['app_sort']) ?? AppSort.name;
    sortAscending = settings['app_sort_asc'] as bool? ?? true;
    final category = settings['app_filter_category'];
    filterCategoryId = (category is String && category.isNotEmpty)
        ? category
        : null;
  }

  /// Turns remembering on or off. Switching it on stores the current choices
  /// straight away, so the next start opens exactly like this one.
  Future<void> setRememberAppFilters(bool value) async {
    rememberAppFilters = value;
    settings['app_filter_remember'] = value;
    if (value) _saveAppFilters(force: true);
    await _persistSettings();
    notifyListeners();
  }

  /// Stores the current choices, writing only when something actually changed.
  void _saveAppFilters({bool force = false}) {
    if (!rememberAppFilters) return;
    final scopeName = scope.name;
    final filterName = filter.name;
    final sortName = sort.name;
    final category = filterCategoryId ?? '';
    final unchanged =
        !force &&
        settings['app_scope'] == scopeName &&
        settings['app_filter'] == filterName &&
        settings['app_filter_category'] == category &&
        settings['app_sort'] == sortName &&
        settings['app_sort_asc'] == sortAscending;
    if (unchanged) return;
    settings['app_filter_remember'] = rememberAppFilters;
    settings['app_scope'] = scopeName;
    settings['app_filter'] = filterName;
    settings['app_filter_category'] = category;
    settings['app_sort'] = sortName;
    settings['app_sort_asc'] = sortAscending;
    unawaited(_persistSettings());
  }

  static T? _enumByName<T extends Enum>(List<T> values, dynamic raw) {
    if (raw is! String) return null;
    for (final value in values) {
      if (value.name == raw) return value;
    }
    return null;
  }

  /// Number of non-default filter/sort options, shown as a badge next to the
  /// filter button on the apps screen.
  int get activeAppFilterCount {
    var n = 0;
    if (scope != AppScope.all) n++;
    if (filter != AppFilter.all) n++;
    if (filterCategoryId != null) n++;
    if (sort != AppSort.name) n++;
    if (!sortAscending) n++;
    if (groupMode != AppGroupMode.none) n++;
    return n;
  }

  /// Natural direction for a freshly picked sort: names read A→Z, while time
  /// and size are most useful newest/largest first.
  static bool _defaultAscending(AppSort s) => s == AppSort.name;

  /// Section headers in the app list. Defaults to [AppGroupMode.none].
  AppGroupMode get groupMode {
    final raw = settings['app_group'] as String?;
    return AppGroupMode.values.firstWhere(
      (m) => m.name == raw,
      orElse: () => AppGroupMode.none,
    );
  }

  Future<void> setAppGroupMode(AppGroupMode value) async {
    settings['app_group'] = value.name;
    await _persistSettings();
    notifyListeners();
  }

  /// The app list split into sections, ready for the sticky-header list.
  List<AppGroup> get groupedApps {
    final uncategorized = AppStrings.current.t('未分类');
    return groupApps(
      visibleApps,
      groupMode,
      nameOf: (a) => displayNameFor(a.packageName),
      categoriesOf: (a) => [
        for (final id in metaFor(a.packageName).categoryIds)
          if (categoryById(id) != null) categoryById(id)!.name,
      ],
      uncategorizedLabel: uncategorized,
      categoryOrder: [for (final c in categories) c.name],
    );
  }

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
    query = '';
    scope = AppScope.all;
    filter = AppFilter.all;
    filterCategoryId = null;
    sort = AppSort.name;
    sortAscending = true;
    refresh();
  }

  /// Applies a whole set of list conditions at once — what the 搜索与筛选 page
  /// collects — with a single settings write instead of one per field.
  Future<void> applyAppFilters({
    required String query,
    required AppScope scope,
    required AppFilter filter,
    required String? filterCategoryId,
    required AppSort sort,
    required bool sortAscending,
    required AppGroupMode group,
  }) async {
    this.query = query.trim();
    this.scope = scope;
    this.filter = filter;
    this.filterCategoryId = filterCategoryId;
    this.sort = sort;
    this.sortAscending = sortAscending;
    settings['app_group'] = group.name;
    if (rememberAppFilters) {
      settings['app_filter_remember'] = true;
      settings['app_scope'] = scope.name;
      settings['app_filter'] = filter.name;
      settings['app_filter_category'] = filterCategoryId ?? '';
      settings['app_sort'] = sort.name;
      settings['app_sort_asc'] = sortAscending;
    }
    if (this.query.isNotEmpty) {
      final list = List<String>.from(searchHistory)
        ..removeWhere((e) => e == this.query)
        ..insert(0, this.query);
      settings['search_history'] = list.take(kSearchHistoryMax).toList();
    }
    notifyListeners();
    await _persistSettings();
  }

  String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch}_${_rand.nextInt(1 << 32)}';

  // ---------------------------------------------------------------- lifecycle

  Future<void> init() async {
    meta = await _loadMeta();
    _syncIconActivities();
    await _loadCustomIcons();
    IconCache.instance.iconPack = iconPack;
    categories = await _loadCategories();
    snapshots = await _loadSnapshots();
    backupLists = await _loadBackupLists();
    settings = await _loadSettings();
    final hourPick = await storage.readJson(_kWidgetHourPick);
    if (hourPick is Map) {
      _hourPick = hourPick.cast<String, dynamic>();
    }
    // Restore the remembered filter/sort before the first build.
    restoreAppFilters();
    IconCache.instance.replaceAll(
      IconCache.decode(await storage.readJson(_kIcons)),
    );
    await _loadIconStamps();
    _applyLanguage();
    _applyFormat();
    // A theme that follows the wallpaper must be re-seeded before the first
    // frame, otherwise the previous seed flashes on screen.
    if (themeFollowWallpaper) await refreshWallpaperColor();
    launchLog = await _loadLaunchLog();
    _pruneLaunchLog();
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
    // The launcher's long-press list is rebuilt from the stored launch log.
    unawaited(syncRecentShortcuts());
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
    // One-time migration: tiles created before explicit cells get concrete
    // positions so the board stops re-packing them on later edits.
    await _migrateTilePositions();
    apps = _parseApps(await storage.readJson(_kAppsCache));
    webApps = _parseWebApps(await storage.readJson(_kWebApps));
    _rebuildApps();
    // Icons cached before stamps existed are taken as belonging to the version
    // the cached scan knows about; the system check below then only refreshes
    // the apps that changed since, instead of re-reading everything.
    var seededStamps = false;
    for (final a in installedApps) {
      if (_iconStamps.containsKey(a.packageName)) continue;
      final slot = IconCache.instance.slotFor(a.packageName);
      if (!IconCache.instance.containsKey(slot)) continue;
      _iconStamps[a.packageName] = a.lastUpdateTime;
      seededStamps = true;
    }
    if (seededStamps) unawaited(_persistIconStamps());
    _applyNotificationBadges();
    _applyLogging();
    NativeApps.startListening();
    _notificationSub ??= NativeApps.notificationCounts.listen(_onNotificationCounts);
    // The listener service is often bound (and publishes its counts) *before*
    // this engine exists, so those events were dropped; seed from the native
    // side now instead of waiting for the next notification. The rebind also
    // recovers a listener the system dropped while the app was closed.
    unawaited(syncNotificationBadges());
    // Fill in entries added before the site itself was read (name, icon,
    // manifest) and ones still missing an icon — quiet, best effort, once per
    // session.
    if (webApps.any(
      (w) =>
          (w.manifestUrl.isEmpty && w.iconUrl.isEmpty) ||
          !IconCache.instance.containsKey(w.id),
    )) {
      unawaited(backfillWebApps());
    }
    initialized = true;
    notifyListeners();
    // A widget used while 囤囤 was closed: count those launches now, then
    // refresh the schedule the widget reads (the counts may change it).
    unawaited(consumeHomeWidgetLaunches());
    unawaited(syncHomeWidget(force: true));
    unawaited(syncPageWidget());
    // An app updated while 囤囤 was closed: read its icon now, without a scan.
    unawaited(refreshUpdatedIcons());
  }

  void _onNotificationCounts(Map<String, int> counts) {
    NotificationBadges.instance.setCounts(counts);
    AppLog.instance.log(
      LogModule.notifications,
      '未读更新 · ${counts.length} 个应用 · $counts',
    );
  }

  /// Pushes the persisted log switch into [AppLog] and the native bridge.
  void _applyLogging() {
    final on = loggingEnabled;
    AppLog.instance.setEnabled(on);
    unawaited(_pushLoggingFlag(on));
  }

  Future<void> _pushLoggingFlag(bool on) async {
    try {
      await NativeApps.setLoggingEnabled(on);
    } catch (_) {
      // Native side unavailable (e.g. widget tests).
    }
  }

  /// Whether the in-app log records anything. Off by default.
  bool get loggingEnabled => settings['logging_enabled'] as bool? ?? false;

  Future<void> setLoggingEnabled(bool value) async {
    settings['logging_enabled'] = value;
    AppLog.instance.setEnabled(value);
    try {
      await NativeApps.setLoggingEnabled(value);
    } catch (_) {
      // Native side unavailable (e.g. widget tests).
    }
    await _persistSettings();
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

  List<WebApp> _parseWebApps(dynamic raw) {
    if (raw is List) {
      return raw
          .map((e) => WebApp.fromMap((e as Map).cast<dynamic, dynamic>()))
          .where((w) => w.id.isNotEmpty)
          .toList();
    }
    return <WebApp>[];
  }

  // ------------------------------------------------------------- web entries

  /// The hand-added entry behind a synthetic package id, or null.
  WebApp? webAppById(String id) {
    for (final w in webApps) {
      if (w.id == id) return w;
    }
    return null;
  }

  /// Adds a website as an app-shaped entry. Available everywhere apps are: a
  /// tile, a category, favorites, search, the usage log.
  ///
  /// [site] is what [PwaDiscovery] read from the address (null when the address
  /// could not be reached) and [iconBytes] its icon, so a PWA brings its own
  /// name, icon, colours and display mode along.
  Future<void> addWebApp({
    required String url,
    String name = '',
    PwaSite? site,
    Uint8List? iconBytes,
  }) async {
    final now = DateTime.now();
    final entry = WebApp(
      id: WebApp.newId(now),
      name: name.trim(),
      url: url.trim(),
      createdAt: now.millisecondsSinceEpoch,
    );
    if (site != null) entry.applySite(site);
    if (entry.name.trim().isEmpty) entry.name = entry.url;
    webApps.add(entry);
    if (iconBytes != null && iconBytes.isNotEmpty) {
      IconCache.instance.put(entry.id, iconBytes);
      await _persistIcons();
    }
    _rebuildApps();
    metaFor(entry.id).lastKnownName = entry.name;
    await _persistWebApps();
    await _persistMeta();
    AppLog.instance.log(
      LogModule.apps,
      '网页入口 · 添加 · ${entry.name} · ${entry.url} · '
          '${entry.isPwa ? 'PWA（${entry.display}）' : '普通网页'}',
    );
    notifyListeners();
    unawaited(syncHomeWidget(force: true));
  }

  /// Re-reads the address: a site may have gained a manifest (or changed its
  /// name/icon) since it was added. Returns what was found, or null.
  Future<PwaSite?> refreshWebApp(String id) async {
    final entry = webAppById(id);
    if (entry == null) return null;
    final site = await PwaDiscovery.discover(entry.url);
    if (site == null) return null;
    entry.applySite(site);
    if (entry.name.trim().isEmpty) entry.name = entry.url;
    // Normalised (validated, scaled, PNG) so a big or odd icon cannot break the
    // cache, the launch screen or the Binder.
    final bytes = await PwaDiscovery.fetchBestIcon(site);
    if (bytes != null) {
      IconCache.instance.put(entry.id, bytes);
      await _persistIcons();
    }
    _rebuildApps();
    metaFor(id).lastKnownName = entry.name;
    await _persistWebApps();
    await _persistMeta();
    AppLog.instance.log(
      LogModule.apps,
      '网页入口 · 识别 · ${entry.name} · ${entry.url} · '
          '${entry.isPwa ? 'PWA ${entry.display} · ${entry.manifestUrl}' : '无清单'}',
    );
    notifyListeners();
    unawaited(syncHomeWidget());
    return site;
  }

  Future<void> updateWebApp(
    String id, {
    String? name,
    String? url,
    String? openMode,
    bool? hideStatusBar,
    String? browserPackage,
    String? browserName,
  }) async {
    final index = webApps.indexWhere((w) => w.id == id);
    if (index < 0) return;
    final entry = webApps[index];
    if (name != null && name.trim().isNotEmpty) entry.name = name.trim();
    if (openMode != null) entry.openMode = openMode;
    if (hideStatusBar != null) entry.hideStatusBar = hideStatusBar;
    if (browserPackage != null) entry.browserPackage = browserPackage;
    if (browserName != null) entry.browserName = browserName;
    if (url != null && url.trim().isNotEmpty && url.trim() != entry.url) {
      entry.url = url.trim();
      // What the manifest said described the old address; drop it rather than
      // launch into the wrong start_url. Callers re-read the site afterwards.
      entry.startUrl = entry.url;
      entry.scope = '';
      entry.display = WebApp.displayBrowser;
      entry.themeColor = 0;
      entry.backgroundColor = 0;
      entry.manifestUrl = '';
      entry.iconUrl = '';
    }
    metaFor(id).lastKnownName = entry.name;
    _rebuildApps();
    await _persistWebApps();
    await _persistMeta();
    notifyListeners();
    unawaited(syncHomeWidget(force: true));
  }

  /// Removes a web entry, together with everything that pointed at it (its
  /// metadata and any tile copies).
  Future<void> removeWebApp(String id) async {
    if (!webApps.any((w) => w.id == id)) return;
    webApps.removeWhere((w) => w.id == id);
    meta.remove(id);
    tiles.removeWhere((t) => t.packageName == id);
    _rebuildApps();
    await _persistWebApps();
    await _persistMeta();
    await _persistTiles();
    notifyListeners();
    unawaited(syncHomeWidget(force: true));
  }

  /// Re-reads the addresses of entries that were added before the site was
  /// identified (older builds stored only a name and a URL) and of entries whose
  /// icon never made it into the cache, so their icons and manifest details
  /// appear without the user having to ask. Runs once per session, quietly.
  Future<void> backfillWebApps() async {
    if (_webBackfillDone) return;
    _webBackfillDone = true;
    for (final entry in List<WebApp>.from(webApps)) {
      final needsSite = entry.manifestUrl.isEmpty && entry.iconUrl.isEmpty;
      final needsIcon = !IconCache.instance.containsKey(entry.id);
      if (!needsSite && !needsIcon) continue;
      if (entry.url.isEmpty) continue;
      try {
        await refreshWebApp(entry.id);
      } catch (_) {
        // Offline, or the site is gone: leave the entry as it is.
      }
    }
    // One push covers every entry the loop refreshed.
    unawaited(syncHomeWidget(force: true));
  }

  bool _webBackfillDone = false;

  Future<void> _persistWebApps() => storage.writeJson(
        _kWebApps,
        webApps.map((w) => w.toMap()).toList(),
      );

  Map<String, dynamic> _parseSettings(dynamic raw) {
    // Copy into a plain map: `raw.cast` returns a view whose `[]=` re-checks
    // values against the source map's value type, which rejects settings that
    // mix map- and scalar-valued keys.
    if (raw is Map) return Map<String, dynamic>.from(raw);
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

  Future<List<LaunchEvent>> _loadLaunchLog() async =>
      _parseLaunchLog(await storage.readJson(_kLaunchLog));

  List<LaunchEvent> _parseLaunchLog(dynamic raw) {
    if (raw is! List) return <LaunchEvent>[];
    final list = <LaunchEvent>[];
    for (final e in raw) {
      if (e is! Map) continue;
      final ev = LaunchEvent.fromMap(e.cast<String, dynamic>());
      if (ev.packageName.isNotEmpty && ev.at > 0) list.add(ev);
    }
    return list;
  }

  // ---------------------------------------------------------------- scanning

  Future<void> scan() async {
    if (scanning) return;
    scanning = true;
    scanError = null;
    pendingUninstalls = <AppMeta>[];
    // Versions, permissions and certificates can all have moved on.
    appFacts = <String, AppFacts>{};
    notifyListeners();

    AppLog.instance.log(
      LogModule.apps,
      '开始扫描应用（含系统应用: $includeSystemInScan）',
    );

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
      // Only installed apps are cached: web entries have their own store and
      // must survive a scan.
      await storage.writeJson(
        _kAppsCache,
        installedApps.map((e) => e.toMap()).toList(),
      );
      await _persistMeta();
      // Installs/updates may have changed which entries packages expose.
      NativeApps.clearLaunchEntryCache();

      sw.stop();
      lastScanMs = sw.elapsedMilliseconds;
      lastScanAt = now;
      AppLog.instance.log(
        LogModule.apps,
        '扫描完成 · ${result.length} 个应用 · ${sw.elapsedMilliseconds}ms'
            '${pending.isEmpty ? '' : ' · 疑似卸载 ${pending.length} 个'}',
      );
      // Installed web apps are worth reporting explicitly: they are the only
      // way to tell "the device has none" from "detection missed one".
      final webApps = result.where((a) => a.isWebApp).toList();
      AppLog.instance.log(LogModule.apps, '网页应用 · ${webApps.length} 个');
      for (final a in webApps) {
        AppLog.instance.log(
          LogModule.apps,
          '网页应用 · ${a.appName} · ${a.packageName} · '
              '${a.webUrl.isEmpty ? '网址未知' : a.webUrl}'
              '${a.webSignal.isEmpty ? '' : ' · 命中=${a.webSignal}'}',
        );
      }
    } catch (e) {
      sw.stop();
      lastScanMs = sw.elapsedMilliseconds;
      scanError = e.toString();
      AppLog.instance.error(LogModule.apps, '扫描失败 · $e');
    } finally {
      scanning = false;
      notifyListeners();
    }
    // Refresh the icons of apps that were installed or updated since their
    // icon was read, so a new version's icon shows up without re-reading the
    // whole list (Settings still has a full "refresh icon cache").
    if (scanError == null) {
      unawaited(refreshChangedIcons());
      // An uninstalled app must not stay on the long-press list.
      unawaited(syncRecentShortcuts());
      // Read permissions/certificates, warn about updates that added some and
      // take the automatic snapshot when it is due.
      unawaited(_afterScanMaintenance());
      // A new app list changes what the widget can offer.
      unawaited(syncHomeWidget(force: true));
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
    return {for (final a in installedApps) a.packageName: a.appName};
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

  /// Apps the user hid from the list, newest first by name.
  List<AppInfo> get hiddenApps =>
      apps.where((a) => metaFor(a.packageName).hidden).toList()..sort(
        (a, b) => _sortName(a).compareTo(_sortName(b)),
      );

  Future<void> setHidden(String packageName, bool hidden) async {
    metaFor(packageName).hidden = hidden;
    await _persistMeta();
    notifyListeners();
    unawaited(syncHomeWidget(force: true));
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
    String? launchActivity,
    String? launchEntryLabel,
    bool? nameFollowsEntry,
  }) async {
    final m = metaFor(packageName);
    if (reason != null) m.reason = reason;
    if (note != null) m.note = note;
    if (favorite != null) m.favorite = favorite;
    if (categoryIds != null) m.categoryIds = categoryIds;
    if (uninstallReason != null) m.uninstallReason = uninstallReason;
    if (launchActivity != null) {
      m.launchActivity = launchActivity;
      m.launchEntryLabel = launchEntryLabel ?? '';
      // The icon follows the chosen entry.
      _syncIconActivities();
    }
    if (nameFollowsEntry != null) m.nameFollowsEntry = nameFollowsEntry;
    await _persistMeta();
    notifyListeners();
    // The widget draws that entry's icon and label, and launches it; refresh
    // now that the choice changed.
    if (launchActivity != null) unawaited(syncHomeWidget(force: true));
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

  /// The category with [id], or null when it was deleted.
  AppCategory? categoryById(String id) {
    for (final c in categories) {
      if (c.id == id) return c;
    }
    return null;
  }

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

    // Permissions, certificate, target SDK and install source, so a later
    // comparison can say what an update actually changed.
    await ensureAppFacts();

    // Currently installed apps, together with their annotations.
    for (final a in apps) {
      final m = metaFor(a.packageName);
      seen.add(a.packageName);
      final facts = appFacts[a.packageName];
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
          permissions: facts?.permissions ?? const <String>[],
          signature: facts?.signature ?? '',
          targetSdk: facts?.targetSdk ?? a.targetSdk,
          installer: facts?.installer ?? a.installer,
          external: facts?.external ?? false,
          reason: m.reason,
          note: m.note,
          categoryIds: List<String>.from(m.categoryIds),
          favorite: m.favorite,
          pinned: m.pinned,
          icon: iconFor(a.packageName),
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
          icon: iconFor(m.packageName),
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

  // ------------------------------------------------------------------- icons

  /// When each app's icon was last read, keyed by package: the app's
  /// `lastUpdateTime` at that moment. A scan uses it to tell which apps were
  /// installed or updated since, and therefore may show a new icon.
  Map<String, int> _iconStamps = <String, int>{};

  Future<void> _loadIconStamps() async {
    final raw = await storage.readJson(_kIconStamps);
    if (raw is! Map) return;
    _iconStamps = {
      for (final e in raw.entries)
        if (e.key is String && e.value is num)
          e.key as String: (e.value as num).toInt(),
    };
  }

  Future<void> _persistIconStamps() =>
      storage.writeJson(_kIconStamps, _iconStamps);

  /// Cached icon bytes for [packageName], accounting for a pinned entry, or
  /// null when never fetched.
  Uint8List? iconFor(String packageName) =>
      IconCache.instance[IconCache.instance.slotFor(packageName)];

  /// Whether [packageName]'s icon was read before its current version, so it
  /// may have changed with an update (or was never read at all).
  bool iconNeedsRefresh(String packageName) {
    final app = appByPackage(packageName);
    if (app == null || app.isWebEntry) return false;
    final slot = IconCache.instance.slotFor(packageName);
    if (!IconCache.instance.containsKey(slot)) return true;
    final stamp = _iconStamps[packageName];
    // An icon read from a *newer* system version than the last scan knows is
    // already current (see [refreshUpdatedIcons]), so `<` rather than `!=`.
    return stamp == null || stamp < app.lastUpdateTime;
  }

  /// Store a freshly fetched icon; [IconCache] persists it (coalesced).
  void rememberIcon(String packageName, Uint8List bytes) {
    IconCache.instance.put(IconCache.instance.slotFor(packageName), bytes);
  }

  /// Mirrors each app's pinned desktop entry into [IconCache], so icons paint
  /// the entry the user chose (entries can have their own icons).
  void _syncIconActivities() {
    IconCache.instance.setActivities({
      for (final m in meta.values)
        if (m.launchActivity.isNotEmpty) m.packageName: m.launchActivity,
    });
  }

  Future<void> _persistIcons() async {
    await storage.writeJson(_kIcons, IconCache.instance.toJson());
  }

  /// Drops every cached icon — memory and disk. Icons are read again on demand
  /// by [AppIcon], so nothing the user made is lost; this only frees the file.
  Future<void> clearIconCache() async {
    IconCache.instance.replaceAll(<String, Uint8List>{});
    await _persistIcons();
    AppLog.instance.log(LogModule.apps, '存储 · 已清理图标缓存');
    notifyListeners();
  }

  /// Drops the cached scan result. The apps already in memory stay (and web
  /// entries are unaffected), so the list does not empty now; the next start
  /// rescans and rebuilds the file.
  Future<void> clearScanCache() async {
    Storage.deleteFile(_kAppsCache);
    AppLog.instance.log(LogModule.apps, '存储 · 已清理应用扫描缓存');
  }

  Future<int>? _iconRefresh;

  /// Drop the icon cache and re-read icons for every installed app from the
  /// system. Returns how many icons were (re)loaded.
  ///
  /// Called by the settings "refresh icon cache" action. Concurrent calls share
  /// the same run.
  Future<int> refreshIconCache() => _startIconRefresh(all: true);

  /// Re-read only the icons of apps installed or updated since their icon was
  /// last read. A scan calls this, so an updated app shows its new icon without
  /// re-reading the whole list; returns how many icons were re-read.
  Future<int> refreshChangedIcons() => _startIconRefresh(all: false);

  /// Compares the package manager's install/update times with what the last
  /// scan saw and re-reads the icons of apps that changed since. Cheap enough
  /// to run on start-up and whenever 囤囤 returns to the foreground, so an app
  /// updated while it was closed still gets its new icon without a full scan.
  Future<int> refreshUpdatedIcons() async {
    if (installedApps.isEmpty) return 0;
    final systemStamps = await NativeApps.packageStamps();
    if (systemStamps.isEmpty) return 0;
    final due = <AppInfo>[];
    for (final a in installedApps) {
      final fresh = systemStamps[a.packageName];
      if (fresh == null || fresh <= a.lastUpdateTime) continue;
      final known = _iconStamps[a.packageName];
      if (known != null && known >= fresh) continue;
      due.add(a);
    }
    if (due.isEmpty) return 0;
    return _startIconRefresh(all: false, systemStamps: systemStamps, only: due);
  }

  Future<int> _startIconRefresh({
    required bool all,
    Map<String, int>? systemStamps,
    List<AppInfo>? only,
  }) {
    final running = _iconRefresh;
    if (running != null) return running;
    final run = all
        ? _runIconRefresh()
        : _runChangedIconRefresh(systemStamps: systemStamps, only: only);
    _iconRefresh = run;
    // Clear the guard in a microtask, not inside the body: a run that returns
    // before its first await would otherwise be pinned for the whole session.
    unawaited(
      run.whenComplete(() {
        if (identical(_iconRefresh, run)) _iconRefresh = null;
      }),
    );
    return run;
  }

  Future<int> _runIconRefresh() async {
    // Web entries are not installed apps, so their icons are never refetched
    // — read them out *before* the sweep clears the cache, or they are lost
    // until the next background re-read.
    final webIcons = _webEntryIcons();
    IconCache.instance.clearSilent();
    // The native side holds decoded icons for the app's lifetime; drop its
    // copy too, or the sweep reads back the very bytes it is replacing.
    await NativeApps.clearIconCache();
    final next = <String, Uint8List>{};
    final stamps = <String, int>{};
    for (final a in installedApps) {
      try {
        // Fetch the icon of the entry this app launches, not blindly the
        // application's own: they can differ.
        final activity = IconCache.instance.activityFor(a.packageName);
        final bytes = await NativeApps.getAppIcon(
          a.packageName,
          size: IconCache.fetchSize,
          activity: activity.isEmpty ? null : activity,
          refresh: true,
        );
        if (bytes != null && bytes.isNotEmpty) {
          next[IconCache.instance.slotFor(a.packageName)] = bytes;
          stamps[a.packageName] = a.lastUpdateTime;
        }
      } catch (_) {
        // Keep going: one unreadable icon must not abort the refresh.
      }
    }
    // Put the hand-added web entries' icons back on top of the fresh map.
    next.addAll(webIcons);
    IconCache.instance.replaceAll(next);
    _iconStamps = stamps;
    await _persistIcons();
    await _persistIconStamps();
    notifyListeners();
    return next.length;
  }

  Future<int> _runChangedIconRefresh({
    Map<String, int>? systemStamps,
    List<AppInfo>? only,
  }) async {
    final due = only ?? <AppInfo>[];
    if (only == null) {
      for (final a in installedApps) {
        final slot = IconCache.instance.slotFor(a.packageName);
        final baseline = a.lastUpdateTime;
        final known = _iconStamps[a.packageName];
        if (!IconCache.instance.containsKey(slot) ||
            known == null ||
            known < baseline) {
          due.add(a);
        }
      }
    }
    if (due.isEmpty) return 0;

    var count = 0;
    for (final a in due) {
      try {
        final activity = IconCache.instance.activityFor(a.packageName);
        final bytes = await NativeApps.getAppIcon(
          a.packageName,
          size: IconCache.fetchSize,
          activity: activity.isEmpty ? null : activity,
          refresh: true,
        );
        if (bytes == null || bytes.isEmpty) continue;
        IconCache.instance.put(
          IconCache.instance.slotFor(a.packageName),
          bytes,
        );
        _iconStamps[a.packageName] =
            systemStamps?[a.packageName] ?? a.lastUpdateTime;
        count++;
      } catch (_) {
        // Keep going: one unreadable icon must not abort the refresh.
      }
    }
    // Forget packages that are gone, so the map cannot grow forever.
    final installed = installedApps.map((a) => a.packageName).toSet();
    _iconStamps.removeWhere((pkg, _) => !installed.contains(pkg));
    await _persistIconStamps();
    if (count > 0) {
      await _persistIcons();
      IconCache.instance.notifyUpdated();
      notifyListeners();
    }
    return count;
  }

  /// Re-reads one app's icon from the system, ignoring both the copy the native
  /// side holds and the one on disk. Returns false when the system reports no
  /// icon (e.g. the package vanished).
  ///
  /// The detail page's 强制刷新图标 action uses this; the app list picks it up
  /// through [IconCache]'s notification.
  Future<bool> refreshAppIcon(String packageName) async {
    final app = appByPackage(packageName);
    Uint8List? bytes;
    try {
      final activity = IconCache.instance.activityFor(packageName);
      bytes = await NativeApps.getAppIcon(
        packageName,
        size: IconCache.fetchSize,
        activity: activity.isEmpty ? null : activity,
        refresh: true,
      );
    } catch (_) {
      bytes = null;
    }
    final label = app?.appName ?? packageName;
    if (bytes == null || bytes.isEmpty) {
      AppLog.instance.log(LogModule.apps, '图标 · 刷新失败 · $label');
      return false;
    }
    IconCache.instance.put(IconCache.instance.slotFor(packageName), bytes);
    IconCache.instance.notifyUpdated();
    if (app != null) {
      // Keep a stamp taken from a *newer* system version (see
      // [refreshUpdatedIcons]); never move it backwards.
      final known = _iconStamps[packageName];
      _iconStamps[packageName] =
          known == null || known < app.lastUpdateTime
          ? app.lastUpdateTime
          : known;
    }
    await _persistIcons();
    await _persistIconStamps();
    notifyListeners();
    AppLog.instance.log(LogModule.apps, '图标 · 已刷新 · $label');
    return true;
  }

  /// The icons of hand-added web entries, as they are right now: a bulk refresh
  /// must carry them over, since none of them belongs to an installed app.
  Map<String, Uint8List> _webEntryIcons() {
    final kept = <String, Uint8List>{};
    for (final w in webApps) {
      final bytes = IconCache.instance[w.id];
      if (bytes != null && bytes.isNotEmpty) kept[w.id] = bytes;
    }
    return kept;
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
    // The 4x1 tab strip mirrors the page list.
    unawaited(syncPageWidget());
  }

  Future<List<Tile>> _loadTiles() async =>
      _parseTiles(await storage.readJson(_kTiles));

  Future<void> _persistTiles() async {
    await storage.writeJson(_kTiles, tiles.map((t) => t.toMap()).toList());
    // A tile edit is deliberate (unlike a launch), so the widget may adopt the
    // new pinned order at once instead of waiting for the next hour.
    if (initialized) _forgetHour();
  }

  Tile? tileById(String id) {
    for (final t in tiles) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// Tiles shown on [page], in stable display order. Tiles whose page no longer
  /// exists fall back to the first page; app tiles whose app is gone are
  /// skipped (info tiles have no app by design and are always kept).
  List<Tile> tilesOnPage(TilePage page) {
    if (tilePages.isEmpty) return const <Tile>[];
    final firstId = tilePages.first.id;
    final validIds = tilePages.map((p) => p.id).toSet();
    final result = tiles.where((t) {
      if (!t.isInfo && appByPackage(t.packageName) == null) return false;
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
    // Give the new tile a concrete cell so it never gets auto-packed (and
    // re-flowed) later by additions or deletions elsewhere on the page.
    final (col, row) = _firstFreeSpot(target, size, size);
    final tile = Tile(
      id: _newId(),
      packageName: packageName,
      pageId: target,
      col: col,
      row: row,
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

  /// Sentinel spec id used to ask the layout engine where a new tile would go.
  static const String _kNewTileSpecId = '\u0000new-tile';
  /// Adds one of the live info tiles (clock, date, battery, storage, unread),
  /// sized by its kind. These have no app behind them, so no meta is touched.
  Future<Tile> addInfoTile(
    TileKind kind, {
    String? pageId,
    Map<String, dynamic>? options,
  }) async {
    final target =
        pageId ??
        currentTilePageId ??
        (tilePages.isEmpty ? '' : tilePages.first.id);
    final (w, h) = kind.defaultSize;
    final (col, row) = _firstFreeSpot(target, w, h);
    final tile = Tile(
      id: _newId(),
      packageName: '',
      pageId: target,
      kind: kind,
      options: options ?? const <String, dynamic>{},
      col: col,
      row: row,
      w: w,
      h: h,
    );
    tiles.add(tile);
    await _persistTiles();
    notifyListeners();
    return tile;
  }

  /// Merges [values] into a tile's own settings (a folder's category, how many
  /// days "new installs" looks back, ...). Null values delete a key.
  Future<void> setTileOptions(
    String tileId,
    Map<String, dynamic> values,
  ) async {
    final tile = tileById(tileId);
    if (tile == null) return;
    final next = <String, dynamic>{...tile.options};
    values.forEach((key, value) {
      if (value == null) {
        next.remove(key);
      } else {
        next[key] = value;
      }
    });
    tile.options = next;
    await _persistTiles();
    notifyListeners();
  }
  /// Concrete (col,row) for a [w]x[h] tile on [pageId]: the first free cell
  /// when packing this page's current tiles.
  (int, int) _firstFreeSpot(String pageId, int w, int h) {
    final specs = <TileSpec>[
      for (final t in tiles)
        if (_normalizedPageId(t) == pageId)
          TileSpec(id: t.id, w: t.w, h: t.h, col: t.col, row: t.row),
      TileSpec(id: _kNewTileSpecId, w: w, h: h),
    ];
    final layout = resolveTileLayout(specs, cols: kTileCols);
    final p = layout.placements[_kNewTileSpecId];
    return p == null ? (0, 0) : (p.col, p.row);
  }

  /// Give every tile an explicit cell so the board no longer re-packs tiles
  /// with an "auto" position when another tile is added, moved or deleted.
  Future<void> _migrateTilePositions() async {
    var changed = false;
    for (final page in tilePages) {
      final pageTiles =
          tiles.where((t) => _normalizedPageId(t) == page.id).toList()
            ..sort((a, b) {
              final ar = a.row < 0 ? 1 << 20 : a.row;
              final br = b.row < 0 ? 1 << 20 : b.row;
              if (ar != br) return ar.compareTo(br);
              final ac = a.col < 0 ? 1 << 20 : a.col;
              final bc = b.col < 0 ? 1 << 20 : b.col;
              if (ac != bc) return ac.compareTo(bc);
              return a.id.compareTo(b.id);
            });
      final specs = pageTiles
          .map((t) => TileSpec(id: t.id, w: t.w, h: t.h, col: t.col, row: t.row))
          .toList();
      final layout = resolveTileLayout(specs, cols: kTileCols);
      for (final t in pageTiles) {
        if (t.col >= 0 && t.row >= 0) continue;
        final p = layout.placements[t.id];
        if (p == null) continue;
        t.col = p.col;
        t.row = p.row;
        changed = true;
      }
    }
    if (changed) await _persistTiles();
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
  /// Removes several tiles at once (the board's multi-select mode).
  Future<void> removeTiles(Iterable<String> ids) async {
    final set = ids.toSet();
    if (set.isEmpty) return;
    final removed = tiles.where((t) => set.contains(t.id)).toList();
    tiles.removeWhere((t) => set.contains(t.id));
    for (final t in removed) {
      _syncPinned(t.packageName);
    }
    await _persistTiles();
    await _persistMeta();
    notifyListeners();
  }

  /// Moves tiles to [pageId], letting the target page pack them.
  Future<void> moveTilesToPage(Iterable<String> ids, String pageId) async {
    final set = ids.toSet();
    if (set.isEmpty) return;
    if (!tilePages.any((p) => p.id == pageId)) return;
    var changed = false;
    for (final t in tiles) {
      if (!set.contains(t.id)) continue;
      t.pageId = pageId;
      // Auto placement: the target page packs them without overlapping.
      t.col = -1;
      t.row = -1;
      changed = true;
    }
    if (!changed) return;
    await _persistTiles();
    notifyListeners();
  }

  /// Duplicates a page and its tiles onto a new page, keeping every tile's size
  /// and position. Returns the new page (null when [pageId] does not exist).
  Future<TilePage?> copyTilePage(String pageId) async {
    final source = tilePages.where((p) => p.id == pageId).firstOrNull;
    if (source == null) return null;
    final now = DateTime.now().millisecondsSinceEpoch;
    final copy = TilePage(
      id: _newId(),
      name: '${source.name} ${AppStrings.current.t('副本')}',
      createdAt: now,
    );
    tilePages.add(copy);
    // Snapshot the source list: the loop adds to [tiles] as it goes.
    final sourceTiles = tiles
        .where((t) => _normalizedPageId(t) == pageId)
        .toList();
    for (final t in sourceTiles) {
      tiles.add(
        Tile(
          id: _newId(),
          packageName: t.packageName,
          pageId: copy.id,
          kind: t.kind,
          options: Map<String, dynamic>.from(t.options),
          col: t.col,
          row: t.row,
          w: t.w,
          h: t.h,
          showLabel: t.showLabel,
          innerPadding: t.innerPadding,
          border: t.border,
        ),
      );
    }
    await _persistTilePages();
    await _persistTiles();
    notifyListeners();
    return copy;
  }

  /// Drops [draggedId] onto [targetId]: both become one folder.
  ///
  /// An existing folder simply gains the app; two app tiles are replaced by a
  /// new folder at the target's cell. A folder built from a category cannot be
  /// extended by hand, so that case returns null and the caller just moves the
  /// tile.
  Future<String?> combineIntoFolder(String draggedId, String targetId) async {
    if (draggedId == targetId) return null;
    final dragged = tileById(draggedId);
    final target = tileById(targetId);
    if (dragged == null || target == null) return null;
    final draggedPackage = dragged.packageName;
    if (draggedPackage.isEmpty) return null;

    if (target.kind == TileKind.folder) {
      if (target.optionString('category').isNotEmpty) return null;
      final apps = target.optionList('apps');
      if (!apps.contains(draggedPackage)) apps.add(draggedPackage);
      final options = <String, dynamic>{
        ...target.options,
        'apps': apps,
      }..remove('category');
      target
        ..options = options
        ..w = target.w < 2 ? 2 : target.w
        ..h = target.h < 2 ? 2 : target.h;
      tiles.removeWhere((t) => t.id == draggedId);
      _syncPinned(draggedPackage);
      await _persistTiles();
      await _persistMeta();
      notifyListeners();
      return target.id;
    }

    if (target.kind != TileKind.app || target.packageName.isEmpty) return null;
    final folder = Tile(
      id: _newId(),
      packageName: '',
      pageId: target.pageId,
      kind: TileKind.folder,
      col: target.col,
      row: target.row < 0 ? dragged.row : target.row,
      w: target.w < 2 ? 2 : target.w,
      h: target.h < 2 ? 2 : target.h,
      options: <String, dynamic>{
        'apps': <String>[target.packageName, draggedPackage],
      },
    );
    tiles.removeWhere((t) => t.id == targetId || t.id == draggedId);
    tiles.add(folder);
    _syncPinned(target.packageName);
    _syncPinned(draggedPackage);
    await _persistTiles();
    await _persistMeta();
    notifyListeners();
    return folder.id;
  }

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
    // Deleting a page deletes the tiles that live on it; nothing is merged
    // into the first page.
    final affected = <String>{
      for (final t in tiles)
        if (t.pageId == id) t.packageName,
    };
    tiles.removeWhere((t) => t.pageId == id);
    for (final pkg in affected) {
      _syncPinned(pkg);
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
    await _persistMeta();
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
    unawaited(syncPageWidget());
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

  Future<Map<String, dynamic>> _loadSettings() async {
    final loaded = _parseSettings(await storage.readJson(_kSettings));
    // 最近 used to be the last launch sub-tab; it now sits left of 磁贴, which
    // shifted every launch sub-tab index. Remap a value written by an older
    // build once (guarded by a marker so it never runs twice).
    if (loaded[_kLaunchTabOrder] != 'recent-left') {
      const remap = <int>[1, 2, 3, 0]; // old index -> new index
      final old = loaded['last_launch_tab'];
      if (old is num) {
        final i = old.toInt();
        if (i >= 0 && i < remap.length) loaded['last_launch_tab'] = remap[i];
      }
      loaded[_kLaunchTabOrder] = 'recent-left';
      await storage.writeJson(_kSettings, loaded);
    }
    // Notification settings were split apart: the single on/off switch became
    // the "capture" master switch, and the one badge style became per-surface
    // modes. Copy the old values across once so an update keeps the user's
    // choice.
    if (!loaded.containsKey('notification_capture') &&
        loaded['notification_badges'] is bool) {
      loaded['notification_capture'] = loaded['notification_badges'];
    }
    final legacyBadgeStyle = loaded['notification_badge_style'];
    if (legacyBadgeStyle is String) {
      loaded['tile_badge_mode'] ??= legacyBadgeStyle;
      loaded['other_badge_mode'] ??= legacyBadgeStyle;
    }
    return loaded;
  }

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

  // ---- notifications

  /// Master switch: whether system notifications are captured (read) at all.
  /// Off by default because it needs the user to grant notification access.
  bool get notificationCapture =>
      settings['notification_capture'] as bool? ?? false;

  /// Badge mode for the app icons on the tile board.
  NotificationBadgeMode get tileBadgeMode =>
      _badgeMode(settings['tile_badge_mode']);

  /// Badge mode for the page chips below the tile board.
  NotificationBadgeMode get pageBadgeMode =>
      _badgeMode(settings['page_badge_mode']);

  /// Badge mode for everything else (lists, categories, favourites, …).
  NotificationBadgeMode get otherBadgeMode =>
      _badgeMode(settings['other_badge_mode']);

  static NotificationBadgeMode _badgeMode(Object? raw) =>
      NotificationBadgeMode.values.firstWhere(
        (m) => m.name == raw,
        orElse: () => NotificationBadgeMode.count,
      );

  Future<void> setNotificationCapture(bool value) async {
    settings['notification_capture'] = value;
    NotificationBadges.instance.setCapture(value);
    if (value) {
      await syncNotificationBadges();
    } else {
      NotificationBadges.instance.clear();
    }
    await _persistSettings();
    notifyListeners();
  }

  Future<void> setTileBadgeMode(NotificationBadgeMode value) async {
    settings['tile_badge_mode'] = value.name;
    NotificationBadges.instance.setMode(value, NotificationBadgeSurface.tile);
    await _persistSettings();
    notifyListeners();
  }

  Future<void> setPageBadgeMode(NotificationBadgeMode value) async {
    settings['page_badge_mode'] = value.name;
    NotificationBadges.instance.setMode(value, NotificationBadgeSurface.page);
    await _persistSettings();
    notifyListeners();
  }

  Future<void> setOtherBadgeMode(NotificationBadgeMode value) async {
    settings['other_badge_mode'] = value.name;
    NotificationBadges.instance.setMode(value, NotificationBadgeSurface.list);
    await _persistSettings();
    notifyListeners();
  }

  /// Whether the user granted this app notification-listener access.
  Future<bool> hasNotificationAccess() async {
    try {
      return await NativeApps.hasNotificationAccess();
    } catch (_) {
      return false;
    }
  }

  /// Opens the system "notification access" UI (directly to our own entry when
  /// the device supports it, otherwise the full list).
  Future<bool> openNotificationAccessSettings() async {
    try {
      return await NativeApps.openNotificationAccessSettings();
    } catch (_) {
      return false;
    }
  }

  /// Live state of the native listener: `{connected, events, packages, total,
  /// lastEventAt}`. Empty when the bridge is unavailable (e.g. tests).
  Future<Map<String, dynamic>> notificationDiagnostics() async {
    try {
      return await NativeApps.notificationDiagnostics();
    } catch (_) {
      return const {};
    }
  }

  /// Pushes the persisted switch and modes into the shared badge state so the
  /// leaf widgets paint the right thing.
  void _applyNotificationBadges() {
    NotificationBadges.instance
      ..setCapture(notificationCapture)
      ..setMode(tileBadgeMode, NotificationBadgeSurface.tile)
      ..setMode(pageBadgeMode, NotificationBadgeSurface.page)
      ..setMode(otherBadgeMode, NotificationBadgeSurface.list);
  }

  /// Re-reads the native counts, nudging the system to (re)bind the listener
  /// first (needed right after access is granted). Safe to call repeatedly.
  Future<void> syncNotificationBadges() async {
    _applyNotificationBadges();
    if (!notificationCapture) {
      NotificationBadges.instance.clear();
      return;
    }
    try {
      if (await NativeApps.hasNotificationAccess()) {
        await NativeApps.requestNotificationRebind();
      }
      NotificationBadges.instance.setCounts(
        await NativeApps.getNotificationCounts(),
      );
    } catch (_) {
      // Native side unavailable (e.g. widget tests): keep the current counts.
    }
  }

  /// Reads the current counts without asking the system to rebind. Used at
  /// startup and whenever the app returns to the foreground, where a plain
  /// refresh is enough (and does not hit the rebind rate limit).
  Future<void> refreshNotificationCounts() async {
    _applyNotificationBadges();
    if (!notificationCapture) {
      NotificationBadges.instance.clear();
      return;
    }
    try {
      NotificationBadges.instance.setCounts(
        await NativeApps.getNotificationCounts(),
      );
    } catch (_) {
      // Native side unavailable (e.g. widget tests).
    }
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

  // ---- recommendations

  /// Whether the 最近 tab shows a "推荐" section. Defaults to true.
  bool get recommendationsEnabled =>
      settings['recent_recommendations'] as bool? ?? true;

  Future<void> setRecommendationsEnabled(bool value) async {
    settings['recent_recommendations'] = value;
    _resetRecommendationPicks();
    await _persistSettings();
    notifyListeners();
    unawaited(syncHomeWidget(force: true));
  }

  // ---- desktop widget

  /// The recommendation layout chosen for the current hour. See
  /// [buildHomeWidgetData]; persisted so a restart cannot shuffle the widget.
  Map<String, dynamic>? _hourPick;

  /// The same idea for the in-app 推荐 grid: the live call keeps the order it
  /// first showed this hour, so tapping one icon does not reshuffle the rest.
  String? _recsHourKey;
  List<Recommendation>? _recsHour;

  /// Whether the home-screen widget draws the app name under each icon.
  bool get widgetShowLabels =>
      settings['widget_show_labels'] as bool? ?? true;

  Future<void> setWidgetShowLabels(bool value) async {
    settings['widget_show_labels'] = value;
    await _persistSettings();
    notifyListeners();
    unawaited(syncHomeWidget(force: true));
  }

  /// How many apps the widget shows at most. One row on a 4-wide widget is 4;
  /// the 4x2 card fits 8. 6 is offered for a balanced 4 + 2 layout.
  int get widgetMaxApps {
    final raw = (settings['widget_max_apps'] as num?)?.toInt() ?? 8;
    return _kWidgetAppCounts.contains(raw) ? raw : 8;
  }

  static const Set<int> _kWidgetAppCounts = {4, 6, 8};

  Future<void> setWidgetMaxApps(int value) async {
    final next = _kWidgetAppCounts.contains(value) ? value : 8;
    if (widgetMaxApps == next) return;
    settings['widget_max_apps'] = next;
    await _persistSettings();
    notifyListeners();
    unawaited(syncHomeWidget(force: true));
  }

  /// Whether the widget clips app icons to rounded squares. Off by default so
  /// every app keeps its own silhouette.
  bool get widgetRoundedIcons =>
      settings['widget_rounded_icons'] as bool? ?? false;

  Future<void> setWidgetRoundedIcons(bool value) async {
    if (widgetRoundedIcons == value) return;
    settings['widget_rounded_icons'] = value;
    await _persistSettings();
    notifyListeners();
    unawaited(syncHomeWidget(force: true));
  }

  /// How the widget arranges a row that is not full: `spread` shares it out
  /// evenly, `left` keeps the normal grid positions (packed to the left) and
  /// `edges` pushes the first and last icon of the row to the two ends.
  String get widgetLayout {
    final raw = settings['widget_layout'] as String?;
    return raw == 'left' || raw == 'edges' ? raw! : 'spread';
  }

  Future<void> setWidgetLayout(String value) async {
    final next = value == 'left' || value == 'edges' ? value : 'spread';
    if (widgetLayout == next) return;
    settings['widget_layout'] = next;
    await _persistSettings();
    notifyListeners();
    unawaited(syncHomeWidget(force: true));
  }

  /// Apps the desktop widget shows at [hour] (0-23), plus where they came from:
  /// `recommend`, `recent`, `pinned` or `empty`.
  ///
  /// Recommendations are time-of-day habits. When that model has nothing for
  /// the hour, the widget falls back to the apps used the most, then the most
  /// recently, then the pinned tiles — a widget that is useful from day one.
  ({List<AppInfo> apps, String kind}) homeWidgetSuggestionForHour(
    int hour, {
    DateTime? at,
    int limit = 8,
  }) {
    if (apps.isEmpty) return (apps: const <AppInfo>[], kind: 'empty');
    final out = <AppInfo>[];
    final seen = <String>{};

    void add(AppInfo a) {
      if (out.length >= limit) return;
      if (a.packageName.isEmpty) return;
      if (metaFor(a.packageName).hidden) return;
      if (!seen.add(a.packageName)) return;
      out.add(a);
    }

    if (recommendationsEnabled && launchLog.isNotEmpty) {
      final now = DateTime.now();
      final moment = at ?? DateTime(now.year, now.month, now.day, hour);
      final installed = <String>{for (final a in apps) a.packageName};
      final events = launchLog
          .where((e) => installed.contains(e.packageName))
          .toList(growable: false);
      final recs = Recommender.recommend(
        events,
        nowMillis: moment.millisecondsSinceEpoch,
        limit: limit,
      );
      for (final r in recs) {
        final a = appByPackage(r.packageName);
        if (a != null) add(a);
      }
      // Exactly what 最近 → 推荐 shows: recommendations only, never padded
      // with other apps. The widget mirrors that section.
      if (out.isNotEmpty) return (apps: out, kind: 'recommend');
    }

    for (final a in recentAppsBy(RecentSort.frequent)) {
      add(a);
    }
    for (final a in recentAppsBy(RecentSort.recent)) {
      add(a);
    }
    var kind = out.isEmpty ? 'pinned' : 'recent';

    if (out.length < limit) {
      // Nothing launched from 囤囤 yet (or everything was hidden): the tiles
      // are the apps the user has already chosen to see.
      for (final t in tiles) {
        if (t.packageName.isEmpty) continue;
        final a = appByPackage(t.packageName);
        if (a != null) add(a);
      }
    }

    if (out.isEmpty) return (apps: const <AppInfo>[], kind: 'empty');
    return (apps: out, kind: kind);
  }

  /// The heading the widget shows for a suggestion source.
  String homeWidgetTitleFor(String kind) {
    final s = AppStrings.current;
    return switch (kind) {
      'recommend' => s.t('推荐'),
      'recent' => s.t('最近常用'),
      'pinned' => s.t('常用应用'),
      _ => s.t('推荐'),
    };
  }

  /// The whole document the widget reads. One entry per hour so the widget can
  /// pick "now" on its own, without starting Flutter or recomputing anything.
  Map<String, dynamic> buildHomeWidgetData() {
    final s = AppStrings.current;
    final now = DateTime.now();
    // Keep the layout picked at the start of this hour. A launch is recorded
    // straight away, but moving the icons under the user's finger reads as a
    // mis-tap; the recommendation refreshes on the next hour instead.
    final pick = _pickFor(now);
    final icons = <String, String>{};
    final maxApps = widgetMaxApps;
    final slots = <Map<String, dynamic>>[];
    for (var h = 0; h < 24; h++) {
      final suggestion =
          h == now.hour ? pick : homeWidgetSuggestionForHour(h);
      slots.add({
        'h': h,
        'title': homeWidgetTitleFor(suggestion.kind),
        'apps': [
          for (final a in suggestion.apps.take(maxApps))
            _homeWidgetApp(a, icons),
        ],
      });
    }
    final hour = now.hour;
    final current = slots[hour];
    return {
      'version': 2,
      'updatedAt': now.millisecondsSinceEpoch,
      'showLabels': widgetShowLabels,
      'roundedIcons': widgetRoundedIcons,
      'layout': widgetLayout,
      'title': current['title'],
      'empty': s.t('在囤囤里启动几次应用，这里就会出现推荐'),
      'slots': slots,
      'fallback': current['apps'],
      // Only the icons the system cannot provide: custom icons and web-app
      // icons. Everything else is read from PackageManager by the widget.
      'icons': icons,
    };
  }

  /// The local hour a pick belongs to, e.g. `2026-10-22-9`.
  static String _hourKey(DateTime at) =>
      '${at.year}-${at.month}-${at.day}-${at.hour}';

  /// The recommendation the widget is showing right now. The settings preview
  /// and the pushed document both use this, so they never disagree.
  ({List<AppInfo> apps, String kind}) homeWidgetNow() =>
      _pickFor(DateTime.now());

  ({List<AppInfo> apps, String kind}) _pickFor(DateTime now) {
    final key = _hourKey(now);
    final frozen = _frozenHour(key);
    if (frozen != null) return frozen;
    final fresh = homeWidgetSuggestionForHour(now.hour, at: now);
    if (fresh.apps.isNotEmpty) _rememberHour(key, fresh.kind, fresh.apps);
    return fresh;
  }

  /// The layout stored for [key], minus apps that were uninstalled or hidden
  /// since. Null when the hour is over or nothing is left.
  ({List<AppInfo> apps, String kind})? _frozenHour(String key) {
    final pick = _hourPick;
    if (pick == null || pick['k'] != key) return null;
    final kind = pick['kind'];
    final packages = pick['pkgs'];
    if (kind is! String || kind.isEmpty || packages is! List) return null;
    final apps = <AppInfo>[];
    for (final raw in packages) {
      if (raw is! String) continue;
      final app = appByPackage(raw);
      if (app == null) continue;
      if (metaFor(raw).hidden) continue;
      apps.add(app);
    }
    return apps.isEmpty ? null : (apps: apps, kind: kind);
  }

  void _rememberHour(String key, String kind, List<AppInfo> apps) {
    final pick = <String, dynamic>{
      'k': key,
      'kind': kind,
      'pkgs': [for (final a in apps) a.packageName],
    };
    _hourPick = pick;
    unawaited(
      storage.writeJson(_kWidgetHourPick, pick).catchError((Object _) {}),
    );
  }

  /// Drops the stored hour pick, e.g. after the recommendation source changed.
  void _forgetHour() {
    if (_hourPick == null) return;
    _hourPick = null;
    unawaited(
      storage.writeJson(_kWidgetHourPick, null).catchError((Object _) {}),
    );
  }

  /// One entry for the widget. An app carries the launcher entry the user
  /// pinned ([AppMeta.launchActivity]) so the widget launches and draws exactly
  /// what the tile board does; a web app carries enough to open it without
  /// running Flutter.
  Map<String, dynamic> _homeWidgetApp(
    AppInfo a,
    Map<String, String> icons,
  ) {
    final name = displayNameFor(a.packageName);
    final web = a.isWebEntry ? webAppById(a.packageName) : null;
    if (web != null) {
      final bytes = IconCache.instance[a.packageName];
      if (bytes != null && bytes.isNotEmpty) {
        icons[a.packageName] = base64Encode(bytes);
      }
      return {
        'p': a.packageName,
        'n': name,
        'w': {
          'name': name,
          'url': web.startUrl.isEmpty ? web.url : web.startUrl,
          'mode': web.opensStandalone ? 'standalone' : 'browser',
          'display': web.windowDisplay,
          'scope': web.scope,
          'theme': web.themeColor,
          'bg': web.backgroundColor,
          'hide': web.hideStatusBar,
          'browser': web.browserPackage,
        },
      };
    }
    final custom = CustomIcons.instance.bytesFor(a.packageName);
    if (custom != null && custom.isNotEmpty) {
      icons[a.packageName] = base64Encode(custom);
    }
    final activity = metaFor(a.packageName).launchActivity;
    return {
      'p': a.packageName,
      'n': name,
      if (activity.isNotEmpty) 'a': activity,
    };
  }

  static const int _kWidgetPushIntervalMs = 30000;
  int _lastWidgetPushAt = 0;
  bool _loggedWidgetPush = false;

  /// Pushes the current suggestions to the widget. Cheap and best effort: the
  /// widget keeps the last document when the platform refuses an update.
  Future<void> syncHomeWidget({bool force = false}) async {
    // Nothing to suggest before the first scan, but a forced push still matters
    // (wiping all data must clear the widget as well).
    if (apps.isEmpty && !force) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now - _lastWidgetPushAt < _kWidgetPushIntervalMs) return;
    _lastWidgetPushAt = now;
    final data = buildHomeWidgetData();
    final ok = await NativeApps.updateHomeWidget(jsonEncode(data));
    if (ok && !_loggedWidgetPush) {
      _loggedWidgetPush = true;
      final count = (data['fallback'] as List).length;
      AppLog.instance.log(
        LogModule.launch,
        '桌面小组件 · 已更新推荐 · $count 个应用',
      );
    }
  }

  /// Recomputes the current hour's layout on request (the widget settings'
  /// refresh button). Launches deliberately never go through here, so the
  /// icons stay still while the user is using them.
  Future<void> refreshHomeWidgetNow() async {
    _resetRecommendationPicks();
    await syncHomeWidget(force: true);
  }

  /// How the page strip marks the current page: `pill` draws the highlight
  /// behind it, `dot` only a small dot underneath.
  String get pageBarMarker =>
      settings['page_bar_marker'] == 'dot' ? 'dot' : 'pill';

  Future<void> setPageBarMarker(String value) async {
    final next = value == 'dot' ? 'dot' : 'pill';
    if (pageBarMarker == next) return;
    settings['page_bar_marker'] = next;
    await _persistSettings();
    notifyListeners();
    unawaited(syncPageWidget());
  }

  /// The 4x1 page-tab strip's document: the page names, in order, and which
  /// one the app is on (drawn highlighted).
  Map<String, dynamic> buildPageWidgetData() {
    final s = AppStrings.current;
    return {
      'marker': pageBarMarker,
      'pages': [
        for (var i = 0; i < tilePages.length; i++)
          {
            'id': tilePages[i].id,
            // A page without a usable name would otherwise render as an empty
            // tab; fall back to its position.
            'n': tilePages[i].name.trim().isEmpty
                ? s.t('页面 {n}', {'n': i + 1})
                : tilePages[i].name.trim(),
          },
      ],
      'current': tilePages.isEmpty
          ? 0
          : currentTilePageIndex.clamp(0, tilePages.length - 1),
    };
  }

  /// Pushes the page tabs to the strip. The page list only changes in 囤囤, so
  /// there is no periodic update on that widget.
  Future<void> syncPageWidget() async {
    if (tilePages.isEmpty) return;
    await NativeApps.updatePageWidget(jsonEncode(buildPageWidgetData()));
  }

  /// Merges launches made from the widget into the normal statistics. The
  /// widget records them natively because it must not wake the Flutter engine;
  /// this is where they join the launch log, 最近 and future recommendations.
  Future<void> consumeHomeWidgetLaunches() async {
    final launches = await NativeApps.consumeWidgetLaunches();
    if (launches.isEmpty) return;
    var counted = 0;
    for (final l in launches) {
      if (appByPackage(l.packageName) == null) continue;
      final m = metaFor(l.packageName);
      if (l.at > m.lastLaunchedAt) m.lastLaunchedAt = l.at;
      m.launchCount += 1;
      _recordLaunch(l.packageName, l.at);
      counted++;
    }
    if (counted == 0) return;
    _pruneLaunchLog();
    await _persistMeta();
    await _persistLaunchLog();
    notifyListeners();
    AppLog.instance.log(LogModule.launch, '桌面小组件 · 计入 $counted 次启动');
    unawaited(syncRecentShortcuts());
    unawaited(syncHomeWidget(force: true));
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

  /// Last launch sub-tab, in the order 最近 / 磁贴 / 分类 / 收藏. Defaults to
  /// 磁贴 (index 1), which sits just right of 最近.
  int get lastLaunchTab {
    if (!rememberPosition) return _kTilesTabIndex;
    return (settings['last_launch_tab'] as num?)?.toInt() ?? _kTilesTabIndex;
  }

  Future<void> setLastLaunchTab(int value) async {
    if (!rememberPosition || lastLaunchTab == value) return;
    settings['last_launch_tab'] = value;
    await _persistSettings();
  }

  /// A launch sub-tab asked for from outside (the launcher shortcuts), waiting
  /// for the launch screen to pick it up. Works even when position memory is
  /// off, because it is a one-shot request rather than a stored preference.
  int? _pendingLaunchTab;

  int? get pendingLaunchTab => _pendingLaunchTab;

  void requestLaunchTab(int index) {
    _pendingLaunchTab = index;
    notifyListeners();
  }

  /// Reads and clears the pending sub-tab request.
  int? consumePendingLaunchTab() {
    final value = _pendingLaunchTab;
    _pendingLaunchTab = null;
    return value;
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

  /// A short, subtle tick for gesture thresholds (e.g. the tile board's
  /// long-press slide). Independent of the configured effect so it always reads
  /// as a light "click" rather than a heavier configured buzz. Respects the
  /// master haptics switch.
  Future<void> hapticLight() async {
    if (!hapticsEnabled) return;
    try {
      await NativeApps.vibrate(15, amplitude: 64);
    } catch (_) {
      // Haptics are best-effort; ignore devices/platforms without support.
    }
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

  /// How swipes on the 磁贴 board switch the launch sub-tabs vs. the tile pages.
  /// Defaults to [TileSwipeMode.holdDrag].
  TileSwipeMode get tileSwipeMode {
    final raw = settings['tile_swipe_mode'] as String?;
    return TileSwipeMode.values.firstWhere(
      (m) => m.name == raw,
      orElse: () => TileSwipeMode.holdDrag,
    );
  }

  Future<void> setTileSwipeMode(TileSwipeMode value) async {
    settings['tile_swipe_mode'] = value.name;
    await _persistSettings();
    notifyListeners();
  }

  /// User-selected navigation presentation. Defaults to [NavMode.auto].
  NavMode get navMode {
    final raw = settings['nav_mode'] as String?;
    // `floating` was the pre-1.0 name for [NavMode.collapsed]; keep reading it
    // so existing installs do not silently fall back to [NavMode.auto].
    if (raw == 'floating') return NavMode.collapsed;
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

  /// Follow the wallpaper: take the seed colour from it and re-read it whenever
  /// the app comes back to the foreground. Defaults to off, because it changes
  /// the look on its own.
  bool get themeFollowWallpaper =>
      settings['theme_follow_wallpaper'] as bool? ?? false;

  Future<void> setThemeFollowWallpaper(bool value) async {
    settings['theme_follow_wallpaper'] = value;
    await _persistSettings();
    notifyListeners();
    if (value) await refreshWallpaperColor();
  }

  /// The colours the wallpaper last offered (primary first); empty before the
  /// first read or when the platform will not say.
  List<int> wallpaperColors = <int>[];

  /// Reads the wallpaper colours and, when the theme follows the wallpaper,
  /// seeds the theme from the first one. Returns the colours that were read, so
  /// the picker can offer them as swatches.
  Future<List<int>> refreshWallpaperColor() async {
    final colors = await NativeApps.wallpaperColors();
    wallpaperColors = colors;
    if (colors.isNotEmpty && themeFollowWallpaper) {
      // Persisted like any other choice, so a cold start before the wallpaper
      // read lands still uses the right seed.
      await setThemeColor(colors.first);
    } else {
      notifyListeners();
    }
    return colors;
  }

  /// Text scale for the whole app (1.0 = the system's own scale).
  double get fontScale =>
      ((settings['font_scale'] as num?)?.toDouble() ?? 1.0).clamp(0.8, 1.6);

  Future<void> setFontScale(double value) async {
    settings['font_scale'] = value.clamp(0.8, 1.6);
    await _persistSettings();
    notifyListeners();
  }

  /// Denser rows in lists (compact visual density).
  bool get compactDensity => settings['compact_density'] as bool? ?? false;

  Future<void> setCompactDensity(bool value) async {
    settings['compact_density'] = value;
    await _persistSettings();
    notifyListeners();
  }

  /// Alignment of the page chips on the bottom bar when there is spare room.
  TileBarAlign get tileBarAlign {
    final raw = settings['tile_bar_align'] as String?;
    return TileBarAlign.values.firstWhere(
      (a) => a.name == raw,
      orElse: () => TileBarAlign.center,
    );
  }

  Future<void> setTileBarAlign(TileBarAlign value) async {
    settings['tile_bar_align'] = value.name;
    await _persistSettings();
    notifyListeners();
  }

  /// Locks the tile board: edit mode cannot be entered, so nothing moves by
  /// accident. Browsing, launching and the tile menu still work.
  bool get layoutLocked => settings['layout_lock'] as bool? ?? false;

  Future<void> setLayoutLocked(bool value) async {
    settings['layout_lock'] = value;
    if (value) tileEditMode = false;
    await _persistSettings();
    notifyListeners();
  }

  /// Automatic snapshot interval in days; 0 (the default) keeps it off.
  int get autoSnapshotDays =>
      (settings['auto_snapshot_days'] as num?)?.toInt() ?? 0;

  Future<void> setAutoSnapshotDays(int value) async {
    settings['auto_snapshot_days'] = value.clamp(0, 90);
    await _persistSettings();
    notifyListeners();
  }

  /// Installed icon pack (a package name); '' uses the launcher icons.
  String get iconPack => settings['icon_pack'] as String? ?? '';

  Future<void> setIconPack(String value) async {
    if (iconPack == value) return;
    settings['icon_pack'] = value;
    await _persistSettings();
    // Every cached picture now means something else.
    IconCache.instance.setIconPack(value);
    await _persistIcons();
    notifyListeners();
  }

  // ---------------------------------------------------------------- custom icons

  static const String _kCustomIcons = 'custom_icons';

  Future<void> _loadCustomIcons() async {
    final icons = CustomIcons.fromBase64(await storage.readJson(_kCustomIcons));
    CustomIcons.instance.replaceAll(icons);
    // A metadata marker without a stored icon would leave the app claiming an
    // icon it cannot draw.
    var changed = false;
    for (final m in meta.values) {
      if (m.customIcon.isEmpty || icons.containsKey(m.packageName)) continue;
      m.customIcon = '';
      changed = true;
    }
    if (changed) await _persistMeta();
  }

  Future<void> _persistCustomIcons() async {
    await storage.writeJson(_kCustomIcons, CustomIcons.instance.toBase64());
  }

  /// Stores a user-chosen icon for [packageName] from raw image bytes. Returns
  /// false when the image could not be decoded.
  Future<bool> setCustomIcon(String packageName, Uint8List bytes) async {
    final png = await CustomIcons.shrink(bytes);
    if (png == null) return false;
    CustomIcons.instance.put(packageName, png);
    metaFor(packageName).customIcon = 'custom';
    await _persistCustomIcons();
    await _persistMeta();
    notifyListeners();
    return true;
  }

  Future<void> clearCustomIcon(String packageName) async {
    if (!CustomIcons.instance.has(packageName)) return;
    CustomIcons.instance.remove(packageName);
    metaFor(packageName).customIcon = '';
    await _persistCustomIcons();
    await _persistMeta();
    notifyListeners();
  }

  // ---------------------------------------------------------------- update alerts

  static const String _kFactsBaseline = 'app_facts_baseline';

  /// Sensitive permissions an app started asking for after an update (and any
  /// changed signing certificate), newest first. Recorded by
  /// [_checkUpdateAlerts] and kept until the user clears them.
  List<Map<String, dynamic>> get permissionAlerts =>
      (settings['permission_alerts'] as List?)
          ?.whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList(growable: false) ??
      const <Map<String, dynamic>>[];

  bool get hasPermissionAlerts => permissionAlerts.isNotEmpty;

  Future<void> dismissPermissionAlerts() async {
    settings['permission_alerts'] = <dynamic>[];
    await _persistSettings();
    notifyListeners();
  }

  Future<void> dismissPermissionAlert(String packageName) async {
    final alerts = permissionAlerts
        .where((e) => e['pkg'] != packageName)
        .map((e) => e.cast<String, dynamic>())
        .toList();
    settings['permission_alerts'] = alerts;
    await _persistSettings();
    notifyListeners();
  }

  /// Compares what the apps ask for now with the first time they were seen, and
  /// records an alert when an update added a sensitive permission or replaced
  /// the certificate. Runs after a scan; the first scan only records a baseline.
  Future<void> _checkUpdateAlerts() async {
    final raw = await storage.readJson(_kFactsBaseline);
    if (raw is! Map) {
      await _saveFactsBaseline();
      return;
    }
    final baseline = <String, Map<String, dynamic>>{
      for (final e in raw.entries)
        if (e.value is Map) '${e.key}': (e.value as Map).cast<String, dynamic>(),
    };
    final now = DateTime.now().millisecondsSinceEpoch;
    final alerts = <Map<String, dynamic>>[
      ...permissionAlerts,
    ];
    var added = 0;
    for (final a in apps) {
      final facts = appFacts[a.packageName];
      final before = baseline[a.packageName];
      if (facts == null || before == null) continue;
      final oldCode = (before['v'] as num?)?.toInt() ?? 0;
      // Only a real update (versionCode moved) is interesting.
      if (oldCode == 0 || oldCode == a.versionCode) continue;
      final oldPerms =
          (before['p'] as List?)?.map((e) => '$e').toSet() ?? <String>{};
      final fresh = facts.permissions.toSet().difference(oldPerms);
      final sensitive = fresh.where(isSensitivePermission).toList()..sort();
      final oldSignature = before['s'] as String? ?? '';
      final signatureChanged = oldSignature.isNotEmpty &&
          facts.signature.isNotEmpty &&
          oldSignature != facts.signature;
      if (sensitive.isEmpty && !signatureChanged) continue;
      alerts.removeWhere((e) => e['pkg'] == a.packageName);
      alerts.insert(0, <String, dynamic>{
        'pkg': a.packageName,
        'name': displayNameFor(a.packageName),
        'at': now,
        'from': oldCode,
        'to': a.versionCode,
        if (sensitive.isNotEmpty) 'added': sensitive,
        if (signatureChanged) 'signature': true,
      });
      added++;
      AppLog.instance.log(
        LogModule.apps,
        '更新提醒 · ${displayNameFor(a.packageName)} · '
            '新增权限=${sensitive.join(',')}'
            '${signatureChanged ? ' · 签名变化' : ''}',
      );
    }
    if (alerts.length > 50) alerts.removeRange(50, alerts.length);
    settings['permission_alerts'] = alerts;
    if (added > 0) {
      await _persistSettings();
      AppLog.instance.log(LogModule.apps, '更新提醒 · 新增 $added 条');
      notifyListeners();
    }
    await _saveFactsBaseline();
  }

  Future<void> _saveFactsBaseline() async {
    final out = <String, dynamic>{};
    for (final a in apps) {
      final facts = appFacts[a.packageName];
      if (facts == null) continue;
      out[a.packageName] = <String, dynamic>{
        'v': a.versionCode,
        'p': facts.permissions,
        's': facts.signature,
      };
    }
    if (out.isEmpty) return;
    await storage.writeJson(_kFactsBaseline, out);
  }

  /// Everything that needs the (lazily read) per-app facts, run after a scan:
  /// the update alerts and the automatic snapshot.
  Future<void> _afterScanMaintenance() async {
    if (apps.isEmpty) return;
    await ensureAppFacts();
    if (appFacts.isEmpty) return;
    await _checkUpdateAlerts();
    await _maybeAutoSnapshot();
  }

  /// Takes a snapshot when the interval has passed and something actually
  /// changed. Default off; never runs when the user has not enabled it.
  Future<void> _maybeAutoSnapshot() async {
    final days = autoSnapshotDays;
    if (days <= 0) return;
    final latest = latestSnapshot;
    final now = DateTime.now().millisecondsSinceEpoch;
    final due =
        latest == null || now - latest.createdAt >= days * 86400000;
    if (!due) return;
    if (latest != null) {
      final diff = SnapshotDiff.between(latest, currentDeviceSnapshot());
      if (diff.changedCount == 0) {
        AppLog.instance.log(LogModule.apps, '自动快照 · 没有变化，跳过');
        return;
      }
    }
    final snapshot = await createSnapshot(
      '${AppStrings.current.t('自动快照')} · '
      '${Fmt.shortDate(now)}',
      note: AppStrings.current.t('按设置的天数自动创建'),
    );
    AppLog.instance.log(
      LogModule.apps,
      '自动快照 · ${snapshot.name} · ${snapshot.installedCount} 个应用',
    );
  }

  /// When the data package was last written to WebDAV (null = never).
  DateTime? get lastWebdavBackupAt {
    final ms = (settings['webdav_backup_at'] as num?)?.toInt() ?? 0;
    return ms == 0 ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  String get lastWebdavBackupPath =>
      settings['webdav_backup_path'] as String? ?? '';

  Future<void> noteWebdavBackup(String path, DateTime at) async {
    settings['webdav_backup_path'] = path;
    settings['webdav_backup_at'] = at.millisecondsSinceEpoch;
    await _persistSettings();
    notifyListeners();
  }

  /// Installed apps per install source, biggest first. The key is the installer
  /// package; '' means the system recorded none (side-loaded or preinstalled).
  List<(String, int)> get installSourceCounts {
    final counts = <String, int>{};
    for (final a in apps) {
      final installer = appFacts[a.packageName]?.installer ?? a.installer;
      counts[installer] = (counts[installer] ?? 0) + 1;
    }
    final entries = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return [for (final e in entries) (e.key, e.value)];
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
    // The widget's title and empty hint are written in the app's language.
    unawaited(syncHomeWidget(force: true));
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
        'launch_log': launchLog.map((e) => e.toMap()).toList(),
        'icons': IconCache.instance.toJson(),
        'custom_icons': CustomIcons.instance.toBase64(),
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
    final newLaunchLog = _parseLaunchLog(d['launch_log']);
    final newIcons = IconCache.decode(d['icons']);

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
    // Web entries ride along in the backup as apps (they have to, so their
    // tiles and metadata make sense); on the way back in they go to their own
    // store, where a scan cannot touch them.
    webApps = newApps
        .where((a) => a.isWebEntry || WebApp.isWebId(a.packageName))
        .map(WebApp.fromAppInfo)
        .toList();
    apps = newApps.where((a) => !WebApp.isWebId(a.packageName)).toList();
    settings = newSettings;
    launchLog = newLaunchLog;
    IconCache.instance.replaceAll(newIcons);
    CustomIcons.instance.replaceAll(CustomIcons.fromBase64(d['custom_icons']));
    _syncIconActivities();
    _pruneLaunchLog();
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

  /// What a data package holds and how much of it this device already has, by
  /// id. Feeds the import preview so merging is a knowing choice.
  Map<String, (int, int)> mergePreview(Map<String, dynamic> pkg) {
    final data = pkg['data'];
    if (data is! Map) return const <String, (int, int)>{};
    final d = data.cast<String, dynamic>();
    final s = AppStrings.current;
    final incomingMeta = _parseMeta(d['meta']);
    final incomingCategories = _parseCategories(d['categories']);
    final incomingSnapshots = _parseSnapshots(d['snapshots']);
    final incomingLists = _parseBackupLists(d['backup_lists']);
    final incomingTiles = _parseTiles(d['tiles']);
    final categoryIds = categories.map((c) => c.id).toSet();
    final snapshotIds = snapshots.map((x) => x.id).toSet();
    final listIds = backupLists.map((x) => x.id).toSet();
    final tileIds = tiles.map((x) => x.id).toSet();
    int already<T>(Iterable<T> items, bool Function(T) has) =>
        items.where(has).length;
    return <String, (int, int)>{
      s.t('应用'): (
        incomingMeta.length,
        already(incomingMeta.values, (m) => meta.containsKey(m.packageName)),
      ),
      s.t('分组'): (
        incomingCategories.length,
        already(incomingCategories, (c) => categoryIds.contains(c.id)),
      ),
      s.t('快照'): (
        incomingSnapshots.length,
        already(incomingSnapshots, (x) => snapshotIds.contains(x.id)),
      ),
      s.t('备份列表'): (
        incomingLists.length,
        already(incomingLists, (x) => listIds.contains(x.id)),
      ),
      s.t('磁贴'): (
        incomingTiles.length,
        already(incomingTiles, (x) => tileIds.contains(x.id)),
      ),
    };
  }

  /// Merge a data package into the current data instead of replacing it.
  ///
  /// Existing annotations win; whatever this device lacks (apps, categories,
  /// snapshots, backup lists, tiles, settings keys, icons) is added. Returns
  /// how many of each were added or filled in, keyed by localised labels.
  Future<Map<String, int>> mergePackage(Map<String, dynamic> pkg) async {
    if (pkg['app'] != 'hamstapp') {
      throw FormatException(AppStrings.current.t('不是囤囤的数据包'));
    }
    final data = pkg['data'];
    if (data is! Map) {
      throw FormatException(AppStrings.current.t('数据包缺少 data 内容'));
    }
    final d = data.cast<String, dynamic>();
    final s = AppStrings.current;
    var appsTouched = 0;
    var categoriesAdded = 0;
    var snapshotsAdded = 0;
    var listsAdded = 0;
    var tilesAdded = 0;

    // Annotations: add unknown apps, fill the empty fields of known ones.
    for (final e in _parseMeta(d['meta']).entries) {
      final incoming = e.value;
      final existing = meta[e.key];
      if (existing == null) {
        meta[e.key] = incoming;
        appsTouched++;
        continue;
      }
      var filled = false;
      if (existing.reason.isEmpty && incoming.reason.isNotEmpty) {
        existing.reason = incoming.reason;
        filled = true;
      }
      if (existing.note.isEmpty && incoming.note.isNotEmpty) {
        existing.note = incoming.note;
        filled = true;
      }
      if (existing.categoryIds.isEmpty && incoming.categoryIds.isNotEmpty) {
        existing.categoryIds = List<String>.from(incoming.categoryIds);
        filled = true;
      }
      if (!existing.favorite && incoming.favorite) {
        existing.favorite = true;
        filled = true;
      }
      if (!existing.hidden && incoming.hidden) {
        existing.hidden = true;
        filled = true;
      }
      if (existing.customIcon.isEmpty && incoming.customIcon.isNotEmpty) {
        existing.customIcon = incoming.customIcon;
        filled = true;
      }
      if (existing.launchActivity.isEmpty &&
          incoming.launchActivity.isNotEmpty) {
        existing.launchActivity = incoming.launchActivity;
        existing.launchEntryLabel = incoming.launchEntryLabel;
        filled = true;
      }
      if (filled) appsTouched++;
    }

    final categoryIds = categories.map((c) => c.id).toSet();
    for (final c in _parseCategories(d['categories'])) {
      if (!categoryIds.add(c.id)) continue;
      categories.add(c);
      categoriesAdded++;
    }

    final snapshotIds = snapshots.map((x) => x.id).toSet();
    for (final snap in _parseSnapshots(d['snapshots'])) {
      if (!snapshotIds.add(snap.id)) continue;
      snapshots.add(snap);
      snapshotsAdded++;
    }

    final listIds = backupLists.map((x) => x.id).toSet();
    for (final list in _parseBackupLists(d['backup_lists'])) {
      if (!listIds.add(list.id)) continue;
      backupLists.add(list);
      listsAdded++;
    }

    // Pages first, so tiles from the package land on a page that exists.
    var pages = _parseTilePages(d['tile_pages']);
    if (tilePages.isEmpty && pages.isNotEmpty) {
      tilePages
        ..clear()
        ..addAll(pages);
    }
    final pageIds = tilePages.map((p) => p.id).toSet();
    for (final page in pages) {
      if (!pageIds.add(page.id)) continue;
      tilePages.add(page);
    }
    if (tilePages.isEmpty) {
      tilePages.add(
        TilePage(
          id: _newId(),
          name: s.t('页面 1'),
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    }
    final validPageIds = tilePages.map((p) => p.id).toSet();
    final tileIds = tiles.map((x) => x.id).toSet();
    for (final tile in _parseTiles(d['tiles'])) {
      if (!tileIds.add(tile.id)) continue;
      if (!validPageIds.contains(tile.pageId)) {
        tile.pageId = tilePages.first.id;
      }
      tiles.add(tile);
      tilesAdded++;
    }

    // Settings only fill the gaps: the device's own choices win.
    final incomingSettings = _parseSettings(d['settings']);
    for (final e in incomingSettings.entries) {
      settings.putIfAbsent(e.key, () => e.value);
    }

    // Launch history: add what is not already there.
    final seen = <String>{
      for (final e in launchLog) '${e.packageName}|${e.at}',
    };
    for (final e in _parseLaunchLog(d['launch_log'])) {
      if (seen.add('${e.packageName}|${e.at}')) launchLog.add(e);
    }

    final incomingIcons = IconCache.decode(d['icons']);
    for (final e in incomingIcons.entries) {
      if (!IconCache.instance.containsKey(e.key)) {
        IconCache.instance.put(e.key, e.value);
      }
    }
    final incomingCustom = CustomIcons.fromBase64(d['custom_icons']);
    for (final e in incomingCustom.entries) {
      if (!CustomIcons.instance.has(e.key)) {
        CustomIcons.instance.put(e.key, e.value);
      }
    }

    _syncIconActivities();
    _pruneLaunchLog();
    await _persistAll();
    notifyListeners();
    unawaited(syncHomeWidget(force: true));
    return <String, int>{
      s.t('应用'): appsTouched,
      s.t('分组'): categoriesAdded,
      s.t('快照'): snapshotsAdded,
      s.t('备份列表'): listsAdded,
      s.t('磁贴'): tilesAdded,
    };
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
    webApps = <WebApp>[];
    settings = <String, dynamic>{};
    launchLog = <LaunchEvent>[];
    IconCache.instance.replaceAll(<String, Uint8List>{});
    CustomIcons.instance.replaceAll(<String, Uint8List>{});
    pendingUninstalls = <AppMeta>[];
    currentTilePageIndex = 0;
    tileEditMode = false;
    query = '';
    lastScanAt = null;
    lastScanMs = 0;
    await _persistAll();
    await applyStatusBarVisibility(true);
    notifyListeners();
    // The widget must not keep showing apps that no longer exist here.
    unawaited(syncHomeWidget(force: true));
  }

  Future<void> _persistAll() async {
    await _persistMeta();
    await _persistCustomIcons();
    await _persistCategories();
    await _persistSnapshots();
    await _persistBackupLists();
    await _persistTiles();
    await _persistTilePages();
    await _persistSettings();
    await storage.writeJson(
      _kAppsCache,
      installedApps.map((a) => a.toMap()).toList(),
    );
    await _persistWebApps();
    await _persistLaunchLog();
    await _persistIcons();
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

  /// Reorder a tile page for drag-and-drop lists.
  ///
  /// [newIndex] follows `ReorderableListView.onReorderItem` semantics: it is
  /// already adjusted after the item was removed. The page currently in view is
  /// kept in view (its index shifts if needed) rather than jumping to the moved
  /// page.
  Future<void> reorderTilePage(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= tilePages.length) return;
    final currentId = currentTilePageId;
    final page = tilePages.removeAt(oldIndex);
    tilePages.insert(newIndex.clamp(0, tilePages.length), page);
    if (currentId != null) {
      final idx = tilePages.indexWhere((p) => p.id == currentId);
      if (idx >= 0) currentTilePageIndex = idx;
    }
    _rememberTilePage();
    await _persistTilePages();
    notifyListeners();
  }

  // ---------------------------------------------------------------- filtering

  /// The current search text, read as text plus filters (`size:`, `installed:`,
  /// `cat:`, `reason:`, `source:`, `type:` — see [AppQuery]).
  AppQuery get parsedQuery =>
      AppQuery.parse(query, now: DateTime.now().millisecondsSinceEpoch);

  /// The last few searches, most recent first, offered as chips under the
  /// search field so a repeated query is one tap.
  static const int kSearchHistoryMax = 8;

  List<String> get searchHistory =>
      (settings['search_history'] as List?)?.map((e) => '$e').toList() ??
      <String>[];

  Future<void> rememberQuery(String raw) async {
    final q = raw.trim();
    if (q.isEmpty) return;
    final list = List<String>.from(searchHistory)
      ..removeWhere((e) => e == q)
      ..insert(0, q);
    settings['search_history'] = list.take(kSearchHistoryMax).toList();
    await _persistSettings();
    notifyListeners();
  }

  Future<void> clearSearchHistory() async {
    settings['search_history'] = <String>[];
    await _persistSettings();
    notifyListeners();
  }

  /// The app list a given set of conditions would show, without touching the
  /// current ones. The 搜索与筛选 page uses it for its live result count, and
  /// [visibleApps] is just this with the current state.
  List<AppInfo> appsFor({
    required String query,
    required AppScope scope,
    required AppFilter filter,
    required String? filterCategoryId,
    required AppSort sort,
    required bool sortAscending,
  }) {
    final parsed = AppQuery.parse(
      query,
      now: DateTime.now().millisecondsSinceEpoch,
    );
    // Only the free text goes through the fuzzy matcher; the filters are
    // predicates below.
    final q = parsed.text.trim();
    final scores = <String, int>{};
    final list = apps.where((app) {
      final meta = metaFor(app.packageName);
      // Hidden apps only show under the 隐藏 filter; every other view leaves
      // them out.
      if (filter == AppFilter.hidden) {
        if (!meta.hidden) return false;
      } else if (meta.hidden) {
        return false;
      }
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
          if (!meta.favorite) return false;
          break;
        case AppFilter.categorized:
          if (meta.categoryIds.isEmpty) return false;
          break;
        case AppFilter.uncategorized:
          if (meta.categoryIds.isNotEmpty) return false;
          break;
        case AppFilter.hasReason:
          if (meta.reason.isEmpty) return false;
          break;
        case AppFilter.unorganized:
          if (!isUnorganized(meta)) return false;
          break;
        case AppFilter.uninstalled:
          // Handled separately via [uninstalledApps].
          return false;
        case AppFilter.hidden:
          // Narrowed above, before the scope check.
          break;
        case AppFilter.all:
          break;
      }
      if (filterCategoryId != null &&
          !meta.categoryIds.contains(filterCategoryId)) {
        return false;
      }
      final score = _matchScore(app, meta, parsed, q);
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
        return _sortName(a).compareTo(_sortName(b));
      });
      return list;
    }

    late final Comparator<AppInfo> cmp;
    switch (sort) {
      case AppSort.name:
        cmp = (a, b) => _sortName(a).compareTo(_sortName(b));
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

  /// Relevance of [app] for [parsed], or null when it does not match. Shared by
  /// [visibleApps] and [searchApps], so both understand the same syntax.
  int? _matchScore(AppInfo app, AppMeta meta, AppQuery parsed, String q) {
    if (parsed.hasFilters) {
      final installer = appFacts[app.packageName]?.installer ?? app.installer;
      final installerLabel = installer.isEmpty
          ? ''
          : '${displayNameFor(installer)} $installer';
      final ok = parsed.matches(
        sizeBytes: app.sizeBytes,
        firstInstallTime: app.firstInstallTime,
        lastUpdateTime: app.lastUpdateTime,
        isSystem: app.isSystem,
        categoryNames: [
          for (final id in meta.categoryIds) categoryById(id)?.name ?? '',
        ].join(' '),
        reason: meta.reason,
        installerLabel: installerLabel,
        sideloaded: installer.isEmpty,
      );
      if (!ok) return null;
    }
    // Match either name: the package's own label, or the name of a pinned
    // launcher entry (which is what the row shows).
    var score = AppSearch.score(app.packageName, app.appName, q);
    if (score == null) {
      final display = displayNameFor(app.packageName);
      if (display != app.appName) {
        score = AppSearch.score(app.packageName, display, q);
      }
    }
    // A web entry is worth finding by its address as well.
    if (score == null && app.webUrl.isNotEmpty) {
      score = AppSearch.score(app.webUrl, app.appName, q);
    }
    return score;
  }

  List<AppInfo> get visibleApps => appsFor(
        query: query,
        scope: scope,
        filter: filter,
        filterCategoryId: filterCategoryId,
        sort: sort,
        sortAscending: sortAscending,
      );

  /// Sort/compare key: the name shown to the user, which can come from a pinned
  /// launcher entry (联系人 vs 电话) instead of the package's own label.
  String _sortName(AppInfo app) =>
      displayNameFor(app.packageName).toLowerCase();

  List<AppInfo> get favorites =>
      apps.where((a) => metaFor(a.packageName).favorite).toList()..sort(
        (a, b) => _sortName(a).compareTo(_sortName(b)),
      );

  /// Apps launched from this app, most recent first.
  /// "Organized" covers anything the user has already invested in from the
  /// launch tab: categories, reasons/notes, favorites and tiles. Shared by the
  /// 应用 page's 未整理 filter and the 未整理 tile, so both agree.
  static bool isUnorganized(AppMeta m) =>
      m.categoryIds.isEmpty &&
      m.reason.isEmpty &&
      m.note.isEmpty &&
      !m.favorite &&
      !m.pinned &&
      // Hiding an app or giving it its own icon is a decision, not neglect.
      !m.hidden &&
      m.customIcon.isEmpty;

  /// Apps that are not sorted out yet.
  List<AppInfo> get unorganizedApps =>
      apps.where((a) => isUnorganized(metaFor(a.packageName))).toList();

  /// The newest stored snapshot, or null when none was taken.
  Snapshot? get latestSnapshot {
    if (snapshots.isEmpty) return null;
    var newest = snapshots.first;
    for (final s in snapshots) {
      if (s.createdAt > newest.createdAt) newest = s;
    }
    return newest;
  }

  /// What is on the device right now, as a snapshot, so it can be diffed
  /// against a stored one (same shape the 快照 page compares against).
  Snapshot currentDeviceSnapshot() => Snapshot(
    id: 'current',
    name: AppStrings.current.t('当前设备'),
    createdAt: DateTime.now().millisecondsSinceEpoch,
    entries: deviceEntries(),
  );

  /// How many of a backup list's apps are installed and how many are missing.
  (int installed, int missing) backupListCounts(String listId) {
    for (final list in backupLists) {
      if (list.id != listId) continue;
      final installed = list.packageNames
          .where((p) => appByPackage(p) != null)
          .length;
      return (installed, list.packageNames.length - installed);
    }
    return (0, 0);
  }

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

  Future<void> markLaunched(String packageName, {DateTime? at}) async {
    final m = metaFor(packageName);
    final when = at ?? DateTime.now();
    m.lastLaunchedAt = when.millisecondsSinceEpoch;
    m.launchCount += 1;
    _recordLaunch(packageName, when.millisecondsSinceEpoch);
    await _persistMeta();
    await _persistLaunchLog();
    notifyListeners();
    // The launcher's long press should offer what was used last.
    unawaited(syncRecentShortcuts());
    // Throttled internally; the widget's "now" suggestion improves with use.
    unawaited(syncHomeWidget());
  }

  /// How many recent apps a long press on 囤囤's icon offers.
  static const int kRecentShortcutCount = 4;

  /// Publishes the most recently launched apps as dynamic launcher shortcuts.
  /// Best effort: a launcher that refuses them changes nothing for the user.
  Future<void> syncRecentShortcuts() async {
    final recents = recentAppsBy(
      RecentSort.recent,
    ).take(kRecentShortcutCount).toList();
    final ok = await NativeApps.setRecentShortcuts([
      for (final a in recents)
        RecentShortcut(
          packageName: a.packageName,
          label: displayNameFor(a.packageName),
        ),
    ]);
    if (!ok) {
      AppLog.instance.log(LogModule.apps, '系统拒绝了快捷方式更新');
    }
  }

  void _recordLaunch(String packageName, int at) {
    launchLog.add(LaunchEvent(packageName: packageName, at: at));
    _pruneLaunchLog();
  }

  void _pruneLaunchLog() {
    final cutoff = DateTime.now()
        .subtract(_kLaunchLogMaxAge)
        .millisecondsSinceEpoch;
    launchLog.removeWhere((e) => e.at < cutoff);
    if (launchLog.length > _kLaunchLogCap) {
      launchLog.removeRange(0, launchLog.length - _kLaunchLogCap);
    }
  }

  Future<void> _persistLaunchLog() => storage.writeJson(
        _kLaunchLog,
        launchLog.map((e) => e.toMap()).toList(),
      );

  /// Apps suggested for right now, based on when they are usually launched.
  /// Returns nothing when the feature is off or there is not enough history.
  List<Recommendation> recommendedApps({DateTime? now, int limit = 8}) {
    if (!recommendationsEnabled || apps.isEmpty || launchLog.isEmpty) {
      return const <Recommendation>[];
    }
    final at = now ?? DateTime.now();
    // Live calls (the 最近 grid) keep the order chosen earlier this hour.
    // Explicit `now` asks for a fresh ranking and is left untouched.
    final live = now == null;
    final key = _hourKey(at);
    if (live && _recsHourKey == key) {
      final cached = _recsHour;
      if (cached != null) {
        final kept = <Recommendation>[
          for (final r in cached)
            if (appByPackage(r.packageName) != null &&
                !metaFor(r.packageName).hidden)
              r,
        ];
        if (kept.isNotEmpty) return kept.take(limit).toList();
      }
    }
    final installed = <String>{for (final a in apps) a.packageName};
    final events = launchLog
        .where((e) => installed.contains(e.packageName))
        .toList(growable: false);
    if (events.isEmpty) return const <Recommendation>[];
    final recs = Recommender.recommend(
      events,
      nowMillis: at.millisecondsSinceEpoch,
      limit: limit,
    );
    if (live) {
      _recsHourKey = key;
      _recsHour = recs;
    }
    return recs;
  }

  /// Rebuilds both recommendation surfaces (widget and 最近 → 推荐) on the
  /// next use. Called when the input changes on purpose: the switch, or a
  /// cleared launch history.
  void _resetRecommendationPicks() {
    _recsHourKey = null;
    _recsHour = null;
    _forgetHour();
  }

  /// Wipes every launch timestamp and count, so the 最近 list and suggestions
  /// start over.
  Future<void> clearLaunchHistory() async {
    _resetRecommendationPicks();
    launchLog = <LaunchEvent>[];
    for (final m in meta.values) {
      m.lastLaunchedAt = 0;
      m.launchCount = 0;
    }
    await _persistLaunchLog();
    await _persistMeta();
    notifyListeners();
    unawaited(syncHomeWidget(force: true));
  }

  /// How many timestamped launches were recorded for [packageName].
  int launchLogCountFor(String packageName) =>
      launchLog.where((e) => e.packageName == packageName).length;

  /// Forgets one app's usage: drops its launch timestamps, count and last-used
  /// time, so it leaves 最近 / 使用趋势 as if it had never been launched.
  Future<void> clearLaunchHistoryFor(String packageName) async {
    _resetRecommendationPicks();
    final before = launchLog.length;
    launchLog.removeWhere((e) => e.packageName == packageName);
    if (launchLog.length == before) {
      // Nothing logged, but still reset the aggregate count if present.
      final m = meta[packageName];
      if (m == null || (m.launchCount == 0 && m.lastLaunchedAt == 0)) return;
    }
    final m = metaFor(packageName);
    m.launchCount = 0;
    m.lastLaunchedAt = 0;
    await _persistLaunchLog();
    await _persistMeta();
    notifyListeners();
    unawaited(syncHomeWidget(force: true));
  }

  // ---- usage trends

  Set<String> get _installedPackages =>
      <String>{for (final a in apps) a.packageName};

  int _sinceMillis(int days) => DateTime.now()
      .subtract(Duration(days: days))
      .millisecondsSinceEpoch;

  /// Apps launched the most in the last [days] days.
  List<UsageEntry> mostUsedApps({required int days, int limit = 20}) =>
      UsageStats.mostUsed(
        launchLog,
        installed: _installedPackages,
        sinceMillis: _sinceMillis(days),
        limit: limit,
      );

  /// Apps that were opened routinely before the last [days] days but not since.
  List<NeglectedEntry> neglectedApps({required int days, int limit = 30}) =>
      UsageStats.neglected(
        launchLog,
        installed: _installedPackages,
        sinceMillis: _sinceMillis(days),
        limit: limit,
      );

  int launchesInDays(int days) => UsageStats.launchesInRange(
        launchLog,
        installed: _installedPackages,
        sinceMillis: _sinceMillis(days),
      );

  int activeAppsInDays(int days) => UsageStats.activeAppsInRange(
        launchLog,
        installed: _installedPackages,
        sinceMillis: _sinceMillis(days),
      );

  int neglectedCountInDays(int days) => UsageStats.neglectedCount(
        launchLog,
        installed: _installedPackages,
        sinceMillis: _sinceMillis(days),
      );

  /// Non-system apps that have never been launched from this app, oldest
  /// installed first (the likeliest cleanup candidates).
  List<AppInfo> neverLaunchedApps({bool includeSystem = false}) {
    final candidates = <String>{
      for (final a in apps)
        if (includeSystem || !a.isSystem) a.packageName,
    };
    final never = UsageStats.neverLaunched(launchLog, candidates: candidates);
    final list = apps.where((a) => never.contains(a.packageName)).toList()
      ..sort((a, b) => a.firstInstallTime.compareTo(b.firstInstallTime));
    return list;
  }

  /// Id of the currently visible tile page, or null when none exist.
  String? get currentTilePageId {
    if (tilePages.isEmpty) return null;
    final i = currentTilePageIndex.clamp(0, tilePages.length - 1);
    return tilePages[i].id;
  }

  AppInfo? appByPackage(String packageName) {
    // Indexed: this is called from list rows and sort/filter paths, where a
    // linear scan over every installed app would add up.
    final index = _appIndex ??= {
      for (final a in _mergedApps) a.packageName: a,
    };
    return index[packageName];
  }

  /// Name to show for an app.
  ///
  /// A package can own several launcher entries with their own names (联系人
  /// and 电话 are two entries of one package), so when the user pinned one of
  /// them, that name wins — matching the icon, which follows the same choice.
  /// Apps can opt out ([AppMeta.nameFollowsEntry]) to keep the name they know.
  /// Falls back to the package's own label, then to the last known name (so an
  /// uninstalled app still shows something).
  String displayNameFor(String packageName) {
    final m = meta[packageName];
    if (m != null &&
        m.launchActivity.isNotEmpty &&
        m.nameFollowsEntry &&
        m.launchEntryLabel.isNotEmpty) {
      return m.launchEntryLabel;
    }
    final a = appByPackage(packageName);
    if (a != null && a.appName.isNotEmpty) return a.appName;
    if (m != null && m.lastKnownName.isNotEmpty) return m.lastKnownName;
    return packageName;
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
        // Installed web apps are called out here so the count is checkable
        // from the app itself, without turning the log on.
        s.t(' · 网页应用 {web}', {'web': webAppCount}) +
        s.t(' · 显示 {visible} · 用时 {ms} ms · {ago}', {
          'visible': visibleApps.length,
          'ms': lastScanMs,
          'ago': ago,
        });
  }

  /// Installed packages that are really websites (WebAPK / Trusted Web
  /// Activity). They are ordinary apps everywhere else.
  int get webAppCount => apps.where((a) => a.isWebApp).length;

  static const _kMeta = 'meta';
  static const _kCategories = 'categories';
  static const _kSnapshots = 'snapshots';
  static const _kBackupLists = 'backup_lists';
  /// Cached scan. Renamed when [AppInfo] gained the web-app fields so an old
  /// cache cannot blank them out — a miss makes the app rescan on startup.
  static const _kAppsCache = Storage.scanCacheFile;

  /// Websites added by hand (see [WebApp]). Kept apart from the scan cache so
  /// no scan can drop them.
  static const _kWebApps = 'web_apps';
  static const _kIcons = Storage.iconsFile;

  /// Package -> `lastUpdateTime` at the moment its icon was read (see
  /// [iconNeedsRefresh]).
  static const _kIconStamps = 'icon_stamps';
  static const _kTilePages = 'tile_pages';
  static const _kTiles = 'tiles';
  static const _kSettings = 'settings';
  static const _kLaunchLog = 'launch_log';

  /// The recommendation layout kept for the current hour (see
  /// [buildHomeWidgetData]).
  static const _kWidgetHourPick = 'widget_hour_pick';

  /// Index of the 磁贴 launch sub-tab in the current order
  /// (最近 / 磁贴 / 分类 / 收藏).
  static const int _kTilesTabIndex = 1;

  /// Settings key recording that the launch sub-tab order migration has run.
  static const String _kLaunchTabOrder = 'launch_tab_order';

  /// Keep the event log small but deep enough for time-of-day analysis.
  static const int _kLaunchLogCap = 2000;
  static const Duration _kLaunchLogMaxAge = Duration(days: 180);
}
