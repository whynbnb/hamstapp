import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../l10n/app_strings.dart';
import '../models/apk_analysis.dart';
import '../services/native_apps.dart';
import '../utils/format.dart';
import '../utils/install_helper.dart';
import '../widgets/app_icon.dart';

/// Deep APK inspector: open or drop an APK file and see its manifest, signing
/// certificates, permissions, native libs and file hashes — without installing.
class ApkAnalyzerScreen extends StatefulWidget {
  const ApkAnalyzerScreen({super.key, this.initialPath});

  /// When set, the file is analyzed immediately on open (e.g. a cached APK).
  final String? initialPath;

  @override
  State<ApkAnalyzerScreen> createState() => _ApkAnalyzerScreenState();
}

class _ApkAnalyzerScreenState extends State<ApkAnalyzerScreen> {
  ApkAnalysis? _analysis;
  String? _error;
  bool _loading = false;
  bool _dragging = false;
  StreamSubscription<String>? _dropSub;
  StreamSubscription<bool>? _dragSub;

  @override
  void initState() {
    super.initState();
    NativeApps.startListening();
    _dropSub = NativeApps.droppedApks.listen(_analyze);
    _dragSub = NativeApps.apkDragging.listen((v) {
      if (mounted) setState(() => _dragging = v);
    });
    final p = widget.initialPath;
    if (p != null && p.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _analyze(p));
    }
  }

  @override
  void dispose() {
    _dropSub?.cancel();
    _dragSub?.cancel();
    super.dispose();
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _pick() async {
    try {
      final picked = await FilePicker.pickFile(
        dialogTitle: context.strings.t('选择 APK 文件'),
        type: FileType.any,
      );
      if (picked == null) return;
      final path = await _localPathOf(picked);
      if (path == null) {
        if (mounted) _snack(context.strings.t('无法读取所选文件'));
        return;
      }
      await _analyze(path);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<String?> _localPathOf(PlatformFile picked) async {
    final path = picked.path;
    if (path != null && path.isNotEmpty) return path;
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/analyze_${DateTime.now().microsecondsSinceEpoch}.apk');
    await file.writeAsBytes(await picked.readAsBytes(), flush: true);
    return file.path;
  }

  Future<void> _analyze(String path) async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await NativeApps.analyzeApk(path);
      if (!mounted) return;
      setState(() {
        _analysis = result;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is PlatformException ? (e.message ?? e.code) : '$e';
        _loading = false;
      });
    }
  }

  Future<void> _install() async {
    final path = _analysis?.path;
    if (path == null || path.isEmpty) return;
    final s = context.strings;
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

  Future<void> _share() async {
    final a = _analysis;
    if (a == null) return;
    final ok = await NativeApps.shareApk(a.path, name: a.appName);
    if (!ok && mounted) _snack(context.strings.t('导出失败，可能无法读取该应用的 APK'));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final a = _analysis;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          s.t('APK 分析'),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          if (a != null)
            IconButton(
              tooltip: s.t('分享'),
              icon: const Icon(Icons.ios_share),
              onPressed: _share,
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          _DropZone(
            dragging: _dragging,
            hasResult: a != null,
            onPick: _pick,
          ),
          if (_loading) ...[
            const SizedBox(height: 32),
            const Center(child: CircularProgressIndicator()),
            const SizedBox(height: 12),
            Center(child: Text(s.t('正在分析…'))),
          ],
          if (_error != null) ...[
            const SizedBox(height: 16),
            _ErrorCard(
              message: s.t('分析失败：{error}', {'error': _error}),
              onRetry: a == null ? _pick : null,
            ),
          ],
          if (a != null && !_loading) ...[
            const SizedBox(height: 16),
            _Header(a: a),
            const SizedBox(height: 12),
            _InstallBanner(a: a, onInstall: _install),
            const SizedBox(height: 12),
            _FileCard(a: a),
            _BasicCard(a: a),
            _ComponentCard(a: a),
            _SignatureCard(a: a),
            _ListCard(
              title: s.t('权限'),
              icon: Icons.key_outlined,
              values: a.permissions,
              emptyText: s.t('未声明任何权限'),
            ),
            _ListCard(
              title: s.t('功能特性'),
              icon: Icons.extension_outlined,
              values: a.features,
              emptyText: s.t('未声明 uses-feature'),
            ),
            _StructureCard(a: a),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- widgets

class _DropZone extends StatelessWidget {
  const _DropZone({
    required this.dragging,
    required this.hasResult,
    required this.onPick,
  });
  final bool dragging;
  final bool hasResult;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onPick,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: hasResult ? 76 : 168,
        decoration: BoxDecoration(
          color: dragging
              ? scheme.primaryContainer.withValues(alpha: 0.6)
              : scheme.surfaceContainerHighest.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: dragging ? scheme.primary : scheme.outlineVariant,
            width: dragging ? 2 : 1,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              dragging ? Icons.file_download : Icons.upload_file_outlined,
              size: hasResult ? 28 : 44,
              color: scheme.primary,
            ),
            const SizedBox(height: 8),
            Text(
              dragging
                  ? s.t('松开以分析')
                  : (hasResult ? s.t('选择另一个 APK') : s.t('将 APK 拖到这里，或点击选择')),
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
            if (!hasResult) ...[
              const SizedBox(height: 4),
              Text(
                s.t('支持选择本机文件，或从文件管理器拖入'),
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message, this.onRetry});
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: scheme.error),
          const SizedBox(width: 10),
          Expanded(child: Text(message)),
          if (onRetry != null)
            TextButton(onPressed: onRetry, child: Text(context.strings.t('重试'))),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.a});
  final ApkAnalysis a;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppIcon(
          packageName: a.packageName,
          label: a.appName,
          bytes: a.icon,
          size: 60,
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                a.appName.isEmpty ? a.packageName : a.appName,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                a.packageName,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 4),
              Text(
                context.strings.t('版本：{version}（{code}）', {
                  'version': a.versionName.isEmpty ? '—' : a.versionName,
                  'code': a.versionCode,
                }),
                style: const TextStyle(fontSize: 13),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _InstallBanner extends StatelessWidget {
  const _InstallBanner({required this.a, required this.onInstall});
  final ApkAnalysis a;
  final VoidCallback onInstall;

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final scheme = Theme.of(context).colorScheme;
    late final Color color;
    late final IconData icon;
    late final String text;
    if (!a.installed) {
      color = scheme.primary;
      icon = Icons.check_circle_outline;
      text = s.t('未安装该应用');
    } else if (a.conflictsWithInstalled) {
      color = scheme.error;
      icon = Icons.gpp_maybe_outlined;
      text = s.t('签名与已安装版本不一致，无法覆盖安装');
    } else {
      color = Colors.green;
      icon = Icons.verified_outlined;
      text = a.canUpdateInstalled
          ? s.t('签名一致，可覆盖安装（升级）')
          : s.t('签名与已安装版本一致');
    }
    final installedInfo = a.installed
        ? s.t('已安装版本：{version}（{code}）', {
            'version': a.installedVersionName.isEmpty
                ? '—'
                : a.installedVersionName,
            'code': a.installedVersionCode,
          })
        : null;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
                if (installedInfo != null)
                  Text(installedInfo, style: const TextStyle(fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.icon, required this.children});
  final String title;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: scheme.primary),
              const SizedBox(width: 6),
              Text(
                title,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: scheme.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ...children,
        ],
      ),
    );
  }
}

class _KV extends StatelessWidget {
  const _KV({
    required this.label,
    required this.value,
    this.mono = false,
    this.copyable = false,
  });
  final String label;
  final String value;
  final bool mono;
  final bool copyable;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: 13,
      fontFamily: mono ? 'monospace' : null,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 104,
            child: Text(
              label,
              style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
            ),
          ),
          Expanded(
            child: copyable
                ? SelectableText(value.isEmpty ? '—' : value, style: style)
                : Text(value.isEmpty ? '—' : value, style: style),
          ),
          if (copyable && value.isNotEmpty)
            InkWell(
              onTap: () {
                Clipboard.setData(ClipboardData(text: value));
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(
                    SnackBar(content: Text(context.strings.t('已复制'))),
                  );
              },
              child: Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Icon(Icons.copy, size: 15, color: Colors.grey.shade500),
              ),
            ),
        ],
      ),
    );
  }
}

