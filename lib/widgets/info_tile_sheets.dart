import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../models/app_info.dart';
import '../models/tile.dart';
import '../services/native_apps.dart';
import '../services/notification_badges.dart';
import '../services/system_stats.dart';
import '../state/app_state.dart';
import '../utils/actions.dart';
import '../utils/format.dart';
import '../utils/search.dart';
import '../widgets/app_icon.dart';
import '../widgets/search_field.dart';
import '../screens/storage_manager_screen.dart';

/// Explains an unsupported tile and offers to remove it.
///
/// A kind can disappear when a newer version drops it; rather than deleting the
/// tile behind the user's back, keep it visible and ask.
void showUnsupportedTileDialog(
  BuildContext context,
  AppState state,
  Tile tile,
) {
  final s = context.strings;
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(s.t('不支持的小组件')),
      content: Text(
        s.t('这个磁贴的类型在当前版本的囤囤里已经不支持了（可能是旧版本添加的）。它不会显示内容，只能移除。'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(s.t('取消')),
        ),
        FilledButton(
          onPressed: () {
            Navigator.pop(ctx);
            state.removeTile(tile.id);
          },
          child: Text(s.t('移除')),
        ),
      ],
    ),
  );
}

/// Opens the storage screen (the storage tile's tap).
void openStorageManager(BuildContext context) {
  Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => const StorageManagerScreen()),
  );
}

// ------------------------------------------------------------ action tiles

/// Actions a 快捷动作 tile can run.
const List<String> kInfoTileActions = ['scan', 'snapshot', 'search', 'storage'];

String actionTitle(String action) => switch (action) {
  'scan' => '扫描应用',
  'snapshot' => '新建快照',
  'search' => '搜索应用',
  'storage' => '存储管理',
  _ => '动作',
};

IconData actionIcon(String action) => switch (action) {
  'scan' => Icons.refresh,
  'snapshot' => Icons.camera_alt_outlined,
  'search' => Icons.search,
  'storage' => Icons.storage_outlined,
  _ => Icons.touch_app_outlined,
};

/// Runs an action tile.
Future<void> runInfoTileAction(
  BuildContext context,
  AppState state,
  Tile tile,
) async {
  final s = context.strings;
  switch (tile.optionString('action', 'scan')) {
    case 'scan':
      await state.scan();
      if (context.mounted) _snack(context, s.t('已重新扫描应用'));
    case 'snapshot':
      final snapshot = await state.createSnapshot(Fmt.dateTime(
        DateTime.now().millisecondsSinceEpoch,
      ));
      if (context.mounted) {
        _snack(context, s.t('已创建快照「{name}」', {'name': snapshot.name}));
      }
    case 'search':
      showAppSearchSheet(context, state);
    case 'storage':
      if (context.mounted) openStorageManager(context);
  }
}

void _snack(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}

// --------------------------------------------------------------- app lists

