import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/app_strings.dart';
import '../models/app_info.dart';
import '../models/tile.dart';
import '../models/tile_page.dart';
import '../state/app_state.dart';
import '../utils/actions.dart';
import '../utils/format.dart';
import '../utils/pager_haptics.dart';
import '../utils/recommender.dart';
import '../utils/search.dart';
import '../utils/tile_layout.dart';
import '../widgets/app_icon.dart';
import '../widgets/category_editor.dart';
import '../widgets/floating_nav.dart';
import '../widgets/search_field.dart';
import 'app_detail_screen.dart';
import 'categories_tab.dart';
import 'tile_pages_screen.dart';
import 'usage_stats_screen.dart';

class QuickLaunchScreen extends StatefulWidget {
  const QuickLaunchScreen({super.key});

  @override
  State<QuickLaunchScreen> createState() => _QuickLaunchScreenState();
}

class _QuickLaunchScreenState extends State<QuickLaunchScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  int _lastTab = 0;

  /// Coalesces sub-tab haptics so one swipe or tap ticks exactly once, however
  /// many tabs the gesture glides across.
  late final PagerHaptics _haptics;

  RecentSort _recentSort = RecentSort.recent;
  int _recentSince = 0;

  @override
  void initState() {
    super.initState();
    final start = context.read<AppState>().lastLaunchTab.clamp(0, 3);
    _lastTab = start;
    _haptics = PagerHaptics(
      () => context.read<AppState>().haptic(HapticTrigger.launchTabs),
    )
      ..align(start)
      ..setPageCount(4);
    _tabs = TabController(length: 4, vsync: this, initialIndex: start)
      ..addListener(_onTabChanged);
  }

  void _onTabChanged() {
    if (_tabs.index == _lastTab) return;
    _lastTab = _tabs.index;
    context.read<AppState>().setLastLaunchTab(_tabs.index);
    // Tapping a tab updates the index immediately; a swipe settles here after
    // the drag already ticked, in which case this is a no-op.
    _haptics.indexChanged(_tabs.index);
    setState(() {});
  }

  /// Switch the launch sub-tab by [delta] (+1 = next, -1 = previous).
  ///
  /// Used by the long-press-and-drag gesture on the tile board's blank area:
  /// a normal horizontal swipe there is consumed by the board's own page pager,
  /// so this is the only way to reach e.g. 分类 without touching the tab bar.
  void _switchLaunchTab(int delta) {
    final target = (_tabs.index + delta).clamp(0, 3);
    if (target == _tabs.index) return;
    // Use the standard sub-tab tick so the gesture feels the same as tapping or
    // swiping between 磁贴/分类/收藏/最近.
    _haptics.tickNow(target);
    _tabs.animateTo(target);
  }

  /// Boils a sub-tab swipe down to at most one tick, fired the moment the
  /// gesture commits to a different tab (crossing the midpoint) rather than
  /// waiting for the snap animation to finish.
  bool _onTabsScroll(ScrollNotification n) {
    // depth 0 = this TabBarView's own pager; deeper notifications come from
    // scroll views inside a tab (e.g. the tile board) and must be ignored.
    if (n.depth != 0 || n.metrics.axis != Axis.horizontal) return false;
    _haptics.handleScroll(n);
    return false;
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final editing = state.tileEditMode && _tabs.index == 0;

    // The four sections live directly in the header (no title text) to save a
    // whole row of vertical space.
    final tabs = TabBar(
      controller: _tabs,
      labelPadding: const EdgeInsets.symmetric(horizontal: 6),
      indicatorSize: TabBarIndicatorSize.label,
      dividerColor: Colors.transparent,
      labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
      unselectedLabelStyle: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w500,
      ),
      tabs: [
        Tab(height: 40, text: context.strings.t('磁贴')),
        Tab(height: 40, text: context.strings.t('分类')),
        Tab(height: 40, text: context.strings.t('收藏')),
        Tab(height: 40, text: context.strings.t('最近')),
      ],
    );

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        leading: FloatingNavScope.activeOf(context)
            ? const FloatingNavButton()
            : null,
        titleSpacing: 8,
        title: editing
            ? Text(
                context.strings.t('编辑磁贴'),
                style: const TextStyle(fontWeight: FontWeight.bold),
              )
            : tabs,
        actions: _actions(context, state, editing),
      ),
      body: NotificationListener<ScrollNotification>(
        onNotification: _onTabsScroll,
        child: TabBarView(
          controller: _tabs,
          physics: editing
              ? const NeverScrollableScrollPhysics()
              : const PageScrollPhysics(),
          children: [
            _TilesTab(
              state: state,
              onSwitchTab: _switchLaunchTab,
              onArm: () => context.read<AppState>().hapticLight(),
            ),
            CategoriesTab(state: state),
            _FavoritesTab(state: state),
            _RecentTab(
              state: state,
              sort: _recentSort,
              sinceMillis: _recentSince,
            ),
          ],
        ),
      ),
    );
  }

  /// Exactly one action in normal mode per section, so the header tabs keep a
  /// constant width (the tile "+" only appears while editing).
  List<Widget> _actions(BuildContext context, AppState state, bool editing) {
    final s = context.strings;
    if (_tabs.index == 0 && editing) {
      return [
        IconButton(
          tooltip: s.t('置顶应用到磁贴'),
          icon: const Icon(Icons.add),
          onPressed: () => showPinSheet(context, state),
        ),
        IconButton(
          tooltip: s.t('磁贴页管理'),
          icon: const Icon(Icons.dashboard_customize_outlined),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => TilePagesScreen(state: state)),
          ),
        ),
        TextButton.icon(
          onPressed: () => state.setTileEditMode(false),
          icon: const Icon(Icons.check, size: 18),
          label: Text(s.t('完成')),
        ),
        const SizedBox(width: 4),
      ];
    }
    switch (_tabs.index) {
      case 0:
        return [
          IconButton(
            tooltip: s.t('编辑磁贴（添加/拖动/缩放）'),
            icon: const Icon(Icons.edit_outlined),
            onPressed: () {
              state.setTileEditMode(true);
              ScaffoldMessenger.of(context)
                ..hideCurrentSnackBar()
                ..showSnackBar(
                  SnackBar(
                    content: Text(
                      s.t(
                        '编辑模式：点右上角 ➕ 置顶应用，长按磁贴拖动移动，拖动右下角缩放；完成后点「完成」',
                      ),
                    ),
                    behavior: SnackBarBehavior.floating,
                    duration: const Duration(seconds: 4),
                  ),
                );
            },
          ),
        ];
      case 1:
        return [
          IconButton(
            tooltip: s.t('新建分类'),
            icon: const Icon(Icons.add),
            onPressed: () => showCategoryEditor(context, state, null),
          ),
        ];
      case 2:
        return [
          IconButton(
            tooltip: s.t('添加收藏'),
            icon: const Icon(Icons.add),
            onPressed: () => showFavoriteSheet(context, state),
          ),
        ];
      default:
        return [
          IconButton(
            tooltip: s.t('排序 / 时间筛选'),
            icon: const Icon(Icons.tune),
            onPressed: () => _showRecentFilterSheet(context),
          ),
        ];
    }
  }

  Future<void> _showRecentFilterSheet(BuildContext context) async {
    final ranges = _recentRanges();
    final s = context.strings;
    final state = context.read<AppState>();
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: StatefulBuilder(
          builder: (ctx, setLocal) => SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text(
                    s.t('最近 · 排序与筛选'),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.schedule),
                  title: Text(s.t('按时间排序')),
                  trailing: _recentSort == RecentSort.recent
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () {
                    setState(() => _recentSort = RecentSort.recent);
                    setLocal(() {});
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.bar_chart),
                  title: Text(s.t('按频次排序')),
                  trailing: _recentSort == RecentSort.frequent
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () {
                    setState(() => _recentSort = RecentSort.frequent);
                    setLocal(() {});
                  },
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(
                    s.t('时间段'),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Wrap(
                    spacing: 8,
                    children: [
                      for (final r in ranges)
                        ChoiceChip(
                          label: Text(r.$1),
                          selected: _recentSince == r.$2,
                          onSelected: (_) {
                            setState(() => _recentSince = r.$2);
                            setLocal(() {});
                          },
                        ),
                    ],
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.insights),
                  title: Text(s.t('使用趋势')),
                  subtitle: Text(s.t('最常用 / 被冷落 / 从未启动')),
                  onTap: () {
                    Navigator.pop(ctx);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const UsageStatsScreen(),
                      ),
                    );
                  },
                ),
                const Divider(height: 1),
                SwitchListTile(
                  secondary: const Icon(Icons.auto_awesome),
                  value: state.recommendationsEnabled,
                  onChanged: (v) async {
                    await state.setRecommendationsEnabled(v);
                    setLocal(() {});
                    if (mounted) setState(() {});
                  },
                  title: Text(s.t('智能推荐')),
                  subtitle: Text(
                    s.t('根据常用时间段，在「最近」顶部推荐此刻可能想用的应用'),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    s.t('已记录 {n} 次启动 · 当前 {m} 个推荐', {
                      'n': state.launchLog.length,
                      'm': state.recommendedApps().length,
                    }),
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.delete_outline),
                  title: Text(s.t('清除启动记录')),
                  subtitle: Text(s.t('删除全部启动时间与次数')),
                  onTap: () async {
                    final ok = await showDialog<bool>(
                      context: ctx,
                      builder: (dctx) => AlertDialog(
                        title: Text(s.t('清除启动记录')),
                        content: Text(
                          s.t('将删除全部启动时间记录与启动次数，且无法恢复。确定吗？'),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(dctx, false),
                            child: Text(s.t('取消')),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(dctx, true),
                            child: Text(s.t('确定')),
                          ),
                        ],
                      ),
                    );
                    if (ok != true) return;
                    await state.clearLaunchHistory();
                    setLocal(() {});
                    if (mounted) setState(() {});
                  },
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<(String, int)> _recentRanges() {
    final s = context.strings;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return [
      (s.t('全部'), 0),
      (s.t('今天'), today.millisecondsSinceEpoch),
      (
        s.t('近 7 天'),
        today.subtract(const Duration(days: 6)).millisecondsSinceEpoch,
      ),
      (
        s.t('近 30 天'),
        today.subtract(const Duration(days: 29)).millisecondsSinceEpoch,
      ),
    ];
  }
}