class _BoolRow extends StatelessWidget {
  const _BoolRow(this.label, this.value);
  final String label;
  final bool value;

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    return _KV(label: label, value: value ? s.t('是') : s.t('否'));
  }
}

class _FileCard extends StatelessWidget {
  const _FileCard({required this.a});
  final ApkAnalysis a;

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    return _Card(
      title: s.t('文件'),
      icon: Icons.insert_drive_file_outlined,
      children: [
        _KV(label: s.t('文件名'), value: a.fileName),
        _KV(label: s.t('大小'), value: Fmt.size(a.size)),
        _KV(label: s.t('修改时间'), value: Fmt.dateTime(a.modified)),
        _KV(label: 'SHA-256', value: a.sha256, mono: true, copyable: true),
        _KV(label: 'MD5', value: a.md5, mono: true, copyable: true),
      ],
    );
  }
}

class _BasicCard extends StatelessWidget {
  const _BasicCard({required this.a});
  final ApkAnalysis a;

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    return _Card(
      title: s.t('基本信息'),
      icon: Icons.info_outline,
      children: [
        _KV(label: s.t('版本名'), value: a.versionName),
        _KV(label: s.t('版本号'), value: '${a.versionCode}'),
        _KV(label: s.t('最低 SDK'), value: '${a.minSdk}'),
        _KV(label: s.t('目标 SDK'), value: '${a.targetSdk}'),
        _BoolRow(s.t('可调试'), a.debuggable),
        _BoolRow(s.t('允许备份'), a.allowBackup),
        _BoolRow(s.t('仅测试'), a.testOnly),
        _BoolRow(s.t('允许明文流量'), a.usesCleartextTraffic),
        _BoolRow(s.t('解压原生库'), a.extractNativeLibs),
      ],
    );
  }
}

