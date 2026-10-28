import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_strings.dart';
import '../state/app_state.dart';
import '../utils/app_exporter.dart';
import '../utils/app_grouping.dart';

/// The one place where the app list is narrowed down: free-text search, scope,
/// state, category, sort and grouping, all in a single page.
///
/// Nothing is applied while the conditions are edited. The bottom bar shows how
/// many apps they match and an 应用筛选 button writes them into [AppState] and
/// returns to the list — so the results are the list, not a separate view.
class AppFinderScreen extends StatefulWidget {
  const AppFinderScreen({super.key, this.focusSearch = true});

  /// Whether the search field takes focus on open. False when the page was
  /// opened from the filter button, where the keyboard would only cover the
  /// conditions.
  final bool focusSearch;

  @override
  State<AppFinderScreen> createState() => _AppFinderScreenState();
}

class _AppFinderScreenState extends State<AppFinderScreen> {
  late final AppState _state = context.read<AppState>();
  final TextEditingController _controller = TextEditingController();

  late String _query = _state.query;
  late AppScope _scope = _state.scope;
  late AppFilter _filter = _state.filter;
  late String? _categoryId = _state.filterCategoryId;
  late AppSort _sort = _state.sort;
  late bool _ascending = _state.sortAscending;
  late AppGroupMode _group = _state.groupMode;

