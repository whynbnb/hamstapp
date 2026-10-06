import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_strings.dart';
import '../models/snapshot.dart';
import '../state/app_state.dart';
import '../utils/format.dart';
import '../widgets/floating_nav.dart';
import 'backup_lists_screen.dart';
import 'compare_screen.dart';

class SnapshotsScreen extends StatefulWidget {
  const SnapshotsScreen({super.key});

  @override
  State<SnapshotsScreen> createState() => _SnapshotsScreenState();
}

class _SnapshotsScreenState extends State<SnapshotsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this)
    ..addListener(() => setState(() {}));

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final onSnapshots = _tabs.index == 0;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        leading: FloatingNavScope.activeOf(context)
            ? const FloatingNavButton()
            : null,
        title: Text(
          context.strings.t('快照与备份'),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        bottom: TabBar(
          controller: _tabs,
          tabs: [
            Tab(text: context.strings.t('快照')),
            Tab(text: context.strings.t('备份')),
          ],
        ),
      ),
      floatingActionButton: onSnapshots
          ? FloatingActionButton.extended(
              onPressed: () => createSnapshot(context, state),
              icon: const Icon(Icons.camera_alt_outlined),
              label: Text(context.strings.t('创建快照')),
            )
          : FloatingActionButton.extended(
              onPressed: () => createBackupList(context, state),
              icon: const Icon(Icons.playlist_add),
              label: Text(context.strings.t('新建备份列表')),
            ),
      body: TabBarView(
        controller: _tabs,
        children: const [_SnapshotsTab(), BackupListsTab()],
      ),
    );
  }
}

List<SnapshotEntry> _currentEntries(AppState state) => state.apps
    .map(
      (a) => SnapshotEntry(
        packageName: a.packageName,
        appName: a.appName,
        versionName: a.versionName,
        versionCode: a.versionCode,
        lastUpdateTime: a.lastUpdateTime,
        firstInstallTime: a.firstInstallTime,
        isSystem: a.isSystem,
        sizeBytes: a.sizeBytes,
        icon: state.iconFor(a.packageName),
      ),
    )
    .toList();

class _SnapshotsTab extends StatelessWidget {
  const _SnapshotsTab();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final snapshots = [...state.snapshots]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    return Column(
      children: [
        if (state.apps.isNotEmpty)
          ListTile(
            leading: const CircleAvatar(child: Icon(Icons.today)),
            title: Text(context.strings.t('当前设备')),
            subtitle: Text(
              context.strings.t('{n} 个应用 · {date}', {
                'n': state.apps.length,
                'date': Fmt.dateTime(
                  state.lastScanAt?.millisecondsSinceEpoch ?? 0,
                ),
              }),
            ),
            trailing: Text(context.strings.t('实时')),
          ),
        const Divider(height: 1),
        Expanded(
          child: snapshots.isEmpty
              ? _snapshotsEmpty()
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 88),
                  itemCount: snapshots.length,
                  itemBuilder: (context, i) {
                    final s = snapshots[i];
                    return ListTile(
                      leading: const CircleAvatar(child: Icon(Icons.history)),
                      title: Text(
                        s.name,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        '${context.strings.t('已安装 {n}', {'n': s.installedCount})}'
                        '${s.uninstalledCount > 0 ? ' · ${context.strings.t('已卸载 {n}', {'n': s.uninstalledCount})}' : ''}'
                        ' · ${Fmt.dateTime(s.createdAt)}'
                        '${s.note.isNotEmpty ? '\n${s.note}' : ''}',
                      ),
                      isThreeLine: s.note.isNotEmpty,
                      trailing: PopupMenuButton<String>(
                        onSelected: (v) =>
                            _onSnapshotAction(context, state, s, v),
                        itemBuilder: (ctx) => [
                          PopupMenuItem(
                            value: 'current',
                            child: Text(ctx.strings.t('与「当前」对比')),
                          ),
                          PopupMenuItem(
                            value: 'other',
                            child: Text(ctx.strings.t('与其它快照对比')),
                          ),
                          PopupMenuItem(
                            value: 'restore',
                            child: Text(ctx.strings.t('恢复标注数据')),
                          ),
                          PopupMenuItem(
                            value: 'rename',
                            child: Text(ctx.strings.t('重命名')),
                          ),
                          PopupMenuItem(
                            value: 'delete',
                            child: Text(ctx.strings.t('删除')),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

Widget _snapshotsEmpty() {
  return Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(
        AppStrings.current.t(
          '还没有快照。\n快照会记录当前安装的应用列表，\n方便以后比对新增 / 卸载 / 更新。',
        ),
        textAlign: TextAlign.center,
      ),
    ),
  );
}

Future<void> createSnapshot(BuildContext context, AppState state) async {
  if (state.apps.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.strings.t('请先在「应用」页扫描应用列表'))),
    );
    return;
  }
  final controller = TextEditingController();
  final defaultName = context.strings.t('快照 {n}', {
    'n': Fmt.day(DateTime.now().millisecondsSinceEpoch),
  });
  controller.text = defaultName;
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(ctx.strings.t('创建快照')),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: InputDecoration(labelText: ctx.strings.t('快照名称')),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(ctx.strings.t('取消')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text.trim()),
          child: Text(ctx.strings.t('保存')),
        ),
      ],
    ),
  );
  if (name == null) return;
  await state.createSnapshot(name);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        context.strings.t('已创建快照「{name}」', {
          'name': name.isEmpty ? defaultName : name,
        }),
      ),
    ),
  );
}