// ---------------------------------------------------------------- 磁贴

class _TilesTab extends StatefulWidget {
  const _TilesTab({
    required this.state,
    required this.onSwitchTab,
    required this.onArm,
  });
  final AppState state;

  /// Called with +1 (next) or -1 (previous) when the user long-presses the
  /// blank area of the board and slides horizontally, to switch the launch
  /// sub-tab (磁贴/分类/收藏/最近).
  final ValueChanged<int> onSwitchTab;

  /// Called once when the long press reaches its threshold, so the gesture can
  /// give a light "armed" tick before the finger slides.
  final VoidCallback onArm;

  @override
  State<_TilesTab> createState() => _TilesTabState();
}

class _TilesTabState extends State<_TilesTab> {
  late final PageController _controller;
  int _index = 0;

  /// Coalesces tile-page haptics so one swipe or tap ticks exactly once,
  /// however many pages the gesture glides across.
  late final PagerHaptics _haptics;

  /// Long-press-and-slide on the board's blank area switches the launch
  /// sub-tab. [_holdMoved] latches so one hold yields at most one switch.
  bool _holdMoved = false;

  /// Horizontal travel (logical px) after a long press before it switches tab.
  static const double _holdThreshold = 48;

  int _clamp(int i) {
    final n = widget.state.tilePages.length;
    if (n == 0) return 0;
    return i < 0 ? 0 : (i >= n ? n - 1 : i);
  }

  @override
  void initState() {
    super.initState();
    // Rebuild the board on the same page the shared state points at. Without
    // this the freshly created PageController would start at page 0 while the
    // bottom bar highlighted a different page (the two got out of sync when
    // this tab was rebuilt, e.g. after switching the top-level tab).
    _index = _clamp(widget.state.currentTilePageIndex);
    widget.state.currentTilePageIndex = _index;
    _haptics = PagerHaptics(
      () => widget.state.haptic(HapticTrigger.tilePages),
    )
      ..align(_index)
      ..setPageCount(widget.state.tilePages.length);
    _controller = PageController(initialPage: _index);
  }

