import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_strings.dart';
import '../models/app_info.dart';
import '../models/remote_source.dart';
import '../services/remote_client.dart';
import '../state/app_state.dart';
import '../utils/format.dart';
import '../utils/install_helper.dart';
import '../widgets/app_icon.dart';

/// Detail page for one remote APK: full metadata, actions and the other
/// versions of the same package available on the same source.
class RemoteApkDetailScreen extends StatefulWidget {
  const RemoteApkDetailScreen({
    super.key,
    required this.source,
    required this.entry,
    this.siblings = const [],
  });

  final RemoteSource source;
  final Map<String, dynamic> entry;

  /// All APK files discovered on the source, used to list other versions.
  final List<Map<String, dynamic>> siblings;

  @override
  State<RemoteApkDetailScreen> createState() => _RemoteApkDetailScreenState();
}

class _RemoteApkDetailScreenState extends State<RemoteApkDetailScreen> {
  Map<String, Map<String, dynamic>> _cache = {};
  List<Map<String, dynamic>> _history = [];
  final Set<String> _busy = {};
  final Map<String, double?> _progress = {};
  final Map<String, Uint8List?> _icons = {};

  @override
  void initState() {
    super.initState();
    _loadCache();
  }

  Future<void> _loadCache() async {
    final cache = await RemoteClient.cacheIndex(widget.source);
    final all = await RemoteClient.cacheIndexAll();
    if (!mounted) return;
    setState(() {
      _cache = cache;
      _history = all
          .where(
            (e) =>
                e['sourceId'] == widget.source.id && e['historical'] == true,
          )
          .toList();
    });
  }

  String _keyOf(Map<String, dynamic> f) =>
      (f['path'] as String?) ?? (f['name'] as String? ?? '');

  Map<String, dynamic>? _metaOf(Map<String, dynamic> f) => _cache[_keyOf(f)];

  String _pkgOf(Map<String, dynamic> f, AppState state) {
    final cached = (_metaOf(f)?['packageName'] as String?)?.trim() ?? '';
    if (cached.isNotEmpty) return cached;
    final name = (f['name'] as String?) ?? '';
    return _matchInstalled(state.apps, name)?.packageName ?? '';
  }

  String _titleOf(Map<String, dynamic> f) {
    final apkName = (_metaOf(f)?['appName'] as String?)?.trim() ?? '';
    if (apkName.isNotEmpty) return apkName;
    return (f['name'] as String?) ?? '';
  }

