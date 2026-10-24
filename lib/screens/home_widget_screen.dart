import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_strings.dart';
import '../models/app_info.dart';
import '../models/tile_page.dart';
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
  HomeWidgetStatus _pagesStatus = const HomeWidgetStatus();
  bool _pinning = false;
  bool _pinningPages = false;

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
    final pages = await NativeApps.homeWidgetStatus(target: 'pages');
    if (!mounted) return;
    setState(() {
      _status = status;
      _pagesStatus = pages;
    });
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

  Future<void> _pinPages() async {
    if (_pinningPages) return;
    setState(() => _pinningPages = true);
    final ok = await NativeApps.requestPinHomeWidget(target: 'pages');
    if (!mounted) return;
    setState(() => _pinningPages = false);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.strings.t('这个桌面不支持直接添加，请长按桌面空白处 → 小组件 → 囤囤'),
          ),
        ),
      );
      return;
    }
    await _load();
  }

  Future<void> _push(AppState state) async {
    // An explicit refresh is allowed to change the hour's layout.
    await state.refreshHomeWidgetNow();
    await state.syncPageWidget();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final state = context.watch<AppState>();
    final suggestion = state.homeWidgetNow();
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
              maxApps: state.widgetMaxApps,
              roundedIcons: state.widgetRoundedIcons,
              layout: state.widgetLayout,
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
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
            child: Text(
              s.t('小组件选项'),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.label_outline),
            title: Text(s.t('显示应用名称')),
            subtitle: Text(s.t('关闭后只显示图标，更紧凑')),
            value: state.widgetShowLabels,
            onChanged: (value) => state.setWidgetShowLabels(value),
          ),
          ListTile(
            leading: const Icon(Icons.grid_view_outlined),
            title: Text(s.t('显示个数')),
            subtitle: Text(s.t('最多显示 {n} 个', {'n': state.widgetMaxApps})),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(56, 0, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SegmentedButton<int>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment<int>(value: 4, label: Text('4')),
                  ButtonSegment<int>(value: 6, label: Text('6')),
                  ButtonSegment<int>(value: 8, label: Text('8')),
                ],
                selected: {state.widgetMaxApps},
                onSelectionChanged: (values) =>
                    state.setWidgetMaxApps(values.first),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.view_column_outlined),
            title: Text(s.t('布局风格')),
            subtitle: Text(s.t('数量不足一行时的排布方式')),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(56, 0, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SegmentedButton<String>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment<String>(
                    value: 'spread',
                    label: Text(s.t('均分')),
                  ),
                  ButtonSegment<String>(value: 'left', label: Text(s.t('居左'))),
                  ButtonSegment<String>(value: 'edges', label: Text(s.t('两端'))),
                ],
                selected: {state.widgetLayout},
                onSelectionChanged: (values) =>
                    state.setWidgetLayout(values.first),
              ),
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.rounded_corner),
            title: Text(s.t('圆角图标')),
            subtitle: Text(s.t('裁成圆角方块，默认保留应用自己的形状')),
            value: state.widgetRoundedIcons,
            onChanged: (value) => state.setWidgetRoundedIcons(value),
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
          const Divider(height: 32),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: Row(
              children: [
                Icon(
                  Icons.view_carousel_outlined,
                  size: 18,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  s.t('磁贴页标签条'),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '4×1',
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: _PageBarPreview(
              pages: state.tilePages,
              current: state.currentTilePageIndex,
              marker: state.pageBarMarker,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: Text(
              s.t('4×1 的小长条，显示磁贴页标签；点标签直接跳到那一页，标签太多时出现「…」'),
              style: TextStyle(
                fontSize: 12.5,
                height: 1.45,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.circle_outlined),
            title: Text(s.t('选中样式')),
            subtitle: Text(s.t('当前页的标记方式')),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(56, 0, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SegmentedButton<String>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment<String>(
                    value: 'pill',
                    label: Text(s.t('高亮框')),
                  ),
                  ButtonSegment<String>(
                    value: 'dot',
                    label: Text(s.t('小圆点')),
                  ),
                ],
                selected: {state.pageBarMarker},
                onSelectionChanged: (values) =>
                    state.setPageBarMarker(values.first),
              ),
            ),
          ),
          ListTile(
            leading: Icon(
              _pagesStatus.count > 0
                  ? Icons.check_circle_outline
                  : Icons.view_week_outlined,
              color: _pagesStatus.count > 0
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
            title: Text(
              _pagesStatus.count > 0
                  ? s.t('已添加标签条 · {n} 个', {'n': _pagesStatus.count})
                  : s.t('还没有添加标签条'),
            ),
            subtitle: _pagesStatus.count == 0 && !_pagesStatus.canPin
                ? Text(s.t('这个桌面不支持直接添加，请长按桌面空白处 → 小组件 → 囤囤'))
                : null,
          ),
          if (_pagesStatus.canPin)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: FilledButton.tonalIcon(
                onPressed: _pinningPages ? null : _pinPages,
                icon: _pinningPages
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add_to_home_screen),
                label: Text(s.t('添加标签条到桌面')),
              ),
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
    required this.maxApps,
    required this.roundedIcons,
    required this.layout,
    required this.nameOf,
  });

  final List<AppInfo> apps;
  final String title;
  final bool showLabels;
  final int maxApps;
  final bool roundedIcons;
  final String layout;
  final String Function(String packageName) nameOf;

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final scheme = Theme.of(context).colorScheme;
    final shown = apps.take(maxApps).toList();

    Widget cell(AppInfo app) {
      Widget icon = AppIcon(
        packageName: app.packageName,
        label: nameOf(app.packageName),
        size: 38,
        showNotificationBadge: false,
      );
      if (roundedIcons) {
        icon = ClipRRect(
          borderRadius: BorderRadius.circular(38 * 0.22),
          child: icon,
        );
      }
      return Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          icon,
          if (showLabels)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                nameOf(app.packageName),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11),
              ),
            ),
        ],
      );
    }

    // Mirrors the widget's row rules for the chosen style.
    const columns = 4;

    Widget? edgeCell(List<AppInfo> items, int column) {
      final count = items.length;
      int? slot;
      if (count == 1) {
        slot = column == columns ~/ 2 ? 0 : null;
      } else if (column == columns - 1) {
        slot = count >= 2 ? count - 1 : null;
      } else if (column < count - 1) {
        slot = column;
      }
      if (slot == null) return null;
      return Align(
        alignment: column == 0
            ? Alignment.centerLeft
            : (column == columns - 1
                  ? Alignment.centerRight
                  : Alignment.center),
        child: cell(items[slot]),
      );
    }

    Widget row(List<AppInfo> items) {
      final count = items.length;
      switch (layout) {
        case 'left':
          return Row(
            children: [
              for (var i = 0; i < columns; i++)
                Expanded(
                  child: i < count ? cell(items[i]) : const SizedBox.shrink(),
                ),
            ],
          );
        case 'edges':
          return Row(
            children: [
              for (var i = 0; i < columns; i++)
                Expanded(
                  child: edgeCell(items, i) ?? const SizedBox.shrink(),
                ),
            ],
          );
        default:
          return Row(
            children: [for (final app in items) Expanded(child: cell(app))],
          );
      }
    }

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
                size: 20,
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
                style: TextStyle(
                  fontSize: 13,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (shown.isEmpty)
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
            Column(
              children: [
                for (var start = 0; start < shown.length; start += columns)
                  Padding(
                    padding: EdgeInsets.only(
                      bottom: start + columns < shown.length ? 8 : 0,
                    ),
                    child: SizedBox(
                      height: showLabels ? 70 : 52,
                      child: row(
                        shown.sublist(
                          start,
                          start + columns <= shown.length
                              ? start + columns
                              : shown.length,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// A drawing of the 4x1 strip with the real page names. The pills keep their
/// natural width and the row is centred — matching the widget, which avoids
/// stretching a short list into wide bars.
class _PageBarPreview extends StatelessWidget {
  const _PageBarPreview({
    required this.pages,
    required this.current,
    required this.marker,
  });

  final List<TilePage> pages;
  final int current;

  /// `pill` highlights the current tab, `dot` only marks it underneath.
  final String marker;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final names = [
      for (var i = 0; i < pages.length; i++)
        pages[i].name.trim().isEmpty ? '页面 ${i + 1}' : pages[i].name.trim(),
    ];
    final overflow = names.length > 8;
    final shown = overflow ? names.take(7).toList() : names.take(8).toList();
    // A single emoji (or one or two characters) is drawn much larger than a
    // text label, matching the widget.
    bool shortName(String name) {
      final text = name.trim();
      if (text.isEmpty) return false;
      if (text.length <= 2) return true;
      return !RegExp(r'[A-Za-z0-9\u4e00-\u9fff]').hasMatch(text);
    }

    Widget pill(String text, {required bool active}) {
      final textSize = shortName(text) ? 28.0 : 13.0;
      final dot = active && marker == 'dot';
      return Container(
        height: 52,
        constraints: const BoxConstraints(minWidth: 44),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: active && !dot
              ? scheme.onSurface.withValues(alpha: 0.16)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(18),
        ),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: textSize,
                color: active ? scheme.onSurface : scheme.onSurfaceVariant,
              ),
            ),
            if (dot)
              Container(
                margin: const EdgeInsets.only(top: 2),
                width: 4,
                height: 4,
                decoration: BoxDecoration(
                  color: scheme.onSurface,
                  shape: BoxShape.circle,
                ),
              ),
          ],
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < shown.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: pill(shown[i], active: i == current),
              ),
            if (overflow)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: pill('…', active: false),
              ),
          ],
        ),
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