  @override
  void didUpdateWidget(covariant _TilesTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Page structure may have changed (add / delete / reorder) or another
    // screen moved the current page; keep local index + controller aligned.
    _syncToState();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _syncToState() {
    final target = _clamp(widget.state.currentTilePageIndex);
    if (target == _index) return;
    _index = target;
    // A structural jump (page added/deleted/reordered elsewhere) should not
    // buzz; sync the tracker silently before the controller follows.
    _haptics.align(target);
    _jumpTo(target);
  }

  void _jumpTo(int i) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      if ((_controller.page?.round() ?? 0) != i) _controller.jumpToPage(i);
    });
  }

  void _setIndex(int i) {
    i = _clamp(i);
    final stateChanged = widget.state.currentTilePageIndex != i;
    final localChanged = _index != i;
    if (!stateChanged && !localChanged) return;
    // onPageChanged fires for every intermediate page while a swipe or chip
    // animation glides across the pager; PagerHaptics guarantees this still
    // yields exactly one tick for the whole action.
    _haptics.indexChanged(i);
    if (localChanged) setState(() => _index = i);
    if (stateChanged) widget.state.setCurrentTilePage(i);
  }

  /// Boils a page swipe down to at most one tick, fired the moment the gesture
  /// commits to a different page (crossing the midpoint), rather than waiting
  /// for the snap animation to finish.
  bool _onPagesScroll(ScrollNotification n) {
    if (n.depth != 0 || n.metrics.axis != Axis.horizontal) return false;
    _haptics.handleScroll(n);
    return false;
  }

  void _onHoldStart(LongPressStartDetails d) {
    _holdMoved = false;
    // Light tick the moment the long press arms, before any movement.
    widget.onArm();
  }

  /// After a long press on the blank board, a horizontal slide switches the
  /// launch sub-tab (left = next, right = previous). A plain quick swipe is
  /// untouched: it is claimed by the board's own page pager.
  void _onHoldMove(LongPressMoveUpdateDetails d) {
    if (_holdMoved) return;
    final dx = d.offsetFromOrigin.dx;
    if (dx <= -_holdThreshold) {
      _holdMoved = true;
      widget.onSwitchTab(1);
    } else if (dx >= _holdThreshold) {
      _holdMoved = true;
      widget.onSwitchTab(-1);
    }
  }

  void _onHoldEnd(LongPressEndDetails d) => _holdMoved = false;

  /// Wraps the board with the blank-area long-press gesture. Left alone while
  /// editing tiles, where a long press is used to drag a tile instead.
  Widget _withHoldToSwitch(Widget child) {
    if (widget.state.tileEditMode) return child;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onLongPressStart: _onHoldStart,
      onLongPressMoveUpdate: _onHoldMove,
      onLongPressEnd: _onHoldEnd,
      onLongPressCancel: () => _holdMoved = false,
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final pages = state.tilePages;
    // Keep the drag-prediction clamp in step when pages are added/removed.
    _haptics.setPageCount(pages.length);
    if (pages.isEmpty) {
      return _withHoldToSwitch(
        _hint(
          context,
          icon: Icons.grid_view_rounded,
          text: context.strings.t('还没有磁贴页'),
        ),
      );
    }
    if (_index >= pages.length) _index = pages.length - 1;

    return Column(
      children: [
        Expanded(
          child: _withHoldToSwitch(
            NotificationListener<ScrollNotification>(
              onNotification: _onPagesScroll,
              child: PageView.builder(
                controller: _controller,
                physics: state.tileEditMode
                    ? const NeverScrollableScrollPhysics()
                    : const PageScrollPhysics(),
                itemCount: pages.length,
                onPageChanged: _setIndex,
                itemBuilder: (context, i) =>
                    _TileBoard(state: state, page: pages[i]),
              ),
            ),
          ),
        ),
        _PageBar(
          state: state,
          currentIndex: _index,
          editing: state.tileEditMode,
          onSelect: (i) {
            // One tick for the tap, regardless of how many pages the animation
            // glides across.
            _haptics.tickNow(_clamp(i));
            _setIndex(i);
            if (_controller.hasClients &&
                (_controller.page?.round() ?? 0) != i) {
              _controller.animateToPage(
                i,
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOut,
              );
            }
          },
          onAdd: () async {
            final page = await _promptAddPage(context, state);
            if (page == null || !mounted) return;
            final idx = state.tilePages.indexWhere((p) => p.id == page.id);
            if (idx < 0) return;
            _haptics.tickNow(idx);
            _setIndex(idx);
            _jumpTo(idx);
          },
          onChanged: _syncToState,
        ),
      ],
    );
  }
}

/// A scrollable 6-column board. Tiles can be freely positioned and sized
/// (1x1 up to 6x6); long-press to drag, tap the corner button for options.
class _TileBoard extends StatefulWidget {
  const _TileBoard({required this.state, required this.page});
  final AppState state;
  final TilePage page;

  @override
  State<_TileBoard> createState() => _TileBoardState();
}

class _TileBoardState extends State<_TileBoard> {
  final GlobalKey _boardKey = GlobalKey();
  static const double _gap = 8;
  static const double _pad = 12;

  // Live resize preview (board-level so tiles re-layout while dragging).
  String? _resizeId;
  int _resizeW = 1;
  int _resizeH = 1;

  // Drag-to-move state with live target-cell highlight. We track the pointer
  // position where the drag *started* and the tile's original top-left so the
  // tile follows the finger by its delta instead of snapping to the pointer
  // (which caused a visible jump on the first frame of the drag).
  String? _dragId;
  int _dragW = 1;
  int _dragH = 1;
  int _dragCol = 0;
  int _dragRow = 0;
  double _cellW = 60;
  int _cols = kTileCols;
  Offset _dragStart = Offset.zero;
  Offset _dragStartLocal = Offset.zero;

  /// Last pointer-down position on a tile, captured by [_Tile]'s Listener.
  Offset _downGlobal = Offset.zero;

  void _startDrag(String tileId, int col, int row) {
    final t = widget.state.tileById(tileId);
    if (t == null) return;
    final unit = _cellW + _gap;
    setState(() {
      _dragId = tileId;
      _dragW = t.w;
      _dragH = t.h;
      _dragCol = col;
      _dragRow = row;
      _dragStart = _downGlobal;
      _dragStartLocal = Offset(_pad + col * unit, _pad + row * unit);
    });
  }

  void _updateDrag(String tileId, Offset globalPosition) {
    if (_dragId != tileId) return;
    final unit = _cellW + _gap;
    final local = _dragStartLocal + (globalPosition - _dragStart);
    final col = ((local.dx - _pad) / unit).round().clamp(0, _cols - _dragW);
    final row = ((local.dy - _pad) / unit).round();
    if (row < 0) return;
    if (col != _dragCol || row != _dragRow) {
      setState(() {
        _dragCol = col;
        _dragRow = row;
      });
    }
  }

  void _endDrag(String tileId) {
    widget.state.moveTile(tileId, _dragCol, _dragRow, cols: _cols);
    setState(() => _dragId = null);
  }

