import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_strings.dart';
import '../models/snapshot.dart';
import '../models/snapshot_diff.dart';
import '../state/app_state.dart';
import '../utils/format.dart';
import '../utils/permissions.dart';
import '../widgets/app_icon.dart';
import '../widgets/uninstall_reason.dart';

class CompareScreen extends StatefulWidget {
  const CompareScreen({
    super.key,
    required this.olderLabel,
    required this.newerLabel,
    required this.older,
    required this.newer,
  });

  final String olderLabel;
  final String newerLabel;
  final List<SnapshotEntry> older;
  final List<SnapshotEntry> newer;

  @override
  State<CompareScreen> createState() => _CompareScreenState();
}

class _CompareScreenState extends State<CompareScreen> {
  late final SnapshotDiff _diff = SnapshotDiff.between(
    Snapshot(id: 'a', name: widget.olderLabel, createdAt: 0, entries: widget.older),
    Snapshot(id: 'b', name: widget.newerLabel, createdAt: 0, entries: widget.newer),
  );

  bool _showUnchanged = false;
  bool _securityOnly = false;

  /// Only the upgrades that changed permissions or the certificate.
  List<DiffItem> get _updatedItems =>
      _securityOnly ? _diff.securityUpdates : _diff.updated;

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final tabs = <Tab>[
      Tab(text: s.t('新增 {n}', {'n': _diff.added.length})),
      Tab(text: s.t('卸载 {n}', {'n': _diff.removed.length})),
      Tab(text: s.t('更新 {n}', {'n': _diff.updated.length})),
    ];

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(s.t('列表差异')),
          bottom: TabBar(
            tabs: tabs,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
          ),
          actions: [
            if (_diff.securityUpdates.isNotEmpty)
              IconButton(
                tooltip: s.t('只看安全相关的变化'),
                isSelected: _securityOnly,
                icon: const Icon(Icons.shield_outlined),
                selectedIcon: const Icon(Icons.shield),
                onPressed: () =>
                    setState(() => _securityOnly = !_securityOnly),
              ),
            IconButton(
              tooltip: _showUnchanged ? s.t('隐藏未变化') : s.t('显示未变化'),
              icon: Icon(_showUnchanged ? Icons.visibility : Icons.visibility_off),
              onPressed: () => setState(() => _showUnchanged = !_showUnchanged),
            ),
          ],
        ),
        body: Column(
          children: [
            _CompareHeader(
              olderLabel: widget.olderLabel,
              newerLabel: widget.newerLabel,
              diff: _diff,
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _DiffList(items: _diff.added, emptyText: s.t('没有新增应用'), unchanged: _showUnchanged ? _diff.unchanged : null),
                  _DiffList(
                    items: _diff.removed,
                    emptyText: s.t('没有卸载应用'),
                    allowUninstallReason: true,
                  ),
                  _DiffList(
                    items: _updatedItems,
                    emptyText: _securityOnly
                        ? s.t('这次升级没有权限或签名的变化')
                        : s.t('没有应用更新'),
                    showVersion: true,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CompareHeader extends StatelessWidget {
  const _CompareHeader({
    required this.olderLabel,
    required this.newerLabel,
    required this.diff,
  });

  final String olderLabel;
  final String newerLabel;
  final SnapshotDiff diff;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  context.strings.t('基准：{label}', {'label': olderLabel}),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              const Icon(Icons.arrow_forward, size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  context.strings.t('对比：{label}', {'label': newerLabel}),
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            context.strings.t(
              '共 {n} 处变化 · 新增 {a} · 卸载 {r} · 更新 {u}',
              {
                'n': diff.changedCount,
                'a': diff.added.length,
                'r': diff.removed.length,
                'u': diff.updated.length,
              },
            ),
            style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
          ),
          if (diff.appsWithNewPermissions > 0 ||
              diff.appsWithSignatureChange > 0) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(
                  Icons.shield_outlined,
                  size: 15,
                  color: scheme.error,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    [
                      if (diff.appsWithNewPermissions > 0)
                        context.strings.t('{n} 个应用新增了权限', {
                          'n': diff.appsWithNewPermissions,
                        }),
                      if (diff.appsWithSignatureChange > 0)
                        context.strings.t('{n} 个应用换了签名', {
                          'n': diff.appsWithSignatureChange,
                        }),
                    ].join(' · '),
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.error,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _DiffList extends StatelessWidget {
  const _DiffList({
    required this.items,
    required this.emptyText,
    this.showVersion = false,
    this.unchanged,
    this.allowUninstallReason = false,
  });

  final List<DiffItem> items;
  final String emptyText;
  final bool showVersion;
  final List<DiffItem>? unchanged;
  final bool allowUninstallReason;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty && (unchanged == null || unchanged!.isEmpty)) {
      return Center(child: Text(emptyText));
    }
    final state = allowUninstallReason ? context.watch<AppState>() : null;
    return ListView(
      children: [
        ...items.map((e) {
          final reason = allowUninstallReason
              ? state!.metaFor(e.packageName).uninstallReason
              : '';
          return _DiffTile(
            item: e,
            showVersion: showVersion,
            uninstallReason: reason,
            onEditReason: allowUninstallReason
                ? () => showUninstallReasonDialog(
                      context,
                      state!,
                      e.packageName,
                      e.appName,
                    )
                : null,
          );
        }),
        if (unchanged != null && unchanged!.isNotEmpty) ...[
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              context.strings.t('未变化 ({n})', {'n': unchanged!.length}),
              style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
            ),
          ),
          ...unchanged!.map((e) => _DiffTile(item: e, showVersion: false)),
        ],
      ],
    );
  }
}

class _DiffTile extends StatelessWidget {
  const _DiffTile({
    required this.item,
    required this.showVersion,
    this.uninstallReason = '',
    this.onEditReason,
  });

  final DiffItem item;
  final bool showVersion;
  final String uninstallReason;
  final VoidCallback? onEditReason;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (item.type) {
      DiffType.added => (Icons.add_circle, Colors.green),
      DiffType.removed => (Icons.remove_circle, Colors.red),
      DiffType.updated => (Icons.upgrade, Colors.blue),
      DiffType.unchanged => (Icons.check_circle_outline, Colors.grey),
    };

    final base = showVersion && item.fromVersion.isNotEmpty
        ? '${item.fromVersion}  →  ${item.toVersion}'
        : '${item.packageName}${item.sizeBytes > 0 ? ' · ${Fmt.size(item.sizeBytes)}' : ''}';

    final details =
        item.type == DiffType.updated && item.hasDetails ? _changes(context) : null;

    return ListTile(
      leading: AppIcon(
        packageName: item.packageName,
        label: item.appName,
        size: 40,
        bytes: item.icon,
      ),
      title: Text(item.appName, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            uninstallReason.isNotEmpty ? '🗑️ $uninstallReason\n$base' : base,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (details != null) ...[
            const SizedBox(height: 6),
            details,
          ],
        ],
      ),
      isThreeLine: uninstallReason.isNotEmpty || details != null,
      trailing: onEditReason != null
          ? IconButton(
              tooltip: uninstallReason.isEmpty
                  ? context.strings.t('添加卸载原因')
                  : context.strings.t('编辑卸载原因'),
              icon: Icon(
                uninstallReason.isEmpty ? Icons.edit_outlined : Icons.check_circle,
                color: uninstallReason.isEmpty ? Colors.grey : Colors.green,
              ),
              onPressed: onEditReason,
            )
          : Icon(icon, color: color),
    );
  }

  /// What the upgrade did beyond bumping the version number: new and dropped
  /// permissions, a replaced certificate, a target-SDK jump, a different
  /// install source or a move to external storage.
  Widget _changes(BuildContext context) {
    final s = context.strings;
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final state = context.read<AppState>();
    final rows = <Widget>[];

    if (item.addedPermissions.isNotEmpty) {
      rows.add(
        _permissionRow(
          context,
          s.t('新增权限'),
          item.addedPermissions,
          scheme.error,
          scheme.errorContainer,
        ),
      );
    }
    if (item.removedPermissions.isNotEmpty) {
      rows.add(
        _permissionRow(
          context,
          s.t('移除权限'),
          item.removedPermissions,
          dark ? Colors.green.shade300 : Colors.green.shade800,
          Colors.green.withValues(alpha: 0.15),
        ),
      );
    }
    if (item.signatureChanged) {
      rows.add(
        _line(
          context,
          Icons.gpp_maybe_outlined,
          scheme.error,
          s.t('签名已变化'),
          '${_short(item.fromSignature)} → ${_short(item.toSignature)}',
        ),
      );
    }
    if (item.fromTargetSdk > 0 &&
        item.toTargetSdk > 0 &&
        item.fromTargetSdk != item.toTargetSdk) {
      rows.add(
        _line(
          context,
          Icons.flag_outlined,
          scheme.onSurfaceVariant,
          'targetSdk',
          '${item.fromTargetSdk} → ${item.toTargetSdk}',
        ),
      );
    }
    if (item.fromInstaller != item.toInstaller) {
      rows.add(
        _line(
          context,
          Icons.move_to_inbox_outlined,
          scheme.onSurfaceVariant,
          s.t('安装来源'),
          '${_installer(state, s, item.fromInstaller)}'
              ' → ${_installer(state, s, item.toInstaller)}',
        ),
      );
    }
    if (item.fromExternal != item.toExternal) {
      rows.add(
        _line(
          context,
          Icons.sd_card_outlined,
          scheme.onSurfaceVariant,
          s.t('安装位置'),
          '${item.fromExternal ? s.t('外部存储') : s.t('内部存储')}'
              ' → ${item.toExternal ? s.t('外部存储') : s.t('内部存储')}',
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: rows,
    );
  }

  Widget _permissionRow(
    BuildContext context,
    String label,
    List<String> permissions,
    Color color,
    Color background,
  ) {
    final s = context.strings;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
          const SizedBox(height: 3),
          Wrap(
            spacing: 5,
            runSpacing: 4,
            children: [
              for (final p in permissions)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: isSensitivePermission(p)
                        ? background
                        : Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest
                            .withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    s.t(permissionLabel(p)),
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: isSensitivePermission(p)
                          ? FontWeight.w700
                          : FontWeight.w400,
                      color: isSensitivePermission(p) ? color : null,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _line(
    BuildContext context,
    IconData icon,
    Color color,
    String label,
    String value,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 5),
          Text(
            '$label ',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  /// The install source as a name when that package is installed, otherwise the
  /// package name itself; '' is a side-load as far as the system knows.
  String _installer(AppState state, AppStrings s, String packageName) {
    if (packageName.isEmpty) return s.t('侧载或未知');
    final app = state.appByPackage(packageName);
    if (app == null) return packageName;
    final label = state.displayNameFor(packageName);
    return label.isEmpty || label == packageName ? packageName : label;
  }

  /// `AB:CD:…:12:34` — enough to compare by eye.
  static String _short(String fingerprint) {
    if (fingerprint.length <= 20) return fingerprint.isEmpty ? '—' : fingerprint;
    return '${fingerprint.substring(0, 10)}…'
        '${fingerprint.substring(fingerprint.length - 8)}';
  }
}
