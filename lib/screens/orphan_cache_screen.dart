import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_strings.dart';
import '../services/native_apps.dart';
import '../services/remote_client.dart';
import '../state/app_state.dart';
import '../utils/format.dart';
import '../utils/install_helper.dart';
import '../widgets/app_icon.dart';

/// Cached APKs whose package is not currently installed on the device.
///
/// These are the leftovers of apps that were uninstalled (or cached from a
/// source and never installed). They can be installed from the local copy or
/// deleted without needing the original source to be reachable.
class OrphanCacheScreen extends StatefulWidget {
  const OrphanCacheScreen({super.key});

  @override
  State<OrphanCacheScreen> createState() => _OrphanCacheScreenState();
}

class _OrphanCacheScreenState extends State<OrphanCacheScreen> {
  List<Map<String, dynamic>> _entries = [];
  bool _loading = true;
  final Set<String> _busy = {};
  final Map<String, Uint8List?> _icons = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final all = await RemoteClient.cacheIndexAll();
    if (!mounted) return;
    setState(() {
      _entries = all;
      _loading = false;
    });
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _install(Map<String, dynamic> e) async {
    final s = context.strings;
    final key = _keyOf(e);
    final path = (e['localPath'] as String?) ?? '';
    if (path.isEmpty) {
      _snack(s.t('缓存文件不存在'));
      return;
    }
    setState(() => _busy.add(key));
    try {
      final outcome = await installLocalApk(path);
      if (!mounted) return;
      switch (outcome) {
        case InstallOutcome.handedOff:
          _snack(s.t('已交给系统安装器'));
        case InstallOutcome.permissionNeeded:
          _snack(s.t('请先允许「安装未知应用」，然后重试'));
        case InstallOutcome.failed:
          _snack(s.t('无法调起系统安装器'));
      }
    } finally {
      if (mounted) setState(() => _busy.remove(key));
    }
  }

  Future<void> _delete(Map<String, dynamic> e) async {
    final id = (e['id'] as String?) ?? '';
    final freed = id.isNotEmpty
        ? await RemoteClient.deleteCacheById(id)
        : await NativeApps.cacheDelete(
            (e['sourceId'] as String?) ?? 'default',
            (e['path'] as String?) ?? '',
          );
    await _load();
    if (!mounted) return;
    _snack(
      context.strings.t('已删除该项缓存（{size}）', {'size': Fmt.size(freed)}),
    );
  }

  Future<void> _deleteGroup(List<Map<String, dynamic>> group) async {
    var freed = 0;
    for (final e in group) {
      final id = (e['id'] as String?) ?? '';
      freed += id.isNotEmpty
          ? await RemoteClient.deleteCacheById(id)
          : await NativeApps.cacheDelete(
              (e['sourceId'] as String?) ?? 'default',
              (e['path'] as String?) ?? '',
            );
    }
    await _load();
    if (!mounted) return;
    _snack(
      context.strings.t('已删除 {n} 项缓存（{size}）', {
        'n': group.length,
        'size': Fmt.size(freed),
      }),
    );
  }

  String _keyOf(Map<String, dynamic> e) =>
      '${e['sourceId']}::${e['path']}';

  Map<String, List<Map<String, dynamic>>> _grouped(
    List<Map<String, dynamic>> orphans,
  ) {
    final groups = <String, List<Map<String, dynamic>>>{};
    for (final e in orphans) {
      final pkg = (e['packageName'] as String?)?.trim() ?? '';
      final k = pkg.isEmpty
          ? '::${e['sourceId']}::${e['name']}'
          : pkg;
      groups.putIfAbsent(k, () => []).add(e);
    }
    return groups;
  }