  void _cancelDrag() {
    if (_dragId == null) return;
    setState(() => _dragId = null);
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final page = widget.page;
    final editable = state.tileEditMode;
    final glass = state.tileStyle == TileStyle.glass;
    final scheme = Theme.of(context).colorScheme;
    final pageTiles = state.tilesOnPage(page);
    // In edit mode an empty page still renders the board so the grid shows and
    // apps can be pinned onto it; only browsing falls back to the hint.
    if (pageTiles.isEmpty && !editable) {
      return _hint(
        context,
        icon: Icons.grid_view_rounded,
        text: context.strings.t(
          '「{page}」还没有磁贴\n点击右上角 ✏️ 进入编辑，再点 ➕ 选择要置顶的应用',
          {'page': page.name},
        ),
      );
    }

    final board = LayoutBuilder(
      builder: (context, constraints) {
        // Adapt the column count to the available width so tablets get more
        // (smaller) cells instead of ballooning phone-sized cells. The board is
        // clamped and centered so cells stay bounded on very wide screens.
        final boardWidth = constraints.maxWidth > kTileBoardMaxWidth
            ? kTileBoardMaxWidth
            : constraints.maxWidth;
        final cols = tileColumnsForWidth(boardWidth);
        _cols = cols;
        final cellW = (boardWidth - _pad * 2 - _gap * (cols - 1)) / cols;
        _cellW = cellW;
        // Rotating (or resizing the window) can change the column count; stored
        // positions that no longer fit are auto-packed by the layout, without
        // overwriting them, so rotating back restores the original placement.
        final specs = pageTiles.map((t) {
          final resizing = t.id == _resizeId;
          return TileSpec(
            id: t.id,
            w: resizing ? _resizeW : t.w,
            h: resizing ? _resizeH : t.h,
            col: t.col,
            row: t.row,
          );
        }).toList();
        final layout = resolveTileLayout(specs, cols: cols);
        final rows = layout.rows;
        // While dragging, extend the board so the highlighted target row is
        // always reachable (and the grid keeps drawing behind it).
        var rowsShown = (_dragId != null && _dragRow + _dragH > rows)
            ? _dragRow + _dragH
            : rows;
        // Guarantee a usable canvas/grid on an empty page in edit mode.
        if (editable && rowsShown < 3) rowsShown = 3;
        final boardHeight =
            _pad * 2 +
            rowsShown * cellW +
            (rowsShown > 1 ? (rowsShown - 1) * _gap : 0.0);

        double x(int col) => _pad + col * (cellW + _gap);
        double y(int row) => _pad + row * (cellW + _gap);
        double w(int n) => n * cellW + (n - 1) * _gap;
        double h(int n) => n * cellW + (n - 1) * _gap;

        return SingleChildScrollView(
          child: Center(
            child: SizedBox(
              key: _boardKey,
              height: boardHeight,
              width: boardWidth,
              child: Stack(
                // The child list must keep a stable structure across drag start:
                // inserting/removing children shifts the list, which disposes the
                // active Draggable and cancels the move. So the highlight slot is
                // always present in edit mode and only its content toggles.
                children: [
                  if (editable)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: CustomPaint(
                          painter: _TileGridPainter(
                            cellW: cellW,
                            gap: _gap,
                            pad: _pad,
                            cols: cols,
                            rows: rowsShown,
                            color: Theme.of(context).colorScheme.outline
                                .withValues(alpha: 0.3),
                          ),
                        ),
                      ),
                    ),
                  if (editable && pageTiles.isEmpty)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              context.strings.t(
                                '点右上角 ➕ 选择要置顶的应用\n长按拖动移动，拖右下角缩放',
                              ),
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.grey.shade600),
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (editable)
                    Positioned(
                      left: x(_dragCol),
                      top: y(_dragRow),
                      width: w(_dragW),
                      height: h(_dragH),
                      child: IgnorePointer(
                        child: _dragId == null
                            ? const SizedBox.shrink()
                            : DecoratedBox(
                                decoration: BoxDecoration(
                                  color: (glass
                                          ? scheme.primary
                                          : Colors.white)
                                      .withValues(alpha: 0.18),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: (glass
                                            ? scheme.primary
                                            : Colors.white)
                                        .withValues(alpha: 0.9),
                                    width: 2,
                                  ),
                                ),
                              ),
                      ),
                    ),
                  for (final t in pageTiles)
                    Builder(
                      builder: (context) {
                        final app = state.appByPackage(t.packageName);
                        if (app == null) return const SizedBox.shrink();
                        final p = layout.placements[t.id]!;
                        return Positioned(
                          left: x(p.col),
                          top: y(p.row),
                          width: w(p.w),
                          height: h(p.h),
                          child: _Tile(
                            key: ValueKey(t.id),
                            tile: t,
                            app: app,
                            state: state,
                            cellW: cellW,
                            gap: _gap,
                            editable: editable,
                            onPointerDown: (pos) => _downGlobal = pos,
                            onDragStart: () => _startDrag(t.id, p.col, p.row),
                            onDragUpdate: (pos) => _updateDrag(t.id, pos),
                            onDragEnd: () => _endDrag(t.id),
                            onDragCancel: _cancelDrag,
                          ),
                        );
                      },
                    ),
                  if (editable)
                    for (final t in pageTiles)
                      Builder(
                        builder: (context) {
                          final p = layout.placements[t.id]!;
                          final tileW = w(p.w);
                          final tileH = h(p.h);
                          // Keep the grip a corner-only target: shrink it on small
                          // tiles so it never covers most of a 1x1 tile (which made
                          // moving small tiles fight with resizing). The dragged
                          // tile's grip is swapped for an empty box (not removed) so
                          // the child list stays structurally stable.
                          final shortest = tileW < tileH ? tileW : tileH;
                          final handle = (shortest * 0.5).clamp(
                            28.0,
                            _kHandleSize,
                          );
                          return Positioned(
                            left: x(p.col) + tileW - handle,
                            top: y(p.row) + tileH - handle,
                            width: handle,
                            height: handle,
                            child: _dragId == t.id
                                ? const SizedBox.shrink()
                                : _ResizeHandle(
                                    state: state,
                                    tileId: t.id,
                                    cellW: cellW,
                                    gap: _gap,
                                    gripSize: handle * 0.55,
                                    onPreview: (pw, ph) => setState(() {
                                      _resizeId = t.id;
                                      _resizeW = pw;
                                      _resizeH = ph;
                                    }),
                                    onEnd: () {
                                      state.setTileSize(
                                        t.id,
                                        _resizeW,
                                        _resizeH,
                                        cols: cols,
                                      );
                                      setState(() => _resizeId = null);
                                    },
                                  ),
                          );
                        },
                      ),
                ],
              ),
            ),
          ),
        );
      },
    );

    // Cache the whole board as one layer so horizontal tab swipes only move it
    // instead of re-rasterizing every tile + shadow each frame.
    return RepaintBoundary(child: board);
  }
}

