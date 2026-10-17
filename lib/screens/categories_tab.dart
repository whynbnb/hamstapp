import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_strings.dart';
import '../models/category.dart';
import '../models/tile.dart';
import '../state/app_state.dart';
import '../utils/actions.dart';
import '../utils/search.dart';
import '../widgets/app_icon.dart';
import '../widgets/category_editor.dart';
import '../widgets/info_tile_sheets.dart';
import '../widgets/search_field.dart';
import '../widgets/web_app_editor.dart';
import 'app_detail_screen.dart';

class CategoriesTab extends StatelessWidget {
  const CategoriesTab({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    if (state.categories.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            context.strings.t('还没有分类。\n点击右上角新建一个，再到应用详情里给应用归类。'),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final cats = state.sortedCategories;
    final manual = state.categorySort == CategorySort.manual;

    Widget tile(BuildContext context, AppCategory c) {
      final count = state.categoryAppCount(c.id);
      return ListTile(
        key: ValueKey(c.id),
        leading: CircleAvatar(
          backgroundColor: Color(c.colorValue).withValues(alpha: 0.18),
          child: Text(c.emoji),
        ),
        title: Text(
          c.name,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(context.strings.t('{n} 个应用', {'n': count})),
        trailing: PopupMenuButton<String>(
          onSelected: (v) {
            if (v == 'edit') showCategoryEditor(context, state, c);
            if (v == 'delete') confirmDeleteCategory(context, state, c);
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              value: 'edit',
              child: Text(context.strings.t('编辑')),
            ),
            PopupMenuItem(
              value: 'delete',
              child: Text(context.strings.t('删除')),
            ),
          ],
        ),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => CategoryAppsScreen(state: state, category: c),
          ),
        ),
      );
    }

    return Column(
      children: [
        _SortBar(state: state, total: cats.length, manual: manual),
        Expanded(
          child: manual
              // Manual mode: drag a row by its handle to persist the order.
              ? ReorderableListView.builder(
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: cats.length,
                  onReorderItem: state.moveCategory,
                  itemBuilder: (context, i) => tile(context, cats[i]),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: cats.length,
                  itemBuilder: (context, i) => tile(context, cats[i]),
                ),
        ),
      ],
    );
  }
}

/// Compact header showing the category count and the sort selector.
class _SortBar extends StatelessWidget {
  const _SortBar({
    required this.state,
    required this.total,
    required this.manual,
  });

