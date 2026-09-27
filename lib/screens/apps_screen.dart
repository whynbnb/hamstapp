import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_strings.dart';
import '../state/app_state.dart';
import '../widgets/app_tile.dart';
import '../widgets/chip_scroller.dart';
import '../widgets/floating_nav.dart';
import '../widgets/uninstall_reason.dart';
import 'app_detail_screen.dart';
import 'sync_screen.dart';

class AppsScreen extends StatelessWidget {
  const AppsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final showUninstalled = state.filter == AppFilter.uninstalled;
    final apps = state.visibleApps;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        leading: FloatingNavScope.activeOf(context)
            ? const FloatingNavButton()
            : null,
        title: Text(
          context.strings.t('应用'),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            tooltip: context.strings.t('同步远程 APK'),
            icon: const Icon(Icons.cloud_sync_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SyncScreen()),
            ),
          ),
          IconButton(
            tooltip: state.appsStatsText,
            icon: const Icon(Icons.info_outline),
            onPressed: () {
              ScaffoldMessenger.of(context)
                ..hideCurrentSnackBar()
                ..showSnackBar(
                  SnackBar(
                    content: Text(state.appsStatsText),
                    behavior: SnackBarBehavior.floating,
                    duration: const Duration(seconds: 4),
                  ),
                );
            },
          ),
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
              : IconButton(
                  tooltip: context.strings.t('刷新应用列表'),
                  icon: const Icon(Icons.refresh),
                  onPressed: state.scan,
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
                  : ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      itemCount: apps.length,
                      itemBuilder: (context, i) {
                        final app = apps[i];
                        return AppListTile(
                          app: app,
                          state: state,
                          showSortFact: true,
                          onTap: () {
                            FocusManager.instance.primaryFocus?.unfocus();
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => AppDetailScreen(
                                  packageName: app.packageName,
                                ),
                              ),
                            );
                          },
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }
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

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              textInputAction: TextInputAction.search,
              onTapOutside: (_) => _focusNode.unfocus(),
              onSubmitted: (_) => _focusNode.unfocus(),
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
    );
  }
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
                  _choice(
                    context,
                    s.t('全部'),
                    state.scope == AppScope.all,
                    () {
                      state.scope = AppScope.all;
                      state.refresh();
                    },
                  ),
                  _choice(
                    context,
                    s.t('用户'),
                    state.scope == AppScope.user,
                    () {
                      state.scope = AppScope.user;
                      state.refresh();
                    },
                  ),
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
                        : _choice(
                            context,
                            e.value,
                            state.filter == e.key,
                            () {
                              state.filter = e.key;
                              state.refresh();
                            },
                          ),
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
                ? context.strings.t('扫描失败：{error}', {
                    'error': state.scanError,
                  })
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