const double _kHandleSize = 40;

/// A bottom-right grip that resizes a tile directly on the board.
///
/// Uses an immediate drag recognizer so the enclosing scroll view never steals
/// the gesture (which made vertical resizing scroll the board instead).
class _ResizeHandle extends StatefulWidget {
  const _ResizeHandle({
    required this.state,
    required this.tileId,
    required this.cellW,
    required this.gap,
    required this.gripSize,
    required this.onPreview,
    required this.onEnd,
  });

  final AppState state;
  final String tileId;
  final double cellW;
  final double gap;
  final double gripSize;
  final void Function(int w, int h) onPreview;
  final VoidCallback onEnd;

  @override
  State<_ResizeHandle> createState() => _ResizeHandleState();
}

class _ResizeHandleState extends State<_ResizeHandle> {
  double _startW = 1;
  double _startH = 1;
  double _accX = 0;
  double _accY = 0;
  int _w = 1;
  int _h = 1;
  bool _active = false;

  void _start(Offset _) {
    final t = widget.state.tileById(widget.tileId);
    if (t == null) return;
    _startW = t.w.toDouble();
    _startH = t.h.toDouble();
    _w = t.w;
    _h = t.h;
    _accX = 0;
    _accY = 0;
    setState(() => _active = true);
  }

  void _update(Offset delta) {
    final unit = widget.cellW + widget.gap;
    _accX += delta.dx;
    _accY += delta.dy;
    final gw = (_startW + _accX / unit).round().clamp(1, kTileCols);
    final gh = (_startH + _accY / unit).round().clamp(1, kTileMaxH);
    if (gw != _w || gh != _h) {
      setState(() {
        _w = gw;
        _h = gh;
      });
      widget.onPreview(gw, gh);
    }
  }

  void _end() {
    if (!_active) return;
    setState(() => _active = false);
    widget.onEnd();
  }

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: <Type, GestureRecognizerFactory>{
        ImmediateMultiDragGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<
              ImmediateMultiDragGestureRecognizer
            >(() => ImmediateMultiDragGestureRecognizer(), (instance) {
              instance.onStart = (position) {
                _start(position);
                return _ResizeDrag(onUpdate: _update, onEnd: _end);
              };
            }),
      },
      child: Align(
        alignment: Alignment.bottomRight,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: SizedBox(
            width: widget.gripSize,
            height: widget.gripSize,
            child: CustomPaint(painter: _CornerGripPainter(active: _active)),
          ),
        ),
      ),
    );
  }
}

class _ResizeDrag extends Drag {
  _ResizeDrag({required this.onUpdate, required this.onEnd});

  final void Function(Offset delta) onUpdate;
  final VoidCallback onEnd;

  @override
  void update(DragUpdateDetails details) => onUpdate(details.delta);

  @override
  void end(DragEndDetails details) => onEnd();

  @override
  void cancel() => onEnd();
}

/// Draws the 6-column cell grid while editing, so tiles can be placed against
/// visible cells. Purely decorative (behind the tiles, ignores pointers).
class _TileGridPainter extends CustomPainter {
  _TileGridPainter({
    required this.cellW,
    required this.gap,
    required this.pad,
    required this.cols,
    required this.rows,
    required this.color,
  });

  final double cellW;
  final double gap;
  final double pad;
  final int cols;
  final int rows;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final unit = cellW + gap;
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        final rect = RRect.fromRectAndRadius(
          Rect.fromLTWH(pad + c * unit, pad + r * unit, cellW, cellW),
          const Radius.circular(8),
        );
        canvas.drawRRect(rect, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _TileGridPainter old) =>
      old.cellW != cellW ||
      old.gap != gap ||
      old.pad != pad ||
      old.cols != cols ||
      old.rows != rows ||
      old.color != color;
}

/// Draws a small rounded corner border in the bottom-right corner.
class _CornerGripPainter extends CustomPainter {
  _CornerGripPainter({required this.active});

  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    const inset = 2.0;
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: active ? 1.0 : 0.7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = active ? 3.5 : 3.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final r = size.width * 0.38;
    final path = Path()
      ..moveTo(inset, size.height - inset)
      ..lineTo(size.width - r, size.height - inset)
      ..quadraticBezierTo(
        size.width - inset,
        size.height - inset,
        size.width - inset,
        size.height - r,
      )
      ..lineTo(size.width - inset, inset);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _CornerGripPainter oldDelegate) =>
      oldDelegate.active != active;
}

/// Bottom page switcher (put at the very bottom, like a tab bar).
///
/// Normal mode: compact chips showing only the page name.
/// Edit mode: larger chips with the tile count, and the "new page" button.
class _PageBar extends StatelessWidget {
  const _PageBar({
    required this.state,
    required this.currentIndex,
    required this.editing,
    required this.onSelect,
    required this.onChanged,
    required this.onAdd,
  });

  final AppState state;
  final int currentIndex;
  final bool editing;
  final ValueChanged<int> onSelect;
  final VoidCallback onChanged;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pages = state.tilePages;
    if (pages.isEmpty) return const SizedBox.shrink();

    final chips = ListView.builder(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      itemCount: pages.length,
      itemBuilder: (context, i) {
        final page = pages[i];
        final selected = i == currentIndex;
        final count = state.pinCountOnPage(page);
        final fg = selected
            ? scheme.onPrimaryContainer
            : scheme.onSurfaceVariant;
        // A single glyph (one character, or one emoji even if it is a multi-code
        // point sequence such as a ZWJ family or a flag) gets a larger font
        // while the capsule keeps the same height/size.
        final isSingle = !editing && page.name.trim().characters.length == 1;
        final hPad = isSingle ? 8.0 : (editing ? 14.0 : 10.0);
        final baseFont = editing ? 13.0 : 12.0;
        return Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 3,
            vertical: editing ? 8 : 6,
          ),
          child: GestureDetector(
            onTap: () => onSelect(i),
            // Page management (rename / reorder / delete) lives in the
            // dedicated management screen reached from edit mode; outside edit
            // mode a long press does nothing.
            onLongPress: editing
                ? () => _pageMenu(context, state, i, onChanged)
                : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: EdgeInsets.symmetric(horizontal: hPad),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected
                    ? scheme.primaryContainer
                    : scheme.surfaceContainerHighest.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(editing ? 20 : 14),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    page.name,
                    style: TextStyle(
                      fontSize: isSingle ? 18 : baseFont,
                      height: isSingle ? 1.0 : null,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: fg,
                    ),
                  ),
                  if (editing) ...[
                    const SizedBox(width: 5),
                    Text(
                      '$count',
                      style: TextStyle(
                        fontSize: 11,
                        color: fg.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );

    return Container(
      height: editing ? 54 : 42,
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: Colors.grey.withValues(alpha: 0.2)),
        ),
      ),
      child: Row(
        children: [
          // The page bar stays interactive while editing so you can switch,
          // rename, reorder or delete pages without leaving edit mode. The
          // board's swipe gesture is disabled during editing, but tapping a
          // chip still navigates.
          Expanded(child: chips),
          if (editing)
            IconButton(
              tooltip: context.strings.t('新建磁贴页'),
              icon: const Icon(Icons.add),
              onPressed: onAdd,
            ),
        ],
      ),
    );
  }
}

