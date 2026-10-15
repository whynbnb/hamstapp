import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_strings.dart';
import '../services/app_log.dart';
import '../services/native_apps.dart';
import '../services/storage_manager.dart';
import '../state/app_state.dart';
import '../utils/format.dart';
import 'orphan_cache_screen.dart';

/// Shows what 囤囤 is using on the device and lets the user drop the parts
/// that are only caches.
///
/// The categories come from [StorageManager]; a category that cannot be read
/// reports zero rather than failing, so the screen never blocks on a broken
/// platform channel.
class StorageManagerScreen extends StatefulWidget {
  const StorageManagerScreen({super.key});

  @override
  State<StorageManagerScreen> createState() => _StorageManagerScreenState();
}

class _StorageManagerScreenState extends State<StorageManagerScreen> {
  /// Latest report; null while measuring or clearing.
  List<StorageUsage>? _report;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final report = await StorageManager.measure();
    if (!mounted) return;
    setState(() => _report = report);
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  static int _bytesIn(List<StorageUsage>? report, StorageCategory category) {
    if (report == null) return 0;
    for (final u in report) {
      if (u.category == category) return u.bytes;
    }
    return 0;
  }

  int _bytesOf(StorageCategory category) => _bytesIn(_report, category);
  int _itemsOf(StorageCategory category) {
    for (final u in _report ?? const <StorageUsage>[]) {
      if (u.category == category) return u.items;
    }
    return 0;
  }

  /// Everything that can go: the sum over the clearable rows.
  int get _clearableBytes => (_report ?? const <StorageUsage>[])
      .where((u) => u.clearable)
      .fold<int>(0, (sum, u) => sum + u.bytes);

  /// Clears one category, re-measures and reports what it freed.
  Future<void> _clear(StorageCategory category) async {
    final s = context.strings;
    final state = context.read<AppState>();
    final before = _bytesOf(category);
    if (!await _confirm(category)) return;
    if (!mounted) return;
    setState(() => _report = null);

    switch (category) {
      case StorageCategory.icons:
        await state.clearIconCache();
      case StorageCategory.scan:
        await state.clearScanCache();
      case StorageCategory.apk:
        try {
          await NativeApps.cacheClear();
        } catch (_) {
          // Nothing was freed, or the channel is unavailable.
        }
      case StorageCategory.temp:
        await StorageManager.clearTemp();
      case StorageCategory.data:
        break;
    }

    final after = await StorageManager.measure();
    if (!mounted) return;
    setState(() => _report = after);
    final freed = (before - _bytesIn(after, category)).clamp(0, before);
    AppLog.instance.log(
      LogModule.apps,
      '存储 · 已清理${_titleFor(category)} · ${Fmt.storage(freed)}',
    );
    _snack(s.t('已清理 {size}', {'size': Fmt.storage(freed)}));
  }