  final AppState state;
  final int total;
  final bool manual;

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).colorScheme.onSurfaceVariant;
    final labels = {
      CategorySort.manual: context.strings.t('手动排序'),
      CategorySort.name: context.strings.t('按名称'),
      CategorySort.count: context.strings.t('按应用数'),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 6, 0),
      child: Row(
        children: [
          Text(context.strings.t('{n} 个分类', {'n': total}),
              style: TextStyle(fontSize: 12, color: hint)),
          if (manual) ...[
            const SizedBox(width: 8),
            Text(context.strings.t('· 拖动行可排序'),
                style: TextStyle(fontSize: 12, color: hint)),
          ],
          const Spacer(),
          PopupMenuButton<CategorySort>(
            tooltip: context.strings.t('分类排序'),
            icon: const Icon(Icons.sort, size: 20),
            initialValue: state.categorySort,
            onSelected: state.setCategorySort,
            itemBuilder: (_) => [
              for (final e in labels.entries)
                CheckedPopupMenuItem(
                  value: e.key,
                  checked: state.categorySort == e.key,
                  child: Text(e.value),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Apps inside a single category. Tap launches, long-press opens details, and
/// the AppBar "+" opens a searchable picker to add more apps to the category.
class CategoryAppsScreen extends StatelessWidget {
  const CategoryAppsScreen({
    super.key,
    required this.state,
    required this.category,
  });

  final AppState state;
  final AppCategory category;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final apps =
        s.apps
            .where(
              (a) => s.metaFor(a.packageName).categoryIds.contains(category.id),
            )
            .toList()
          ..sort(
            (a, b) => s
                .displayNameFor(a.packageName)
                .toLowerCase()
                .compareTo(s.displayNameFor(b.packageName).toLowerCase()),
          );

    return Scaffold(
      appBar: AppBar(
        title: Text('${category.emoji} ${category.name}'),
        actions: [
          IconButton(
            tooltip: context.strings.t('添加应用到该分类'),
            icon: const Icon(Icons.add),
            onPressed: () => showCategoryPicker(context, s, category),
          ),
        ],
      ),
      body: apps.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  context.strings.t('该分类下还没有应用\n点击右上角 ➕ 添加'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade600),
                ),
              ),
            )
          : ListView.builder(
              itemCount: apps.length,
              itemBuilder: (context, i) {
                final app = apps[i];
                final name = state.displayNameFor(app.packageName);
                return ListTile(
                  leading: AppIcon(
                    packageName: app.packageName,
                    label: name,
                  ),
                  title: Text(name),
                  subtitle: Text(
                    app.packageName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: context.strings.t('启动'),
                        icon: const Icon(
                          Icons.rocket_launch_outlined,
                          size: 20,
                        ),
                        onPressed: () => launchApp(context, app.packageName),
                      ),
                      PopupMenuButton<String>(
                        tooltip: context.strings.t('更多'),
                        onSelected: (v) {
                          if (v == 'detail') {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    AppDetailScreen(packageName: app.packageName),
                              ),
                            );
                          } else if (v == 'remove') {
                            final ids = List<String>.from(
                              s.metaFor(app.packageName).categoryIds,
                            )..remove(category.id);
                            s.updateMeta(app.packageName, categoryIds: ids);
                          }
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 'detail',
                            child: Text(context.strings.t('应用详情')),
                          ),
                          PopupMenuItem(
                            value: 'remove',
                            child: Text(context.strings.t('移出分类')),
                          ),
                        ],
                      ),
                    ],
                  ),
                  onTap: () => launchApp(context, app.packageName),
                  onLongPress: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          AppDetailScreen(packageName: app.packageName),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

/// Searchable sheet for toggling category membership. Tap a row to add or
/// remove the app from [category].
void showCategoryPicker(
  BuildContext context,
  AppState state,
  AppCategory category,
) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => _CategoryPickerSheet(state: state, category: category),
  );
}

class _CategoryPickerSheet extends StatefulWidget {
  const _CategoryPickerSheet({required this.state, required this.category});

  final AppState state;
  final AppCategory category;

  @override
  State<_CategoryPickerSheet> createState() => _CategoryPickerSheetState();
}