Future<TilePage?> _promptAddPage(BuildContext context, AppState state) async {
  final controller = TextEditingController();
  final s = context.strings;
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(s.t('新建磁贴页')),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: InputDecoration(labelText: s.t('页面名称')),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(s.t('取消')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text.trim()),
          child: Text(s.t('创建')),
        ),
      ],
    ),
  );
  if (name == null) return null;
  return state.addTilePage(name);
}

void _pageMenu(
  BuildContext context,
  AppState state,
  int index,
  VoidCallback onChanged,
) {
  final page = state.tilePages[index];
  final s = context.strings;
  final canLeft = index > 0;
  final canRight = index < state.tilePages.length - 1;
  showModalBottomSheet(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    page.name,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Text(
                  s.t('第 {index} / {total} 页', {
                    'index': index + 1,
                    'total': state.tilePages.length,
                  }),
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.arrow_back),
            title: Text(s.t('左移（手动排序）')),
            enabled: canLeft,
            onTap: canLeft
                ? () async {
                    Navigator.pop(ctx);
                    await state.moveTilePage(index, -1);
                    onChanged();
                  }
                : null,
          ),
          ListTile(
            leading: const Icon(Icons.arrow_forward),
            title: Text(s.t('右移（手动排序）')),
            enabled: canRight,
            onTap: canRight
                ? () async {
                    Navigator.pop(ctx);
                    await state.moveTilePage(index, 1);
                    onChanged();
                  }
                : null,
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.drive_file_rename_outline),
            title: Text(s.t('重命名页面')),
            onTap: () async {
              Navigator.pop(ctx);
              final controller = TextEditingController(text: page.name);
              final name = await showDialog<String>(
                context: context,
                builder: (dctx) => AlertDialog(
                  title: Text(s.t('重命名页面')),
                  content: TextField(controller: controller, autofocus: true),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dctx),
                      child: Text(s.t('取消')),
                    ),
                    FilledButton(
                      onPressed: () =>
                          Navigator.pop(dctx, controller.text.trim()),
                      child: Text(s.t('保存')),
                    ),
                  ],
                ),
              );
              if (name != null && name.isNotEmpty) {
                await state.renameTilePage(page.id, name);
                onChanged();
              }
            },
          ),
          if (state.tilePages.length > 1)
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: Text(s.t('删除页面')),
              subtitle: Text(s.t('页面上的磁贴会移回第一个页面')),
              onTap: () async {
                Navigator.pop(ctx);
                // Deleting a page needs a second confirmation.
                if (await confirmDeleteTilePage(context, state, page)) {
                  await state.deleteTilePage(page.id);
                  onChanged();
                }
              },
            ),
        ],
      ),
    ),
  );
}

class _Tile extends StatelessWidget {
  const _Tile({
    super.key,
    required this.tile,
    required this.app,
    required this.state,
    required this.cellW,
    required this.gap,
    required this.editable,
    required this.onPointerDown,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onDragCancel,
  });

  final Tile tile;
  final AppInfo app;
  final AppState state;
  final double cellW;
  final double gap;
  final bool editable;
  final ValueChanged<Offset> onPointerDown;
  final VoidCallback onDragStart;
  final void Function(Offset globalPosition) onDragUpdate;
  final VoidCallback onDragEnd;
  final VoidCallback onDragCancel;

  @override
  Widget build(BuildContext context) {
    final width = tile.w * cellW + (tile.w - 1) * gap;
    final height = tile.h * cellW + (tile.h - 1) * gap;

    final content = _content(context, editable);

    if (!editable) return content;

    // Observe the raw pointer-down so the move follows the finger by delta from
    // where it actually started (childDragAnchorStrategy keeps the feedback
    // aligned to the tile, so there is no snap/jump on the first frame).
    return Listener(
      onPointerDown: (e) => onPointerDown(e.position),
      child: LongPressDraggable<String>(
        data: tile.id,
        delay: const Duration(milliseconds: 180),
        dragAnchorStrategy: childDragAnchorStrategy,
        feedback: _feedback(width, height, content),
        childWhenDragging: Opacity(opacity: 0.3, child: content),
        onDragStarted: () {
          HapticFeedback.selectionClick();
          onDragStart();
        },
        onDragUpdate: (d) => onDragUpdate(d.globalPosition),
        onDragEnd: (d) => onDragEnd(),
        onDraggableCanceled: (v, o) => onDragCancel(),
        child: content,
      ),
    );
  }

  Widget _content(BuildContext context, bool editable) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final glass = state.tileStyle == TileStyle.glass;
    final color = _tileColor(app.appName);
    final radius = BorderRadius.circular(glass ? 14 : 10);
    // Frameless mode is its own per-tile switch, independent of the label and
    // inner-margin options.
    final frameless = !tile.border;

    final ink = InkWell(
      // Outside edit mode a tap launches the app and a long press does nothing
      // (the tile options live in the edit-mode menu); in edit mode a tap opens
      // the tile menu and a long press drags the tile.
      onTap: editable
          ? () => _showTileMenu(context)
          : () => launchApp(context, app.packageName),
      // Consume the long press so the blank-area long-press gesture (switching
      // the launch sub-tab) stays limited to the empty board, not the tiles.
      onLongPress: editable ? null : () {},
      child: _inner(context, glass: glass, frameless: frameless),
    );

    // No backdrop: show only the content. App icons carry their own rounded/
    // transparent corners, so a colored backdrop with a different corner radius
    // could poke out behind them; without a backdrop the icon's own shape
    // defines the tile and the look stays clean.
    if (frameless) {
      final bare = Material(
        key: const ValueKey('bare-tile'),
        type: MaterialType.transparency,
        child: ink,
      );
      return editable ? _editFrame(bare, radius, scheme.primary) : bare;
    }

