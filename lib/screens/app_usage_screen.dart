import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_strings.dart';
import '../services/native_apps.dart';
import '../state/app_state.dart';
import '../utils/format.dart';
import '../widgets/app_icon.dart';

/// What the system itself recorded: foreground time per app and this month's
/// traffic per app. Both need the "usage access" grant; without it the screen
/// explains that and offers the switch instead of showing zeros.
class AppUsageScreen extends StatefulWidget {
  const AppUsageScreen({super.key});

  @override
  State<AppUsageScreen> createState() => _AppUsageScreenState();
}

class _AppUsageScreenState extends State<AppUsageScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
  AppUsageReport? _usage;
  AppTrafficReport? _traffic;
  bool _loading = true;

  /// 0 = today, 1 = last 7 days, 2 = last 30 days.
  int _window = 1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabs.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Returned from the usage-access screen: read again, so a fresh grant
    // shows up without a restart.
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final usage = await NativeApps.appUsageStats();
    final traffic = await NativeApps.appTraffic();
    if (!mounted) return;
    setState(() {
      _usage = usage;
      _traffic = traffic;
      _loading = false;
    });
  }

  int _millisOf(AppUsageStat s) => switch (_window) {
    0 => s.todayMillis,
    1 => s.weekMillis,
    _ => s.monthMillis,
  };

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final state = context.watch<AppState>();
    final permitted = _usage?.permitted ?? false;
    final usage = [...?_usage?.apps]
      ..sort((a, b) => _millisOf(b).compareTo(_millisOf(a)));
    final shown = usage.where((u) => _millisOf(u) > 0).toList();
    final traffic = [...?_traffic?.apps]
      ..sort((a, b) => b.bytes.compareTo(a.bytes));

    return Scaffold(
      appBar: AppBar(
        title: Text(
          s.t('使用时长与流量'),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            tooltip: s.t('重新读取'),
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: [
            Tab(text: s.t('使用时长')),
            Tab(text: s.t('流量')),
          ],
        ),
      ),
      body: _loading && _usage == null
          ? const Center(child: CircularProgressIndicator())
          : !permitted
          ? _PermissionCard(onOpen: _openPermission)
          : TabBarView(
              controller: _tabs,
              children: [
                Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                      child: SegmentedButton<int>(
                        segments: [
                          ButtonSegment(value: 0, label: Text(s.t('今天'))),
                          ButtonSegment(value: 1, label: Text(s.t('7 天'))),
                          ButtonSegment(value: 2, label: Text(s.t('30 天'))),
                        ],
                        selected: {_window},
                        onSelectionChanged: (v) =>
                            setState(() => _window = v.first),
                      ),
                    ),
                    Expanded(
                      child: shown.isEmpty
                          ? _empty(s.t('这段时间没有使用记录'))
                          : _ranked(
                              count: shown.length,
                              itemBuilder: (i) {
                                final stat = shown[i];
                                final maxMillis = _millisOf(shown.first);
                                return _UsageRow(
                                  packageName: stat.packageName,
                                  name: state.displayNameFor(stat.packageName),
                                  value: Fmt.duration(_millisOf(stat)),
                                  fraction: maxMillis == 0
                                      ? 0
                                      : _millisOf(stat) / maxMillis,
                                  subtitle: s.t('上次使用 {ago}', {
                                    'ago': Fmt.relative(stat.lastUsed),
                                  }),
                                );
                              },
                            ),
                    ),
                  ],
                ),
                traffic.isEmpty
                    ? _empty(s.t('这个月还没有流量记录'))
                    : _ranked(
                        count: traffic.length,
                        itemBuilder: (i) {
                          final stat = traffic[i];
                          final maxBytes = traffic.first.bytes;
                          return _UsageRow(
                            packageName: stat.packageName,
                            name: state.displayNameFor(stat.packageName),
                            value: Fmt.size(stat.bytes),
                            fraction: maxBytes == 0
                                ? 0
                                : stat.bytes / maxBytes,
                            subtitle: s.t('本月 · 移动网络 + Wi-Fi'),
                          );
                        },
                      ),
              ],
            ),
    );
  }

  Future<void> _openPermission() async {
    await NativeApps.openUsageAccessSettings();
  }

  Widget _empty(String text) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(text, style: TextStyle(color: Colors.grey.shade600)),
    ),
  );

  Widget _ranked({
    required int count,
    required Widget Function(int index) itemBuilder,
  }) {
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: count,
      itemBuilder: (context, i) => itemBuilder(i),
    );
  }
}

class _UsageRow extends StatelessWidget {
  const _UsageRow({
    required this.packageName,
    required this.name,
    required this.value,
    required this.fraction,
    required this.subtitle,
  });

  final String packageName;
  final String name;
  final String value;
  final double fraction;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Row(
        children: [
          AppIcon(packageName: packageName, label: name, size: 38),
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
                        style: const TextStyle(fontSize: 13.5),
                      ),
                    ),
                    Text(
                      value,
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: fraction.clamp(0.0, 1.0),
                    minHeight: 5,
                    backgroundColor: scheme.surfaceContainerHighest,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey.shade600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PermissionCard extends StatelessWidget {
  const _PermissionCard({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 40),
        Icon(Icons.insights_outlined, size: 56, color: Colors.grey.shade400),
        const SizedBox(height: 16),
        Text(
          s.t('系统只把使用时长和流量交给获得「使用情况访问」的应用。'),
          textAlign: TextAlign.center,
          style: const TextStyle(height: 1.4),
        ),
        const SizedBox(height: 12),
        Center(
          child: FilledButton.tonalIcon(
            onPressed: onOpen,
            icon: const Icon(Icons.settings_outlined, size: 18),
            label: Text(s.t('开启「使用情况访问」')),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          s.t('开启后回到这里会自动重新读取；不开启也不影响其它功能。'),
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
      ],
    );
  }
}
