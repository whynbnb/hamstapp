import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_strings.dart';
import '../models/app_info.dart';
import '../services/native_apps.dart';
import '../state/app_state.dart';
import '../widgets/app_icon.dart';

/// Settings for the home-screen widget: preview, the "add to home screen"
/// action, and the one display option the widget itself does not infer.
class HomeWidgetScreen extends StatefulWidget {
  const HomeWidgetScreen({super.key});

  @override
  State<HomeWidgetScreen> createState() => _HomeWidgetScreenState();
}

class _HomeWidgetScreenState extends State<HomeWidgetScreen>
    with WidgetsBindingObserver {
  HomeWidgetStatus _status = const HomeWidgetStatus();
  bool _pinning = false;

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
    // The system's "add widget" dialog is another window; the count is only
    // accurate once we are back in the foreground.
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final status = await NativeApps.homeWidgetStatus();
    if (!mounted) return;
    setState(() => _status = status);
  }

  Future<void> _pin() async {
    if (_pinning) return;
    setState(() => _pinning = true);
    final ok = await NativeApps.requestPinHomeWidget();
    if (!mounted) return;
    setState(() => _pinning = false);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.strings.t('这个桌面不支持直接添加，请长按桌面空白处 → 小组件 → 囤囤')),
        ),
      );
      return;
    }
    await _load();
  }

  Future<void> _push(AppState state) async {
    await state.syncHomeWidget(force: true);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final state = context.watch<AppState>();
    final now = DateTime.now();
    final suggestion = state.homeWidgetSuggestionForHour(now.hour, at: now);
    final title = state.homeWidgetTitleFor(suggestion.kind);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          s.t('桌面小组件'),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            tooltip: s.t('重新推送推荐'),
            icon: const Icon(Icons.refresh),
            onPressed: () => _push(state),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 28),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: _Preview(
              apps: suggestion.apps,
              title: title,
              showLabels: state.widgetShowLabels,
              nameOf: state.displayNameFor,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: Text(
              s.t('把此刻推荐的应用放到桌面。点按图标会直接启动应用，并计入囤囤的启动次数与推荐。'),
              style: TextStyle(
                fontSize: 13,
                height: 1.45,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: Icon(
              _status.count > 0
                  ? Icons.check_circle_outline
                  : Icons.widgets_outlined,
              color: _status.count > 0
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
            title: Text(
              _status.count > 0
                  ? s.t('已添加到桌面 · {n} 个', {'n': _status.count})
                  : s.t('还没有添加到桌面'),
            ),
            subtitle: _status.count == 0 && !_status.canPin
                ? Text(s.t('这个桌面不支持直接添加，请长按桌面空白处 → 小组件 → 囤囤'))
                : null,
          ),
          if (_status.canPin)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: FilledButton.tonalIcon(
                onPressed: _pinning ? null : _pin,
                icon: _pinning
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add_to_home_screen),
                label: Text(s.t('添加到桌面')),
              ),
            ),
          SwitchListTile(
            secondary: const Icon(Icons.label_outline),
            title: Text(s.t('显示应用名称')),
            subtitle: Text(s.t('关闭后只显示图标，更紧凑')),
            value: state.widgetShowLabels,
            onChanged: (value) => state.setWidgetShowLabels(value),
          ),
          const Divider(height: 1),
          _Note(
            icon: Icons.auto_awesome_outlined,
            text: s.t('推荐按你平时启动应用的时间段计算，数据不够时先显示常用应用'),
          ),
          _Note(
            icon: Icons.battery_saver_outlined,
            text: s.t('小组件大约每 30 分钟刷新一次，不使用后台服务'),
          ),
        ],
      ),
    );
  }
}

/// A roughly-to-scale drawing of the widget, filled with the same suggestions
/// the real one is showing right now.
class _Preview extends StatelessWidget {
  const _Preview({
    required this.apps,
    required this.title,
    required this.showLabels,
    required this.nameOf,
  });

  final List<AppInfo> apps;
  final String title;
  final bool showLabels;
  final String Function(String packageName) nameOf;

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const AppIcon(
                packageName: 'me.whynbnb.hamstapp',
                label: '囤囤',
                size: 18,
                showNotificationBadge: false,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                '›',
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (apps.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Center(
                child: Text(
                  s.t('在囤囤里启动几次应用，这里就会出现推荐'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            )
          else
            GridView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              physics: const NeverScrollableScrollPhysics(),
              // Same rule as the widget and 最近 → 推荐: up to four per row, and
              // the row only uses as many columns as there are suggestions.
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: apps.length < 4 ? apps.length : 4,
                crossAxisSpacing: 4,
                mainAxisSpacing: 8,
                mainAxisExtent: showLabels ? 62 : 44,
              ),
              itemCount: apps.length > 8 ? 8 : apps.length,
              itemBuilder: (context, i) {
                final app = apps[i];
                return Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    AppIcon(
                      packageName: app.packageName,
                      label: nameOf(app.packageName),
                      size: 34,
                      showNotificationBadge: false,
                    ),
                    if (showLabels)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          nameOf(app.packageName),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 10),
                        ),
                      ),
                  ],
                );
              },
            ),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            size: 17,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.45,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
