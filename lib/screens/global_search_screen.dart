import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_strings.dart';
import '../models/app_info.dart';
import '../models/backup_list.dart';
import '../models/category.dart';
import '../models/snapshot.dart';
import '../models/tile.dart';
import '../state/app_state.dart';
import '../utils/format.dart';
import '../utils/search.dart';
import '../widgets/app_icon.dart';
import '../widgets/info_tile_sheets.dart';
import 'apk_analyzer_screen.dart';
import 'app_detail_screen.dart';
import 'app_usage_screen.dart';
import 'backup_lists_screen.dart';
import 'compare_screen.dart';
import 'health_screen.dart';
import 'home_widget_screen.dart';
import 'log_screen.dart';
import 'orphan_cache_screen.dart';
import 'permission_audit_screen.dart';
import 'storage_manager_screen.dart';
import 'sync_screen.dart';
import 'usage_stats_screen.dart';
import 'web_app_check_screen.dart';

/// One search across the whole app: applications (including web entries),
/// categories, backup lists, snapshots, and a few direct shortcuts to screens
/// that are otherwise buried in Settings.
class GlobalSearchScreen extends StatefulWidget {
  const GlobalSearchScreen({super.key});

  @override
  State<GlobalSearchScreen> createState() => _GlobalSearchScreenState();
}

class _GlobalSearchScreenState extends State<GlobalSearchScreen> {
  final TextEditingController _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _open(Widget screen) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final s = context.strings;
    final q = _query.trim().toLowerCase();

    final apps = q.isEmpty
        ? const <AppInfo>[]
        : AppSearch.rank(state.apps, q, limit: 10);
    final categories = q.isEmpty
        ? <AppCategory>[]
        : state.categories
              .where((c) => c.name.toLowerCase().contains(q))
              .take(5)
              .toList();
    final lists = q.isEmpty
        ? <BackupList>[]
        : state.backupLists
              .where((b) => b.name.toLowerCase().contains(q))
              .take(5)
              .toList();
    final snapshots = q.isEmpty
        ? <Snapshot>[]
        : state.snapshots
              .where(
                (snap) =>
                    snap.name.toLowerCase().contains(q) ||
                    snap.note.toLowerCase().contains(q),
              )
              .take(5)
              .toList();
    final shortcuts = <(String, IconData, Widget Function())>[
      (s.t('整理与体检'), Icons.health_and_safety_outlined, () => const HealthScreen()),
      (s.t('桌面小组件'), Icons.widgets_outlined, () => const HomeWidgetScreen()),
      (s.t('存储管理'), Icons.sd_storage_outlined, () => const StorageManagerScreen()),
      (s.t('权限体检'), Icons.security_outlined, () => const PermissionAuditScreen()),
      (s.t('使用趋势'), Icons.insights_outlined, () => const UsageStatsScreen()),
      (s.t('使用时长与流量'), Icons.bar_chart_outlined, () => const AppUsageScreen()),
      (s.t('网页应用检测'), Icons.public, () => const WebAppCheckScreen()),
      (s.t('孤立缓存'), Icons.inventory_2_outlined, () => const OrphanCacheScreen()),
      (s.t('同步（FTP / Samba / WebDAV）'), Icons.cloud_sync_outlined, () => const SyncScreen()),
      (s.t('APK 分析'), Icons.manage_search, () => const ApkAnalyzerScreen()),
      (s.t('日志'), Icons.receipt_long_outlined, () => const LogScreen()),
    ].where((e) => q.isEmpty || e.$1.toLowerCase().contains(q)).toList();

    final nothing =
        q.isNotEmpty &&
        apps.isEmpty &&
        categories.isEmpty &&
        lists.isEmpty &&
        snapshots.isEmpty &&
        shortcuts.isEmpty;

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: s.t('搜索应用、分类、清单、快照、功能'),
            border: InputBorder.none,
            suffixIcon: _query.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      _controller.clear();
                      setState(() => _query = '');
                    },
                  ),
          ),
          onChanged: (v) => setState(() => _query = v),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          if (q.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                s.t('输入应用名、包名或拼音，也可以直接找下面这些功能。'),
                style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600),
              ),
            ),
          if (apps.isNotEmpty) _header(s.t('应用')),
          for (final app in apps)
            ListTile(
              leading: AppIcon(
                packageName: app.packageName,
                label: state.displayNameFor(app.packageName),
                size: 38,
              ),
              title: Text(
                state.displayNameFor(app.packageName),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                [
                  app.packageName,
                  if (state.metaFor(app.packageName).hidden) s.t('已隐藏'),
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _open(
                AppDetailScreen(packageName: app.packageName),
              ),
            ),
          if (categories.isNotEmpty) _header(s.t('分类')),
          for (final category in categories)
            ListTile(
              leading: Text(
                category.emoji.isEmpty ? '📁' : category.emoji,
                style: const TextStyle(fontSize: 20),
              ),
              title: Text(category.name),
              subtitle: Text(
                s.t('{n} 个应用', {
                  'n': state.apps
                      .where(
                        (a) => state
                            .metaFor(a.packageName)
                            .categoryIds
                            .contains(category.id),
                      )
                      .length,
                }),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showAppListSheet(
                context,
                state,
                // The sheet only wants a colour; a folder tile is the closest
                // existing "list of apps" presentation.
                _folderKind,
                apps: state.apps
                    .where(
                      (a) => state
                          .metaFor(a.packageName)
                          .categoryIds
                          .contains(category.id),
                    )
                    .toList(),
              ),
            ),
          if (lists.isNotEmpty) _header(s.t('备份列表')),
          for (final list in lists)
            ListTile(
              leading: const Icon(Icons.checklist_outlined),
              title: Text(list.name),
              subtitle: Text(
                s.t('{n} 个包', {'n': list.packageNames.length}),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _open(BackupListDetailScreen(listId: list.id)),
            ),
          if (snapshots.isNotEmpty) _header(s.t('快照')),
          for (final snap in snapshots)
            ListTile(
              leading: const Icon(Icons.history),
              title: Text(snap.name),
              subtitle: Text(
                s.t('{date} · {n} 个应用', {
                  'date': Fmt.dateTime(snap.createdAt),
                  'n': snap.installedCount,
                }),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                await state.ensureAppFacts();
                if (!mounted) return;
                _open(
                  CompareScreen(
                    olderLabel: '${snap.name} (${Fmt.dateTime(snap.createdAt)})',
                    newerLabel: s.t('当前设备'),
                    older: snap.entries,
                    newer: state.deviceEntries(),
                  ),
                );
              },
            ),
          if (shortcuts.isNotEmpty) _header(s.t('功能')),
          for (final (label, icon, build) in shortcuts)
            ListTile(
              leading: Icon(icon),
              title: Text(label),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _open(build()),
            ),
          if (nothing)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 40, 16, 0),
              child: Column(
                children: [
                  Icon(Icons.search_off, size: 56, color: Colors.grey.shade400),
                  const SizedBox(height: 10),
                  Text(
                    s.t('没有找到匹配的内容'),
                    style: TextStyle(color: Colors.grey.shade600),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static const _folderKind = TileKind.folder;

  Widget _header(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 12.5,
        fontWeight: FontWeight.w700,
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}