    if (!glass) {
      final tappable = Material(
        color: color,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: ink,
      );
      return editable ? _editFrame(tappable, radius, Colors.white) : tappable;
    }

    // 通透: cheap translucency. Deliberately no BackdropFilter (a blur per
    // tile makes tab swipes janky) and no board-wide backdrop either — that
    // would slide with the tab and make the background visibly brighten/
    // darken while swiping. The glass look is fully self-contained per tile.
    final dark = theme.brightness == Brightness.dark;
    final tappable = DecoratedBox(
      key: const ValueKey('glass-tile'),
      decoration: BoxDecoration(
        borderRadius: radius,
        gradient: _glassGradient(theme, color),
        border: Border.all(
          color: scheme.onSurface.withValues(alpha: dark ? 0.14 : 0.08),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.28 : 0.08),
            blurRadius: 14,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Material(type: MaterialType.transparency, child: ink),
    );
    return editable ? _editFrame(tappable, radius, scheme.primary) : tappable;
  }

  /// Wraps a tile with the edit-mode outline used to show it can be moved.
  Widget _editFrame(Widget child, BorderRadius radius, Color border) {
    return Stack(
      children: [
        Positioned.fill(child: child),
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: radius,
                border: Border.all(
                  color: border.withValues(alpha: 0.85),
                  width: 1.5,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Translucent gradient for the frosted (通透) tile fill. A soft highlight
  /// of the app color in the top-left fades into a mostly neutral, translucent
  /// surface — a clean glass card rather than a muddy wash. Self-contained so
  /// nothing behind the tile has to move for the effect to read.
  LinearGradient _glassGradient(ThemeData theme, Color tint) {
    final dark = theme.brightness == Brightness.dark;
    final surface = theme.colorScheme.surface;
    Color fill(double tintA, double surfA) => Color.alphaBlend(
          tint.withValues(alpha: tintA),
          surface.withValues(alpha: surfA),
        );
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        fill(dark ? 0.34 : 0.30, dark ? 0.48 : 0.62),
        fill(dark ? 0.10 : 0.08, dark ? 0.40 : 0.60),
        fill(dark ? 0.05 : 0.03, dark ? 0.32 : 0.50),
      ],
      stops: const [0.0, 0.5, 1.0],
    );
  }

  Widget _inner(
    BuildContext context, {
    required bool glass,
    required bool frameless,
  }) {
    final scheme = Theme.of(context).colorScheme;
    // Without a backdrop the label sits on the page background, so use the
    // theme's on-surface color instead of the solid style's white.
    final labelColor =
        (glass || frameless) ? scheme.onSurface : Colors.white;
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final shortest = w < h ? w : h;
        // Per-tile inner margin; dropping it lets the content (a big icon when
        // the label is hidden too) fill the whole tile.
        final pad = tile.innerPadding
            ? (shortest * 0.07).clamp(3.0, 18.0).toDouble()
            : 0.0;
        // Tiles shorter than the label height never fit text; the per-tile
        // flag additionally lets any tile be icon-only.
        final showLabel = tile.showLabel && h > 46;
        // Multi-cell tiles get a slightly smaller icon so it does not look
        // oversized; 1xN tiles keep filling the space.
        final iconScale = (tile.w >= 2 && tile.h >= 2) ? 0.8 : 1.0;

        if (!showLabel) {
          return Padding(
            padding: EdgeInsets.all(pad),
            child: Center(
              child: AppIcon(
                packageName: app.packageName,
                label: app.appName,
                size: (shortest - pad * 2)
                    .clamp(8.0, double.infinity)
                    .toDouble(),
              ),
            ),
          );
        }

        final maxLines = h >= 120 ? 2 : 1;
        final fontSize = (shortest * 0.15).clamp(10.0, 16.0).toDouble();
        return Padding(
          padding: EdgeInsets.all(pad),
          child: Column(
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, inner) {
                    var side = inner.maxWidth < inner.maxHeight
                        ? inner.maxWidth
                        : inner.maxHeight;
                    side *= iconScale;
                    return Center(
                      child: AppIcon(
                        packageName: app.packageName,
                        label: app.appName,
                        size: side.clamp(8.0, double.infinity).toDouble(),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 2),
              Text(
                app.appName,
                maxLines: maxLines,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: labelColor,
                  fontSize: fontSize,
                  fontWeight: FontWeight.w600,
                  height: 1.1,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _feedback(double width, double height, Widget child) {
    return SizedBox(
      width: width,
      height: height,
      child: Transform.scale(
        scale: 1.04,
        child: Material(
          color: Colors.transparent,
          elevation: 8,
          borderRadius: BorderRadius.circular(10),
          child: Opacity(opacity: 0.92, child: child),
        ),
      ),
    );
  }

  void _showTileMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          // Rebuild the sheet when the tile is toggled so the switch reflects
          // the new value without closing the sheet.
          child: ListenableBuilder(
            listenable: state,
            builder: (ctx, _) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.label_outline),
                  title: Text(context.strings.t('显示应用名称')),
                  subtitle: Text(context.strings.t('关闭后磁贴只显示图标')),
                  value: state.tileById(tile.id)?.showLabel ?? true,
                  onChanged: (v) => state.setTileShowLabel(tile.id, v),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.crop_free),
                  title: Text(context.strings.t('内边距')),
                  subtitle: Text(context.strings.t('关闭后内容填满磁贴')),
                  value: state.tileById(tile.id)?.innerPadding ?? true,
                  onChanged: (v) => state.setTileInnerPadding(tile.id, v),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.border_clear),
                  title: Text(context.strings.t('显示边框')),
                  subtitle: Text(context.strings.t('关闭后只显示图标/文字，无底板')),
                  value: state.tileById(tile.id)?.border ?? true,
                  onChanged: (v) => state.setTileBorder(tile.id, v),
                ),
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: Text(context.strings.t('应用详情')),
                  onTap: () {
                    Navigator.pop(ctx);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => AppDetailScreen(
                          packageName: app.packageName,
                          fromTileBoard: true,
                        ),
                      ),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.push_pin_outlined),
                  title: Text(context.strings.t('移除该磁贴')),
                  onTap: () async {
                    Navigator.pop(ctx);
                    // Removing a tile needs a second confirmation.
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (dctx) => AlertDialog(
                        title: Text(context.strings.t('移除该磁贴')),
                        content: Text(
                          context.strings.t('确定移除这个磁贴吗？'),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(dctx, false),
                            child: Text(context.strings.t('取消')),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(dctx, true),
                            child: Text(context.strings.t('移除')),
                          ),
                        ],
                      ),
                    );
                    if (ok == true) state.removeTile(tile.id);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Color _tileColor(String label) {
    final hash = label.codeUnits.fold<int>(0, (p, c) => p * 31 + c);
    final hue = (hash % 360).abs().toDouble();
    return HSLColor.fromAHSL(1, hue, 0.5, 0.42).toColor();
  }
}

// ---------------------------------------------------------------- 收藏

/// Searchable sheet used to add/remove favorites (like the pin sheet).
void showFavoriteSheet(BuildContext context, AppState state) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => _FavoriteSheet(state: state),
  );
}