/// A sheet with a list of apps (recent, frequent, new installs, neglected).
void showAppListSheet(
  BuildContext context,
  AppState state,
  TileKind kind, {
  required List<AppInfo> apps,
}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        builder: (ctx, controller) => Column(
          children: [
            _sheetHeader(
              ctx,
              ctx.strings.t(_sheetTitle(kind)),
              ctx.strings.t('{n} 个应用', {'n': apps.length}),
            ),
            if (apps.isEmpty)
              Expanded(
                child: Center(
                  child: Text(ctx.strings.t(_sheetEmpty(kind))),
                ),
              )
            else
              Expanded(
                child: ListView.builder(
                  controller: controller,
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
                      subtitle: Text(_sheetSubtitle(ctx, state, kind, app)),
                      onTap: () {
                        Navigator.pop(ctx);
                        launchApp(context, app.packageName);
                      },
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

String _sheetTitle(TileKind kind) => switch (kind) {
  TileKind.recent => '最近使用',
  TileKind.frequent => '常用应用',
  TileKind.newApps => '最近安装',
  TileKind.neglected => '长期未打开',
  TileKind.folder => '文件夹',
  TileKind.unread => '未读通知',
  _ => '应用',
};

String _sheetEmpty(TileKind kind) => switch (kind) {
  TileKind.recent || TileKind.frequent => '还没有启动记录',
  TileKind.newApps => '这段时间没有安装新应用',
  TileKind.neglected => '没有长期未打开的应用',
  _ => '没有内容',
};

String _sheetSubtitle(
  BuildContext context,
  AppState state,
  TileKind kind,
  AppInfo app,
) {
  final s = context.strings;
  final meta = state.metaFor(app.packageName);
  switch (kind) {
    case TileKind.recent:
    case TileKind.frequent:
      return s.t('启动 {count} 次 · 上次 {ago}', {
        'count': meta.launchCount,
        'ago': Fmt.relative(meta.lastLaunchedAt),
      });
    case TileKind.newApps:
      return s.t('安装于 {when}', {'when': Fmt.dateTime(app.firstInstallTime)});
    case TileKind.neglected:
      return s.t('上次 {ago}', {'ago': Fmt.relative(meta.lastLaunchedAt)});
    default:
      return app.packageName;
  }
}

/// Per-app unread counts (the unread tile's tap).
void showUnreadSheet(BuildContext context, AppState state) {
  final badges = NotificationBadges.instance;
  final entries = badges.counts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        builder: (ctx, controller) => Column(
          children: [
            _sheetHeader(
              ctx,
              ctx.strings.t('未读通知'),
              ctx.strings.t('{apps} 个应用共 {total} 条未读', {
                'apps': badges.appCount,
                'total': badges.total,
              }),
            ),
            if (entries.isEmpty)
              Expanded(
                child: Center(child: Text(ctx.strings.t('没有未读通知'))),
              )
            else
              Expanded(
                child: ListView.builder(
                  controller: controller,
                  itemCount: entries.length,
                  itemBuilder: (context, i) {
                    final pkg = entries[i].key;
                    final count = entries[i].value;
                    final name = state.displayNameFor(pkg);
                    return ListTile(
                      leading: AppIcon(packageName: pkg, label: name),
                      title: Text(name),
                      subtitle: Text(pkg, maxLines: 1),
                      trailing: Text(
                        '$count',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      onTap: () {
                        Navigator.pop(ctx);
                        launchApp(context, pkg);
                      },
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

// ------------------------------------------------------------------ folders

/// The apps a folder tile shows: a whole category, or a hand-picked list.
List<AppInfo> folderApps(AppState? state, Tile tile) {
  if (state == null) return const <AppInfo>[];
  final picked = tile.optionList('apps');
  if (picked.isNotEmpty) {
    return [
      for (final pkg in picked)
        if (state.appByPackage(pkg) != null) state.appByPackage(pkg)!,
    ];
  }
  final categoryId = tile.optionString('category');
  if (categoryId.isEmpty) return const <AppInfo>[];
  return state.apps
      .where((a) => state.metaFor(a.packageName).categoryIds.contains(categoryId))
      .toList();
}

/// The folder's caption: the category name, or "自选应用".
String folderName(AppState? state, Tile tile, AppStrings s) {
  if (tile.optionList('apps').isNotEmpty) return s.t('自选应用');
  final id = tile.optionString('category');
  for (final c in state?.categories ?? const []) {
    if (c.id == id) return c.name;
  }
  return s.t('文件夹');
}

void showFolderSheet(BuildContext context, AppState state, Tile tile) {
  final s = context.strings;
  final apps = folderApps(state, tile);
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.55,
        builder: (ctx, controller) => Column(
          children: [
            _sheetHeader(
              ctx,
              folderName(state, tile, s),
              s.t('{n} 个应用', {'n': apps.length}),
            ),
            if (apps.isEmpty)
              Expanded(
                child: Center(
                  child: Text(s.t('这个文件夹还是空的，进设置里选内容')),
                ),
              )
            else
              Expanded(
                child: GridView.builder(
                  controller: controller,
                  padding: const EdgeInsets.all(12),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                  ),
                  itemCount: apps.length,
                  itemBuilder: (context, i) {
                    final app = apps[i];
                    final name = state.displayNameFor(app.packageName);
                    return InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () {
                        Navigator.pop(ctx);
                        launchApp(context, app.packageName);
                      },
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AppIcon(
                            packageName: app.packageName,
                            label: name,
                            showNotificationBadge: false,
                            size: 46,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 11),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

// ------------------------------------------------------------------ traffic

void showTrafficSheet(BuildContext context) {
  final s = context.strings;
  final traffic = SystemStatsService.instance.traffic;
  showModalBottomSheet(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _sheetHeader(
            ctx,
            s.t('本月流量'),
            traffic.permitted
                ? s.t('合计 {size}', {'size': Fmt.storage(traffic.totalBytes)})
                : s.t('需要「使用情况访问」'),
          ),
          ListTile(
            leading: const Icon(Icons.signal_cellular_alt),
            title: Text(s.t('移动数据')),
            trailing: Text(Fmt.storage(traffic.mobileBytes)),
          ),
          ListTile(
            leading: const Icon(Icons.wifi),
            title: Text(s.t('Wi-Fi')),
            trailing: Text(Fmt.storage(traffic.wifiBytes)),
          ),
          if (!traffic.permitted)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.t('统计流量需要「使用情况访问」，和存储占用用的是同一个授权。'),
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.tonalIcon(
                      onPressed: () async {
                        await NativeApps.openUsageAccessSettings();
                        if (!ctx.mounted) return;
                        await SystemStatsService.instance.refresh(force: true);
                      },
                      icon: const Icon(Icons.settings_outlined, size: 18),
                      label: Text(s.t('开启「使用情况访问」')),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

// ------------------------------------------------------------------- search

/// The 搜索应用 action: a searchable list that launches what you pick.
void showAppSearchSheet(BuildContext context, AppState state) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => _AppSearchSheet(state: state),
  );
}

class _AppSearchSheet extends StatefulWidget {
  const _AppSearchSheet({required this.state});

  final AppState state;

  @override
  State<_AppSearchSheet> createState() => _AppSearchSheetState();
}

class _AppSearchSheetState extends State<_AppSearchSheet> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final apps = AppSearch.rank(widget.state.apps, _query, limit: 60);
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          builder: (ctx, controller) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    s.t('搜索应用'),
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
                  hintText: s.t('搜索应用'),
                  autofocus: true,
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  controller: controller,
                  itemCount: apps.length,
                  itemBuilder: (context, i) {
                    final app = apps[i];
                    final name = widget.state.displayNameFor(app.packageName);
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
                      onTap: () {
                        Navigator.pop(context);
                        launchApp(context, app.packageName);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------- settings

/// Whether this kind has anything to configure.
bool infoTileHasSettings(TileKind kind) => switch (kind) {
  TileKind.frequent ||
  TileKind.newApps ||
  TileKind.neglected ||
  TileKind.action ||
  TileKind.folder => true,
  _ => false,
};

/// Per-tile settings: what the tile shows and how much of it.
void showInfoTileSettings(BuildContext context, AppState state, Tile tile) {
  final s = context.strings;
  final options = tile.options;
  void save(Map<String, dynamic> values) => state.setTileOptions(tile.id, values);

  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: StatefulBuilder(
        builder: (ctx, setSheetState) => SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _sheetHeader(ctx, s.t('磁贴设置'), s.t(infoTileTitle(tile.kind))),
              if (tile.kind == TileKind.frequent) ...[
                _choice(
                  ctx,
                  s.t('显示内容'),
                  [
                    ('count', s.t('按启动次数（常用）')),
                    ('recommend', s.t('按时间段推荐')),
                  ],
                  options['source'] as String? ?? 'count',
                  (v) {
                    save({'source': v});
                    setSheetState(() {});
                  },
                ),
              ],
              if (tile.kind == TileKind.newApps) ...[
                _choice(
                  ctx,
                  s.t('统计范围'),
                  [
                    ('7', s.t('最近 7 天')),
                    ('30', s.t('最近 30 天')),
                  ],
                  '${tile.optionInt('days', 7)}',
                  (v) {
                    save({'days': int.parse(v)});
                    setSheetState(() {});
                  },
                ),
              ],
              if (tile.kind == TileKind.neglected) ...[
                _choice(
                  ctx,
                  s.t('多久算长期未用'),
                  [
                    ('30', s.t('30 天')),
                    ('60', s.t('60 天')),
                    ('90', s.t('90 天')),
                  ],
                  '${tile.optionInt('days', 30)}',
                  (v) {
                    save({'days': int.parse(v)});
                    setSheetState(() {});
                  },
                ),
              ],
              if (tile.kind == TileKind.action) ...[
                _choice(
                  ctx,
                  s.t('点一下做什么'),
                  [for (final a in kInfoTileActions) (a, s.t(actionTitle(a)))],
                  tile.optionString('action', 'scan'),
                  (v) {
                    save({'action': v});
                    setSheetState(() {});
                  },
                ),
              ],
              if (tile.kind == TileKind.folder) _folderSettings(ctx, state, tile),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    ),
  );
}

Widget _choice(
  BuildContext ctx,
  String label,
  List<(String, String)> options,
  String current,
  ValueChanged<String> onPick,
) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            color: Theme.of(ctx).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (value, text) in options)
              ChoiceChip(
                label: Text(text),
                selected: value == current,
                onSelected: (_) => onPick(value),
              ),
          ],
        ),
      ],
    ),
  );
}

/// A folder either shows a category or a hand-picked list of apps.
Widget _folderSettings(BuildContext ctx, AppState state, Tile tile) {
  final s = ctx.strings;
  final picked = tile.optionList('apps');
  final categoryId = tile.optionString('category');
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _choice(
        ctx,
        s.t('文件夹内容'),
        [
          ('', s.t('自选应用')),
          for (final c in state.categories) (c.id, c.name),
        ],
        picked.isNotEmpty ? '' : categoryId,
        (v) async {
          Navigator.pop(ctx);
          if (v.isEmpty) {
            await showFolderPicker(context: ctx, state: state, tile: tile);
          } else {
            await state.setTileOptions(tile.id, {
              'category': v,
              'apps': null,
            });
          }
        },
      ),
      if (picked.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () =>
                  showFolderPicker(context: ctx, state: state, tile: tile),
              icon: const Icon(Icons.checklist, size: 18),
              label: Text(s.t('已选 {n} 个应用 · 点击修改', {'n': picked.length})),
            ),
          ),
        ),
    ],
  );
}

/// Multi-select of apps for a hand-picked folder.
Future<void> showFolderPicker({
  required BuildContext context,
  required AppState state,
  required Tile tile,
}) async {
  final s = context.strings;
  final picked = {...tile.optionList('apps')};
  final selected = await showDialog<Set<String>>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) {
        final controller = TextEditingController();
        var query = '';
        return AlertDialog(
          title: Text(s.t('选择应用')),
          content: SizedBox(
            width: double.maxFinite,
            height: 400,
            child: StatefulBuilder(
              builder: (ctx, setInner) {
                final apps = AppSearch.rank(state.apps, query, limit: 200);
                return Column(
                  children: [
                    SearchField(
                      controller: controller,
                      hintText: s.t('搜索应用'),
                      onChanged: (v) => setInner(() => query = v),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: ListView.builder(
                        itemCount: apps.length,
                        itemBuilder: (context, i) {
                          final app = apps[i];
                          final name = state.displayNameFor(app.packageName);
                          final on = picked.contains(app.packageName);
                          return CheckboxListTile(
                            dense: true,
                            value: on,
                            onChanged: (v) => setDialogState(() {
                              if (v == true) {
                                picked.add(app.packageName);
                              } else {
                                picked.remove(app.packageName);
                              }
                            }),
                            secondary: AppIcon(
                              packageName: app.packageName,
                              label: name,
                              size: 34,
                              showNotificationBadge: false,
                            ),
                            title: Text(name, maxLines: 1),
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(s.t('取消')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, picked),
              child: Text(s.t('确定')),
            ),
          ],
        );
      },
    ),
  );
  if (selected == null) return;
  final ordered = [
    for (final a in state.apps)
      if (selected.contains(a.packageName)) a.packageName,
  ];
  await state.setTileOptions(tile.id, {
    'apps': ordered.isEmpty ? null : ordered,
    if (ordered.isNotEmpty) 'category': null,
  });
}

// ------------------------------------------------------------------- shared

Widget _sheetHeader(BuildContext context, String title, String subtitle) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    ),
  );
}

/// Localizable name of an info tile kind (Chinese source string).
String infoTileTitle(TileKind kind) => switch (kind) {
  TileKind.clock => '时钟',
  TileKind.date => '日期',
  TileKind.battery => '电量',
  TileKind.storage => '存储空间',
  TileKind.memory => '内存',
  TileKind.screenTime => '今日屏幕用时',
  TileKind.traffic => '本月流量',
  TileKind.alarm => '下一个闹钟',
  TileKind.unread => '未读汇总',
  TileKind.recent => '最近使用',
  TileKind.frequent => '常用应用',
  TileKind.newApps => '新装应用',
  TileKind.neglected => '长期未打开',
  TileKind.folder => '文件夹',
  TileKind.action => '快捷动作',
  TileKind.unknown => '不支持的小组件',
  TileKind.app => '应用',
};

String infoTileSubtitle(TileKind kind) => switch (kind) {
  TileKind.clock => '当前时间，按分钟更新',
  TileKind.date => '今天几号、星期几',
  TileKind.battery => '电量与充电状态，每分钟刷新',
  TileKind.storage => '本机存储占用，每分钟刷新',
  TileKind.memory => '内存占用，每分钟刷新',
  TileKind.screenTime => '今天累计亮屏用时（需使用情况访问）',
  TileKind.traffic => '本月移动 + Wi-Fi 流量（需使用情况访问）',
  TileKind.alarm => '系统里下一个闹钟，点一下打开时钟',
  TileKind.unread => '未读通知总数，点开看哪个应用几条',
  TileKind.recent => '最近从囤囤启动的应用',
  TileKind.frequent => '启动次数最多的应用',
  TileKind.newApps => '最近安装的应用',
  TileKind.neglected => '很久没打开的应用数',
  TileKind.folder => '一个分类或自选几个应用，点开是网格',
  TileKind.action => '点一下执行一个动作',
  TileKind.unknown => '当前版本不支持这种磁贴，点一下可以移除',
  TileKind.app => '',
};

IconData infoTileIcon(TileKind kind) => switch (kind) {
  TileKind.clock => Icons.schedule,
  TileKind.date => Icons.calendar_today_outlined,
  TileKind.battery => Icons.battery_charging_full,
  TileKind.storage => Icons.storage_outlined,
  TileKind.memory => Icons.memory,
  TileKind.screenTime => Icons.hourglass_bottom,
  TileKind.traffic => Icons.data_usage,
  TileKind.alarm => Icons.alarm,
  TileKind.unread => Icons.mark_email_unread_outlined,
  TileKind.recent => Icons.history,
  TileKind.frequent => Icons.star_outline,
  TileKind.newApps => Icons.fiber_new_outlined,
  TileKind.neglected => Icons.hourglass_disabled,
  TileKind.folder => Icons.folder_outlined,
  TileKind.action => Icons.touch_app_outlined,
  TileKind.unknown => Icons.help_outline,
  TileKind.app => Icons.apps,
};
