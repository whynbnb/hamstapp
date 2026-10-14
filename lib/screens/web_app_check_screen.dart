import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_strings.dart';
import '../services/native_apps.dart';
import '../utils/format.dart';

/// What the scan found out about installed web apps.
///
/// A web app installed from a browser or a store is an ordinary package
/// (WebAPK / Trusted Web Activity), but a browser "add to home screen" may also
/// leave just a shortcut on the desktop — which is not a package at all and
/// cannot be read by anyone but the launcher. This screen shows which of the
/// two the device holds, so "nothing was found" can be told apart from
/// "detection missed one".
class WebAppCheckScreen extends StatefulWidget {
  const WebAppCheckScreen({super.key});

  @override
  State<WebAppCheckScreen> createState() => _WebAppCheckScreenState();
}

class _WebAppCheckScreenState extends State<WebAppCheckScreen> {
  Map<String, dynamic>? _report;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    Map<String, dynamic>? report;
    try {
      // A bridge that never answers must not leave the screen spinning.
      report = await NativeApps.webAppReport().timeout(
        const Duration(seconds: 10),
      );
    } catch (_) {
      report = null;
    }
    if (!mounted) return;
    setState(() {
      _report = report;
      _loading = false;
    });
  }

  List<Map<String, dynamic>> _list(String key) =>
      ((_report?[key] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();

  String _signalLabel(AppStrings s, String signal) {
    switch (signal) {
      case 'entry':
        return s.t('入口类名');
      case 'packageName':
        return s.t('包名');
      case 'small':
        return s.t('APK 很小');
    }
    return signal;
  }

  /// Everything on screen as one plain text block, for handing to a developer.
  String _plainText() {
    final s = AppStrings.current;
    final r = _report;
    final b = StringBuffer()..writeln(s.t('网页应用检测'));
    if (r == null) {
      b.writeln(s.t('读取失败'));
      return b.toString();
    }
    b.writeln(s.t('包 {total} 个 · 用户 {user} · 系统 {system}', {
      'total': '${r['total']}',
      'user': '${r['user']}',
      'system': '${r['system']}',
    }));
    b.writeln(s.t('元数据可读 {meta} · 桌面入口 {entries} · 入口命中 {shells}', {
      'meta': '${r['metaReadable']}',
      'entries': '${r['launcherEntries']}',
      'shells': '${r['shells']}',
    }));
    for (final key in ['webApps', 'candidates']) {
      final items = _list(key);
      b.writeln();
      b.writeln(
        '${key == 'webApps' ? s.t('已识别网页应用') : s.t('疑似网页应用（未确认）')}'
        ' · ${items.length}',
      );
      for (final e in items) {
        b.writeln(
          '  ${e['appName']} | ${e['packageName']} | '
          '${Fmt.size((e['sizeBytes'] as num?)?.toInt() ?? 0)} | '
          '${e['signal'] == null ? '' : '${_signalLabel(s, '${e['signal']}')} '}'
          '${e['activity']} | ${e['webUrl']}',
        );
      }
    }
    return b.toString();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    return Scaffold(
      appBar: AppBar(
        title: Text(s.t('网页应用检测')),
        actions: [
          IconButton(
            tooltip: s.t('复制'),
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: _report == null
                ? null
                : () async {
                    await Clipboard.setData(ClipboardData(text: _plainText()));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context)
                      ..hideCurrentSnackBar()
                      ..showSnackBar(SnackBar(content: Text(s.t('已复制'))));
                  },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _counts(s),
                const SizedBox(height: 16),
                _Section(
                  title: s.t('已识别网页应用'),
                  empty: s.t('未发现网页应用'),
                  items: _list('webApps'),
                  label: (e) => '',
                  s: s,
                ),
                const SizedBox(height: 16),
                _Section(
                  title: s.t('疑似网页应用（未确认）'),
                  empty: s.t('没有可疑的候选'),
                  items: _list('candidates'),
                  label: (e) => _signalLabel(s, '${e['signal']}'),
                  s: s,
                ),
                const SizedBox(height: 16),
                Text(
                  s.t(
                    '说明：浏览器「添加到主屏幕」有时只在桌面留下一个快捷方式，它不是一个应用包，'
                    '系统不允许第三方读取或启动，所以无法纳入。要把它变成真正的网页应用，'
                    '请在浏览器里用「安装应用」（WebAPK / TWA），装好后它会出现在上面的列表里。',
                  ),
                  style: TextStyle(fontSize: 12.5, height: 1.4, color: Colors.grey.shade700),
                ),
              ],
            ),
    );
  }

  Widget _counts(AppStrings s) {
    final r = _report;
    if (r == null) {
      return Card(
        elevation: 0,
        color: Colors.grey.withValues(alpha: 0.08),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(s.t('读取失败')),
        ),
      );
    }
    return Card(
      elevation: 0,
      color: Colors.grey.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(s.t('包 {total} 个 · 用户 {user} · 系统 {system}', {
              'total': '${r['total']}',
              'user': '${r['user']}',
              'system': '${r['system']}',
            }), style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              s.t('元数据可读 {meta} · 桌面入口 {entries} · 入口命中 {shells}', {
                'meta': '${r['metaReadable']}',
                'entries': '${r['launcherEntries']}',
                'shells': '${r['shells']}',
              }),
              style: TextStyle(fontSize: 12.5, color: Colors.grey.shade700),
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.empty,
    required this.items,
    required this.label,
    required this.s,
  });

  final String title;
  final String empty;
  final List<Map<String, dynamic>> items;
  final String Function(Map<String, dynamic>) label;
  final AppStrings s;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$title · ${items.length}',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        if (items.isEmpty)
          Text(empty, style: TextStyle(fontSize: 13, color: Colors.grey.shade700))
        else
          for (final e in items)
            Card(
              elevation: 0,
              color: Colors.grey.withValues(alpha: 0.06),
              child: ListTile(
                dense: true,
                leading: const Icon(Icons.public, size: 20),
                title: Text('${e['appName']}'),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${e['packageName']}',
                        style: const TextStyle(fontSize: 12)),
                    Text(
                      '${Fmt.size((e['sizeBytes'] as num?)?.toInt() ?? 0)}'
                      '${'${e['activity']}'.isEmpty ? '' : ' · ${e['activity']}'}'
                      '${'${e['webUrl']}'.isEmpty ? '' : ' · ${e['webUrl']}'}',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                    ),
                  ],
                ),
                trailing: label(e).isEmpty
                    ? null
                    : Text(label(e), style: const TextStyle(fontSize: 12)),
              ),
            ),
      ],
    );
  }
}
