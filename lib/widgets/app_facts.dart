import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/app_strings.dart';
import '../state/app_state.dart';
import '../services/native_apps.dart';
import '../services/remote_client.dart';
import '../utils/format.dart';

/// Per-app storage: APK, data, cache. The system only hands these numbers to an
/// app with "usage access", so without it the card explains the grant and
/// offers to open the system page rather than showing a bare zero.
class AppStorageCard extends StatefulWidget {
  const AppStorageCard({super.key, required this.packageName});

  final String packageName;

  @override
  State<AppStorageCard> createState() => _AppStorageCardState();
}

class _AppStorageCardState extends State<AppStorageCard>
    with WidgetsBindingObserver {
  AppStorageInfo? _info;
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
    // Returned from the system's "usage access" screen: try again, so a grant
    // made there shows up without the user having to ask.
    if (state == AppLifecycleState.resumed &&
        !(_info?.ok ?? false) &&
        !_loading) {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final info = await NativeApps.appStorage(widget.packageName);
    if (!mounted) return;
    setState(() {
      _info = info;
      _loading = false;
    });
  }

  Future<void> _openPermission() async {
    await NativeApps.openUsageAccessSettings();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final scheme = Theme.of(context).colorScheme;
    final info = _info;

    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.pie_chart_outline, size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Text(
                  s.t('存储占用'),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                if (_loading)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: s.t('重新读取'),
                    icon: const Icon(Icons.refresh, size: 18),
                    onPressed: _load,
                  ),
              ],
            ),
            if (!_loading && info != null) ...[
              if (!info.ok && info.needsPermission) ...[
                Text(
                  s.t('系统只允许被授权的应用读取其它应用的数据与缓存占用。'),
                  style: const TextStyle(fontSize: 12.5, height: 1.4),
                ),
                const SizedBox(height: 8),
                FilledButton.tonalIcon(
                  onPressed: _openPermission,
                  icon: const Icon(Icons.settings_outlined, size: 18),
                  label: Text(s.t('开启「使用情况访问」')),
                ),
              ] else if (!info.ok) ...[
                Text(
                  s.t('这个应用没有可读取的占用数据（{reason}）', {
                    'reason': info.reason,
                  }),
                  style: const TextStyle(fontSize: 12.5, height: 1.4),
                ),
              ] else ...[
                _bar(info),
                const SizedBox(height: 10),
                _line(s, s.t('安装包'), info.apkBytes, scheme.primary),
                _line(s, s.t('数据'), info.dataBytes, scheme.tertiary),
                _line(s, s.t('缓存'), info.cacheBytes, scheme.outline),
                const Divider(height: 14),
                _line(s, s.t('合计'), info.totalBytes, null, bold: true),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => NativeApps.openAppInfo(widget.packageName),
                    icon: const Icon(Icons.cleaning_services_outlined, size: 18),
                    label: Text(s.t('在系统设置里清理')),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  /// APK / data / cache proportions.
  Widget _bar(AppStorageInfo info) {
    final scheme = Theme.of(context).colorScheme;
    Widget seg(int bytes, Color color) => Expanded(
      flex: bytes <= 0 ? 1 : bytes,
      child: ColoredBox(color: bytes <= 0 ? Colors.transparent : color),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: 8,
        child: Row(
          children: [
            seg(info.apkBytes, scheme.primary),
            seg(info.dataBytes, scheme.tertiary),
            seg(info.cacheBytes, scheme.outline),
          ],
        ),
      ),
    );
  }

  Widget _line(
    AppStrings s,
    String label,
    int bytes,
    Color? dot, {
    bool bold = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          if (dot != null) ...[
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ),
          Text(
            Fmt.storage(bytes),
            style: TextStyle(
              fontSize: 13,
              fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

/// The permissions an app requests, dangerous and granted ones first, with a
/// shortcut into the system's permission screen for that app.
class AppPermissionsCard extends StatefulWidget {
  const AppPermissionsCard({super.key, required this.packageName});

  final String packageName;

  @override
  State<AppPermissionsCard> createState() => _AppPermissionsCardState();
}

class _AppPermissionsCardState extends State<AppPermissionsCard> {
  List<PermissionEntry>? _permissions;
  bool _showAll = false;
  bool _loading = true;

  /// Dangerous ones are what the user actually cares about; keep the list short
  /// and put the rest behind "show all".
  static const int _previewCount = 6;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final permissions = await NativeApps.appPermissions(widget.packageName);
    if (!mounted) return;
    setState(() {
      _permissions = permissions;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final scheme = Theme.of(context).colorScheme;
    final all = _permissions ?? const <PermissionEntry>[];
    final dangerous = all.where((p) => p.dangerous).toList();
    final granted = dangerous.where((p) => p.granted).length;
    final shown = _showAll ? all : all.take(_previewCount).toList();

    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.shield_outlined, size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Text(
                  s.t('权限'),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                if (_loading)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            if (!_loading) ...[
              Text(
                all.isEmpty
                    ? s.t('没有声明任何权限')
                    : s.t('申请 {total} 项 · 敏感 {dangerous} 项（已授予 {granted} 项）', {
                        'total': all.length,
                        'dangerous': dangerous.length,
                        'granted': granted,
                      }),
                style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 4),
              for (final p in shown) _row(s, p),
              if (all.length > _previewCount)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => setState(() => _showAll = !_showAll),
                    child: Text(
                      _showAll
                          ? s.t('收起')
                          : s.t('显示全部 {n} 项', {'n': all.length}),
                    ),
                  ),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => NativeApps.openAppInfo(widget.packageName),
                  icon: const Icon(Icons.tune, size: 18),
                  label: Text(s.t('去系统设置里管理')),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _row(AppStrings s, PermissionEntry p) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          if (p.dangerous)
            Container(
              width: 7,
              height: 7,
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(
                color: p.granted ? scheme.error : scheme.outline,
                shape: BoxShape.circle,
              ),
            )
          else
            const SizedBox(width: 15),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p.shortName,
                  style: const TextStyle(fontSize: 13),
                ),
                if (p.group.isNotEmpty)
                  Text(
                    _groupLabel(p.group),
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          Text(
            p.granted ? s.t('已授予') : s.t('未授予'),
            style: TextStyle(
              fontSize: 11.5,
              color: p.granted ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// `android.permission-group.CAMERA` -> `CAMERA`.
  static String _groupLabel(String group) {
    final prefix = 'android.permission-group.';
    return group.startsWith(prefix) ? group.substring(prefix.length) : group;
  }
}

/// The certificate the installed app is signed with, and — when the sync
/// source has a cached APK for it — whether that copy would update in place.
class AppSignatureCard extends StatefulWidget {
  const AppSignatureCard({
    super.key,
    required this.packageName,
    required this.appName,
  });

  final String packageName;
  final String appName;

  @override
  State<AppSignatureCard> createState() => _AppSignatureCardState();
}

class _AppSignatureCardState extends State<AppSignatureCard> {
  SignatureInfo? _signature;
  bool _loading = true;
  bool _comparing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final signature = await NativeApps.appSignature(widget.packageName);
    if (!mounted) return;
    setState(() {
      _signature = signature;
      _loading = false;
    });
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  /// Analyzes the newest cached APK of this package and reports whether its
  /// signature matches the installed app.
  Future<void> _compareWithCache() async {
    final s = context.strings;
    setState(() => _comparing = true);
    try {
      final all = await RemoteClient.cacheIndexAll();
      final mine = all
          .where((e) => (e['packageName'] as String?) == widget.packageName)
          .toList()
        ..sort(
          (a, b) => ((b['versionCode'] as num?)?.toInt() ?? 0).compareTo(
            (a['versionCode'] as num?)?.toInt() ?? 0,
          ),
        );
      if (mine.isEmpty) {
        _snack(s.t('同步源里没有这个应用的安装包'));
        return;
      }
      final path = (mine.first['localPath'] as String?) ?? '';
      if (path.isEmpty) {
        _snack(s.t('缓存文件不存在'));
        return;
      }
      final analysis = await NativeApps.analyzeApk(path);
      if (!mounted) return;
      final same = analysis.sameSignerAsInstalled;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(ctx.strings.t('与缓存安装包的比对')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                ctx.strings.t('缓存：{version}（{code}）', {
                  'version': analysis.versionName,
                  'code': analysis.versionCode,
                }),
              ),
              Text(
                ctx.strings.t('已安装：{version}（{code}）', {
                  'version': analysis.installedVersionName,
                  'code': analysis.installedVersionCode,
                }),
              ),
              const SizedBox(height: 10),
              Text(
                same
                    ? ctx.strings.t('签名一致，可覆盖安装（升级）')
                    : ctx.strings.t('签名与已安装版本不一致，无法覆盖安装'),
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: same
                      ? Theme.of(ctx).colorScheme.primary
                      : Theme.of(ctx).colorScheme.error,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(ctx.strings.t('关闭')),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _comparing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final scheme = Theme.of(context).colorScheme;
    final sig = _signature;

    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.verified_outlined, size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Text(
                  s.t('签名'),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                if (_loading)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            if (!_loading && sig == null)
              Text(
                s.t('读不到签名信息'),
                style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
              ),
            if (!_loading && sig != null) ...[
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  if (sig.system) _chip(s, s.t('系统应用')),
                  if (sig.selfSigned) _chip(s, s.t('自签名')),
                  if (sig.multipleSigners) _chip(s, s.t('多重签名 {n}', {'n': sig.count})),
                  if (sig.rotated) _chip(s, s.t('密钥轮换过')),
                ],
              ),
              const SizedBox(height: 8),
              _kv(
                s.t('证书指纹'),
                _short(sig.sha256),
                onTap: () async {
                  await Clipboard.setData(ClipboardData(text: sig.sha256));
                  _snack(s.t('已复制证书指纹'));
                },
              ),
              if (sig.subject.isNotEmpty) _kv(s.t('证书主体'), sig.subject),
              if (sig.issuer.isNotEmpty && sig.issuer != sig.subject)
                _kv(s.t('颁发者'), sig.issuer),
              if (sig.notAfter > 0) _kv(s.t('有效期至'), Fmt.dateTime(sig.notAfter)),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _comparing ? null : _compareWithCache,
                  icon: _comparing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.compare_arrows, size: 18),
                  label: Text(s.t('与同步源的安装包比对')),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _chip(AppStrings s, String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(text, style: const TextStyle(fontSize: 11.5)),
  );

  Widget _kv(String label, String value, {VoidCallback? onTap}) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 78,
            child: Text(
              label,
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: GestureDetector(
              onTap: onTap,
              child: Text(
                value,
                style: const TextStyle(fontSize: 12.5),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// `AB:CD:…:12:34` — enough to eyeball, full value goes to the clipboard.
  static String _short(String fingerprint) {
    if (fingerprint.length <= 24) return fingerprint;
    return '${fingerprint.substring(0, 12)}…${fingerprint.substring(fingerprint.length - 12)}';
  }
}

/// Where the app came from: the installer the system recorded, plus — on
/// Android 11 and newer — who asked for the install and who it is attributed
/// to. A missing installer is normal for system apps and for anything that was
/// side-loaded, so it says so instead of leaving a blank.
class AppInstallSourceCard extends StatefulWidget {
  const AppInstallSourceCard({super.key, required this.packageName});

  final String packageName;

  @override
  State<AppInstallSourceCard> createState() => _AppInstallSourceCardState();
}

class _AppInstallSourceCardState extends State<AppInstallSourceCard> {
  InstallSource? _source;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final source = await NativeApps.installSource(widget.packageName);
    if (!mounted) return;
    setState(() {
      _source = source;
      _loading = false;
    });
  }

  /// The label of the installer package when it is installed, so a store shows
  /// its name instead of its package. Falls back to the package name.
  String _labelFor(AppState state, String packageName) {
    if (packageName.isEmpty) return '';
    final app = state.appByPackage(packageName);
    if (app == null) return packageName;
    final label = state.displayNameFor(packageName);
    return label.isEmpty || label == packageName
        ? packageName
        : '$label（$packageName）';
  }

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final state = context.read<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final source = _source;

    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.move_to_inbox_outlined,
                    size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Text(
                  s.t('安装来源'),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                if (_loading)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: s.t('重新读取'),
                    icon: const Icon(Icons.refresh, size: 18),
                    onPressed: _load,
                  ),
              ],
            ),
            if (!_loading) ...[
              if (source == null || source.isEmpty) ...[
                Text(
                  s.t('系统没有记录安装者：通常是侧载安装（直接装安装包），或者本来就是系统预装的应用。'),
                  style: const TextStyle(fontSize: 12.5, height: 1.4),
                ),
              ] else ...[
                _row(s, s.t('安装者'), _labelFor(state, source.installer)),
                if (source.initiating.isNotEmpty &&
                    source.initiating != source.installer)
                  _row(s, s.t('发起安装'), _labelFor(state, source.initiating)),
                if (source.originating.isNotEmpty &&
                    source.originating != source.installer)
                  _row(s, s.t('来源应用'), _labelFor(state, source.originating)),
                if (source.installer.isEmpty &&
                    (source.initiating.isNotEmpty ||
                        source.originating.isNotEmpty))
                  Text(
                    s.t('系统没有记录安装者，但记录到了发起安装的应用。'),
                    style: const TextStyle(fontSize: 12.5, height: 1.4),
                  ),
                if (!source.detailed) ...[
                  const SizedBox(height: 4),
                  Text(
                    s.t('Android 11 以下只能读到安装者，无法区分发起安装的应用。'),
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.35,
                      color: Colors.grey.shade600,
                    ),
                  ),
                ],
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _row(AppStrings s, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
            ),
          ),
          Expanded(
            child: GestureDetector(
              onTap: () {
                Clipboard.setData(ClipboardData(text: value));
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(
                    SnackBar(
                      content: Text(s.t('已复制')),
                      duration: const Duration(milliseconds: 1200),
                    ),
                  );
              },
              child: Text(
                value.isEmpty ? s.t('未知') : value,
                style: const TextStyle(fontSize: 13, height: 1.35),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