Future<void> _onSnapshotAction(
  BuildContext context,
  AppState state,
  Snapshot s,
  String action,
) async {
  switch (action) {
    case 'current':
      if (state.apps.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.strings.t('请先在「应用」页扫描应用列表'))),
        );
        return;
      }
      _openCompare(
        context,
        olderLabel: '${s.name} (${Fmt.dateTime(s.createdAt)})',
        newerLabel: context.strings.t('当前设备'),
        older: s.entries,
        newer: _currentEntries(state),
      );
      break;
    case 'other':
      final other = await showModalBottomSheet<Snapshot>(
        context: context,
        builder: (ctx) => ListView(
          shrinkWrap: true,
          children: state.snapshots
              .where((e) => e.id != s.id)
              .map(
                (e) => ListTile(
                  leading: const Icon(Icons.history),
                  title: Text(e.name),
                  subtitle: Text(Fmt.dateTime(e.createdAt)),
                  onTap: () => Navigator.pop(ctx, e),
                ),
              )
              .toList(),
        ),
      );
      if (other == null || !context.mounted) return;
      final older = s.createdAt <= other.createdAt ? s : other;
      final newer = s.createdAt <= other.createdAt ? other : s;
      _openCompare(
        context,
        olderLabel: '${older.name} (${Fmt.dateTime(older.createdAt)})',
        newerLabel: '${newer.name} (${Fmt.dateTime(newer.createdAt)})',
        older: older.entries,
        newer: newer.entries,
      );
      break;
    case 'rename':
      final controller = TextEditingController(text: s.name);
      final newName = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(ctx.strings.t('重命名快照')),
          content: TextField(controller: controller, autofocus: true),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(ctx.strings.t('取消')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: Text(ctx.strings.t('保存')),
            ),
          ],
        ),
      );
      if (newName != null && newName.isNotEmpty) {
        await state.renameSnapshot(s.id, newName);
      }
      break;
    case 'delete':
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(ctx.strings.t('删除快照')),
          content: Text(ctx.strings.t('确定删除「{name}」吗？', {'name': s.name})),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(ctx.strings.t('取消')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(ctx.strings.t('删除')),
            ),
          ],
        ),
      );
      if (ok == true) await state.deleteSnapshot(s.id);
      break;
    case 'restore':
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(ctx.strings.t('恢复标注数据')),
          content: Text(
            '${ctx.strings.t('将用「{name}」中记录的安装原因、备注、分类、收藏及卸载记录', {'name': s.name})}'
            '${ctx.strings.t('覆盖当前对应应用的标注数据。\n\n')}'
            '${ctx.strings.t('此操作只恢复数据，不会安装或卸载任何应用。')}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(ctx.strings.t('取消')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(ctx.strings.t('恢复')),
            ),
          ],
        ),
      );
      if (ok != true) return;
      final count = await state.restoreSnapshot(s.id);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.strings.t('已恢复 {count} 条应用的标注数据', {'count': count}),
          ),
        ),
      );
      break;
  }
}

void _openCompare(
  BuildContext context, {
  required String olderLabel,
  required String newerLabel,
  required List<SnapshotEntry> older,
  required List<SnapshotEntry> newer,
}) {
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => CompareScreen(
        olderLabel: olderLabel,
        newerLabel: newerLabel,
        older: older,
        newer: newer,
      ),
    ),
  );
}
