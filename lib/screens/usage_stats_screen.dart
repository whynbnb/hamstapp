import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_strings.dart';
import '../models/app_info.dart';
import '../state/app_state.dart';
import '../utils/actions.dart';
import '../utils/format.dart';
import '../utils/usage_stats.dart';
import '../widgets/app_icon.dart';
import 'app_detail_screen.dart';

/// Usage trends built from the timestamped launch log: what gets opened the
/// most in a window, what has gone quiet and what was never opened at all.
///
/// The "neglected" section is intentionally *used-then-stopped*, not
/// *least-used*: with hundreds of installed apps the latter would be entirely
/// apps that were never opened. One-off trials are filtered out for the same
/// reason, so the list stays short and actionable.
class UsageStatsScreen extends StatefulWidget {
  const UsageStatsScreen({super.key});

  @override
  State<UsageStatsScreen> createState() => _UsageStatsScreenState();
}

class _UsageStatsScreenState extends State<UsageStatsScreen> {
  static const List<int> _windows = [7, 30, 90];
  int _days = 30;

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final state = context.watch<AppState>();

    final mostUsed = state.mostUsedApps(days: _days);
    final neglected = state.neglectedApps(days: _days);
    final never = state.neverLaunchedApps();
    final total = state.launchesInDays(_days);
    final active = state.activeAppsInDays(_days);
    final neglectedCount = state.neglectedCountInDays(_days);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          s.t('使用趋势'),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: state.launchLog.isEmpty
          ? _EmptyHint(s: s)
          : CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                        child: SegmentedButton<int>(
                          showSelectedIcon: false,
                          segments: [
                            for (final d in _windows)
                              ButtonSegment<int>(
                                value: d,
                                label: Text(s.t('{n} 天', {'n': d})),
                              ),
                          ],
                          selected: {_days},
                          onSelectionChanged: (v) =>
                              setState(() => _days = v.first),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: Text(
                          s.t(
                            '近 {days} 天启动 {total} 次 · 覆盖 {active} 个应用 · 被冷落 {neglected} 个 · 从未启动 {never} 个',
                            {
                              'days': _days,
                              'total': total,
                              'active': active,
                              'neglected': neglectedCount,
                              'never': never.length,
                            },
                          ),
                          style: TextStyle(
                            fontSize: 13,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                ..._section(
                  s.t('最常用'),
                  Icons.trending_up,
                  count: mostUsed.length,
                  children: [
                    for (final e in mostUsed) _usedRow(state, e),
                  ],
                  emptyText: s.t('这段时间还没有启动记录'),
                ),
                ..._section(
                  s.t('被冷落'),
                  Icons.trending_down,
                  subtitle: s.t('曾经常用，近 {days} 天未打开', {'days': _days}),
                  count: neglectedCount,
                  children: [
                    for (final e in neglected) _neglectedRow(state, e),
                  ],
                  footer: neglectedCount > neglected.length
                      ? s.t('仅显示最常用的前 {n} 个', {'n': neglected.length})
                      : null,
                  emptyText: s.t('没有长期搁置的应用'),
                ),
                ..._section(
                  s.t('从未启动'),
                  Icons.fiber_new_outlined,
                  subtitle: s.t('已安装，但从未从囤囤启动过'),
                  count: never.length,
                  children: [
                    for (final a in never) _neverRow(state, a),
                  ],
                  emptyText: s.t('所有应用都至少启动过一次'),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 24)),
              ],
            ),
    );
  }

  List<Widget> _section(
    String title,
    IconData icon, {
    required List<Widget> children,
    required String emptyText,
    String? subtitle,
    String? footer,
    int? count,
  }) {
    return [
      SliverToBoxAdapter(
        child: _SectionHeader(
          title: title,
          icon: icon,
          subtitle: subtitle,
          count: count,
        ),
      ),
      if (children.isEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Text(
              emptyText,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        )
      else
        SliverList.builder(
          itemCount: children.length,
          itemBuilder: (context, i) => children[i],
        ),
      if (footer != null)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Text(
              footer,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
    ];
  }

  Widget _usedRow(AppState state, UsageEntry e) {
    final app = state.appByPackage(e.packageName);
    final name = app?.appName ?? e.packageName;
    return ListTile(
      leading: AppIcon(packageName: e.packageName, label: name),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(context.strings.t('上次 {ago}', {'ago': Fmt.relative(e.lastAt)})),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _CountPill(text: context.strings.t('{n} 次', {'n': e.count})),
          _usageMenu(name, e.packageName),
        ],
      ),
      onTap: () => launchApp(context, e.packageName),
      onLongPress: () => _openDetail(e.packageName),
    );
  }

  Widget _neglectedRow(AppState state, NeglectedEntry e) {
    final app = state.appByPackage(e.packageName);
    final name = app?.appName ?? e.packageName;
    return ListTile(
      leading: AppIcon(packageName: e.packageName, label: name),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        context.strings.t('曾启动 {count} 次 · 上次 {ago}', {
          'count': e.pastCount,
          'ago': Fmt.relative(e.lastAt),
        }),
      ),
      trailing: _usageMenu(name, e.packageName),
      onTap: () => launchApp(context, e.packageName),
      onLongPress: () => _openDetail(e.packageName),
    );
  }

  Widget _usageMenu(String name, String packageName) {
    final s = context.strings;
    return PopupMenuButton<String>(
      tooltip: s.t('更多'),
      onSelected: (v) {
        if (v == 'detail') {
          _openDetail(packageName);
        } else if (v == 'clear') {
          _clearUsage(name, packageName);
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(value: 'detail', child: Text(s.t('查看详情'))),
        PopupMenuItem(value: 'clear', child: Text(s.t('清除使用记录'))),
      ],
    );
  }

  Future<void> _clearUsage(String name, String packageName) async {
    final s = context.strings;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.t('清除「{name}」的使用记录？', {'name': name})),
        content: Text(
          s.t('将删除该应用的启动次数与时间记录，不影响它的分类、原因和备注。'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(s.t('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(s.t('确定')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await context.read<AppState>().clearLaunchHistoryFor(packageName);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(s.t('已清除「{name}」的使用记录', {'name': name}))),
      );
  }

  Widget _neverRow(AppState state, AppInfo app) {
    return ListTile(
      leading: AppIcon(packageName: app.packageName, label: app.appName),
      title: Text(app.appName, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          if (app.firstInstallTime > 0)
            context.strings.t('安装于 {date}', {
              'date': Fmt.day(app.firstInstallTime),
            }),
          Fmt.size(app.sizeBytes),
        ].join(' · '),
      ),
      onTap: () => launchApp(context, app.packageName),
      onLongPress: () => _openDetail(app.packageName),
    );
  }

  void _openDetail(String packageName) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AppDetailScreen(packageName: packageName),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.icon,
    this.subtitle,
    this.count,
  });
  final String title;
  final IconData icon;
  final String? subtitle;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: scheme.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: scheme.primary,
                      ),
                    ),
                    if (count != null && count! > 0) ...[
                      const SizedBox(width: 6),
                      Text(
                        '$count',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle!,
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
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

class _CountPill extends StatelessWidget {
  const _CountPill({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: scheme.onPrimaryContainer,
        ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.s});
  final AppStrings s;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.insights, size: 56),
            const SizedBox(height: 12),
            Text(s.t('还没有启动记录'), style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 6),
            Text(
              s.t('从囤囤里启动应用后，这里会统计最常用、被冷落和从未启动的应用。'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}