  Future<void> _download(Map<String, dynamic> f, {bool force = false}) async {
    final key = _keyOf(f);
    setState(() {
      _busy.add(key);
      _progress[key] = 0;
    });
    try {
      await RemoteClient.download(
        widget.source,
        f,
        force: force,
        onProgress: (received, total) {
          if (!mounted || !_busy.contains(key)) return;
          setState(() {
            _progress[key] =
                total > 0 ? (received / total).clamp(0.0, 1.0) : null;
          });
        },
      );
      await _loadCache();
    } finally {
      if (mounted) {
        setState(() {
          _busy.remove(key);
          _progress.remove(key);
        });
      }
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _install(Map<String, dynamic> f) async {
    final s = context.strings;
    try {
      await _download(f);
      final path = (_metaOf(f)?['localPath'] as String?) ?? '';
      if (path.isEmpty) throw StateError(s.t('无法读取缓存文件'));
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
    } catch (e) {
      _snack(s.t('安装失败：{error}', {'error': e}));
    }
  }

  Future<void> _fetch(Map<String, dynamic> f, {bool force = false}) async {
    final s = context.strings;
    try {
      await _download(f, force: force);
      _snack(s.t('已获取 APK 信息'));
    } catch (e) {
      _snack(s.t('获取信息失败：{error}', {'error': e}));
    }
  }

  Future<void> _deleteCache(Map<String, dynamic> f) async {
    final freed = await RemoteClient.deleteCache(widget.source, _keyOf(f));
    await _loadCache();
    if (!mounted) return;
    _snack(
      context.strings.t('已删除该项缓存（{size}）', {'size': Fmt.size(freed)}),
    );
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
    final state = context.watch<AppState>();
    final s = context.strings;
    final entry = widget.entry;
    final meta = _metaOf(entry);
    final pkg = _pkgOf(entry, state);
    final installed = pkg.isNotEmpty ? state.appByPackage(pkg) : null;
    final versions = _versions(state, pkg);
    final history = pkg.isEmpty
        ? const <Map<String, dynamic>>[]
        : _history
              .where((e) => ((e['packageName'] as String?) ?? '') == pkg)
              .toList();
    final cachedForEntry = meta != null;
    final key = _keyOf(entry);
    final busy = _busy.contains(key);

    return Scaffold(
      appBar: AppBar(
        title: Text(_titleOf(entry), overflow: TextOverflow.ellipsis),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _header(state, entry, meta, pkg, installed),
          const SizedBox(height: 16),
          if (busy)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: LinearProgressIndicator(),
            ),
          _actions(entry, installed, cached: cachedForEntry),
          const SizedBox(height: 22),
          _sectionTitle(s.t('文件信息')),
          _infoCard([
            (s.t('文件名'), (entry['name'] as String?) ?? ''),
            (s.t('相对路径'), (entry['rel'] as String?) ?? ''),
            (s.t('远程路径'), (entry['path'] as String?) ?? ''),
            (s.t('来源'), widget.source.displayName),
            (s.t('大小'), Fmt.size((entry['size'] as num?)?.toInt() ?? 0)),
            (
              s.t('远程修改时间'),
              Fmt.dateTime((entry['modified'] as num?)?.toInt() ?? 0),
            ),
          ]),
          const SizedBox(height: 22),
          _sectionTitle(s.t('APK 信息')),
          if (meta == null)
            Text(
              s.t('尚未解析，点「获取信息」后可查看包名、版本等，并参与版本归组'),
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            )
          else
            _infoCard([
              (s.t('应用名'), (meta['appName'] as String?) ?? ''),
              (s.t('包名'), (meta['packageName'] as String?) ?? ''),
              (s.t('版本名'), (meta['versionName'] as String?) ?? ''),
              (s.t('版本号'), '${(meta['versionCode'] as num?)?.toInt() ?? 0}'),
              ('minSdk', '${(meta['minSdk'] as num?)?.toInt() ?? 0}'),
              ('targetSdk', '${(meta['targetSdk'] as num?)?.toInt() ?? 0}'),
              (s.t('本地缓存'), (meta['localPath'] as String?) ?? ''),
            ]),
          if (installed != null) ...[
            const SizedBox(height: 22),
            _sectionTitle(s.t('已安装')),
            _infoCard([
              (s.t('应用名'), installed.appName),
              (s.t('版本名'), installed.versionName),
              (s.t('版本号'), '${installed.versionCode}'),
            ]),
          ],
          const SizedBox(height: 22),
          _sectionTitle(
            pkg.isEmpty
                ? s.t('历史版本（先获取信息以归组）')
                : s.t('历史版本 · {n} 个', {
                    'n': versions.length + history.length,
                  }),
          ),
          ...versions.map(
            (f) => _versionTile(state, f, installed, current: f == entry),
          ),
          ...history.map(_historyTile),
        ],
      ),
    );
  }

  List<Map<String, dynamic>> _versions(AppState state, String pkg) {
    if (pkg.isEmpty) return [widget.entry];
    final list = widget.siblings.where((f) => _pkgOf(f, state) == pkg).toList();
    if (list.isEmpty) list.add(widget.entry);
    list.sort((a, b) {
      final ca = (_metaOf(a)?['versionCode'] as num?)?.toInt() ?? 0;
      final cb = (_metaOf(b)?['versionCode'] as num?)?.toInt() ?? 0;
      if (ca != cb) return cb.compareTo(ca);
      return ((b['modified'] as num?)?.toInt() ?? 0).compareTo(
        (a['modified'] as num?)?.toInt() ?? 0,
      );
    });
    return list;
  }

