/// What a tile shows.
///
/// An `app` tile draws a launchable app; the others are small live tiles drawn
/// by the board itself (no app behind them), so they carry no package name.
enum TileKind {
  app,
  clock,
  date,
  battery,
  storage,
  unread;

  static TileKind byName(String? name) => TileKind.values.firstWhere(
    (k) => k.name == name,
    orElse: () => TileKind.app,
  );

  bool get isInfo => this != TileKind.app;

  /// Board size (w×h) a freshly added tile of this kind gets.
  (int, int) get defaultSize => switch (this) {
    TileKind.app => (1, 1),
    TileKind.clock => (2, 2),
    TileKind.date => (2, 1),
    TileKind.battery => (1, 1),
    TileKind.storage => (2, 1),
    TileKind.unread => (1, 1),
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

  factory Tile.fromMap(Map<String, dynamic> map) => Tile(
        id: map['id'] as String,
        packageName: map['packageName'] as String? ?? '',
        pageId: map['pageId'] as String? ?? '',
        kind: TileKind.byName(map['kind'] as String?),
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
        'col': col,
        'row': row,
        'w': w,
        'h': h,
        'showLabel': showLabel,
        'innerPadding': innerPadding,
        'border': border,
      };
}