  @override
  void initState() {
    super.initState();
    _controller.text = _query;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  int get _count {
    if (_filter == AppFilter.uninstalled) return _state.uninstalledApps.length;
    return _state
        .appsFor(
          query: _query,
          scope: _scope,
          filter: _filter,
          filterCategoryId: _categoryId,
          sort: _sort,
          sortAscending: _ascending,
        )
        .length;
  }

  void _reset() {
    _controller.clear();
    setState(() {
      _query = '';
      _scope = AppScope.all;
      _filter = AppFilter.all;
      _categoryId = null;
      _sort = AppSort.name;
      _ascending = true;
    });
  }

  /// Writes the conditions into the state (and remembers a real search) so the
  /// list behind this page shows exactly these apps. All of it is one settings
  /// write, so applying can never race another save.
  void _apply({bool leave = true}) {
    unawaited(
      _state.applyAppFilters(
        query: _query,
        scope: _scope,
        filter: _filter,
        filterCategoryId: _categoryId,
        sort: _sort,
        sortAscending: _ascending,
        group: _group,
      ),
    );
    if (leave) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final s = context.strings;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(s.t('搜索与筛选')),
        actions: [
          IconButton(
            tooltip: s.t('筛选语法'),
            icon: const Icon(Icons.help_outline),
            onPressed: () => showSearchSyntaxHelp(
              context,
              onPick: (example) {
                _controller.value = TextEditingValue(
                  text: example,
                  selection: TextSelection.collapsed(offset: example.length),
                );
                setState(() => _query = example);
              },
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    autofocus: widget.focusSearch,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _apply(),
                    onChanged: (value) => setState(() => _query = value),
                    decoration: InputDecoration(
                      hintText: s.t('搜索应用名 / 包名 / 拼音首字母'),
                      prefixIcon: const Icon(Icons.search),
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
                // Clears only the search; 重置 below clears everything.
                IconButton(
                  tooltip: s.t('清除搜索'),
                  onPressed: _query.isEmpty
                      ? null
                      : () {
                          _controller.clear();
                          setState(() => _query = '');
                        },
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              children: [
                _label(s.t('应用类型')),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final (value, label) in <(AppScope, String)>[
                      (AppScope.all, s.t('全部')),
                      (AppScope.user, s.t('用户应用')),
                      (AppScope.system, s.t('系统应用')),
                    ])
                      ChoiceChip(
                        label: Text(label),
                        selected: _scope == value,
                        onSelected: (_) => setState(() => _scope = value),
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                _label(s.t('筛选')),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final value in AppFilter.values)
                      if (value == AppFilter.unorganized)
                        Tooltip(
                          message: s.t('未分组、无原因/备注，且未收藏、未固定到磁贴'),
                          child: _filterChip(s, value),
                        )
                      else
                        _filterChip(s, value),
                  ],
                ),
                if (state.categories.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  _label(s.t('分类')),
                  DropdownButtonFormField<String>(
                    initialValue: _categoryId ?? '',
                    isExpanded: true,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      DropdownMenuItem(
                        value: '',
                        child: Text(s.t('全部分类')),
                      ),
                      for (final c in state.categories)
                        DropdownMenuItem(
                          value: c.id,
                          child: Text(
                            '${c.emoji} ${c.name}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (value) => setState(
                      () => _categoryId = (value == null || value.isEmpty)
                          ? null
                          : value,
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                _label(s.t('排序')),
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
                      ChoiceChip(
                        label: Text(e.value),
                        selected: _sort == e.key,
                        onSelected: (_) => setState(() {
                          _sort = e.key;
                          _ascending = e.key == AppSort.name;
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
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
                  selected: {_ascending},
                  onSelectionChanged: (v) =>
                      setState(() => _ascending = v.first),
                ),
                const SizedBox(height: 18),
                _label(s.t('分组')),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final e in <AppGroupMode, String>{
                      AppGroupMode.none: s.t('不分组'),
                      AppGroupMode.initial: s.t('按首字母'),
                      AppGroupMode.category: s.t('按分类'),
                    }.entries)
                      ChoiceChip(
                        label: Text(e.value),
                        selected: _group == e.key,
                        onSelected: (_) => setState(() => _group = e.key),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                const Divider(height: 24),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.bookmark_outline),
                  title: Text(s.t('记忆筛选')),
                  subtitle: Text(s.t('退出后下次打开应用列表时，沿用现在的筛选与排序')),
                  value: state.rememberAppFilters,
                  onChanged: state.setRememberAppFilters,
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.description_outlined),
                  title: Text(s.t('导出应用清单')),
                  subtitle: Text(s.t('按当前筛选导出为 Markdown / CSV / 纯文本')),
                  onTap: () {
                    // Export what the form is showing, not what the list was
                    // showing before it was opened.
                    _apply(leave: false);
                    exportAppList(context, state);
                  },
                ),
                const SizedBox(height: 6),
                Text(
                  s.t('结果会显示在应用列表里'),
                  style: TextStyle(
                    fontSize: 11.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Material(
            elevation: 3,
            color: scheme.surface,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                child: Row(
                  children: [
                    OutlinedButton(
                      onPressed: _reset,
                      child: Text(s.t('重置')),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _apply,
                        icon: const Icon(Icons.check),
                        label: Text(
                          s.t('应用筛选 · {n} 个', {'n': _count}),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _filterChip(AppStrings s, AppFilter value) => FilterChip(
    label: Text(appFilterLabel(s, value)),
    selected: _filter == value,
    onSelected: (_) => setState(() => _filter = value),
  );

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
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

/// Label for one of the app-list state filters, used by the finder page and by
/// the applied-conditions bar on the list.
String appFilterLabel(AppStrings s, AppFilter filter) {
  switch (filter) {
    case AppFilter.all:
      return s.t('全部');
    case AppFilter.favorite:
      return '⭐${s.t('收藏')}';
    case AppFilter.categorized:
      return s.t('已分类');
    case AppFilter.uncategorized:
      return s.t('未分类');
    case AppFilter.hasReason:
      return s.t('有原因');
    case AppFilter.unorganized:
      return '🫥${s.t('未整理')}';
    case AppFilter.uninstalled:
      return '🗑️${s.t('已卸载')}';
    case AppFilter.hidden:
      return '🙈${s.t('隐藏')}';
  }
}

/// Explains the search syntax; with [onPick] an example fills the field.
void showSearchSyntaxHelp(
  BuildContext context, {
  ValueChanged<String>? onPick,
}) {
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
            s.t(
              '语法可以和名字、包名、拼音一起用。认不出来的 key:value 会当成普通文字搜索。',
            ),
            style: const TextStyle(fontSize: 12.5, height: 1.35),
          ),
          const SizedBox(height: 10),
          for (final (example, explanation) in rows)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              trailing: onPick == null
                  ? null
                  : const Icon(Icons.north_west, size: 16),
              onTap: onPick == null
                  ? null
                  : () {
                      Navigator.pop(ctx);
                      onPick(example);
                    },
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