class _FavoriteSheet extends StatefulWidget {
  const _FavoriteSheet({required this.state});

  final AppState state;

  @override
  State<_FavoriteSheet> createState() => _FavoriteSheetState();
}

class _FavoriteSheetState extends State<_FavoriteSheet> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final apps = AppSearch.rank(state.apps, _query, limit: 150);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      builder: (ctx, scrollController) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                ctx.strings.t('添加收藏'),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: SearchField(
              controller: _search,
              hintText: ctx.strings.t('搜索应用'),
              autofocus: true,
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: scrollController,
              itemCount: apps.length,
              itemBuilder: (context, i) {
                final app = apps[i];
                final fav = state.metaFor(app.packageName).favorite;
                return ListTile(
                  leading: AppIcon(
                    packageName: app.packageName,
                    label: app.appName,
                  ),
                  title: Text(app.appName),
                  subtitle: Text(
                    app.packageName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Icon(
                    fav ? Icons.star_rounded : Icons.star_border_rounded,
                    color: fav ? Colors.orange : Colors.grey,
                  ),
                  onTap: () {
                    state.updateMeta(app.packageName, favorite: !fav);
                    setState(() {});
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _FavoritesTab extends StatelessWidget {
  const _FavoritesTab({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final favorites = state.favorites;
    if (favorites.isEmpty) {
      return _hint(
        context,
        icon: Icons.star_outline,
        text: context.strings.t('还没有收藏的应用\n点击右上角 ➕ 添加，即可在这里一键启动'),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 110,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.82,
      ),
      itemCount: favorites.length,
      itemBuilder: (context, i) {
        final app = favorites[i];
        return InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => launchApp(context, app.packageName),
          onLongPress: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => AppDetailScreen(packageName: app.packageName),
            ),
          ),
          child: Column(
            children: [
              AppIcon(
                packageName: app.packageName,
                label: app.appName,
                size: 56,
              ),
              const SizedBox(height: 8),
              Text(
                app.appName,
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------- 最近

class _RecentTab extends StatelessWidget {
  const _RecentTab({
    required this.state,
    required this.sort,
    required this.sinceMillis,
  });
  final AppState state;
  final RecentSort sort;
  final int sinceMillis;

  @override
  Widget build(BuildContext context) {
    final apps = state.recentAppsBy(sort, sinceMillis: sinceMillis);
    final recs = state.recommendedApps();

    if (apps.isEmpty && recs.isEmpty) {
      return _hint(
        context,
        icon: Icons.history,
        text: sinceMillis > 0
            ? context.strings.t('该时间段内没有启动记录\n可在右上角调整时间段')
            : context.strings.t('还没有启动记录\n从囤囤里启动应用后会出现在这里'),
      );
    }

    return CustomScrollView(
      slivers: [
        if (recs.isNotEmpty)
          SliverToBoxAdapter(
            child: _RecommendationSection(state: state, items: recs),
          ),
        if (apps.isNotEmpty) ...[
          SliverToBoxAdapter(child: _SectionLabel(text: context.strings.t('最近'))),
          SliverList.builder(
            itemCount: apps.length,
            itemBuilder: (context, i) => _recentTile(context, apps[i]),
          ),
        ] else
          SliverFillRemaining(
            hasScrollBody: false,
            child: _hint(
              context,
              icon: Icons.history,
              text: sinceMillis > 0
                  ? context.strings.t('该时间段内没有启动记录\n可在右上角调整时间段')
                  : context.strings.t('还没有启动记录\n从囤囤里启动应用后会出现在这里'),
            ),
          ),
      ],
    );
  }

  Widget _recentTile(BuildContext context, AppInfo app) {
    final meta = state.metaFor(app.packageName);
    return ListTile(
      leading: AppIcon(packageName: app.packageName, label: app.appName),
      title: Text(app.appName),
      subtitle: Text(
        context.strings.t('启动 {count} 次 · 上次 {ago}', {
          'count': meta.launchCount,
          'ago': Fmt.relative(meta.lastLaunchedAt),
        }),
      ),
      trailing: const Icon(Icons.rocket_launch_outlined, size: 20),
      onTap: () => launchApp(context, app.packageName),
      onLongPress: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => AppDetailScreen(packageName: app.packageName),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

class _RecommendationSection extends StatelessWidget {
  const _RecommendationSection({required this.state, required this.items});
  final AppState state;
  final List<Recommendation> items;

  static const int _maxItems = 8;

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final scheme = Theme.of(context).colorScheme;
    final shown =
        items.length > _maxItems ? items.sublist(0, _maxItems) : items;
    // Fill the border evenly: one equal-width column per item, capping at four
    // per row so up to eight items form a balanced two-row grid.
    final columns = shown.length < 4 ? shown.length : 4;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome, size: 15, color: scheme.primary),
              const SizedBox(width: 6),
              Text(
                s.t('推荐'),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: scheme.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.6),
              ),
            ),
            child: GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: EdgeInsets.zero,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                crossAxisSpacing: 4,
                mainAxisSpacing: 8,
                mainAxisExtent: 76,
              ),
              itemCount: shown.length,
              itemBuilder: (context, i) =>
                  _RecommendationItem(state: state, rec: shown[i]),
            ),
          ),
        ],
      ),
    );
  }
}

class _RecommendationItem extends StatelessWidget {
  const _RecommendationItem({required this.state, required this.rec});
  final AppState state;
  final Recommendation rec;

  @override
  Widget build(BuildContext context) {
    final name =
        state.appByPackage(rec.packageName)?.appName ?? rec.packageName;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => launchApp(context, rec.packageName),
      onLongPress: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => AppDetailScreen(packageName: rec.packageName),
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AppIcon(packageName: rec.packageName, label: name, size: 44),
          const SizedBox(height: 6),
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }
}

Widget _hint(
  BuildContext context, {
  required IconData icon,
  required String text,
}) {
  return Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 64, color: Colors.grey),
          const SizedBox(height: 12),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey.shade600),
          ),
        ],
      ),
    ),
  );
}
