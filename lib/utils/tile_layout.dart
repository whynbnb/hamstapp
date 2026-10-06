/// Number of grid columns per row on the tile board (one row = 6 cells).
///
/// This is also the maximum width of a single tile, so persisted tile sizes
/// stay valid on the narrowest (phone) board. Wider screens render *more*
/// columns (see [tileColumnsForWidth]) rather than bigger cells.
const int kTileCols = 6;

/// Allowed tile size range (1..kTileCols wide, 1..kTileMaxH tall).
const int kTileMaxH = 6;

/// Comfortable logical cell size (dp) the adaptive grid aims for.
const double kTileTargetCell = 72;

/// Upper bound on the number of columns shown on very wide screens.
const int kTileMaxCols = 16;

/// The board is centered and clamped to this width so cells never balloon on
/// large tablets/foldables.
const double kTileBoardMaxWidth = 1200;

/// Column count for a board of [width] logical pixels.
///
/// Phones keep the classic 6 columns; wider devices get more columns so the
/// cell (and therefore every tile/icon) stays close to [kTileTargetCell]
/// instead of growing with the screen.
int tileColumnsForWidth(double width) {
  if (width.isNaN || width <= 0) return kTileCols;
  final cols = (width / kTileTargetCell).round();
  return cols.clamp(kTileCols, kTileMaxCols).toInt();
}

/// Desired placement of a tile. col/row < 0 means "auto place".
class TileSpec {
  final String id;
  final int w;
  final int h;
  final int col;
  final int row;

  const TileSpec({
    required this.id,
    this.w = 1,
    this.h = 1,
    this.col = -1,
    this.row = -1,
  });
}

class TilePlacement {
  final String id;
  final int col;
  final int row;
  final int w;
  final int h;

  const TilePlacement(this.id, this.col, this.row, this.w, this.h);
}

class TileLayoutResult {
  final Map<String, TilePlacement> placements;
  final int rows;

  const TileLayoutResult(this.placements, this.rows);
}

/// Resolve a collision-free layout for [specs].
///
/// Stored positions that fit are honoured first; the rest are packed into the
/// first free cells in the given order. When [ignoreStored] is true every tile
/// is packed sequentially (used by the sort/reflow actions).
TileLayoutResult resolveTileLayout(
  List<TileSpec> specs, {
  int cols = kTileCols,
  bool ignoreStored = false,
}) {
  final occupied = <int>{};
  int key(int c, int r) => r * cols + c;

  bool fits(int c, int r, int w, int h) {
    if (c < 0 || r < 0 || c + w > cols) return false;
    for (var x = c; x < c + w; x++) {
      for (var y = r; y < r + h; y++) {
        if (occupied.contains(key(x, y))) return false;
      }
    }
    return true;
  }

  void occupy(int c, int r, int w, int h) {
    for (var x = c; x < c + w; x++) {
      for (var y = r; y < r + h; y++) {
        occupied.add(key(x, y));
      }
    }
  }

  final result = <String, TilePlacement>{};

  if (!ignoreStored) {
    for (final s in specs) {
      if (s.col >= 0 && s.row >= 0 && fits(s.col, s.row, s.w, s.h)) {
        occupy(s.col, s.row, s.w, s.h);
        result[s.id] = TilePlacement(s.id, s.col, s.row, s.w, s.h);
      }
    }
  }

  for (final s in specs) {
    if (result.containsKey(s.id)) continue;
    final w = s.w.clamp(1, cols);
    final h = s.h.clamp(1, kTileMaxH);
    var placed = false;
    for (var r = 0; !placed; r++) {
      for (var c = 0; c + w <= cols; c++) {
        if (fits(c, r, w, h)) {
          occupy(c, r, w, h);
          result[s.id] = TilePlacement(s.id, c, r, w, h);
          placed = true;
          break;
        }
      }
    }
  }

  var rows = 0;
  for (final p in result.values) {
    if (p.row + p.h > rows) rows = p.row + p.h;
  }
  return TileLayoutResult(result, rows);
}

/// Find a free spot for a tile of [w]x[h] as close as possible to
/// ([wantCol], [wantRow]), treating [others] as already placed.
TilePlacement resolveMove(
  List<TileSpec> others,
  String id,
  int wantCol,
  int wantRow,
  int w,
  int h, {
  int cols = kTileCols,
}) {
  final occupied = <int>{};
  int key(int c, int r) => r * cols + c;
  final base = resolveTileLayout(others, cols: cols);
  for (final p in base.placements.values) {
    for (var x = p.col; x < p.col + p.w; x++) {
      for (var y = p.row; y < p.row + p.h; y++) {
        occupied.add(key(x, y));
      }
    }
  }

  bool fits(int c, int r) {
    if (c < 0 || r < 0 || c + w > cols) return false;
    for (var x = c; x < c + w; x++) {
      for (var y = r; y < r + h; y++) {
        if (occupied.contains(key(x, y))) return false;
      }
    }
    return true;
  }

  final cc = wantCol.clamp(0, cols - w);
  final rr = wantRow < 0 ? 0 : wantRow;
  if (fits(cc, rr)) return TilePlacement(id, cc, rr, w, h);

  // The requested spot is taken: place the tile in the nearest free cell
  // (Manhattan distance), scanning row-major so ties resolve to the top-most
  // then left-most option. This keeps the tile right next to where it was
  // dropped instead of jumping to the left edge of the row.
  var bestCol = 0;
  var bestRow = 0;
  var bestDist = 1 << 30;
  final maxRow = base.rows + h; // always includes a fully free row below
  for (var r = 0; r <= maxRow; r++) {
    for (var c = 0; c + w <= cols; c++) {
      if (!fits(c, r)) continue;
      final d = (c - cc).abs() + (r - rr).abs();
      if (d < bestDist) {
        bestDist = d;
        bestCol = c;
        bestRow = r;
      }
    }
  }
  return TilePlacement(id, bestCol, bestRow, w, h);
}