class _ComponentCard extends StatelessWidget {
  const _ComponentCard({required this.a});
  final ApkAnalysis a;

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    return _Card(
      title: s.t('组件'),
      icon: Icons.widgets_outlined,
      children: [
        _KV(label: s.t('活动'), value: '${a.activityCount}'),
        _KV(label: s.t('服务'), value: '${a.serviceCount}'),
        _KV(label: s.t('广播接收器'), value: '${a.receiverCount}'),
        _KV(label: s.t('内容提供者'), value: '${a.providerCount}'),
      ],
    );
  }
}

class _SignatureCard extends StatelessWidget {
  const _SignatureCard({required this.a});
  final ApkAnalysis a;

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    return _Card(
      title: s.t('签名与证书'),
      icon: Icons.verified_user_outlined,
      children: [
        _BoolRow(s.t('V1 签名'), a.hasV1Signature),
        _KV(label: s.t('证书数量'), value: '${a.signers.length}'),
        _BoolRow(s.t('多重签名'), a.hasMultipleSigners),
        _BoolRow(s.t('签名轮换'), a.hasPastSigningCertificates),
        if (a.signers.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              s.t('未找到签名证书（可能是未签名或解析失败）'),
              style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
            ),
          ),
        for (var i = 0; i < a.signers.length; i++) ...[
          const Divider(height: 18),
          Text(
            s.t('证书 {n}', {'n': i + 1}),
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
          _KV(label: s.t('证书主体'), value: a.signers[i].subject),
          _KV(label: s.t('颁发者'), value: a.signers[i].issuer),
          _KV(label: s.t('序列号'), value: a.signers[i].serialNumber, mono: true),
          _KV(
            label: s.t('签名算法'),
            value: a.signers[i].signatureAlgorithm,
          ),
          _BoolRow(s.t('自签名'), a.signers[i].selfSigned),
          _KV(
            label: s.t('有效期'),
            value: s.t('{from} ~ {to}', {
              'from': Fmt.dateTime(a.signers[i].notBefore),
              'to': Fmt.dateTime(a.signers[i].notAfter),
            }),
          ),
          _KV(
            label: 'SHA-256',
            value: a.signers[i].sha256,
            mono: true,
            copyable: true,
          ),
          _KV(
            label: 'SHA-1',
            value: a.signers[i].sha1,
            mono: true,
            copyable: true,
          ),
        ],
      ],
    );
  }
}

class _ListCard extends StatelessWidget {
  const _ListCard({
    required this.title,
    required this.icon,
    required this.values,
    required this.emptyText,
  });
  final String title;
  final IconData icon;
  final List<String> values;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _Card(
      title: values.isEmpty ? title : '$title（${values.length}）',
      icon: icon,
      children: [
        if (values.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              emptyText,
              style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 6),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final v in values)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      v,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _StructureCard extends StatelessWidget {
  const _StructureCard({required this.a});
  final ApkAnalysis a;

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    return _Card(
      title: s.t('原生库与文件结构'),
      icon: Icons.account_tree_outlined,
      children: [
        _KV(
          label: s.t('原生库 ABI'),
          value: a.abis.isEmpty ? '—' : a.abis.join(', '),
        ),
        _KV(label: s.t('原生库数量'), value: '${a.nativeLibCount}'),
        _KV(label: s.t('DEX 文件'), value: '${a.dexCount}'),
        _KV(label: s.t('DEX 大小'), value: Fmt.size(a.dexBytes)),
        _KV(label: s.t('压缩包条目'), value: '${a.apkEntryCount}'),
        _KV(
          label: s.t('解压后大小'),
          value: Fmt.size(a.apkUncompressedBytes),
        ),
        _BoolRow(s.t('包含 resources.arsc'), a.hasResourcesArsc),
        _BoolRow(s.t('包含 AndroidManifest'), a.hasManifest),
      ],
    );
  }
}
