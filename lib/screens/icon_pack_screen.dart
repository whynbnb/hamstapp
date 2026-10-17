import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_strings.dart';
import '../services/native_apps.dart';
import '../state/app_state.dart';

/// Picks an installed icon pack. Only the icons 囤囤 draws are affected — the
/// system launcher keeps its own.
class IconPackScreen extends StatefulWidget {
  const IconPackScreen({super.key});

  @override
  State<IconPackScreen> createState() => _IconPackScreenState();
}

class _IconPackScreenState extends State<IconPackScreen> {
  List<IconPackInfo> _packs = const <IconPackInfo>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final packs = await NativeApps.iconPacks();
    if (!mounted) return;
    setState(() {
      _packs = packs;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: Text(
          s.t('图标包'),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            tooltip: s.t('重新读取'),
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Text(
                    s.t(
                      '只改变囤囤里显示的应用图标，系统桌面不受影响。换图标包会清空图标缓存并重新读取。',
                    ),
                    style: const TextStyle(fontSize: 12.5, height: 1.4),
                  ),
                ),
                _option(
                  context,
                  icon: Icons.phone_android,
                  title: s.t('系统图标'),
                  subtitle: '',
                  selected: state.iconPack.isEmpty,
                  onTap: () => _select(state, ''),
                ),
                for (final pack in _packs)
                  _option(
                    context,
                    icon: Icons.palette_outlined,
                    title: pack.name.isEmpty ? pack.packageName : pack.name,
                    subtitle: [
                      pack.packageName,
                      if (pack.icons > 0) s.t('{n} 个图标', {'n': pack.icons}),
                    ].join(' · '),
                    selected: state.iconPack == pack.packageName,
                    onTap: () => _select(state, pack.packageName),
                  ),
                if (_packs.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
                    child: Text(
                      s.t('没有找到图标包。安装一个支持 launcher 图标包的应用后，这里会出现。'),
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.4,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _option(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(icon, color: selected ? scheme.primary : null),
      title: Text(
        title,
        style: TextStyle(
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
      subtitle: subtitle.isEmpty ? null : Text(subtitle),
      trailing: selected
          ? Icon(Icons.check_circle, color: scheme.primary, size: 20)
          : const Icon(Icons.circle_outlined, size: 20),
      onTap: onTap,
    );
  }

  Future<void> _select(AppState state, String packageName) async {
    if (state.iconPack == packageName) return;
    await state.setIconPack(packageName);
  }
}
