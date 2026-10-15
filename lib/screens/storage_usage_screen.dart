import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_strings.dart';
import '../services/native_apps.dart';
import '../state/app_state.dart';
import '../utils/format.dart';
import '../widgets/app_icon.dart';
import 'app_detail_screen.dart';

/// Which installed apps use the most space: APK + data + cache, biggest first.
///
/// The numbers come from the system's per-app storage statistics, which need
/// "usage access". Without it the screen explains the grant and offers to open
/// the system page instead of showing a misleading zero.
class StorageUsageScreen extends StatefulWidget {
  const StorageUsageScreen({super.key});

  @override
  State<StorageUsageScreen> createState() => _StorageUsageScreenState();
}

class _StorageUsageScreenState extends State<StorageUsageScreen>
    with WidgetsBindingObserver {
  StorageRanking? _ranking;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back from the system's "usage access" screen: read again, so the
    // freshly granted permission takes effect without a manual refresh.
    if (state == AppLifecycleState.resumed &&
        !(_ranking?.permitted ?? false) &&
        !_loading) {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final ranking = await NativeApps.storageRanking();
    if (!mounted) return;
    setState(() {
      _ranking = ranking;
      _loading = false;
    });
  }

  Future<void> _openPermission() async {
    await NativeApps.openUsageAccessSettings();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(context.strings.t('开启后回到这里会自动重新读取')),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final state = context.watch<AppState>();
    final ranking = _ranking;
    final permitted = ranking?.permitted ?? false;
    final entries = ranking?.entries ?? const <StorageRankEntry>[];
    final max = entries.isEmpty ? 0 : entries.first.totalBytes;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          s.t('应用占用'),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            tooltip: s.t('重新统计'),
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : !permitted
          ? _permissionHint(s)
          : entries.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  s.t('没有读到任何应用的占用数据'),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 10),
                  child: Text(
                    s.t('{n} 个应用共 {size}（不含系统组件）', {
                      'n': entries.length,
                      'size': Fmt.storage(
                        entries.fold<int>(0, (a, e) => a + e.totalBytes),
                      ),
                    }),
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                for (final e in entries) _row(s, state, e, max),
              ],
            ),
    );
  }

  Widget _permissionHint(AppStrings s) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.pie_chart_outline, size: 56, color: scheme.primary),
            const SizedBox(height: 14),
            Text(
              s.t('需要「使用情况访问」'),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              s.t(
                '系统只允许被授权的应用读取其它应用的数据与缓存占用。'
                '在接下来的系统设置里找到「囤囤」，打开「允许使用情况访问」。',
              ),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, height: 1.5),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: _openPermission,
              icon: const Icon(Icons.settings_outlined),
              label: Text(s.t('去开启')),
            ),
            const SizedBox(height: 6),
            TextButton(
              onPressed: _load,
              child: Text(s.t('已开启，重新读取')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(
    AppStrings s,
    AppState state,
    StorageRankEntry e,
    int max,
  ) {
    final scheme = Theme.of(context).colorScheme;
    // Prefer the user's own name for the app; fall back to the name the system
    // reported when the app is not in the (possibly unscanned) list.
    final known = state.appByPackage(e.packageName);
    final name = known == null
        ? e.appName
        : state.displayNameFor(e.packageName);
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => AppDetailScreen(packageName: e.packageName),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Row(
            children: [
              AppIcon(
                packageName: e.packageName,
                label: name,
                size: 42,
                showNotificationBadge: false,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Text(
                          Fmt.storage(e.totalBytes),
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 13.5,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    _breakdownBar(e, max),
                    const SizedBox(height: 6),
                    Text(
                      s.t('安装包 {apk} · 数据 {data} · 缓存 {cache}', {
                        'apk': Fmt.storage(e.apkBytes),
                        'data': Fmt.storage(e.dataBytes),
                        'cache': Fmt.storage(e.cacheBytes),
                      }),
                      style: TextStyle(
                        fontSize: 11.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: s.t('去清理'),
                icon: const Icon(Icons.cleaning_services_outlined, size: 20),
                onPressed: () => NativeApps.openAppInfo(e.packageName),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// APK / data / cache proportions of this app, relative to the biggest app on
  /// the list so the bars are comparable at a glance.
  Widget _breakdownBar(StorageRankEntry e, int max) {
    final scheme = Theme.of(context).colorScheme;
    final scale = max <= 0 ? 1.0 : e.totalBytes / max;
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: 7,
        child: FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: scale.clamp(0.02, 1.0).toDouble(),
          child: Row(
            children: [
              _segment(e.apkBytes, scheme.primary),
              _segment(e.dataBytes, scheme.tertiary),
              _segment(e.cacheBytes, scheme.outline),
            ],
          ),
        ),
      ),
    );
  }

  Widget _segment(int bytes, Color color) => Expanded(
    flex: bytes <= 0 ? 1 : bytes,
    child: ColoredBox(color: bytes <= 0 ? Colors.transparent : color),
  );
}
