import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_strings.dart';
import '../models/app_info.dart';
import '../state/app_state.dart';
import '../widgets/app_tile.dart';
import '../widgets/chip_scroller.dart';
import '../widgets/collapsed_nav.dart';
import '../widgets/uninstall_reason.dart';
import '../utils/app_exporter.dart';
import '../utils/app_grouping.dart';
import '../widgets/web_app_editor.dart';
import 'app_detail_screen.dart';
import 'apk_analyzer_screen.dart';
import 'sync_screen.dart';

class AppsScreen extends StatefulWidget {
  const AppsScreen({super.key});

  @override
  State<AppsScreen> createState() => _AppsScreenState();
}

class _AppsScreenState extends State<AppsScreen> {
  late final AppState _state;
  bool _wasScanning = false;

  @override
  void initState() {
    super.initState();
    _state = context.read<AppState>();
    _wasScanning = _state.scanning;
    // Surface the summary automatically when a scan finishes. Same transient
    // snackbar as long-pressing refresh, so nothing stays on screen.
    _state.addListener(_onState);
  }

  @override
  void dispose() {
    _state.removeListener(_onState);
    super.dispose();
  }

  void _onState() {
    final scanning = _state.scanning;
    if (_wasScanning && !scanning) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showStats(context, _state);
      });
    }
    _wasScanning = scanning;
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final showUninstalled = state.filter == AppFilter.uninstalled;
    final apps = state.visibleApps;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        leading: CollapsedNavScope.activeOf(context)
            ? const CollapsedNavButton()
            : null,
        title: Text(
          context.strings.t('应用'),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            tooltip: context.strings.t('添加网页应用'),
            icon: const Icon(Icons.add_link),
            onPressed: () => showWebAppEditor(context, state),
          ),
          IconButton(
            tooltip: context.strings.t('APK 分析'),
            icon: const Icon(Icons.manage_search),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ApkAnalyzerScreen()),
            ),
          ),
          IconButton(
            tooltip: context.strings.t('同步远程 APK'),
            icon: const Icon(Icons.cloud_sync_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SyncScreen()),
            ),
          ),
          // The stats used to live behind a separate info button. Now tapping
          // refresh refreshes and long-pressing shows the summary; a finished
          // scan shows the same summary on its own.
          state.scanning
              ? const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                )
              : Tooltip(
                  message: context.strings.t('刷新应用列表\n长按查看统计信息'),
                  child: InkResponse(
                    onTap: state.scan,
                    onLongPress: () => _showStats(context, state),
                    radius: 24,
                    child: const Padding(
                      padding: EdgeInsets.all(12),
                      child: Icon(Icons.refresh),
                    ),
                  ),
                ),
        ],
      ),
      body: Column(
        children: [
          _SearchBar(state: state),
          Expanded(
            child: RefreshIndicator(
              onRefresh: state.scan,
              child: showUninstalled
                  ? _UninstalledList(state: state)
                  : apps.isEmpty
                  ? _EmptyView(state: state)
                  : state.groupMode != AppGroupMode.none &&
                        state.query.trim().isEmpty
                  ? _GroupedAppList(state: state)
                  : ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      itemCount: apps.length,
                      itemBuilder: (context, i) =>
                          _appTile(context, state, apps[i]),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One row of the app list, wired to the detail page.
Widget _appTile(BuildContext context, AppState state, AppInfo app) {
  return AppListTile(
    app: app,
    state: state,
    showSortFact: true,
    onTap: () {
      FocusManager.instance.primaryFocus?.unfocus();
      // A search that led somewhere is worth repeating.
      if (state.query.trim().isNotEmpty) state.rememberQuery(state.query);
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => AppDetailScreen(packageName: app.packageName),
        ),
      );
    },
  );
}

/// The app list with a section header pinned to the top while its apps scroll
/// past. Grouping is off while searching: results are ranked by relevance, and
/// cutting them into sections would hide that order.
class _GroupedAppList extends StatelessWidget {
  const _GroupedAppList({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final groups = state.groupedApps;
    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: [
        for (final group in groups) ...[
          SliverPersistentHeader(
            pinned: true,
            delegate: _GroupHeaderDelegate(
              label: group.label,
              count: group.apps.length,
              // The page background, not the tinted surface: the header must
              // look like part of the list, not like a band across it.
              background: Theme.of(context).scaffoldBackgroundColor,
            ),
          ),
          SliverList.builder(
            itemCount: group.apps.length,
            itemBuilder: (context, i) =>
                _appTile(context, state, group.apps[i]),
          ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }
}

/// A pinned section header: the letter or category, with how many apps it holds.
class _GroupHeaderDelegate extends SliverPersistentHeaderDelegate {
  _GroupHeaderDelegate({
    required this.label,
    required this.count,
    required this.background,
  });

  final String label;
  final int count;
  final Color background;

  static const double _height = 30;

  @override
  double get minExtent => _height;

  @override
  double get maxExtent => _height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: _height,
      color: background,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: scheme.primary,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$count',
            style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(_GroupHeaderDelegate old) =>
      old.label != label || old.count != count || old.background != background;
}

/// Shows the scan/app counters without leaving the screen.
void _showStats(BuildContext context, AppState state) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(state.appsStatsText),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
      ),
    );
}

class _UninstalledList extends StatelessWidget {
  const _UninstalledList({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final items = state.uninstalledApps;
    if (items.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 120),
          const Icon(Icons.history_toggle_off, size: 64, color: Colors.grey),
          const SizedBox(height: 12),
          Center(child: Text(context.strings.t('还没有卸载记录'))),
        ],
      );
    }
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      itemCount: items.length,
      itemBuilder: (context, i) =>
          UninstalledTile(meta: items[i], state: state),
    );
  }
}