class _CategoryPickerSheetState extends State<_CategoryPickerSheet> {
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
    final category = widget.category;
    final apps = AppSearch.rank(state.apps, _query, limit: 300);

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      builder: (ctx, scrollController) {
        final memberCount = state.apps
            .where(
              (a) =>
                  state.metaFor(a.packageName).categoryIds.contains(category.id),
            )
            .length;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      ctx.strings.t(
                        '添加到「{emoji} {name}」',
                        {'emoji': category.emoji, 'name': category.name},
                      ),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      ctx.strings.t(
                        '已添加 {count} 个应用 · 点击行切换',
                        {'count': memberCount},
                      ),
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
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
                  final inCat = state
                      .metaFor(app.packageName)
                      .categoryIds
                      .contains(category.id);
                  final name = state.displayNameFor(app.packageName);
                  return ListTile(
                    leading: AppIcon(
                      packageName: app.packageName,
                      label: name,
                    ),
                    title: Text(name),
                    subtitle: Text(
                      app.packageName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: inCat
                        ? const Icon(Icons.check_circle, color: Colors.green)
                        : const Icon(Icons.add_circle_outline, color: Colors.grey),
                    onTap: () {
                      final ids = List<String>.from(
                        state.metaFor(app.packageName).categoryIds,
                      );
                      if (inCat) {
                        ids.remove(category.id);
                      } else {
                        ids.add(category.id);
                      }
                      state.updateMeta(app.packageName, categoryIds: ids);
                      setState(() {});
                    },
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Bottom sheet to pin/unpin apps on the currently visible tile page.
///
/// Tap: pin when not pinned on this page, otherwise unpin (remove one).
/// Long-press: add another copy of the same app to this page.
void showPinSheet(BuildContext context, AppState state) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => _PinSheet(state: state),
  );
}

/// Live info tiles, grouped the way the picker offers them.
const List<TileKind> kInfoTileReadings = <TileKind>[
  TileKind.clock,
  TileKind.date,
  TileKind.battery,
  TileKind.storage,
  TileKind.memory,
  TileKind.screenTime,
  TileKind.traffic,
  TileKind.alarm,
  TileKind.uptime,
  TileKind.netSpeed,
  TileKind.unread,
];

const List<TileKind> kInfoTileAppLists = <TileKind>[
  TileKind.recent,
  TileKind.frequent,
  TileKind.newApps,
  TileKind.neglected,
  TileKind.favorites,
  TileKind.biggest,
  TileKind.folder,
];

/// Tiles about 囤囤's own state (snapshots, caches, backup lists).
const List<TileKind> kInfoTileOwn = <TileKind>[
  TileKind.snapshot,
  TileKind.unorganized,
  TileKind.cache,
  TileKind.backupList,
];

/// Small tools: a switch, a dial shortcut, a countdown, a note.
const List<TileKind> kInfoTileTools = <TileKind>[
  TileKind.torch,
  TileKind.dial,
  TileKind.countdown,
  TileKind.worldClock,
  TileKind.note,
  TileKind.overview,
];

/// The picker's groups, in order. The sheet shows them all or just one.
const List<(String, List<TileKind>)> kInfoTileGroups =
    <(String, List<TileKind>)>[
  ('读数', kInfoTileReadings),
  ('应用', kInfoTileAppLists),
  ('囤囤', kInfoTileOwn),
  ('工具', kInfoTileTools),
  // Driven by kInfoTileActions rather than by kinds: each entry is one action.
  ('动作', <TileKind>[]),
];

/// Picker for the live info tiles, filterable by group.
void showInfoTileSheet(BuildContext context, AppState state) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => _InfoTileSheet(state: state),
  );
}

class _InfoTileSheet extends StatefulWidget {
  const _InfoTileSheet({required this.state});

  final AppState state;

  @override
  State<_InfoTileSheet> createState() => _InfoTileSheetState();
}

class _InfoTileSheetState extends State<_InfoTileSheet> {
  /// Which group is showing; -1 means all of them.
  int _group = -1;

  AppState get state => widget.state;

  Future<void> _add(
    TileKind kind,
    String title, {
    Map<String, dynamic>? options,
  }) async {
    await state.addInfoTile(kind, options: options);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(context.strings.t('已添加「{name}」磁贴', {'name': title})),
          duration: const Duration(milliseconds: 1200),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final groups = <(String, List<TileKind>)>[
      for (final (title, kinds) in kInfoTileGroups) (s.t(title), kinds),
    ];
    final shown = _group < 0
        ? List<int>.generate(groups.length, (i) => i)
        : <int>[_group];

    return SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        builder: (ctx, controller) => ListView(
          controller: controller,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.t('添加信息磁贴'),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      s.t('磁贴板上会实时显示的小卡片，不依赖任何应用'),
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Filter by group, or look at everything.
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  _chip(s.t('全部'), -1),
                  for (var i = 0; i < groups.length; i++)
                    _chip(groups[i].$1, i),
                ],
              ),
            ),
            for (final i in shown) ...[
              if (_group < 0) _header(groups[i].$1),
              ..._rows(groups[i].$2),
            ],
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Widget _chip(String label, int index) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: _group == index,
        // Tapping the selected chip again returns to "all", which keeps the
        // whole list one tap away.
        onSelected: (_) => setState(() => _group = _group == index ? -1 : index),
        labelStyle: TextStyle(
          fontSize: 13,
          fontWeight: _group == index ? FontWeight.w700 : FontWeight.w400,
          color: _group == index ? scheme.onSecondaryContainer : null,
        ),
      ),
    );
  }

  Widget _header(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            text,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
      );

  /// Rows for one group. An empty kind list means the actions group.
  List<Widget> _rows(List<TileKind> kinds) {
    if (kinds.isEmpty) {
      return [
        for (final action in kInfoTileActions)
          ListTile(
            dense: true,
            leading: Icon(actionIcon(action)),
            title: Text(context.strings.t(actionTitle(action))),
            subtitle: Text(
              context.strings.t(infoTileSubtitle(TileKind.action)),
            ),
            onTap: () {
              Navigator.pop(context);
              _add(
                TileKind.action,
                context.strings.t(actionTitle(action)),
                options: {'action': action},
              );
            },
          ),
      ];
    }
    return [
      for (final kind in kinds)
        ListTile(
          dense: true,
          leading: Icon(infoTileIcon(kind)),
          title: Text(context.strings.t(infoTileTitle(kind))),
          subtitle: Text(context.strings.t(infoTileSubtitle(kind))),
          onTap: () {
            Navigator.pop(context);
            _add(kind, context.strings.t(infoTileTitle(kind)));
          },
        ),
    ];
  }
}

