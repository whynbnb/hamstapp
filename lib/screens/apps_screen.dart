import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_strings.dart';
import '../models/app_info.dart';
import '../state/app_state.dart';
import '../widgets/app_tile.dart';
import '../widgets/collapsed_nav.dart';
import '../widgets/uninstall_reason.dart';
import '../utils/app_grouping.dart';
import '../widgets/web_app_editor.dart';
import 'app_detail_screen.dart';
import 'apk_analyzer_screen.dart';
import 'app_finder_screen.dart';
import 'health_screen.dart';
import 'sync_screen.dart';

class AppsScreen extends StatefulWidget {
  const AppsScreen({super.key});

  @override
  State<AppsScreen> createState() => _AppsScreenState();
}

class _AppsScreenState extends State<AppsScreen> {
  late final AppState _state;
  bool _wasScanning = false;

  /// The app shown in the wide-screen side pane.
  String? _selectedPackage;

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
          _ActiveConditions(state: state),
          if (state.hasPermissionAlerts) _UpdateAlertBanner(state: state),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // A tablet in landscape can show the list and the app page side
                // by side instead of pushing a page over the list.
                final wide = constraints.maxWidth >= 840;
                void select(AppInfo app) =>
                    setState(() => _selectedPackage = app.packageName);
                final list = RefreshIndicator(
                  onRefresh: state.scan,
                  child: state.scanning && apps.isEmpty
                      ? const _SkeletonList()
                      : showUninstalled
                      ? _UninstalledList(state: state)
                      : state.filter == AppFilter.hidden
                      ? _HiddenList(
                          state: state,
                          onSelect: wide ? select : null,
                        )
                      : apps.isEmpty
                      ? _EmptyView(state: state)
                      : state.groupMode != AppGroupMode.none &&
                            state.query.trim().isEmpty
                      ? _GroupedAppList(
                          state: state,
                          onSelect: wide ? select : null,
                        )
                      : ListView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
                          keyboardDismissBehavior:
                              ScrollViewKeyboardDismissBehavior.onDrag,
                          itemCount: apps.length,
                          itemBuilder: (context, i) => _appTile(
                            context,
                            state,
                            apps[i],
                            onTap: wide ? () => select(apps[i]) : null,
                          ),
                        ),
                );
                if (!wide) return list;
                return Row(
                  children: [
                    SizedBox(width: 360, child: list),
                    const VerticalDivider(width: 1),
                    Expanded(
                      child: _selectedPackage == null
                          ? Center(
                              child: Text(
                                context.strings.t('选择左侧的应用查看详情'),
                                style: TextStyle(color: Colors.grey.shade600),
                              ),
                            )
                          : AppDetailScreen(
                              key: ValueKey(_selectedPackage),
                              packageName: _selectedPackage!,
                              embedded: true,
                            ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// A red-ish strip above the list when the last scan found apps that started
/// asking for more after an update.
class _UpdateAlertBanner extends StatelessWidget {
  const _UpdateAlertBanner({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.shield_outlined, size: 18, color: scheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              s.t('{n} 个应用在更新后新增了权限或换了签名', {
                'n': state.permissionAlerts.length,
              }),
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const HealthScreen()),
            ),
            child: Text(s.t('查看')),
          ),
          IconButton(
            tooltip: s.t('忽略'),
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close, size: 18),
            onPressed: state.dismissPermissionAlerts,
          ),
        ],
      ),
    );
  }
}

/// The hidden apps, with a note about what hiding does and does not do.
class _HiddenList extends StatelessWidget {
  const _HiddenList({required this.state, this.onSelect});
  final AppState state;
  final ValueChanged<AppInfo>? onSelect;

  @override
  Widget build(BuildContext context) {
    final apps = state.hiddenApps;
    if (apps.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 100),
          Icon(Icons.visibility_off_outlined, size: 64, color: Colors.grey),
          const SizedBox(height: 12),
          Center(child: Text(context.strings.t('没有隐藏的应用'))),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              context.strings.t('在应用详情页的菜单里可以隐藏；分类、原因和备注都会保留'),
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade600, fontSize: 12.5),
            ),
          ),
        ],
      );
    }
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      itemCount: apps.length + 1,
      itemBuilder: (context, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              context.strings.t('隐藏的应用不会出现在列表里；分类、原因、备注和磁贴都还在。'),
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          );
        }
        final app = apps[i - 1];
        return _appTile(
          context,
          state,
          app,
          onTap: onSelect == null ? null : () => onSelect!(app),
        );
      },
    );
  }
}

/// Shown while the first scan is running: blocks that suggest the list that is
/// about to arrive instead of a lone spinner.
class _SkeletonList extends StatelessWidget {
  const _SkeletonList();

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).colorScheme.onSurface
        .withValues(alpha: 0.07);
    Widget bar(double width, double height) => Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: base,
        borderRadius: BorderRadius.circular(height / 2),
      ),
    );
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: 8,
      itemBuilder: (context, i) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: base,
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            const SizedBox(width: 14),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                bar(120 + (i % 3) * 30, 12),
                const SizedBox(height: 8),
                bar(180 + (i % 2) * 40, 9),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// One row of the app list, wired to the detail page.
