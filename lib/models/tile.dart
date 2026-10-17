/// What a tile shows.
///
/// An `app` tile draws a launchable app; the others are small live tiles drawn
/// by the board itself (no app behind them), so they carry no package name.
enum TileKind {
  app,

  // Live readings.
  clock,
  date,
  battery,
  storage,
  memory,
  screenTime,
  traffic,
  alarm,
  unread,

  // App lists.
  recent,
  frequent,
  newApps,
  neglected,
  folder,
  favorites,
  biggest,

  // 囤囤's own state.
  snapshot,
  unorganized,
  cache,
  backupList,

  // Device extras.
  torch,
  uptime,
  dial,
  countdown,
  worldClock,
  note,
  netSpeed,
  overview,

  /// A tile that runs one action when tapped (scan, snapshot, search, storage).
  action,

  /// A kind this build does not know: added by a newer version, or removed
  /// since. Kept on the board (and in the layout) and shown as a placeholder,
  /// so the user can decide to remove it instead of it vanishing silently.
  unknown;

  /// The stored kind name. An empty/missing name is an app tile: tiles predate
  /// the info kinds. Anything unrecognised is [TileKind.unknown].
  static TileKind byName(String? name) {
    if (name == null || name.isEmpty) return TileKind.app;
    for (final kind in TileKind.values) {
      if (kind.name == name) return kind;
    }
    return TileKind.unknown;
  }

  bool get isInfo => this != TileKind.app;

  /// Board size (w×h) a freshly added tile of this kind gets.
  (int, int) get defaultSize => switch (this) {
    TileKind.app => (1, 1),
    TileKind.clock => (2, 2),
    TileKind.date => (2, 1),
    TileKind.battery => (1, 1),
    TileKind.storage => (2, 1),
    TileKind.memory => (2, 1),
    TileKind.screenTime => (2, 1),
    TileKind.traffic => (2, 1),
    TileKind.alarm => (2, 1),
    TileKind.unread => (1, 1),
    TileKind.recent => (2, 2),
    TileKind.frequent => (2, 2),
    TileKind.newApps => (2, 2),
    TileKind.neglected => (2, 1),
    TileKind.folder => (2, 2),
    TileKind.favorites => (2, 2),
    TileKind.biggest => (2, 2),
    TileKind.snapshot => (2, 2),
    TileKind.unorganized => (2, 1),
    TileKind.cache => (2, 1),
    TileKind.backupList => (2, 1),
    TileKind.torch => (1, 1),
    TileKind.uptime => (2, 1),
    TileKind.dial => (1, 1),
    TileKind.countdown => (2, 2),
    TileKind.worldClock => (2, 1),
    TileKind.note => (2, 2),
    TileKind.netSpeed => (2, 1),
    TileKind.overview => (2, 2),
    TileKind.action => (1, 1),
    TileKind.unknown => (2, 1),
  };
}

/// A single tile on the quick-launch board.
///
/// Tiles are independent entities keyed by [id], so the same app can appear
/// multiple times on the same page (and across pages) without restriction.
class Tile {
  final String id;
  String packageName;

  /// Which [TilePage] this tile lives on.
  String pageId;

  /// What the tile shows; [TileKind.app] for ordinary app tiles.
  TileKind kind;

  /// Per-tile settings for the info tiles: which category a folder shows, how
  /// many days "new installs" counts, which action an action tile runs, ...
  /// Opaque to everything but the tile's own UI, and persisted as JSON.
  Map<String, dynamic> options;

  /// Grid position/size on the 6-column board. col/row of -1 means auto.
  int col;
  int row;
  int w;
  int h;

  /// Whether the app name is shown under the icon. When false the tile is
  /// icon-only (1x1 tiles already hide the label regardless of this).
  bool showLabel;

  /// Whether the tile keeps an inner margin around its content. When false the
  /// icon/label fill the tile edge-to-edge; together with [showLabel] off this
  /// yields a single large, full-bleed icon.
  bool innerPadding;

  /// Whether the tile draws its backdrop (fill + rounded border + shadow).
  /// When false only the content (icon and/or name) is shown, frameless.
  bool border;

  Tile({
    required this.id,
    required this.packageName,
    required this.pageId,
    this.kind = TileKind.app,
    this.options = const <String, dynamic>{},
    this.col = -1,
    this.row = -1,
    this.w = 1,
    this.h = 1,
    this.showLabel = true,
    this.innerPadding = true,
    this.border = true,
  });

  /// An info tile has no app behind it.
  bool get isInfo => kind.isInfo;

  /// The kind as stored, with one extra rule: an app tile without a package
  /// cannot show anything, so it is treated as unsupported rather than as an
  /// invisible tile that still occupies grid cells.
  static TileKind _kindFor(Map<String, dynamic> map) {
    final kind = TileKind.byName(map['kind'] as String?);
    final packageName = map['packageName'] as String? ?? '';
    if (kind == TileKind.app && packageName.isEmpty) return TileKind.unknown;
    return kind;
  }

  /// String option, e.g. a folder's category id.
  String optionString(String key, [String fallback = '']) {
    final v = options[key];
    return v is String ? v : fallback;
  }

  /// Boolean option, e.g. whether the world clock also shows its date.
  bool optionBool(String key, [bool fallback = false]) {
    final v = options[key];
    return v is bool ? v : fallback;
  }

  /// Integer option, e.g. how many days "new installs" looks back.
  int optionInt(String key, [int fallback = 0]) {
    final v = options[key];
    return v is num ? v.toInt() : fallback;
  }

  /// String list option, e.g. the hand-picked apps of a folder tile.
  List<String> optionList(String key) {
    final v = options[key];
    if (v is! List) return const <String>[];
    return [
      for (final e in v)
        if (e is String && e.isNotEmpty) e,
    ];
  }

  factory Tile.fromMap(Map<String, dynamic> map) => Tile(
        id: map['id'] as String,
        packageName: map['packageName'] as String? ?? '',
        pageId: map['pageId'] as String? ?? '',
        kind: _kindFor(map),
        options: switch (map['options']) {
          final Map<dynamic, dynamic> m => m.cast<String, dynamic>(),
          _ => const <String, dynamic>{},
        },
        col: map['col'] as int? ?? -1,
        row: map['row'] as int? ?? -1,
        w: map['w'] as int? ?? 1,
        h: map['h'] as int? ?? 1,
        showLabel: map['showLabel'] as bool? ?? true,
        innerPadding: map['innerPadding'] as bool? ?? true,
        border: map['border'] as bool? ?? true,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'packageName': packageName,
        'pageId': pageId,
        'kind': kind.name,
        if (options.isNotEmpty) 'options': options,
        'col': col,
        'row': row,
        'w': w,
        'h': h,
        'showLabel': showLabel,
        'innerPadding': innerPadding,
        'border': border,
      };
}
