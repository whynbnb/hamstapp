import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_strings.dart';
import '../models/remote_source.dart';
import '../services/remote_client.dart';
import '../state/app_state.dart';

/// Create or edit one sync source (FTP / Samba / WebDAV).
class SyncSourceEditScreen extends StatefulWidget {
  const SyncSourceEditScreen({super.key, this.source});

  /// `null` means "create a new source".
  final RemoteSource? source;

  @override
  State<SyncSourceEditScreen> createState() => _SyncSourceEditScreenState();
}

class _SyncSourceEditScreenState extends State<SyncSourceEditScreen> {
  late String _protocol;
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _path;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _domain;
  late bool _anonymous;
  late bool _secure;
  late bool _keepAllVersions;
  bool _busy = false;

  bool get _isNew => widget.source == null;

  @override
  void initState() {
    super.initState();
    final s = widget.source ?? RemoteSource();
    // Normalise legacy/unknown protocol values so the segmented control is valid.
    _protocol = s.isSmb ? 'smb' : (s.isWebdav ? 'webdav' : 'ftp');
    _name = TextEditingController(text: s.name);
    _host = TextEditingController(text: s.host);
    _port = TextEditingController(text: s.port.toString());
    _path = TextEditingController(text: s.path);
    _username = TextEditingController(text: s.username);
    _password = TextEditingController(text: s.password);
    _domain = TextEditingController(text: s.domain);
    _anonymous = s.anonymous;
    _secure = s.secure;
    _keepAllVersions = s.keepAllVersions;
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _path.dispose();
    _username.dispose();
    _password.dispose();
    _domain.dispose();
    super.dispose();
  }

  RemoteSource _build() => RemoteSource(
        id: widget.source?.id ?? '',
        name: _name.text.trim(),
        protocol: _protocol,
        host: _host.text.trim(),
        port: int.tryParse(_port.text.trim()) ??
            RemoteSource.defaultPort(_protocol, secure: _secure),
        path: _path.text.trim(),
        username: _username.text,
        password: _password.text,
        anonymous: _anonymous,
        domain: _domain.text,
        secure: _secure,
        keepAllVersions: _keepAllVersions,
      );

  void _snack(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  void _onProtocolChanged(String p) {
    setState(() {
      if (_port.text.trim() ==
          RemoteSource.defaultPort(_protocol, secure: _secure).toString()) {
        _port.text = RemoteSource.defaultPort(p, secure: _secure).toString();
      }
      _protocol = p;
    });
  }

  void _onSecureChanged(bool v) {
    setState(() {
      if (_port.text.trim() ==
          RemoteSource.defaultPort(_protocol, secure: _secure).toString()) {
        _port.text = RemoteSource.defaultPort(_protocol, secure: v).toString();
      }
      _secure = v;
    });
  }

  Future<void> _save() async {
    final cfg = _build();
    final s = context.strings;
    if (cfg.host.trim().isEmpty || cfg.path.trim().isEmpty) {
      _snack(s.t('请至少填写主机和路径'));
      return;
    }
    final state = context.read<AppState>();
    if (_isNew) {
      await state.addSyncSource(cfg);
    } else {
      await state.updateSyncSource(cfg);
    }
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  Future<void> _test() async {
    final cfg = _build();
    final s = context.strings;
    if (!cfg.configured) {
      _snack(s.t('请先填写主机和路径'));
      return;
    }
    setState(() => _busy = true);
    try {
      final r = await RemoteClient.test(cfg);
      final ok = r['ok'] == true;
      _snack(
        ok
            ? s.t('连接成功，发现 {n} 个 APK', {'n': r['count']})
            : s.t('连接失败：{error}', {
                'error': r['error'] ?? s.t('未知错误'),
              }),
      );
    } catch (e) {
      _snack(s.t('连接失败：{error}', {'error': e}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? s.t('新建同步源') : s.t('编辑同步源'),
            style: const TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          TextButton(
            onPressed: _busy ? null : _test,
            child: Text(s.t('测试连接')),
          ),
          IconButton(
            tooltip: s.t('保存'),
            icon: const Icon(Icons.check),
            onPressed: _busy ? null : _save,
          ),
        ],
        bottom: _busy
            ? const PreferredSize(
                preferredSize: Size.fromHeight(4),
                child: LinearProgressIndicator(minHeight: 3),
              )
            : null,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          TextField(
            controller: _name,
            decoration: InputDecoration(
              labelText: s.t('名称'),
              hintText: s.t('例如 NAS / 路由器共享'),
              helperText: s.t('显示在同步界面的标签页上，留空则用协议名'),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'ftp', label: Text('FTP')),
              ButtonSegment(value: 'smb', label: Text('Samba')),
              ButtonSegment(value: 'webdav', label: Text('WebDAV')),
            ],
            selected: {_protocol},
            onSelectionChanged: (v) => _onProtocolChanged(v.first),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _host,
            decoration: InputDecoration(
              labelText: s.t('主机'),
              hintText: '192.168.1.10 / nas.local',
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _port,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: s.t('端口'),
              helperText: s.t('默认 {port}', {
                'port':
                    RemoteSource.defaultPort(_protocol, secure: _secure),
              }),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _path,
            decoration: InputDecoration(
              labelText: _protocol == 'smb' ? s.t('共享路径') : s.t('远程目录'),
              hintText: _protocol == 'smb' ? 'share/apks' : '/apks',
              helperText: s.t('支持多层目录，会自动递归查找其中的 APK'),
              border: const OutlineInputBorder(),
            ),
          ),
          if (_protocol == 'webdav')
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _secure,
              onChanged: _onSecureChanged,
              title: Text(s.t('使用 HTTPS')),
              subtitle: const Text('WebDAV over TLS'),
            ),
          const SizedBox(height: 8),
          Text(
            s.t('缓存版本'),
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          SegmentedButton<bool>(
            segments: [
              ButtonSegment(
                value: false,
                icon: const Icon(Icons.compress, size: 16),
                label: Text(s.t('仅保留最新版')),
              ),
              ButtonSegment(
                value: true,
                icon: const Icon(Icons.layers_outlined, size: 16),
                label: Text(s.t('全部保留')),
              ),
            ],
            selected: {_keepAllVersions},
            onSelectionChanged: (v) =>
                setState(() => _keepAllVersions = v.first),
          ),
          const SizedBox(height: 6),
          Text(
            s.t('「仅保留最新版」用新版覆盖缓存；「全部保留」保留历史版本以便离线重装。'),
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _anonymous,
            onChanged: (v) => setState(() => _anonymous = v),
            title: Text(s.t('匿名登录')),
            subtitle: Text(s.t('FTP anonymous / SMB 来宾 / WebDAV 无鉴权')),
          ),
          if (!_anonymous) ...[
            TextField(
              controller: _username,
              decoration: InputDecoration(
                labelText: s.t('用户名'),
                helperText: s.t('SMB 可用 域\\用户名（如 WORKGROUP\\why）'),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              obscureText: true,
              decoration: InputDecoration(
                labelText: s.t('密码'),
                border: const OutlineInputBorder(),
              ),
            ),
            if (_protocol == 'smb') ...[
              const SizedBox(height: 12),
              TextField(
                controller: _domain,
                decoration: InputDecoration(
                  labelText: s.t('域 / 工作组（可选）'),
                  hintText: 'WORKGROUP',
                  helperText: s.t('Windows 本地账户或域常需填写，Samba 一般留空'),
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          ],
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _busy ? null : _save,
            icon: const Icon(Icons.save_outlined),
            label: Text(s.t('保存')),
          ),
        ],
      ),
    );
  }
}
