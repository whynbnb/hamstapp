import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_strings.dart';
import '../services/remote_client.dart';
import '../state/app_state.dart';
import '../utils/app_health.dart';
import '../utils/format.dart';
import '../utils/permissions.dart';
import '../widgets/app_icon.dart';
import 'app_detail_screen.dart';

/// 整理与体检: what the last scans noticed — updates that added permissions,
/// where the installed apps came from, packages that look like each other, and
/// the apps the user hid.
class HealthScreen extends StatefulWidget {
  const HealthScreen({super.key});

  @override
  State<HealthScreen> createState() => _HealthScreenState();
}

class _HealthScreenState extends State<HealthScreen> {
  AppHealthReport? _report;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    setState(() => _loading = true);
    // Signatures live in the facts cache; read them before grouping.
    await state.ensureAppFacts();
    final cache = await RemoteClient.cacheIndexAll();
    if (!mounted) return;

    final apps = [
      for (final a in state.apps)
        HealthApp(
          packageName: a.packageName,
          name: state.displayNameFor(a.packageName),
          signature: state.appFacts[a.packageName]?.signature ?? '',
          isSystem: a.isSystem,
        ),
    ];
    final versions = <String, (List<int>, int)>{};
    for (final e in cache) {
      final pkg = (e['packageName'] as String?) ?? '';
      if (pkg.isEmpty) continue;
      final code = (e['versionCode'] as num?)?.toInt() ?? 0;
      final bytes = (e['size'] as num?)?.toInt() ?? 0;
      final current = versions[pkg] ?? (<int>[], 0);
      versions[pkg] = (<int>[...current.$1, code], current.$2 + bytes);
    }
    setState(() {
      _report = analyzeHealth(
        apps: apps,
        cache: [
          for (final e in versions.entries)
            CachedVersions(
              packageName: e.key,
              versions: e.value.$1,
              bytes: e.value.$2,
            ),
        ],
      );
      _loading = false;
    });
  }

  void _openApp(String packageName) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AppDetailScreen(packageName: packageName),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final s = context.strings;
    final alerts = state.permissionAlerts;
    final report = _report;
    final sources = state.installSourceCounts;
    final hidden = state.hiddenApps;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          s.t('整理与体检'),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            tooltip: s.t('重新检查'),
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading && report == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                if (_loading) const LinearProgressIndicator(minHeight: 2),
                if (alerts.isNotEmpty) ...[
                  _Section(
                    icon: Icons.shield_outlined,
                    title: s.t('更新提醒'),
                    trailing: Text(
                      s.t('{n} 条', {'n': alerts.length}),
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ),
                  for (final alert in alerts)
                    _AlertCard(
                      alert: alert,
                      onOpen: () => _openApp('${alert['pkg']}'),
                      onDismiss: () => state.dismissPermissionAlert(
                        '${alert['pkg']}',
                      ),
                    ),
                  const SizedBox(height: 16),
                ],
                _Section(
                  icon: Icons.move_to_inbox_outlined,
                  title: s.t('安装来源'),
                  trailing: Text(
                    s.t('{n} 个应用', {'n': state.apps.length}),
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade600,
                    ),
                  ),
                ),
                _SourceCard(
                  sources: sources,
                  labelFor: (installer) =>
                      installer.isEmpty ? '' : state.displayNameFor(installer),
                ),
                const SizedBox(height: 16),
                _Section(
                  icon: Icons.content_copy_outlined,
                  title: s.t('重复与相似应用'),
                  trailing: report == null
                      ? null
                      : Text(
                          report.riskyCount > 0
                              ? s.t('{n} 组值得看', {'n': report.riskyCount})
                              : s.t('{n} 组', {'n': report.groupCount}),
                          style: TextStyle(
                            fontSize: 12,
                            color: report.riskyCount > 0
                                ? Theme.of(context).colorScheme.error
                                : Colors.grey.shade600,
                          ),
                        ),
                ),
                if (report != null && report.duplicates.isEmpty)
                  _Hint(s.t('没有发现同名的应用，也没有多个版本的缓存')),
                for (final group in report?.duplicates ?? const <DuplicateGroup>[])
                  _DuplicateCard(
                    group: group,
                    state: state,
                    onOpen: _openApp,
                  ),
                const SizedBox(height: 16),
                _Section(
                  icon: Icons.visibility_off_outlined,
                  title: s.t('隐藏的应用'),
                  trailing: Text(
                    s.t('{n} 个', {'n': hidden.length}),
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade600,
                    ),
                  ),
                ),
                if (hidden.isEmpty)
                  _Hint(s.t('没有隐藏的应用。详情页菜单里可以隐藏，分类与备注会保留。'))
                else
                  for (final app in hidden)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: AppIcon(
                        packageName: app.packageName,
                        label: state.displayNameFor(app.packageName),
                        size: 36,
                      ),
                      title: Text(state.displayNameFor(app.packageName)),
                      subtitle: Text(app.packageName),
                      trailing: IconButton(
                        tooltip: s.t('取消隐藏'),
                        icon: const Icon(Icons.visibility_outlined),
                        onPressed: () =>
                            state.setHidden(app.packageName, false),
                      ),
                      onTap: () => _openApp(app.packageName),
                    ),
              ],
            ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.icon, required this.title, this.trailing});

  final IconData icon;
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 8),
      child: Row(
        children: [
          Icon(icon, size: 18, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text,
      style: TextStyle(fontSize: 12.5, height: 1.35, color: Colors.grey.shade600),
    ),
  );
}

/// One "this update asked for more" entry.
class _AlertCard extends StatelessWidget {
  const _AlertCard({
    required this.alert,
    required this.onOpen,
    required this.onDismiss,
  });