  Future<Uint8List?> _iconBytes(String? path) async {
    if (path == null || path.isEmpty) return null;
    if (_icons.containsKey(path)) return _icons[path];
    try {
      final bytes = await File(path).readAsBytes();
      _icons[path] = bytes;
      return bytes;
    } catch (_) {
      _icons[path] = null;
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final state = context.watch<AppState>();
    final installed = {for (final a in state.apps) a.packageName};
    final orphans = _entries.where((e) {
      final pkg = (e['packageName'] as String?)?.trim() ?? '';
      return pkg.isEmpty || !installed.contains(pkg);
    }).toList();
    final groups = _grouped(orphans);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          s.t('孤包列表'),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          if (orphans.isNotEmpty)
            IconButton(
              tooltip: s.t('全部删除'),
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: () => _deleteGroup(orphans),
            ),
          IconButton(
            tooltip: s.t('刷新'),
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : orphans.isEmpty
          ? _Empty(s: s)
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 10),
                  child: Text(
                    s.t('共 {n} 个孤包 · {size}', {
                      'n': groups.length,
                      'size': Fmt.size(
                        orphans.fold<int>(
                          0,
                          (a, e) => a + ((e['size'] as num?)?.toInt() ?? 0),
                        ),
                      ),
                    }),
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                for (final group in groups.values)
                  _groupCard(state, group),
              ],
            ),
    );
  }

  Widget _groupCard(AppState state, List<Map<String, dynamic>> group) {
    final s = context.strings;
    final first = group.first;
    final pkg = (first['packageName'] as String?)?.trim() ?? '';
    final name = (first['appName'] as String?)?.trim().isNotEmpty == true
        ? (first['appName'] as String)
        : (first['name'] as String? ?? '');
    final iconPath = group
        .map((e) => e['iconPath'] as String?)
        .firstWhere((p) => p != null && p.isNotEmpty, orElse: () => null);
    final sources = {for (final e in group) e['sourceId'] as String? ?? ''};
    final total = group.fold<int>(
      0,
      (a, e) => a + ((e['size'] as num?)?.toInt() ?? 0),
    );
    final sorted = [...group]..sort(
      (a, b) => ((b['versionCode'] as num?)?.toInt() ?? 0).compareTo(
        (a['versionCode'] as num?)?.toInt() ?? 0,
      ),
    );

    return Card(
      elevation: 0,
      color: Theme.of(
        context,
      ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(
        children: [
          ListTile(
            leading: iconPath != null
                ? FutureBuilder<Uint8List?>(
                    future: _iconBytes(iconPath),
                    builder: (context, snap) => AppIcon(
                      packageName: pkg,
                      label: name,
                      bytes: snap.data,
                      size: 46,
                    ),
                  )
                : const CircleAvatar(child: Icon(Icons.android)),
            title: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              [
                if (pkg.isNotEmpty) pkg else s.t('未知包名'),
                s.t('{n} 个版本 · {size}', {
                  'n': group.length,
                  'size': Fmt.size(total),
                }),
                if (sources.length == 1 && sources.first.isNotEmpty)
                  s.t('来源：{src}', {'src': _sourceName(state, sources.first)}),
              ].join('\n'),
              style: const TextStyle(height: 1.35),
            ),
            isThreeLine: true,
            trailing: IconButton(
              tooltip: s.t('全部删除'),
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _deleteGroup(group),
            ),
          ),
          const Divider(height: 1),
          for (final e in sorted) _versionRow(e),
        ],
      ),
    );
  }

  Widget _versionRow(Map<String, dynamic> e) {
    final s = context.strings;
    final key = _keyOf(e);
    final busy = _busy.contains(key);
    final version = (e['versionName'] as String?)?.trim() ?? '';
    final code = (e['versionCode'] as num?)?.toInt() ?? 0;
    final title = version.isEmpty
        ? ((e['name'] as String?) ?? '')
        : 'v$version${code > 0 ? ' ($code)' : ''}';
    return ListTile(
      contentPadding: const EdgeInsets.only(left: 16, right: 4),
      dense: true,
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${Fmt.size((e['size'] as num?)?.toInt() ?? 0)}'
        '${((e['modified'] as num?)?.toInt() ?? 0) > 0 ? ' · ${Fmt.relative((e['modified'] as num?)?.toInt() ?? 0)}' : ''}',
        style: const TextStyle(fontSize: 12),
      ),
      trailing: busy
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: s.t('安装'),
                  icon: const Icon(Icons.download_for_offline_outlined),
                  onPressed: () => _install(e),
                ),
                IconButton(
                  tooltip: s.t('删除该项缓存'),
                  icon: const Icon(Icons.close),
                  onPressed: () => _delete(e),
                ),
              ],
            ),
    );
  }

  String _sourceName(AppState state, String id) {
    for (final src in state.syncSources) {
      if (src.id == id) return src.displayName;
    }
    return context.strings.t('已删除的源');
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.s});
  final AppStrings s;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.inventory_2_outlined, size: 56),
            const SizedBox(height: 12),
            Text(
              s.t('没有孤包缓存'),
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 6),
            Text(
              s.t('这里列出已缓存、但当前未安装的 APK，可离线安装或删除。'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}