Widget _appTile(
  BuildContext context,
  AppState state,
  AppInfo app, {
  VoidCallback? onTap,
}) {
  return AppListTile(
    app: app,
    state: state,
    showSortFact: true,
    onTap:
        onTap ??
        () {
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
  const _GroupedAppList({required this.state, this.onSelect});
  final AppState state;

  /// Set on wide screens: tapping a row fills the side pane instead of pushing
  /// a page.
  final ValueChanged<AppInfo>? onSelect;

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
            itemBuilder: (context, i) => _appTile(
              context,
              state,
              group.apps[i],
              onTap: onSelect == null ? null : () => onSelect!(group.apps[i]),
            ),
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

/// The quick search: typing filters the list right away, like it always did.
/// Everything that needs combining (scope, state, category, sort, grouping and
/// the `key:value` syntax) lives one tap away behind 高级, so the two never
/// fight over what the list should show.
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

  @override
  void initState() {
    super.initState();
    // The advanced page, a condition chip or 清除 can change the query while
    // this field is alive; keep the text in step with it.
    widget.state.addListener(_syncFromState);
  }

  @override
  void dispose() {
    widget.state.removeListener(_syncFromState);
    _controller.dispose();
    super.dispose();
  }

  void _syncFromState() {
    final query = widget.state.query;
    if (_controller.text == query) return;
    _controller.value = TextEditingValue(
      text: query,
      selection: TextSelection.collapsed(offset: query.length),
    );
  }

  void _setQuery(String value) {
    widget.state.query = value;
    widget.state.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final s = context.strings;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 2),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  textInputAction: TextInputAction.search,
                  onChanged: _setQuery,
                  onSubmitted: (value) {
                    unawaited(state.rememberQuery(value));
                    FocusManager.instance.primaryFocus?.unfocus();
                  },
                  decoration: InputDecoration(
                    hintText: s.t('快速搜索'),
                    // The field itself stays uncluttered; a long press on the
                    // magnifier explains how it differs from 高级.
                    prefixIcon: Tooltip(
                      message: s.t('输入即筛选；组合范围、状态、分类与排序用「高级」'),
                      child: const Icon(Icons.search),
                    ),
                    suffixIcon: _controller.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: MaterialLocalizations.of(
                              context,
                            ).clearButtonTooltip,
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _controller.clear();
                              _setQuery('');
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
              const SizedBox(width: 4),
              TextButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const AppFinderScreen(focusSearch: false),
                  ),
                ),
                icon: Badge(
                  isLabelVisible: state.activeAppFilterCount > 0,
                  label: Text('${state.activeAppFilterCount}'),
                  backgroundColor: scheme.primary,
                  child: const Icon(Icons.tune, size: 20),
                ),
                label: Text(s.t('高级')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The conditions currently narrowing the list, as removable chips. An applied
/// search stays visible here (and in the search bar), so a short list never
/// looks like the scan lost apps.
class _ActiveConditions extends StatelessWidget {
  const _ActiveConditions({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final chips = <Widget>[];
    if (state.scope != AppScope.all) {
      chips.add(
        _chip(
          context,
          state.scope == AppScope.user ? s.t('用户应用') : s.t('系统应用'),
          () {
            state.scope = AppScope.all;
            state.refresh();
          },
        ),
      );
    }
    if (state.filter != AppFilter.all) {
      chips.add(
        _chip(context, appFilterLabel(s, state.filter), () {
          state.filter = AppFilter.all;
          state.refresh();
        }),
      );
    }
    final categoryId = state.filterCategoryId;
    final category = categoryId == null ? null : state.categoryById(categoryId);
    if (category != null) {
      chips.add(
        _chip(
          context,
          s.t('分类：{name}', {'name': '${category.emoji} ${category.name}'}),
          () {
            state.filterCategoryId = null;
            state.refresh();
          },
        ),
      );
    }
    if (chips.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < chips.length; i++) ...[
                    if (i > 0) const SizedBox(width: 6),
                    chips[i],
                  ],
                ],
              ),
            ),
          ),
          TextButton(
            onPressed: () {
              state.query = '';
              state.scope = AppScope.all;
              state.filter = AppFilter.all;
              state.filterCategoryId = null;
              state.refresh();
            },
            child: Text(s.t('清除')),
          ),
        ],
      ),
    );
  }

  Widget _chip(BuildContext context, String label, VoidCallback onDelete) {
    return InputChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      visualDensity: VisualDensity.compact,
      onDeleted: onDelete,
      deleteIcon: const Icon(Icons.close, size: 14),
    );
  }
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