class _PinSheet extends StatefulWidget {
  const _PinSheet({required this.state});

  final AppState state;

  @override
  State<_PinSheet> createState() => _PinSheetState();
}

class _PinSheetState extends State<_PinSheet> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          duration: const Duration(milliseconds: 900),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final apps = AppSearch.rank(state.apps, _query, limit: 150);
    final pages = state.tilePages;
    final pageIndex = pages.isEmpty
        ? -1
        : state.currentTilePageIndex.clamp(0, pages.length - 1);
    final pageName = pageIndex < 0
        ? context.strings.t('（无磁贴页）')
        : pages[pageIndex].name;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      builder: (ctx, scrollController) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    ctx.strings.t('固定到磁贴'),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    ctx.strings.t(
                      '当前页：{page} · 点击固定/取消，长按再添加一个',
                      {'page': pageName},
                    ),
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  // Two secondary ways to add something to the board, side by
                  // side: stacked they pushed the app list down for little.
                  Row(
                    children: [
                      Flexible(
                        child: TextButton.icon(
                          onPressed: () async {
                            await showWebAppEditor(context, state);
                            if (mounted) setState(() {});
                          },
                          icon: const Icon(Icons.add_link, size: 18),
                          label: Text(
                            ctx.strings.t('添加网页应用'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: TextButton.icon(
                          onPressed: () => showInfoTileSheet(context, state),
                          icon: const Icon(Icons.schedule, size: 18),
                          label: Text(
                            ctx.strings.t('添加信息磁贴'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
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
                final count = state.pinCountOnCurrentPage(app.packageName);
                final pinned = count > 0;
                final name = state.displayNameFor(app.packageName);
                return ListTile(
                  leading: AppIcon(
                    packageName: app.packageName,
                    label: name,
                  ),
                  title: Text(name),
                  subtitle: Text(
                    app.packageName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: pinned
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.push_pin,
                              color: Colors.orange,
                              size: 18,
                            ),
                            if (count > 1) ...[
                              const SizedBox(width: 4),
                              Text('×$count'),
                            ],
                          ],
                        )
                      : const Icon(
                          Icons.add_circle_outline,
                          color: Colors.grey,
                        ),
                  onTap: () {
                    if (pinned) {
                      state.removeOneTileOnCurrentPage(app.packageName);
                      setState(() {});
                      _snack(ctx.strings.t('已取消固定'));
                    } else {
                      state.addTile(
                        app.packageName,
                        pageId: state.currentTilePageId,
                      );
                      setState(() {});
                      _snack(
                        ctx.strings.t('已固定到「{page}」', {'page': pageName}),
                      );
                    }
                  },
                  onLongPress: () {
                    state.addTile(
                      app.packageName,
                      pageId: state.currentTilePageId,
                    );
                    setState(() {});
                    _snack(
                      ctx.strings.t('已再添加一个到「{page}」', {
                        'page': pageName,
                      }),
                    );
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