  final Map<String, dynamic> alert;
  final VoidCallback onOpen;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final scheme = Theme.of(context).colorScheme;
    final added = (alert['added'] as List?)?.map((e) => '$e').toList() ??
        const <String>[];
    final signed = alert['signature'] == true;
    final at = (alert['at'] as num?)?.toInt() ?? 0;
    return Card(
      elevation: 0,
      color: scheme.errorContainer.withValues(alpha: 0.28),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${alert['name'] ?? alert['pkg']}',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    Fmt.dateTime(at),
                    style: TextStyle(
                      fontSize: 11.5,
                      color: Colors.grey.shade600,
                    ),
                  ),
                  IconButton(
                    tooltip: s.t('忽略'),
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: onDismiss,
                  ),
                ],
              ),
              if (added.isNotEmpty) ...[
                const SizedBox(height: 2),
                Wrap(
                  spacing: 5,
                  runSpacing: 4,
                  children: [
                    for (final permission in added)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.error.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          s.t(permissionLabel(permission)),
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: scheme.error,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
              if (signed) ...[
                const SizedBox(height: 4),
                Text(
                  s.t('签名证书也变了'),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: scheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Where the installed apps came from, as a small bar list.
class _SourceCard extends StatelessWidget {
  const _SourceCard({required this.sources, required this.labelFor});

  final List<(String, int)> sources;
  final String Function(String installer) labelFor;

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final scheme = Theme.of(context).colorScheme;
    if (sources.isEmpty) {
      return _Hint(s.t('还没有扫描到应用'));
    }
    final total = sources.fold<int>(0, (sum, e) => sum + e.$2);
    final max = sources.first.$2;
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          children: [
            for (final (installer, count) in sources.take(6)) ...[
              Row(
                children: [
                  SizedBox(
                    width: 150,
                    child: Text(
                      installer.isEmpty
                          ? s.t('侧载或系统预装')
                          : (labelFor(installer).isEmpty
                                ? installer
                                : labelFor(installer)),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5),
                    ),
                  ),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: max == 0 ? 0 : count / max,
                        minHeight: 6,
                        backgroundColor: scheme.surfaceContainerHighest,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 44,
                    child: Text(
                      '$count',
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        fontSize: 12,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
            ],
            if (sources.length > 6)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  s.t('还有 {n} 个来源共 {count} 个应用', {
                    'n': sources.length - 6,
                    'count': total - sources.take(6).fold<int>(0, (sum, e) => sum + e.$2),
                  }),
                  style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One same-name group or cache group.
class _DuplicateCard extends StatelessWidget {
  const _DuplicateCard({
    required this.group,
    required this.state,
    required this.onOpen,
  });

  final DuplicateGroup group;
  final AppState state;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final scheme = Theme.of(context).colorScheme;
    final risky = group.signatureMismatch;
    final color = risky ? scheme.error : scheme.onSurfaceVariant;

    if (group.kind == DuplicateKind.similarName) {
      return Card(
        elevation: 0,
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.family_restroom, size: 17, color: color),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      group.label,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    s.t('同签名 · 名字相近'),
                    style: const TextStyle(fontSize: 11.5),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  s.t('通常同一个开发者的不同版本（Lite / Pro）。如果其中一个不是从商店装的，值得看一眼。'),
                  style: const TextStyle(fontSize: 12, height: 1.35),
                ),
              ),
              for (final app in group.apps)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: AppIcon(
                    packageName: app.packageName,
                    label: app.name,
                    size: 32,
                  ),
                  title: Text(app.name, style: const TextStyle(fontSize: 13.5)),
                  subtitle: Text(
                    app.packageName,
                    style: const TextStyle(fontSize: 11.5),
                  ),
                  trailing: const Icon(Icons.chevron_right, size: 18),
                  onTap: () => onOpen(app.packageName),
                ),
            ],
          ),
        ),
      );
    }

    if (group.kind == DuplicateKind.cachedVersions) {
      final name = state.appByPackage(group.label) == null
          ? null
          : state.displayNameFor(group.label);
      return Card(
        elevation: 0,
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
        child: ListTile(
          leading: const Icon(Icons.inventory_2_outlined),
          title: Text(name ?? group.label),
          subtitle: Text(
            s.t('缓存里有 {n} 个版本：{versions}', {
              'n': group.versions.length,
              'versions': group.versions.join(' / '),
            }),
          ),
          trailing: Text(
            Fmt.size(group.bytes),
            style: const TextStyle(fontSize: 12),
          ),
        ),
      );
    }

    return Card(
      elevation: 0,
      color: risky
          ? scheme.errorContainer.withValues(alpha: 0.3)
          : scheme.surfaceContainerHighest.withValues(alpha: 0.35),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  risky ? Icons.gpp_maybe_outlined : Icons.content_copy_outlined,
                  size: 17,
                  color: color,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    group.label,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  risky
                      ? s.t('签名不同')
                      : s.t('{n} 个包', {'n': group.apps.length}),
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: risky ? FontWeight.w700 : FontWeight.w400,
                    color: color,
                  ),
                ),
              ],
            ),
            if (risky)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  s.t('同名但签名不同：至少有一个不是它声称的那个应用，别随便更新或覆盖安装。'),
                  style: TextStyle(fontSize: 12, height: 1.35, color: color),
                ),
              ),
            for (final app in group.apps)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: AppIcon(
                  packageName: app.packageName,
                  label: app.name,
                  size: 32,
                ),
                title: Text(
                  app.isSystem ? s.t('{name}（系统）', {'name': app.name}) : app.name,
                  style: const TextStyle(fontSize: 13.5),
                ),
                subtitle: Text(
                  app.packageName,
                  style: const TextStyle(fontSize: 11.5),
                ),
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: () => onOpen(app.packageName),
              ),
          ],
        ),
      ),
    );
  }
}