  Widget _header(
    AppState state,
    Map<String, dynamic> entry,
    Map<String, dynamic>? meta,
    String pkg,
    AppInfo? installed,
  ) {
    final status = _status(installed, meta);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _leading(meta, installed),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _titleOf(entry),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (pkg.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  pkg,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ],
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: status.$2.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  status.$1,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: status.$2,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _actions(
    Map<String, dynamic> entry,
    AppInfo? installed, {
    required bool cached,
  }) {
    final s = context.strings;
    final key = _keyOf(entry);
    final busy = _busy.contains(key);
    final progress = _progress[key];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: busy ? null : () => _install(entry),
          icon: const Icon(Icons.download_for_offline_outlined),
          label: Text(
            installed == null ? s.t('安装') : s.t('更新 / 覆盖安装'),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: busy ? null : () => _fetch(entry, force: cached),
                icon: const Icon(Icons.refresh),
                label: Text(
                  cached ? s.t('刷新 APK 信息') : s.t('获取 APK 信息'),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: cached && !busy ? () => _deleteCache(entry) : null,
                icon: const Icon(Icons.delete_outline),
                label: Text(s.t('删除缓存')),
              ),
            ),
          ],
        ),
        if (busy && progress != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: LinearProgressIndicator(value: progress, minHeight: 3),
          ),
      ],
    );
  }

  Widget _versionTile(
    AppState state,
    Map<String, dynamic> f,
    AppInfo? installed, {
    required bool current,
  }) {
    final s = context.strings;
    final meta = _metaOf(f);
    final cached = meta != null;
    final key = _keyOf(f);
    final busy = _busy.contains(key);
    final progress = _progress[key];
    final version = (meta?['versionName'] as String?)?.trim() ?? '';
    final code = (meta?['versionCode'] as num?)?.toInt() ?? 0;
    final title = version.isEmpty
        ? ((f['name'] as String?) ?? '')
        : 'v$version${code > 0 ? ' ($code)' : ''}';
    final subtitle = <String>[
      (f['name'] as String?) ?? '',
      Fmt.size((f['size'] as num?)?.toInt() ?? 0) +
          (((f['modified'] as num?)?.toInt() ?? 0) > 0
              ? ' · ${Fmt.relative((f['modified'] as num?)?.toInt() ?? 0)}'
              : ''),
      cached ? s.t('已缓存') : s.t('未缓存'),
    ];
    return Card(
      elevation: 0,
      color: current
          ? Theme.of(context).colorScheme.primaryContainer.withValues(
              alpha: 0.35,
            )
          : Theme.of(context).colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.4,
            ),
      child: Column(
        children: [
          ListTile(
            contentPadding: const EdgeInsets.only(left: 12, right: 4),
            leading: Icon(
              current ? Icons.radio_button_checked : Icons.history,
              color: current ? Theme.of(context).colorScheme.primary : null,
            ),
            title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              subtitle.join('\n'),
              style: const TextStyle(height: 1.35),
            ),
            isThreeLine: true,
            trailing: busy
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : _versionMenu(f, cached: cached),
          ),
          if (busy && progress != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: LinearProgressIndicator(value: progress, minHeight: 3),
            ),
        ],
      ),
    );
  }

  Future<void> _installCached(Map<String, dynamic> e) async {
    final s = context.strings;
    final path = (e['localPath'] as String?) ?? '';
    if (path.isEmpty) {
      _snack(s.t('缓存文件不存在'));
      return;
    }
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
  }

  Future<void> _deleteHistory(Map<String, dynamic> e) async {
    final id = (e['id'] as String?) ?? '';
    final freed = await RemoteClient.deleteCacheById(id);
    await _loadCache();
    if (!mounted) return;
    _snack(
      context.strings.t('已删除该项缓存（{size}）', {'size': Fmt.size(freed)}),
    );
  }

  Widget _historyTile(Map<String, dynamic> e) {
    final s = context.strings;
    final key = (e['id'] as String?) ?? '';
    final busy = _busy.contains(key);
    final version = (e['versionName'] as String?)?.trim() ?? '';
    final code = (e['versionCode'] as num?)?.toInt() ?? 0;
    final title = version.isEmpty
        ? ((e['name'] as String?) ?? '')
        : 'v$version${code > 0 ? ' ($code)' : ''}';
    return Card(
      elevation: 0,
      color: Theme.of(
        context,
      ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
      child: ListTile(
        contentPadding: const EdgeInsets.only(left: 12, right: 4),
        leading: Icon(
          Icons.inventory_2_outlined,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          [
            (e['name'] as String?) ?? '',
            Fmt.size((e['size'] as num?)?.toInt() ?? 0),
            s.t('历史缓存'),
          ].join('\n'),
          style: const TextStyle(height: 1.35),
        ),
        isThreeLine: true,
        trailing: busy
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: s.t('安装'),
                    icon: const Icon(Icons.download_for_offline_outlined),
                    onPressed: () => _installCached(e),
                  ),
                  IconButton(
                    tooltip: s.t('删除该项缓存'),
                    icon: const Icon(Icons.close),
                    onPressed: () => _deleteHistory(e),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _versionMenu(Map<String, dynamic> f, {required bool cached}) {
    final s = context.strings;
    return PopupMenuButton<String>(
      tooltip: s.t('更多'),
      icon: const Icon(Icons.more_vert),
      onSelected: (v) {
        switch (v) {
          case 'install':
            _install(f);
          case 'info':
            _fetch(f);
          case 'refresh':
            _fetch(f, force: true);
          case 'delete':
            _deleteCache(f);
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'install',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.download_for_offline_outlined),
            title: Text(s.t('安装此版本')),
          ),
        ),
        PopupMenuItem(
          value: 'info',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.info_outline),
            title: Text(s.t(cached ? '刷新 APK 信息' : '获取 APK 信息')),
          ),
        ),
        if (cached)
          PopupMenuItem(
            value: 'refresh',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.refresh),
              title: Text(s.t('忽略缓存重新获取')),
            ),
          ),
        if (cached)
          PopupMenuItem(
            value: 'delete',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.delete_outline),
              title: Text(s.t('删除该项缓存')),
            ),
          ),
      ],
    );
  }

  Widget _leading(Map<String, dynamic>? meta, AppInfo? installed) {
    if (installed != null) {
      return AppIcon(packageName: installed.packageName, label: installed.appName, size: 64);
    }
    final iconPath = meta?['iconPath'] as String?;
    if (iconPath != null && iconPath.isNotEmpty) {
      return FutureBuilder<Uint8List?>(
        future: _iconBytes(iconPath),
        builder: (context, snap) => AppIcon(
          packageName: (meta?['packageName'] as String?) ?? '',
          label: (meta?['appName'] as String?) ?? '',
          bytes: snap.data,
          size: 64,
        ),
      );
    }
    return const CircleAvatar(
      radius: 32,
      child: Icon(Icons.android, size: 32),
    );
  }

  (String, Color) _status(AppInfo? installed, Map<String, dynamic>? meta) {
    final s = context.strings;
    final scheme = Theme.of(context).colorScheme;
    final code = (meta?['versionCode'] as num?)?.toInt() ?? 0;
    if (installed == null) {
      return (s.t('新安装'), scheme.primary);
    }
    if (meta == null || code <= 0) {
      return (s.t('更新（版本未知）'), Colors.orange);
    }
    if (code > installed.versionCode) {
      return (
        s.t('可更新 {from} → {to}', {
          'from': 'v${installed.versionName}',
          'to': code,
        }),
        Colors.green,
      );
    }
    if (code == installed.versionCode) {
      return (s.t('已是最新 ({version})', {'version': installed.versionName}), scheme.onSurfaceVariant);
    }
    return (
      s.t('已安装更高版本 ({version})', {'version': installed.versionName}),
      Colors.redAccent,
    );
  }

  Widget _sectionTitle(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text,
      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
    ),
  );

  Widget _infoCard(List<(String, String)> rows) {
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(
        alpha: 0.4,
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            for (final r in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 92,
                      child: Text(
                        r.$1,
                        style: TextStyle(
                          color: Colors.grey.shade600,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    Expanded(
                      child: SelectableText(
                        r.$2.isEmpty ? '—' : r.$2,
                        style: const TextStyle(fontSize: 13),
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

  static AppInfo? _matchInstalled(List<AppInfo> apps, String fileName) {
    final lower = fileName.toLowerCase();
    for (final a in apps) {
      final pkg = a.packageName.toLowerCase();
      if (pkg.isNotEmpty && lower.contains(pkg)) return a;
    }
    return null;
  }
}
