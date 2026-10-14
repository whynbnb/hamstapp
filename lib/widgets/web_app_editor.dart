import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_strings.dart';
import '../models/web_app.dart';
import '../services/pwa.dart';
import '../state/app_state.dart';

/// What the editor resolved to.
class _Edited {
  const _Edited({required this.name, required this.url, this.site, this.icon});

  final String name;
  final String url;
  final PwaSite? site;
  final Uint8List? icon;
}

/// Adds a web app, or edits an existing one.
///
/// This is how a web app that only lives on the desktop as a browser shortcut
/// gets into the app: the shortcut itself is invisible to everyone but the
/// launcher, so the address is typed in once. The app then reads the site's
/// Web App Manifest — the PWA standard's own description of the app — and takes
/// its name, icon and colours from there instead of asking for them.
Future<void> showWebAppEditor(
  BuildContext context,
  AppState state, {
  WebApp? entry,
}) async {
  final result = await showDialog<_Edited>(
    context: context,
    builder: (_) => _WebAppEditorDialog(entry: entry),
  );
  if (result == null) return;

  if (entry == null) {
    await state.addWebApp(
      url: result.url,
      name: result.name,
      site: result.site,
      iconBytes: result.icon,
    );
  } else {
    final urlChanged = result.url != entry.url;
    await state.updateWebApp(entry.id, name: result.name, url: result.url);
    // A new address means the stored manifest no longer describes the site.
    if (urlChanged) await state.refreshWebApp(entry.id);
  }
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          entry == null
              ? AppStrings.current.t('已添加「{name}」', {'name': result.name})
              : AppStrings.current.t('已保存「{name}」', {'name': result.name}),
        ),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
}

class _WebAppEditorDialog extends StatefulWidget {
  const _WebAppEditorDialog({this.entry});

  final WebApp? entry;

  @override
  State<_WebAppEditorDialog> createState() => _WebAppEditorDialogState();
}

class _WebAppEditorDialogState extends State<_WebAppEditorDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.entry?.name ?? '',
  );
  late final TextEditingController _url = TextEditingController(
    text: widget.entry?.url ?? '',
  );

  bool _identifying = false;
  bool _identified = false;
  PwaSite? _site;
  Uint8List? _icon;
  String _error = '';

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    super.dispose();
  }

  /// Reads the site's manifest and icon, and fills the name in from what the
  /// site says about itself.
  Future<void> _identify() async {
    final url = WebApp.normalizeUrl(_url.text);
    if (!WebApp.isValidUrl(url)) {
      setState(() => _error = context.strings.t('网址看起来不对，例如 example.com'));
      return;
    }
    setState(() {
      _identifying = true;
      _error = '';
    });
    final site = await PwaDiscovery.discover(url);
    Uint8List? bytes;
    if (site != null) {
      bytes = await PwaDiscovery.fetchBestIcon(site);
    }
    if (!mounted) return;
    setState(() {
      _identifying = false;
      _identified = site != null;
      _site = site;
      _icon = bytes;
      if (site == null) {
        _error = context.strings.t('读不到这个网址（网络或站点问题），仍可保存为普通网页');
      } else if (site.name.isNotEmpty && _name.text.trim().isEmpty) {
        // The site's own name, which is what the standard puts in the manifest.
        _name.text = site.name;
      }
    });
  }

  Future<void> _save() async {
    var url = WebApp.normalizeUrl(_url.text);
    if (!WebApp.isValidUrl(url)) {
      setState(() => _error = context.strings.t('网址看起来不对，例如 example.com'));
      return;
    }
    // Not identified yet: try once, so a PWA brings its own name and icon even
    // when the user just pastes an address and hits save.
    if (!_identified && !_identifying) {
      await _identify();
      url = WebApp.normalizeUrl(_url.text);
    }
    if (!mounted) return;
    var name = _name.text.trim();
    if (name.isEmpty) name = _site?.name ?? '';
    if (name.isEmpty) name = Uri.tryParse(url)?.host ?? url;
    Navigator.pop(
      context,
      _Edited(name: name, url: url, site: _site, icon: _icon),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final site = _site;
    return AlertDialog(
      title: Text(
        widget.entry == null ? s.t('添加网页应用') : s.t('编辑网页应用'),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _url,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: s.t('网址'),
                hintText: s.t('例如：zhihu.com'),
                suffixIcon: IconButton(
                  tooltip: s.t('识别'),
                  icon: const Icon(Icons.travel_explore),
                  onPressed: _identifying ? null : _identify,
                ),
              ),
              onSubmitted: (_) => _identify(),
            ),
            const SizedBox(height: 12),
            if (_identifying)
              Row(
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    s.t('正在读取网站信息…'),
                    style: TextStyle(fontSize: 12.5, color: Colors.grey.shade700),
                  ),
                ],
              ),
            if (!_identifying && site != null) _result(s, site),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              decoration: InputDecoration(
                labelText: s.t('名称'),
                hintText: s.t('识别后自动填写，也可以自己改'),
              ),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 10),
            Text(
              s.t('保存后会像普通应用一样放进磁贴、收藏和分类；点按按网站的显示模式打开。'),
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            if (_error.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                _error,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(s.t('取消')),
        ),
        FilledButton(onPressed: _save, child: Text(s.t('保存'))),
      ],
    );
  }

  /// What the standard says about this site, shown before saving.
  Widget _result(AppStrings s, PwaSite site) {
    final icon = _icon;
    final pwa = site.isPwa;
    final manifest = site.manifest;
    final line = !pwa
        ? s.t('没有找到 PWA 清单（manifest），会当作普通网页')
        : s.t('PWA · 显示模式 {mode}', {'mode': site.display});
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.memory(icon, width: 40, height: 40, fit: BoxFit.cover),
            )
          else
            const Icon(Icons.public, size: 40),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  site.name.isEmpty ? site.url : site.name,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  line,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                ),
                if (manifest != null && manifest.description.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    manifest.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                ],
                if (!site.secure) ...[
                  const SizedBox(height: 2),
                  Text(
                    s.t('不是 HTTPS，无法作为 PWA 独立打开'),
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Convenience for menus: the entry backing a synthetic package id.
WebApp? webAppFor(AppState state, String id) => state.webAppById(id);

/// Shared helper so callers do not have to import the state just for this.
Future<void> editWebApp(BuildContext context, String id) async {
  final state = context.read<AppState>();
  final entry = state.webAppById(id);
  if (entry == null) return;
  await showWebAppEditor(context, state, entry: entry);
}