class _SearchBar extends StatefulWidget {
  const _SearchBar({required this.state});
  final AppState state;

  @override
  State<_SearchBar> createState() => _SearchBarState();
}

class _SearchBarState extends State<_SearchBar> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.state.query,
  );
  final FocusNode _focusNode = FocusNode();

  /// The syntax the list understands, offered as one-tap chips.
  static const List<String> kSyntaxHints = <String>[
    'size:>100m',
    'installed:<7d',
    'updated:<30d',
    'cat:',
    'reason:',
    'source:none',
    'type:system',
  ];

  @override
  void initState() {
    super.initState();
    // The history/syntax panel only shows while the field has focus.
    _focusNode.addListener(_onFocusChanged);
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _setQuery(String value) {
    _controller.text = value;
    _controller.selection = TextSelection.collapsed(offset: value.length);
    widget.state.query = value;
    widget.state.refresh();
    setState(() {});
  }

  /// Adds a filter to whatever is already typed, without clobbering it.
  void _appendQuery(String value) {
    final current = _controller.text.trim();
    _setQuery(current.isEmpty ? value : '$current $value');
  }

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final history = widget.state.searchHistory;
    // A TapRegion, not the field's own onTapOutside: the history and syntax
    // chips sit just below the field, and tapping one of them must not close
    // the panel, otherwise only one filter could ever be added.
    return TapRegion(
      onTapOutside: (_) => _focusNode.unfocus(),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (v) {
                      widget.state.rememberQuery(v);
                      _focusNode.unfocus();
                    },
                    onChanged: (v) {
                      widget.state.query = v;
                      widget.state.refresh();
                      setState(() {});
                    },
                    decoration: InputDecoration(
                      hintText: context.strings.t('搜索应用名 / 包名 / 拼音首字母'),
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _controller.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                _controller.clear();
                                widget.state.query = '';
                                widget.state.refresh();
                                setState(() {});
                              },
                            ),
                      isDense: true,
                      filled: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _FilterButton(state: widget.state),
              ],
            ),
            if (_focusNode.hasFocus) ...[
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 6,
                  runSpacing: 2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (history.isNotEmpty) ...[
                      Text(
                        s.t('最近搜索'),
                        style: TextStyle(
                          fontSize: 11.5,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      for (final q in history)
                        ActionChip(
                          visualDensity: VisualDensity.compact,
                          label: Text(
                            q,
                            style: const TextStyle(fontSize: 11.5),
                          ),
                          onPressed: () => _setQuery(q),
                        ),
                      ActionChip(
                        visualDensity: VisualDensity.compact,
                        avatar: const Icon(Icons.delete_outline, size: 14),
                        label: Text(
                          s.t('清除'),
                          style: const TextStyle(fontSize: 11.5),
                        ),
                        onPressed: widget.state.clearSearchHistory,
                      ),
                    ],
                  ],
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 6,
                  runSpacing: 2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      s.t('筛选语法'),
                      style: TextStyle(
                        fontSize: 11.5,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    for (final hint in kSyntaxHints)
                      ActionChip(
                        visualDensity: VisualDensity.compact,
                        label: Text(
                          hint,
                          style: const TextStyle(fontSize: 11.5),
                        ),
                        onPressed: () => _appendQuery(hint),
                      ),
                    ActionChip(
                      visualDensity: VisualDensity.compact,
                      avatar: const Icon(Icons.help_outline, size: 14),
                      label: Text(
                        s.t('说明'),
                        style: const TextStyle(fontSize: 11.5),
                      ),
                      onPressed: () => showSearchSyntaxHelp(context),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Explains the search syntax; the examples can be tapped to try them.
void showSearchSyntaxHelp(BuildContext context) {
  final s = context.strings;
  final rows = <(String, String)>[
    ('size:>100m', s.t('大于 100 MB（< 更小，10m-2g 表示区间；不带单位按 MB 算）')),
    ('installed:<7d', s.t('最近 7 天安装的（也支持 >30d、>2026-01-01）')),
    ('updated:<30d', s.t('最近 30 天更新过的')),
    ('cat:游戏', s.t('分类名里含「游戏」的应用')),
    ('reason:工作', s.t('安装原因里含「工作」；只写 reason: 表示填过原因')),
    ('source:none', s.t('系统没有记录安装者（侧载）；也可写来源包名或应用名')),
    ('type:system', s.t('只看系统应用（type:user 只看用户应用）')),
    ('cat:', s.t('只写 key: 表示「有」：cat: 有分类、reason: 有原因、source: 有安装者')),
  ];
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          Text(
            s.t('筛选语法'),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            s.t('语法可以和名字、包名、拼音一起用，也可以和上面的筛选面板叠加。认不出来的 key:value 会当成普通文字搜索。'),
            style: const TextStyle(fontSize: 12.5, height: 1.35),
          ),
          const SizedBox(height: 10),
          for (final (example, explanation) in rows)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: SizedBox(
                width: 104,
                child: Text(
                  example,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12.5,
                  ),
                ),
              ),
              title: Text(
                explanation,
                style: const TextStyle(fontSize: 12.5, height: 1.35),
              ),
            ),
        ],
      ),
    ),
  );
}