  Future<void> _clearAll() async {
    final s = context.strings;
    final state = context.read<AppState>();
    final before = _clearableBytes;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.strings.t('清理全部缓存')),
        content: Text(
          ctx.strings.t(
            '将清理图标缓存、扫描缓存、APK 缓存和临时文件，共 {size}。'
            '设置、磁贴、分组、快照和网页入口不受影响。',
            {'size': Fmt.storage(before)},
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ctx.strings.t('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(ctx.strings.t('清理')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _report = null);

    await state.clearIconCache();
    await state.clearScanCache();
    try {
      await NativeApps.cacheClear();
    } catch (_) {
      // Ignore: the other categories still get cleared.
    }
    await StorageManager.clearTemp();

    final after = await StorageManager.measure();
    if (!mounted) return;
    setState(() => _report = after);
    final freed = (before - _clearableBytes).clamp(0, before);
    AppLog.instance.log(
      LogModule.apps,
      '存储 · 已清理全部缓存 · ${Fmt.storage(freed)}',
    );
    _snack(s.t('已清理 {size}', {'size': Fmt.storage(freed)}));
  }

  /// Confirms the clears whose cost is not obvious: the APKs have to be
  /// downloaded again. The other caches rebuild quietly.
  Future<bool> _confirm(StorageCategory category) async {
    if (category != StorageCategory.apk) return true;
    final bytes = _bytesOf(category);
    if (bytes <= 0) return false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.strings.t('清理 APK 缓存')),
        content: Text(
          ctx.strings.t('删除 {n} 个已缓存的安装包（{size}）？下次安装会重新下载。', {
            'n': _itemsOf(category),
            'size': Fmt.storage(bytes),
          }),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ctx.strings.t('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(ctx.strings.t('清理')),
          ),
        ],
      ),
    );
    return ok == true;
  }

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final report = _report;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          s.t('存储管理'),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            tooltip: s.t('重新统计'),
            icon: const Icon(Icons.refresh),
            onPressed: report == null ? null : _reload,
          ),
        ],
      ),
      body: report == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              children: [
                _summary(s, report),
                const SizedBox(height: 4),
                for (final u in report)
                  if (u.category != StorageCategory.data)
                    _cacheRow(s, u),
                if (report.any((u) => u.category == StorageCategory.data))
                  _dataRow(
                    s,
                    report.firstWhere(
                      (u) => u.category == StorageCategory.data,
                    ),
                  ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: FilledButton.tonalIcon(
                    onPressed: _clearableBytes > 0 ? _clearAll : null,
                    icon: const Icon(Icons.cleaning_services_outlined),
                    label: Text(
                      s.t('清理全部缓存（{size}）', {
                        'size': Fmt.storage(_clearableBytes),
                      }),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    s.t(
                      '只清理可以重建的缓存，不会删除设置、磁贴、分组、快照和网页入口。',
                    ),
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.5,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const Divider(height: 28),
                ListTile(
                  leading: const Icon(Icons.inventory_2_outlined),
                  title: Text(s.t('APK 缓存明细')),
                  subtitle: Text(s.t('按应用查看、单独安装或删除已缓存的安装包')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const OrphanCacheScreen(),
                      ),
                    );
                    await _reload();
                  },
                ),
              ],
            ),
    );
  }

  Widget _summary(AppStrings s, List<StorageUsage> report) {
    final scheme = Theme.of(context).colorScheme;
    final clearable = report
        .where((u) => u.clearable)
        .fold<int>(0, (sum, u) => sum + u.bytes);
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Row(
          children: [
            Icon(Icons.storage_outlined, color: scheme.primary),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.t('囤囤占用 {size}', {
                      'size': Fmt.storage(
                        report.fold<int>(0, (sum, u) => sum + u.bytes),
                      ),
                    }),
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    s.t('其中 {size} 可清理', {
                      'size': Fmt.storage(clearable),
                    }),
                    style: TextStyle(
                      fontSize: 12.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cacheRow(AppStrings s, StorageUsage u) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(_iconFor(u.category)),
      title: Text(s.t(_titleFor(u.category))),
      subtitle: Text(
        s.t(_detailFor(u.category), {
          'n': u.items,
        }),
        style: const TextStyle(height: 1.35),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            Fmt.storage(u.bytes),
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
          ),
          IconButton(
            tooltip: s.t('清理'),
            icon: const Icon(Icons.delete_outline),
            onPressed: u.bytes > 0 ? () => _clear(u.category) : null,
          ),
        ],
      ),
    );
  }

  Widget _dataRow(AppStrings s, StorageUsage u) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(_iconFor(u.category), color: scheme.onSurfaceVariant),
      title: Text(s.t(_titleFor(u.category))),
      subtitle: Text(
        s.t(_detailFor(u.category), {'n': u.items}),
        style: const TextStyle(height: 1.35),
      ),
      trailing: Text(
        Fmt.storage(u.bytes),
        style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
      ),
    );
  }
}

IconData _iconFor(StorageCategory category) {
  switch (category) {
    case StorageCategory.icons:
      return Icons.image_outlined;
    case StorageCategory.scan:
      return Icons.manage_search;
    case StorageCategory.apk:
      return Icons.download_for_offline_outlined;
    case StorageCategory.temp:
      return Icons.cleaning_services_outlined;
    case StorageCategory.data:
      return Icons.folder_outlined;
  }
}

String _titleFor(StorageCategory category) {
  switch (category) {
    case StorageCategory.icons:
      return '图标缓存';
    case StorageCategory.scan:
      return '应用扫描缓存';
    case StorageCategory.apk:
      return 'APK 缓存';
    case StorageCategory.temp:
      return '临时文件';
    case StorageCategory.data:
      return '其它数据';
  }
}

String _detailFor(StorageCategory category) {
  switch (category) {
    case StorageCategory.icons:
      return '{n} 个应用图标（删除后会在需要时重新读取）';
    case StorageCategory.scan:
      return '上次扫描得到的应用列表（下次启动会重新扫描）';
    case StorageCategory.apk:
      return '{n} 个安装包（下次安装会重新下载）';
    case StorageCategory.temp:
      return '拖入的安装包、分享副本与网页缓存（系统也会自行清理）';
    case StorageCategory.data:
      return '{n} 个数据文件：设置、磁贴、分组、快照、网页入口等，不随缓存清理';
  }
}
