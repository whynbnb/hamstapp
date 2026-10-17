import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/app_strings.dart';
import '../models/app_info.dart';
import '../models/tile.dart';
import '../models/tile_page.dart';
import '../services/device_status.dart';
import '../services/native_apps.dart';
import '../services/notification_badges.dart';
import '../state/app_state.dart';
import '../utils/actions.dart';
import '../utils/format.dart';
import '../utils/pager_haptics.dart';
import '../utils/recommender.dart';
import '../utils/search.dart';
import '../utils/tile_layout.dart';
import '../widgets/app_icon.dart';
import '../widgets/category_editor.dart';
import '../widgets/collapsed_nav.dart';
import '../widgets/info_tile.dart';
import '../widgets/info_tile_sheets.dart';
import '../widgets/search_field.dart';
import 'app_detail_screen.dart';
import 'global_search_screen.dart';
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
  late final PageController _tabPager;
  int _lastTab = 0;

  /// Accumulated horizontal travel of a body-wide swipe used in the split
  /// swipe modes (the launch pager itself no longer scrolls natively there).
  double _bodySwipeDx = 0;

  /// The four launch sections (磁贴/分类/收藏/最近). The pager loops, so pages
  /// are addressed by a large "virtual" index reduced modulo [_tabCount].
  static const int _tabCount = 4;
  static const int _tabBase = 4000; // a multiple of _tabCount, well above zero

  int _tabVirtual(int logical) => _tabBase + logical;

  /// Coalesces sub-tab haptics so one swipe or tap ticks exactly once, however
  /// many tabs the gesture glides across.
  late final PagerHaptics _haptics;

  RecentSort _recentSort = RecentSort.recent;
  int _recentSince = 0;

  @override
  void initState() {
    super.initState();
    final start = context.read<AppState>().lastLaunchTab.clamp(
      0,
      _tabCount - 1,
    );
    _lastTab = start;
    _haptics =
        PagerHaptics(
            () => context.read<AppState>().haptic(HapticTrigger.launchTabs),
          )
          ..align(start)
          ..setPageCount(_tabCount)
          ..setPageMapper((raw) => ((raw % _tabCount) + _tabCount) % _tabCount);
    _tabs = TabController(length: _tabCount, vsync: this, initialIndex: start)
      ..addListener(_onTabChanged);
    _tabPager = PageController(initialPage: _tabVirtual(start));
  }

  void _onTabChanged() {
    final i = _tabs.index;
    if (i == _lastTab) return;
    _lastTab = i;
    context.read<AppState>().setLastLaunchTab(i);
    // Tapping a tab updates the index immediately; a swipe settles here after
    // the drag already ticked, in which case this is a no-op.
    _haptics.indexChanged(i);
    // Tapping the bar moves the index but not the pager, so drive the pager to
    // follow. When the pager itself changed the index it is already aligned and
    // this is skipped.
    if (_tabPager.hasClients && _tabPagerLogical != i) _animateLaunchPager(i);
    setState(() {});
  }

  int get _tabPagerLogical {
    final page = (_tabPager.page ?? _tabVirtual(_lastTab)).round();
    return ((page % _tabCount) + _tabCount) % _tabCount;
  }

  /// A body-wide horizontal swipe that switches the launch sub-tab.
  ///
  /// Only used in the split swipe modes, where the launch pager is switched
  /// programmatically instead of scrolled natively: a native fling kept
  /// grabbing the next swipe for a moment after landing, which made both halves
  /// keep changing the launch sub-tab instead of the tile pages. On the 磁贴
  /// board the deeper per-half gesture takes over, so this only fires on the
  /// other sub-tabs (分類 / 收藏 / 最近).
  Widget _splitSwipeLayer({required bool enabled, required Widget child}) {
    if (!enabled) return child;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: (_) => _bodySwipeDx = 0,
      onHorizontalDragUpdate: (d) => _bodySwipeDx += d.delta.dx,
      onHorizontalDragEnd: (d) {
        final velocity = d.primaryVelocity ?? 0;
        final dx = _bodySwipeDx.abs() >= 24 ? _bodySwipeDx : velocity * 0.08;
        if (dx.abs() < 8) return;
        _switchLaunchTab(dx < 0 ? 1 : -1); // swipe left -> next
      },
      child: child,
    );
  }

  /// Move the launch pager from [currentLogical] to [logical] following the tab
  /// order, exactly the way the TabBar indicator travels.
  ///
  /// The pager moves linearly in index (never wrapping the loop), so 磁贴 →
  /// 最近 glides forward through 分类 and 收藏 while 最近 → 分类 slides back
  /// through 收藏. Wrapping the other way made the content and the indicator
  /// move in opposite directions, which looked like a long detour.
  void _animateLaunchPager(int logical) {
    final current = (_tabPager.page ?? _tabVirtual(logical)).round();
    final currentLogical = ((current % _tabCount) + _tabCount) % _tabCount;
    final diff = logical - currentLogical; // -(_tabCount-1) .. _tabCount-1
    if (diff == 0) return;
    final steps = diff.abs();
    _tabPager.animateToPage(
      current + diff,
      duration: Duration(milliseconds: 240 + 110 * (steps - 1)),
      curve: Curves.easeOut,
    );
  }

  /// The launch pager landed on virtual page [virtual] (swipe or animation).
  void _onLaunchPageChanged(int virtual) {
    final logical = ((virtual % _tabCount) + _tabCount) % _tabCount;
    if (_tabs.index != logical) _tabs.index = logical;
  }

  /// Switch the launch sub-tab by [delta] (+1 = next, -1 = previous).
  ///
  /// Used by the long-press-and-drag gesture on the tile board's blank area:
  /// a normal horizontal swipe there is consumed by the board's own page pager,
  /// so this is the only way to reach e.g. 分类 without touching the tab bar.
  /// Loops around: previous on 磁贴 lands on 最近 and next on 最近 lands on 磁贴.
  void _switchLaunchTab(int delta) {
    final target = (_tabs.index + delta + _tabCount) % _tabCount;
    if (target == _tabs.index) return;
    // Use the standard sub-tab tick so the gesture feels the same as tapping or
    // swiping between 磁贴/分类/收藏/最近.
    _haptics.tickNow(target);
    _tabs.index = target; // _onTabChanged animates the pager to follow
  }

  /// Boils a sub-tab swipe down to at most one tick, fired the moment the
  /// gesture commits to a different tab (crossing the midpoint) rather than
  /// waiting for the snap animation to finish.
  bool _onTabsScroll(ScrollNotification n) {
    // depth 0 = this pager's own scroll; deeper notifications come from scroll
    // views inside a tab (e.g. the tile board) and must be ignored.
    if (n.depth != 0 || n.metrics.axis != Axis.horizontal) return false;
    _haptics.handleScroll(n);
    return false;
  }

  @override
  void dispose() {
    _tabs.dispose();
    _tabPager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    // 磁贴 is the second tab (最近 sits to its left).
    final editing = state.tileEditMode && _tabs.index == 1;
    final split = state.tileSwipeMode != TileSwipeMode.holdDrag;

    // A sub-tab asked for from outside (a launcher shortcut) is applied after
    // this frame, once the tab controller and pager are laid out.
    if (state.pendingLaunchTab != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final target = context.read<AppState>().consumePendingLaunchTab();
        if (target == null) return;
        final clamped = target.clamp(0, _tabCount - 1);
        if (_tabs.index != clamped) {
          _tabs.animateTo(clamped);
        } else {
          _animateLaunchPager(clamped);
        }
      });
    }

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
        Tab(height: 40, text: context.strings.t('最近')),
        Tab(height: 40, text: context.strings.t('磁贴')),
        Tab(height: 40, text: context.strings.t('分类')),
        Tab(height: 40, text: context.strings.t('收藏')),
      ],
    );

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        leading: CollapsedNavScope.activeOf(context)
            ? const CollapsedNavButton()
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
      body: _splitSwipeLayer(
        enabled: split && !editing,
        child: NotificationListener<ScrollNotification>(
          onNotification: _onTabsScroll,
          child: PageView.builder(
            controller: _tabPager,
            physics: editing || split
                ? const NeverScrollableScrollPhysics()
                : const PageScrollPhysics(),
            itemCount: null,
            onPageChanged: _onLaunchPageChanged,
            itemBuilder: (context, virtual) {
              switch (((virtual % _tabCount) + _tabCount) % _tabCount) {
                case 0:
                  return _RecentTab(
                    state: state,
                    sort: _recentSort,
                    sinceMillis: _recentSince,
                  );
                case 1:
                  return _TilesTab(
                    state: state,
                    onSwitchTab: _switchLaunchTab,
                    onArm: () => context.read<AppState>().hapticLight(),
                  );
                case 2:
                  return CategoriesTab(state: state);
                default:
                  return _FavoritesTab(state: state);
              }
            },
          ),
        ),
      ),
    );
  }

  /// Exactly one action in normal mode per section, so the header tabs keep a
  /// constant width (the tile "+" only appears while editing).
  List<Widget> _actions(BuildContext context, AppState state, bool editing) {
    final s = context.strings;
    if (_tabs.index == 1 && editing) {
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
        IconButton(
          tooltip: s.t('锁定布局'),
          icon: const Icon(Icons.lock_outline),
          onPressed: () async {
            await state.setLayoutLocked(true);
          },
        ),
        TextButton.icon(
          onPressed: () => state.setTileEditMode(false),
          icon: const Icon(Icons.check, size: 18),
          label: Text(s.t('完成')),
        ),
        const SizedBox(width: 4),
      ];
    }
    final search = IconButton(
      tooltip: s.t('全局搜索'),
      icon: const Icon(Icons.search),
      onPressed: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const GlobalSearchScreen()),
      ),
    );
    switch (_tabs.index) {
      case 0: // 最近
        return [
          search,
          IconButton(
            tooltip: s.t('排序 / 时间筛选'),
            icon: const Icon(Icons.tune),
            onPressed: () => _showRecentFilterSheet(context),
          ),
        ];
      case 1: // 磁贴
        return [
          search,
          IconButton(
            tooltip: s.t('编辑磁贴（添加/拖动/缩放）'),
            icon: const Icon(Icons.edit_outlined),
            onPressed: () {
              if (state.layoutLocked) {
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(
                    SnackBar(content: Text(s.t('布局已锁定：先在设置里关闭「锁定磁贴布局」再编辑'))),
                  );
                return;
              }
              state.setTileEditMode(true);
              ScaffoldMessenger.of(context)
                ..hideCurrentSnackBar()
                ..showSnackBar(
                  SnackBar(
                    content: Text(
                      s.t('编辑模式：点右上角 ➕ 置顶应用或添加信息磁贴，长按拖动移动，拖右下角缩放；完成后点「完成」'),
                    ),
                    behavior: SnackBarBehavior.floating,
                    duration: const Duration(seconds: 2),
                  ),
                );
            },
          ),
        ];
      case 2: // 分类
        return [
          search,
          IconButton(
            tooltip: s.t('新建分类'),
            icon: const Icon(Icons.add),
            onPressed: () => showCategoryEditor(context, state, null),
          ),
        ];
      default: // 收藏
        return [
          search,
          IconButton(
            tooltip: s.t('添加收藏'),
            icon: const Icon(Icons.add),
            onPressed: () => showFavoriteSheet(context, state),
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
                  subtitle: Text(s.t('根据常用时间段，在「最近」顶部推荐此刻可能想用的应用')),
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
                        content: Text(s.t('将删除全部启动时间记录与启动次数，且无法恢复。确定吗？')),
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

  /// Number of real tile pages and the virtual base for the looping pager:
  /// virtual page = _base + logical, logical = virtual % _n, so the pager can
  /// be swiped in either direction without hitting a hard stop.
  int _n = 0;
  int _base = 0;

  /// Coalesces tile-page haptics so one swipe or tap ticks exactly once,
  /// however many pages the gesture glides across.
  late final PagerHaptics _haptics;

  /// Long-press-and-slide on the board's blank area switches the launch
  /// sub-tab. [_holdMoved] latches so one hold yields at most one switch.
  bool _holdMoved = false;

  /// Multi-select state for the board (edit mode only).
  bool _selectMode = false;
  final Set<String> _selected = <String>{};

  /// Horizontal travel (logical px) after a long press before it switches tab.
  static const double _holdThreshold = 48;

  int _clamp(int i) {
    final n = widget.state.tilePages.length;
    if (n == 0) return 0;
    return i < 0 ? 0 : (i >= n ? n - 1 : i);
  }

  int _virtualOf(int logical) => _base + logical;

  int _logicalOf(int virtual) {
    if (_n <= 0) return 0;
    return ((virtual % _n) + _n) % _n;
  }

  @override
  void initState() {
    super.initState();
    // Rebuild the board on the same page the shared state points at. Without
    // this the freshly created PageController would start at page 0 while the
    // bottom bar highlighted a different page (the two got out of sync when
    // this tab was rebuilt, e.g. after switching the top-level tab).
    _n = widget.state.tilePages.length;
    _base = _n * 1000;
    _index = _clamp(widget.state.currentTilePageIndex);
    widget.state.currentTilePageIndex = _index;
    _haptics = PagerHaptics(() => widget.state.haptic(HapticTrigger.tilePages))
      ..align(_index)
      ..setPageCount(_n <= 0 ? 1 : _n)
      ..setPageMapper(_logicalOf);
    _controller = PageController(initialPage: _virtualOf(_index));
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
    final n = widget.state.tilePages.length;
    final target = _clamp(widget.state.currentTilePageIndex);
    if (n != _n) {
      // Pages were added/removed/reordered elsewhere: re-anchor the virtual
      // base so the modulo mapping stays valid and the same logical page stays
      // on screen, without buzzing.
      _n = n;
      _base = n * 1000;
      _index = target;
      _haptics.setPageCount(n <= 0 ? 1 : n);
      _haptics.align(target);
      _jumpToVirtual(_virtualOf(target));
      return;
    }
    if (target == _index) return;
    _index = target;
    // A structural jump (page deleted/reordered elsewhere) should not buzz;
    // sync the tracker silently before the controller follows.
    _haptics.align(target);
    _jumpToVirtual(_virtualOf(target));
  }

  void _jumpToVirtual(int target) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      if ((_controller.page?.round() ?? 0) != target) {
        _controller.jumpToPage(target);
      }
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

  // ---- gesture layer -------------------------------------------------------

  /// Whether the last split-mode swipe started in the top half of the board.
  bool _splitTop = false;
  double _splitDx = 0;

  /// Wraps the board with the blank-area gesture layer.
  ///
  /// The [GestureDetector] stays in the tree across edit-mode and swipe-mode
  /// changes (only its callbacks are cleared) so the same widget type is kept
  /// here: removing it used to rebuild the inner pager, which snapped the board
  /// back to the page its controller was created on.
  ///
  /// - [TileSwipeMode.holdDrag]: long-press the blank board and slide to switch
  ///   the launch sub-tab.
  /// - [TileSwipeMode.topLaunch] / [TileSwipeMode.bottomLaunch]: a plain swipe
  ///   switches either the launch sub-tab or the tile pages, depending on which
  ///   half of the board it started in.
  Widget _boardGestures(Widget child) {
    final editing = widget.state.tileEditMode;
    final split = widget.state.tileSwipeMode != TileSwipeMode.holdDrag;
    final canHold = !editing && !split;
    final canSplit = !editing && split;
    return LayoutBuilder(
      builder: (context, constraints) {
        final half = constraints.maxHeight / 2;
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onLongPressStart: canHold ? _onHoldStart : null,
          onLongPressMoveUpdate: canHold ? _onHoldMove : null,
          onLongPressEnd: canHold ? _onHoldEnd : null,
          onLongPressCancel: canHold ? () => _holdMoved = false : null,
          onHorizontalDragStart: canSplit
              ? (d) => _onSplitStart(d, half)
              : null,
          onHorizontalDragUpdate: canSplit ? _onSplitUpdate : null,
          onHorizontalDragEnd: canSplit ? _onSplitEnd : null,
          child: child,
        );
      },
    );
  }

  void _onSplitStart(DragStartDetails d, double halfHeight) {
    _splitTop = d.localPosition.dy < halfHeight;
    _splitDx = 0;
  }

  void _onSplitUpdate(DragUpdateDetails d) => _splitDx += d.delta.dx;

  /// Routes a finished swipe to the launch sub-tabs or the tile pages depending
  /// on which half of the board it started in.
  void _onSplitEnd(DragEndDetails d) {
    final velocity = d.primaryVelocity ?? 0;
    final dx = _splitDx.abs() >= 24 ? _splitDx : velocity * 0.08;
    if (dx.abs() < 8) return;
    final delta = dx < 0 ? 1 : -1; // swipe left -> next
    if (_splitTargetsLaunch) {
      widget.onSwitchTab(delta);
    } else {
      _switchTilePage(delta);
    }
  }

  bool get _splitTargetsLaunch {
    final top = _splitTop;
    return widget.state.tileSwipeMode == TileSwipeMode.topLaunch ? top : !top;
  }

  /// Move the tile-page pager by [delta] pages (the pager loops).
  void _switchTilePage(int delta) {
    if (widget.state.tilePages.length <= 1 || !_controller.hasClients) return;
    final current = _controller.page?.round() ?? _virtualOf(_index);
    final target = current + delta;
    _haptics.tickNow(_logicalOf(target));
    _controller.animateToPage(
      target,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOut,
    );
  }

  // ---- multi-select --------------------------------------------------------

  Widget _selectToggle(AppState state) {
    final s = context.strings;
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 3,
      borderRadius: BorderRadius.circular(20),
      color: scheme.surfaceContainerHigh,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => setState(() => _selectMode = true),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.checklist, size: 16),
              const SizedBox(width: 5),
              Text(
                s.t('多选'),
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _selectionBar(AppState state) {
    final s = context.strings;
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(16),
      color: scheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          children: [
            Text(
              s.t('已选 {n}', {'n': _selected.length}),
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            IconButton(
              tooltip: s.t('全选本页'),
              icon: const Icon(Icons.select_all),
              onPressed: _selectAll,
            ),
            IconButton(
              tooltip: s.t('移到页面'),
              icon: const Icon(Icons.drive_file_move_outline),
              onPressed: _selected.isEmpty ? null : () => _moveSelection(state),
            ),
            IconButton(
              tooltip: s.t('删除'),
              icon: const Icon(Icons.delete_outline),
              onPressed: _selected.isEmpty
                  ? null
                  : () => _deleteSelection(state),
            ),
            IconButton(
              tooltip: s.t('退出多选'),
              icon: const Icon(Icons.close),
              onPressed: () => setState(() {
                _selectMode = false;
                _selected.clear();
              }),
            ),
          ],
        ),
      ),
    );
  }

  void _selectAll() {
    final state = widget.state;
    if (state.tilePages.isEmpty) return;
    final page = state.tilePages[_clamp(_index)];
    setState(() {
      _selected
        ..clear()
        ..addAll(state.tilesOnPage(page).map((t) => t.id));
    });
  }

  Future<void> _moveSelection(AppState state) async {
    if (_selected.isEmpty) return;
    final s = context.strings;
    final target = await showDialog<TilePage>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(s.t('移到页面')),
        children: [
          for (final page in state.tilePages)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, page),
              child: Text(page.name),
            ),
        ],
      ),
    );
    if (target == null) return;
    await state.moveTilesToPage(_selected, target.id);
    if (!mounted) return;
    setState(() {
      _selectMode = false;
      _selected.clear();
    });
  }

  Future<void> _deleteSelection(AppState state) async {
    if (_selected.isEmpty) return;
    final s = context.strings;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.t('删除磁贴')),
        content: Text(s.t('删除选中的 {n} 块磁贴？应用本身不会被卸载。', {'n': _selected.length})),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(s.t('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(s.t('删除')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await state.removeTiles(_selected);
    if (!mounted) return;
    setState(() {
      _selectMode = false;
      _selected.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final pages = state.tilePages;
    // Keep the drag-prediction clamp in step when pages are added/removed.
    _haptics.setPageCount(pages.length);
    if (pages.isEmpty) {
      return _boardGestures(
        _hint(
          context,
          icon: Icons.grid_view_rounded,
          text: context.strings.t('还没有磁贴页'),
        ),
      );
    }
    if (_index >= pages.length) _index = pages.length - 1;
    // Leaving edit mode (or locking the layout) also leaves multi-select; the
    // build that does so already renders without the bar.
    if (!state.tileEditMode && _selectMode) {
      _selectMode = false;
      _selected.clear();
    }

    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: _boardGestures(
                  NotificationListener<ScrollNotification>(
                    onNotification: _onPagesScroll,
                    child: PageView.builder(
                      controller: _controller,
                      physics:
                          state.tileEditMode ||
                              state.tileSwipeMode != TileSwipeMode.holdDrag
                          ? const NeverScrollableScrollPhysics()
                          : const PageScrollPhysics(),
                      itemCount: null,
                      onPageChanged: (v) => _setIndex(_logicalOf(v)),
                      itemBuilder: (context, v) => _TileBoard(
                        state: state,
                        page: pages[_logicalOf(v)],
                        selectMode: _selectMode,
                        selectedIds: _selected,
                        onToggleSelect: (id) => setState(() {
                          if (!_selected.remove(id)) _selected.add(id);
                        }),
                      ),
                    ),
                  ),
                ),
              ),
              if (state.tileEditMode && !_selectMode)
                Positioned(top: 6, right: 8, child: _selectToggle(state)),
              if (_selectMode)
                Positioned(
                  left: 8,
                  right: 8,
                  bottom: 8,
                  child: _selectionBar(state),
                ),
            ],
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
            final target = _virtualOf(_clamp(i));
            if (_controller.hasClients &&
                (_controller.page?.round() ?? 0) != target) {
              _controller.animateToPage(
                target,
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
            // The page count grew, so _syncToState re-anchors the virtual base
            // and jumps to the new page on the next build.
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
  const _TileBoard({
    required this.state,
    required this.page,
    this.selectMode = false,
    this.selectedIds = const <String>{},
    this.onToggleSelect,
  });

  final AppState state;
  final TilePage page;

  /// Multi-select mode (edit mode only): taps toggle tiles instead of opening
  /// their menu.
  final bool selectMode;
  final Set<String> selectedIds;
  final ValueChanged<String>? onToggleSelect;

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

  /// The cells currently occupied by each tile, refreshed on every layout.
  /// Used to find what a dragged tile was dropped on.
  Map<String, TilePlacement> _placements = <String, TilePlacement>{};

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

  /// The tile under the dragged cell, if any.
  Tile? _tileAt(int col, int row, {String? ignore}) {
    for (final t in widget.state.tilesOnPage(widget.page)) {
      if (t.id == ignore) continue;
      final p = _placements[t.id];
      if (p == null) continue;
      final overlaps =
          !(col + 1 <= p.col ||
              p.col + p.w <= col ||
              row + 1 <= p.row ||
              p.row + p.h <= row);
      if (overlaps) return t;
    }
    return null;
  }

  void _endDrag(String tileId) {
    final dragged = widget.state.tileById(tileId);
    final target = _tileAt(_dragCol, _dragRow, ignore: tileId);
    setState(() => _dragId = null);
    if (dragged != null &&
        target != null &&
        dragged.kind == TileKind.app &&
        (target.kind == TileKind.app || target.kind == TileKind.folder)) {
      unawaited(_offerFolder(dragged, target));
      return;
    }
    widget.state.moveTile(tileId, _dragCol, _dragRow, cols: _cols);
  }

  /// Dropping one tile on another combines them into a folder (or adds the app
  /// to an existing folder). A category folder cannot take extra apps, so that
  /// case falls back to a plain move.
  Future<void> _offerFolder(Tile dragged, Tile target) async {
    final s = context.strings;
    final draggedName = widget.state.displayNameFor(dragged.packageName);
    final targetName = target.kind == TileKind.folder
        ? s.t('这个文件夹')
        : widget.state.displayNameFor(target.packageName);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          target.kind == TileKind.folder ? s.t('加入文件夹？') : s.t('放进同一个文件夹？'),
        ),
        content: Text(
          target.kind == TileKind.folder
              ? s.t('把「{app}」放进{target}。', {
                  'app': draggedName,
                  'target': targetName,
                })
              : s.t('把「{a}」和「{b}」放进一个文件夹，之后可以像其它磁贴一样移动和缩放。', {
                  'a': draggedName,
                  'b': targetName,
                }),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(s.t('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(s.t('放进文件夹')),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (ok != true) {
      await widget.state.moveTile(dragged.id, _dragCol, _dragRow, cols: _cols);
      return;
    }
    final folder = await widget.state.combineIntoFolder(dragged.id, target.id);
    if (folder == null && mounted) {
      await widget.state.moveTile(dragged.id, _dragCol, _dragRow, cols: _cols);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(s.t('这个文件夹是按分类生成的，不能直接加入应用；可以换成「自选应用」文件夹'))),
        );
    }
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
          '「{page}」还没有磁贴\n点击右上角 ✏️ 进入编辑，再点 ➕ 置顶应用或添加信息磁贴',
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
        _placements = layout.placements;
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
                                  color: (glass ? scheme.primary : Colors.white)
                                      .withValues(alpha: 0.18),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color:
                                        (glass ? scheme.primary : Colors.white)
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
                        final app = t.isInfo
                            ? null
                            : state.appByPackage(t.packageName);
                        // An app tile without its app (uninstalled) is skipped;
                        // info tiles have no app by design.
                        if (app == null && !t.isInfo) {
                          return const SizedBox.shrink();
                        }
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
                            selectMode: widget.selectMode,
                            selected: widget.selectedIds.contains(t.id),
                            onSelect: widget.onToggleSelect == null
                                ? null
                                : () => widget.onToggleSelect!(t.id),
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
/// Unread badge for one tile-page chip: the total unread count of every app on
/// that page, drawn as a number or a dot (or nothing) per the page-bar setting.
class _PageUnreadBadge extends StatelessWidget {
  const _PageUnreadBadge({required this.page, required this.state});

  final TilePage page;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: NotificationBadges.instance,
      builder: (context, _) {
        final badges = NotificationBadges.instance;
        final mode = badges.modeFor(NotificationBadgeSurface.page);
        if (mode == NotificationBadgeMode.none) return const SizedBox.shrink();
        var total = 0;
        for (final t in state.tiles) {
          if (t.pageId != page.id) continue;
          total += badges.countFor(
            t.packageName,
            surface: NotificationBadgeSurface.page,
          );
        }
        if (total <= 0) return const SizedBox.shrink();

        final scheme = Theme.of(context).colorScheme;
        final ring = scheme.surface;
        if (mode == NotificationBadgeMode.dot) {
          return Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: scheme.error,
              shape: BoxShape.circle,
              border: Border.all(color: ring, width: 1.5),
            ),
          );
        }
        return Container(
          height: 15,
          constraints: const BoxConstraints(minWidth: 15),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 3.5),
          decoration: BoxDecoration(
            color: scheme.error,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: ring, width: 1.5),
          ),
          child: Text(
            NotificationBadges.labelFor(total),
            style: TextStyle(
              color: scheme.onError,
              fontSize: 9.5,
              fontWeight: FontWeight.w700,
              height: 1.0,
            ),
          ),
        );
      },
    );
  }
}

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
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                AnimatedContainer(
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
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w500,
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
                // Floats over the chip's top-right corner so it never widens
                // the chip or shifts the row.
                if (!editing)
                  Positioned(
                    top: -5,
                    right: -5,
                    child: _PageUnreadBadge(page: page, state: state),
                  ),
              ],
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
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(s.t('取消'))),
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
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(ctx).size.height * 0.85,
        ),
        child: SingleChildScrollView(
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
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                      ),
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
                leading: const Icon(Icons.copy_all_outlined),
                title: Text(s.t('复制页面')),
                subtitle: Text(s.t('连同这一页的磁贴一起复制到新的一页')),
                onTap: () async {
                  Navigator.pop(ctx);
                  await state.copyTilePage(page.id);
                  onChanged();
                },
              ),
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
                      content: TextField(
                        controller: controller,
                        autofocus: true,
                      ),
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
                  subtitle: Text(s.t('页面上的磁贴也会一并删除')),
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
    this.selectMode = false,
    this.selected = false,
    this.onSelect,
  });

  final Tile tile;

  /// The app behind this tile; null for the live info tiles.
  final AppInfo? app;
  final AppState state;
  final double cellW;
  final double gap;
  final bool editable;
  final ValueChanged<Offset> onPointerDown;
  final VoidCallback onDragStart;
  final void Function(Offset globalPosition) onDragUpdate;
  final VoidCallback onDragEnd;
  final VoidCallback onDragCancel;

  /// Multi-select mode: a tap toggles this tile instead of opening its menu.
  final bool selectMode;
  final bool selected;
  final VoidCallback? onSelect;

  @override
  Widget build(BuildContext context) {
    // A small step back when arranging: the board visibly "picks up" the tiles
    // instead of the outline simply appearing.
    final body = AnimatedScale(
      scale: editable && !selectMode ? 0.97 : 1.0,
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      child: _buildTile(context),
    );
    if (!selectMode) return body;
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(child: body),
        Positioned(
          top: 4,
          right: 4,
          child: Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: selected
                  ? scheme.primary
                  : Colors.black.withValues(alpha: 0.35),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white70, width: 1.5),
            ),
            child: Icon(
              selected ? Icons.check : Icons.add,
              size: 15,
              color: Colors.white,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTile(BuildContext context) {
    final width = tile.w * cellW + (tile.w - 1) * gap;
    final height = tile.h * cellW + (tile.h - 1) * gap;

    final content = _withBadge(
      _content(context, editable),
      width,
      height,
      editable,
    );

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

  /// Draws the unread bubble in the tile's own top-right corner (not the
  /// icon's), scaled to the tile. Hidden while arranging tiles.
  Widget _withBadge(Widget child, double width, double height, bool editable) {
    // Info tiles carry their own numbers (the unread tile *is* the count).
    if (editable || tile.isInfo) return child;
    final packageName = app?.packageName ?? '';
    if (packageName.isEmpty) return child;
    final shortest = width < height ? width : height;
    return ListenableBuilder(
      listenable: NotificationBadges.instance,
      builder: (context, _) {
        final badges = NotificationBadges.instance;
        final count = badges.countFor(
          packageName,
          surface: NotificationBadgeSurface.tile,
        );
        if (count <= 0) return child;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(child: child),
            Positioned(
              top: 2,
              right: 2,
              child: IconNotificationBadge(
                count: count,
                iconSize: shortest,
                mode: badges.modeFor(NotificationBadgeSurface.tile),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _content(BuildContext context, bool editable) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final glass = state.tileStyle == TileStyle.glass;
    final color = tile.isInfo
        ? infoTileColor(
            context,
            tile.kind,
            status: DeviceStatusService.instance.status,
          )
        : _tileColor(app?.appName ?? '');
    final radius = BorderRadius.circular(glass ? 14 : 10);
    // Frameless mode is its own per-tile switch, independent of the label and
    // inner-margin options.
    final frameless = !tile.border;
    final packageName = app?.packageName ?? '';

    final ink = InkWell(
      // Outside edit mode a tap launches the app and a long press opens the
      // app's details (same gesture as the favourites/recent lists); in edit
      // mode a tap opens the tile menu and a long press drags the tile. In
      // multi-select mode a tap only toggles the tile.
      onTap: selectMode
          ? onSelect
          : editable
          ? () => _showTileMenu(context)
          : _browseTap(context, packageName),
      // Handled here rather than left to the board, so the blank-area long
      // press (switching the launch sub-tab) stays limited to the empty board.
      onLongPress: editable || packageName.isEmpty
          ? null
          : () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => AppDetailScreen(
                  packageName: packageName,
                  fromTileBoard: true,
                ),
              ),
            ),
      child: _inner(context, glass: glass, frameless: frameless),
    );

    // Per-tile gestures. Only installed when an action is configured, because
    // a double-tap recognizer makes every single tap wait for its timeout —
    // a tile without the gesture keeps launching instantly.
    final doubleTap = tile.optionString('doubleTap');
    final swipeUp = tile.optionString('swipeUp');
    final surface =
        (editable || selectMode || (doubleTap.isEmpty && swipeUp.isEmpty))
        ? ink
        : GestureDetector(
            onDoubleTap: doubleTap.isEmpty
                ? null
                : () => _runGesture(context, doubleTap),
            onVerticalDragEnd: swipeUp.isEmpty
                ? null
                : (details) {
                    if ((details.primaryVelocity ?? 0) < -180) {
                      _runGesture(context, swipeUp);
                    }
                  },
            child: ink,
          );

    // No backdrop: show only the content. App icons carry their own rounded/
    // transparent corners, so a colored backdrop with a different corner radius
    // could poke out behind them; without a backdrop the icon's own shape
    // defines the tile and the look stays clean.
    if (frameless) {
      final bare = Material(
        key: const ValueKey('bare-tile'),
        type: MaterialType.transparency,
        child: surface,
      );
      return editable ? _editFrame(bare, radius, scheme.primary) : bare;
    }

    if (!glass) {
      final tappable = Material(
        color: color,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: surface,
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
      child: Material(type: MaterialType.transparency, child: surface),
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
    // Live info tiles (clock, date, battery, storage, unread) have no app
    // behind them: the board draws their content itself.
    if (tile.isInfo) {
      return InfoTileContent(
        tile: tile,
        state: state,
        foreground: (glass || frameless) ? scheme.onSurface : Colors.white,
      );
    }
    final packageName = app?.packageName ?? '';
    // A pinned launcher entry can rename the app (联系人 and 电话 are the same
    // package), and its icon follows the same choice.
    final name = state.displayNameFor(packageName);
    // Without a backdrop the label sits on the page background, so use the
    // theme's on-surface color instead of the solid style's white.
    final labelColor = (glass || frameless) ? scheme.onSurface : Colors.white;
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
                packageName: packageName,
                label: name,
                showNotificationBadge: false,
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
                        packageName: packageName,
                        label: name,
                        showNotificationBadge: false,
                        size: side.clamp(8.0, double.infinity).toDouble(),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 2),
              Text(
                name,
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

  /// Browse-mode tap: an app tile launches its app, an info tile runs its own
  /// action (a sheet, a screen or a device action).
  VoidCallback? _browseTap(BuildContext context, String packageName) {
    if (packageName.isNotEmpty) {
      return () => launchApp(context, packageName);
    }
    if (!infoTileIsTappable(tile.kind)) return null;
    return () => handleInfoTileTap(context, state, tile);
  }

  /// Runs a gesture action configured for this tile.
  void _runGesture(BuildContext context, String action) {
    if (action == 'details') {
      if (tile.isInfo) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => AppDetailScreen(
            packageName: tile.packageName,
            fromTileBoard: true,
          ),
        ),
      );
      return;
    }
    if (action == 'launch') {
      if (tile.isInfo || tile.packageName.isEmpty) return;
      launchApp(context, tile.packageName);
      return;
    }
    if (action == 'search') {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const GlobalSearchScreen()),
      );
      return;
    }
    if (action.startsWith('page:')) {
      final id = action.substring(5);
      final index = state.tilePages.indexWhere((p) => p.id == id);
      if (index >= 0) state.setCurrentTilePage(index);
    }
  }

  /// Picks what a double tap / an upward swipe on this tile does.
  Future<void> _showGestureSettings(BuildContext context) async {
    final s = context.strings;
    final actions = <(String, String)>[
      ('', s.t('不设置')),
      if (!tile.isInfo) ('details', s.t('查看详情')),
      if (!tile.isInfo) ('launch', s.t('启动应用')),
      ('search', s.t('打开搜索')),
      for (final page in state.tilePages)
        ('page:${page.id}', s.t('跳到「{name}」', {'name': page.name})),
    ];
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          Widget editor(String label, String optionKey) {
            final current =
                state.tileById(tile.id)?.optionString(optionKey) ?? '';
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final (value, text) in actions)
                        ChoiceChip(
                          label: Text(text),
                          selected: current == value,
                          onSelected: (_) async {
                            await state.setTileOptions(tile.id, {
                              optionKey: value.isEmpty ? null : value,
                            });
                            if (ctx.mounted) setSheet(() {});
                          },
                        ),
                    ],
                  ),
                ],
              ),
            );
          }

          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(ctx).size.height * 0.8,
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                      child: Text(
                        s.t('磁贴手势'),
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                      child: Text(
                        s.t('默认点击就是启动；这里给双击和上滑各绑定一个动作。设置后单击会等一小会儿再响应。'),
                        style: const TextStyle(fontSize: 12.5, height: 1.35),
                      ),
                    ),
                    editor(s.t('双击'), 'doubleTap'),
                    editor(s.t('上滑'), 'swipeUp'),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// Lists the app's own long-press shortcuts (the ones the launcher shows).
  Future<void> _showAppShortcuts(BuildContext context) async {
    final s = context.strings;
    if (tile.isInfo || tile.packageName.isEmpty) return;
    final result = await NativeApps.appShortcuts(tile.packageName);
    if (!context.mounted) return;
    if (!result.permitted) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(s.t('需要把囤囤设为默认桌面')),
          content: Text(
            s.t(
              'Android 只向当前桌面应用提供其它应用的快捷方式。把囤囤设为默认桌面后，这里的「扫一扫」之类的入口就能用；不设置也不影响其它功能。',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(s.t('取消')),
            ),
            FilledButton(
              onPressed: () async {
                Navigator.pop(ctx);
                await NativeApps.openHomeSettings();
              },
              child: Text(s.t('去设置')),
            ),
          ],
        ),
      );
      return;
    }
    if (result.shortcuts.isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(s.t('这个应用没有提供快捷方式'))));
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text(
                s.t('应用快捷方式'),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            for (final shortcut in result.shortcuts)
              ListTile(
                leading: const Icon(Icons.bolt_outlined),
                title: Text(
                  shortcut.label.isEmpty ? shortcut.id : shortcut.label,
                ),
                onTap: () async {
                  final ok = await NativeApps.startAppShortcut(
                    tile.packageName,
                    shortcut.id,
                  );
                  if (!ctx.mounted) return;
                  Navigator.pop(ctx);
                  if (!ok) {
                    ScaffoldMessenger.of(context)
                      ..hideCurrentSnackBar()
                      ..showSnackBar(
                        SnackBar(content: Text(s.t('无法打开这个快捷方式'))),
                      );
                  }
                },
              ),
          ],
        ),
      ),
    );
  }

  void _showTileMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      // The menu grew (gestures, app shortcuts); the default 9/16 height cut
      // the last entries off on shorter screens.
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.85,
          ),
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
                    title: Text(
                      context.strings.t(tile.isInfo ? '显示说明文字' : '显示应用名称'),
                    ),
                    subtitle: Text(
                      context.strings.t(
                        tile.isInfo ? '关闭后只显示数值' : '关闭后磁贴只显示图标',
                      ),
                    ),
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
                  if (tile.isInfo && infoTileHasSettings(tile.kind))
                    ListTile(
                      leading: const Icon(Icons.tune),
                      title: Text(context.strings.t('磁贴设置')),
                      subtitle: Text(context.strings.t('选内容、范围或动作')),
                      onTap: () {
                        Navigator.pop(ctx);
                        showInfoTileSettings(context, state, tile);
                      },
                    ),
                  ListTile(
                    leading: const Icon(Icons.gesture),
                    title: Text(context.strings.t('磁贴手势')),
                    subtitle: Text(context.strings.t('双击 / 上滑绑定一个动作')),
                    onTap: () {
                      Navigator.pop(ctx);
                      _showGestureSettings(context);
                    },
                  ),
                  if (!tile.isInfo)
                    ListTile(
                      leading: const Icon(Icons.bolt_outlined),
                      title: Text(context.strings.t('应用快捷方式')),
                      subtitle: Text(context.strings.t('系统长按菜单里的入口')),
                      onTap: () {
                        Navigator.pop(ctx);
                        _showAppShortcuts(context);
                      },
                    ),
                  if (!tile.isInfo)
                    ListTile(
                      leading: const Icon(Icons.info_outline),
                      title: Text(context.strings.t('应用详情')),
                      onTap: () {
                        Navigator.pop(ctx);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => AppDetailScreen(
                              packageName: app?.packageName ?? '',
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
                          content: Text(context.strings.t('确定移除这个磁贴吗？')),
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
                final name = state.displayNameFor(app.packageName);
                return ListTile(
                  leading: AppIcon(packageName: app.packageName, label: name),
                  title: Text(name),
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
        final name = state.displayNameFor(app.packageName);
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
              AppIcon(packageName: app.packageName, label: name, size: 56),
              const SizedBox(height: 8),
              Text(
                name,
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
          SliverToBoxAdapter(
            child: _SectionLabel(text: context.strings.t('最近')),
          ),
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
    final name = state.displayNameFor(app.packageName);
    return ListTile(
      leading: AppIcon(packageName: app.packageName, label: name),
      title: Text(name),
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
    final shown = items.length > _maxItems
        ? items.sublist(0, _maxItems)
        : items;
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
    final name = state.displayNameFor(rec.packageName);
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