/// Opens the combined filter/sort panel as a bottom sheet. Shows a badge with
/// how many non-default options are active so the collapsed bar stays clean.
class _FilterButton extends StatelessWidget {
  const _FilterButton({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final scheme = Theme.of(context).colorScheme;
    final count = state.activeAppFilterCount;
    return IconButton(
      tooltip: s.t('筛选与排序'),
      onPressed: () => showAppFilterSheet(context, state),
      icon: Badge(
        isLabelVisible: count > 0,
        label: Text('$count'),
        backgroundColor: scheme.primary,
        child: const Icon(Icons.tune),
      ),
    );
  }
}

/// Bottom sheet holding every list control: app type (scope), annotation
/// filter, category filter and sort order/direction.
void showAppFilterSheet(BuildContext context, AppState state) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _AppFilterSheet(state: state),
  );
}

class _AppFilterSheet extends StatelessWidget {
  const _AppFilterSheet({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    // Rebuild the sheet as filters change so chips/switches stay in sync.
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      s.t('筛选与排序'),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: state.activeAppFilterCount == 0
                        ? null
                        : state.resetAppFilters,
                    child: Text(s.t('重置')),
                  ),
                ],
              ),
              _label(context, s.t('应用类型')),
              Wrap(
                spacing: 8,
                children: [
                  _choice(context, s.t('全部'), state.scope == AppScope.all, () {
                    state.scope = AppScope.all;
                    state.refresh();
                  }),
                  _choice(context, s.t('用户'), state.scope == AppScope.user, () {
                    state.scope = AppScope.user;
                    state.refresh();
                  }),
                  _choice(
                    context,
                    s.t('系统'),
                    state.scope == AppScope.system,
                    () {
                      state.scope = AppScope.system;
                      state.refresh();
                    },
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _label(context, s.t('筛选')),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final e in <AppFilter, String>{
                    AppFilter.all: s.t('全部'),
                    AppFilter.favorite: '⭐${s.t('收藏')}',
                    AppFilter.categorized: s.t('已分类'),
                    AppFilter.uncategorized: s.t('未分类'),
                    AppFilter.hasReason: s.t('有原因'),
                    AppFilter.unorganized: '🫥${s.t('未整理')}',
                    AppFilter.uninstalled: '🗑️${s.t('已卸载')}',
                  }.entries)
                    e.key == AppFilter.unorganized
                        ? Tooltip(
                            message: s.t('未分组、无原因/备注，且未收藏、未固定到磁贴'),
                            child: _choice(
                              context,
                              e.value,
                              state.filter == e.key,
                              () {
                                state.filter = e.key;
                                state.refresh();
                              },
                            ),
                          )
                        : _choice(context, e.value, state.filter == e.key, () {
                            state.filter = e.key;
                            state.refresh();
                          }),
                ],
              ),
              if (state.categories.isNotEmpty) ...[
                const SizedBox(height: 16),
                _label(context, s.t('分类')),
                ChipScroller(
                  children: [
                    _choice(
                      context,
                      s.t('全部'),
                      state.filterCategoryId == null,
                      () {
                        state.filterCategoryId = null;
                        state.refresh();
                      },
                    ),
                    for (final c in state.categories)
                      _choice(
                        context,
                        '${c.emoji} ${c.name}',
                        state.filterCategoryId == c.id,
                        () {
                          state.filterCategoryId =
                              state.filterCategoryId == c.id ? null : c.id;
                          state.refresh();
                        },
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              _label(context, s.t('排序')),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final e in <AppSort, String>{
                    AppSort.name: s.t('按名称'),
                    AppSort.installTime: s.t('按安装时间'),
                    AppSort.updateTime: s.t('按更新时间'),
                    AppSort.size: s.t('按大小'),
                  }.entries)
                    _choice(
                      context,
                      e.value,
                      state.sort == e.key,
                      () => state.setAppSort(e.key),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              _label(context, s.t('分组')),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final e in <AppGroupMode, String>{
                    AppGroupMode.none: s.t('不分组'),
                    AppGroupMode.initial: s.t('按首字母'),
                    AppGroupMode.category: s.t('按分类'),
                  }.entries)
                    _choice(
                      context,
                      e.value,
                      state.groupMode == e.key,
                      () => state.setAppGroupMode(e.key),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              SegmentedButton<bool>(
                segments: [
                  ButtonSegment(
                    value: true,
                    icon: const Icon(Icons.arrow_upward, size: 16),
                    label: Text(s.t('正序')),
                  ),
                  ButtonSegment(
                    value: false,
                    icon: const Icon(Icons.arrow_downward, size: 16),
                    label: Text(s.t('倒序')),
                  ),
                ],
                selected: {state.sortAscending},
                onSelectionChanged: (v) => state.setSortAscending(v.first),
              ),
              const SizedBox(height: 12),
              const Divider(height: 1),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.description_outlined),
                title: Text(s.t('导出应用清单')),
                subtitle: Text(s.t('按当前筛选导出为 Markdown / CSV / 纯文本')),
                onTap: () {
                  Navigator.pop(context);
                  exportAppList(context, state);
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.bookmark_outline),
                title: Text(s.t('记忆筛选')),
                subtitle: Text(s.t('退出后下次打开应用列表时，沿用现在的筛选与排序')),
                value: state.rememberAppFilters,
                onChanged: state.setRememberAppFilters,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _label(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );

  Widget _choice(
    BuildContext context,
    String label,
    bool selected,
    VoidCallback onTap,
  ) => FilterChip(
    label: Text(label),
    selected: selected,
    onSelected: (_) => onTap(),
  );
}

class _EmptyView extends StatelessWidget {
  const _EmptyView({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        const SizedBox(height: 120),
        Icon(Icons.inbox_outlined, size: 64, color: Colors.grey.shade400),
        const SizedBox(height: 12),
        Center(
          child: Text(
            state.scanError != null
                ? context.strings.t('扫描失败：{error}', {'error': state.scanError})
                : state.scanning
                ? context.strings.t('正在扫描已安装应用…')
                : context.strings.t('没有匹配的应用'),
            style: TextStyle(color: Colors.grey.shade600),
          ),
        ),
      ],
    );
  }
}
