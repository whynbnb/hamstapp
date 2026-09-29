import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_strings.dart';
import '../models/app_info.dart';
import '../models/category.dart';
import '../services/native_apps.dart';
import '../state/app_state.dart';
import '../utils/actions.dart';
import '../utils/format.dart';
import '../widgets/app_icon.dart';
import '../widgets/app_tile.dart';
import '../widgets/chip_scroller.dart';
import 'apk_analyzer_screen.dart';

class AppDetailScreen extends StatefulWidget {
  const AppDetailScreen({
    super.key,
    required this.packageName,
    this.fromTileBoard = false,
  });

  final String packageName;

  /// True when this screen was opened from the 磁贴 board, which enables the
  /// quick "pin to the current page" switch.
  final bool fromTileBoard;

  @override
  State<AppDetailScreen> createState() => _AppDetailScreenState();
}

class _AppDetailScreenState extends State<AppDetailScreen> {
  late final AppState _appState;
  late final TextEditingController _reason;
  late final TextEditingController _note;
  Timer? _debounce;
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    // Capture the state now: looking it up from context during dispose() is
    // unsafe (the element is already deactivated).
    _appState = context.read<AppState>();
    final meta = _appState.metaFor(widget.packageName);
    _reason = TextEditingController(text: meta.reason);
    _note = TextEditingController(text: meta.note);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _appState.persistMeta();
    _reason.dispose();
    _note.dispose();
    super.dispose();
  }

  String _currentPageName(AppState state) {
    final pages = state.tilePages;
    if (pages.isEmpty) return AppStrings.current.t('无磁贴页');
    final i = state.currentTilePageIndex.clamp(0, pages.length - 1);
    return pages[i].name;
  }

  void _schedulePersist() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () {
      if (mounted) _appState.persistMeta();
    });
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  /// Copies the installed APK to a temp dir and opens the system share sheet.
  Future<void> _exportApk(AppInfo? app) async {
    if (_exporting) return;
    final path = app?.apkPath ?? '';
    if (path.isEmpty) {
      _snack(context.strings.t('找不到该应用的 APK 文件'));
      return;
    }
    setState(() => _exporting = true);
    final base = (app!.appName.isEmpty ? widget.packageName : app.appName) +
        (app.versionName.isEmpty ? '' : '_${app.versionName}');
    final ok = await NativeApps.shareApk(path, name: base);
    if (!mounted) return;
    setState(() => _exporting = false);
    if (!ok) {
      _snack(context.strings.t('导出失败，可能无法读取该应用的 APK'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final meta = state.metaFor(widget.packageName);
    final app = state.appByPackage(widget.packageName);
    final name = app?.appName ?? widget.packageName;
    final pinLocations = state.pinLocationsFor(widget.packageName);
    final currentPinCount = state.pinCountOnCurrentPage(widget.packageName);

    return Scaffold(
      appBar: AppBar(
        title: Text(name, overflow: TextOverflow.ellipsis),
        actions: [
          if (app != null)
            IconButton(
              tooltip: context.strings.t('分析已安装的 APK'),
              icon: const Icon(Icons.manage_search),
              onPressed: () {
                final path = app.apkPath;
                if (path.isEmpty) {
                  _snack(context.strings.t('找不到该应用的 APK 文件'));
                  return;
                }
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ApkAnalyzerScreen(initialPath: path),
                  ),
                );
              },
            ),
          if (app != null)
            _exporting
                ? const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  )
                : PopupMenuButton<String>(
                    tooltip: context.strings.t('更多'),
                    onSelected: (v) {
                      switch (v) {
                        case 'export':
                          _exportApk(app);
                        case 'info':
                          openAppInfo(context, widget.packageName);
                        case 'uninstall':
                          uninstallApp(
                            context,
                            widget.packageName,
                            name,
                          );
                      }
                    },
                    itemBuilder: (ctx) => [
                      PopupMenuItem(
                        value: 'export',
                        child: ListTile(
                          leading: const Icon(Icons.ios_share),
                          title: Text(ctx.strings.t('导出 APK（分享）')),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'info',
                        child: ListTile(
                          leading: const Icon(Icons.info_outline),
                          title: Text(ctx.strings.t('应用信息')),
                        ),
                      ),
                      if (!app.isSystem)
                        PopupMenuItem(
                          value: 'uninstall',
                          child: ListTile(
                            leading: const Icon(Icons.delete_outline),
                            title: Text(ctx.strings.t('卸载')),
                          ),
                        ),
                    ],
                  ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Header(app: app, packageName: widget.packageName, name: name),
          const SizedBox(height: 16),
          if (app != null)
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => launchApp(context, widget.packageName),
                    icon: const Icon(Icons.rocket_launch),
                    label: Text(context.strings.t('启动')),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () =>
                        state.updateMeta(widget.packageName, favorite: !meta.favorite),
                    icon: Icon(meta.favorite
                        ? Icons.star_rounded
                        : Icons.star_border_rounded),
                    label: Text(meta.favorite
                        ? context.strings.t('已收藏')
                        : context.strings.t('收藏')),
                  ),
                ),
              ],
            ),
          const SizedBox(height: 8),
          _SectionTitle(context.strings.t('固定到磁贴')),
          if (pinLocations.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 8),
              child: Text(
                context.strings.t('尚未固定到任何磁贴页'),
                style: const TextStyle(fontSize: 13),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 4),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (page, count) in pinLocations)
                    InputChip(
                      avatar: const Icon(Icons.push_pin, size: 16),
                      label: Text(
                        count > 1 ? '${page.name} ×$count' : page.name,
                      ),
                      onDeleted: () =>
                          state.removeTilesOnPage(widget.packageName, page.id),
                    ),
                ],
              ),
            ),
          // Quick pin, only offered from the tile board where "the current
          // page" is meaningful.
          if (widget.fromTileBoard && state.tilePages.isNotEmpty)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: currentPinCount > 0,
              onChanged: (v) => v
                  ? state.addTile(widget.packageName,
                      pageId: state.currentTilePageId)
                  : state.removeTilesOnCurrentPage(widget.packageName),
              title: Text(
                context.strings.t('固定到当前页「{page}」', {
                  'page': _currentPageName(state),
                }),
              ),
              subtitle: currentPinCount > 1
                  ? Text(
                      context.strings.t('当前页已有 {n} 份（可多份）', {
                        'n': currentPinCount,
                      }),
                    )
                  : Text(context.strings.t('在当前磁贴页显示')),
            ),
          // Pick any page, so managing an app from the Apps tab is not tied to
          // whichever tile page happened to be selected.
          if (state.tilePages.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                context.strings.t('还没有磁贴页，先在「启动 → 磁贴」新建一个吧'),
                style: const TextStyle(fontSize: 13),
              ),
            )
          else
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.dashboard_customize_outlined),
              title: Text(context.strings.t('固定到磁贴页…')),
              subtitle: Text(context.strings.t('可固定到任意磁贴页，或长按再加一份')),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showPinToPagesSheet(
                context,
                state,
                widget.packageName,
              ),
            ),
          const SizedBox(height: 12),
          _SectionTitle(context.strings.t('安装原因')),
          TextField(
            controller: _reason,
            maxLines: 3,
            minLines: 2,
            decoration: InputDecoration(
              hintText: context.strings.t(
                '为什么安装它？例如：薅羊毛、工作需要、朋友推荐…',
              ),
              border: const OutlineInputBorder(),
            ),
            onChanged: (v) {
              state.metaFor(widget.packageName).reason = v;
              _schedulePersist();
            },
          ),
          const SizedBox(height: 20),
          _SectionTitle(context.strings.t('备注')),
          TextField(
            controller: _note,
            maxLines: 3,
            minLines: 2,
            decoration: InputDecoration(
              hintText: context.strings.t('其它想记录的信息'),
              border: const OutlineInputBorder(),
            ),
            onChanged: (v) {
              state.metaFor(widget.packageName).note = v;
              _schedulePersist();
            },
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              _SectionTitle(context.strings.t('分类')),
              const Spacer(),
              TextButton.icon(
                onPressed: () => _createCategory(context, state),
                icon: const Icon(Icons.add, size: 18),
                label: Text(context.strings.t('新建分类')),
              ),
            ],
          ),
          if (state.categories.isNotEmpty)
            ChipScroller(
              children: state.categories.map((c) {
                final selected = meta.categoryIds.contains(c.id);
                return FilterChip(
                  label: Text('${c.emoji} ${c.name}'),
                  selected: selected,
                  onSelected: (v) {
                    final ids = List<String>.from(meta.categoryIds);
                    if (v) {
                      ids.add(c.id);
                    } else {
                      ids.remove(c.id);
                    }
                    state.updateMeta(widget.packageName, categoryIds: ids);
                  },
                );
              }).toList(),
            ),
          if (state.categories.isEmpty)
            Text(context.strings.t('还没有分类，点击「新建分类」创建一个吧'),
                style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
          const SizedBox(height: 24),
          if (app != null) _InfoTable(app: app),
          const SizedBox(height: 24),
          _SectionTitle(context.strings.t('使用记录')),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.history),
            title: Text(
              meta.launchCount > 0
                  ? context.strings.t('从囤囤启动 {count} 次', {
                      'count': meta.launchCount,
                    })
                  : context.strings.t('还没有从囤囤启动过'),
            ),
            subtitle: meta.lastLaunchedAt > 0
                ? Text(context.strings.t('上次 {ago}', {
                    'ago': Fmt.relative(meta.lastLaunchedAt),
                  }))
                : null,
            trailing: (meta.launchCount > 0 || meta.lastLaunchedAt > 0)
                ? TextButton.icon(
                    onPressed: () => _clearUsage(state, name),
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: Text(context.strings.t('清除')),
                  )
                : null,
          ),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            onPressed: () async {
              await state.clearMeta(widget.packageName);
              if (!context.mounted) return;
              _reason.clear();
              _note.clear();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(context.strings.t('已清除该应用的自定义信息')),
                ),
              );
            },
            icon: const Icon(Icons.restart_alt),
            label: Text(context.strings.t('清除该应用的自定义信息')),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Future<void> _clearUsage(AppState state, String name) async {
    final s = context.strings;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.t('清除「{name}」的使用记录？', {'name': name})),
        content: Text(
          s.t('将删除该应用的启动次数与时间记录，不影响它的分类、原因和备注。'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(s.t('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(s.t('确定')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await state.clearLaunchHistoryFor(widget.packageName);
    if (!mounted) return;
    _snack(s.t('已清除「{name}」的使用记录', {'name': name}));
  }

  Future<void> _createCategory(BuildContext context, AppState state) async {    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.strings.t('新建分类')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            hintText: context.strings.t('分类名称'),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(context.strings.t('取消'))),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: Text(context.strings.t('创建')),
          ),
        ],
      ),
    );
    if (name != null && name.trim().isNotEmpty) {
      final c = await state.addCategory(name.trim());
      final meta = state.metaFor(widget.packageName);
      final ids = List<String>.from(meta.categoryIds)..add(c.id);
      await state.updateMeta(widget.packageName, categoryIds: ids);
    }
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.app, required this.packageName, required this.name});

  final AppInfo? app;
  final String packageName;
  final String name;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        AppIcon(packageName: packageName, label: name, size: 64),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(packageName,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
              if (app != null) ...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  children: [
                    if (app!.versionName.isNotEmpty)
                      CategoryChip(
                        category: AppCategory(
                            id: '_v', name: 'v${app!.versionName}', emoji: '🏷️'),
                      ),
                    if (app!.isSystem)
                      CategoryChip(
                        category: AppCategory(
                            id: '_s',
                            name: context.strings.t('系统应用'),
                            emoji: '⚙️'),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
    );
  }
}

class _InfoTable extends StatelessWidget {
  const _InfoTable({required this.app});
  final AppInfo app;

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final rows = <(String, String)>[
      (s.t('安装时间'), Fmt.dateTime(app.firstInstallTime)),
      (s.t('更新时间'), Fmt.dateTime(app.lastUpdateTime)),
      (s.t('大小'), Fmt.size(app.sizeBytes)),
      (s.t('版本号'), '${app.versionName} (${app.versionCode})'),
      ('targetSdk', '${app.targetSdk}'),
      ('minSdk', '${app.minSdk}'),
      ('UID', '${app.uid}'),
      (s.t('APK 路径'), app.apkPath),
    ];
    return Card(
      elevation: 0,
      color: Colors.grey.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: rows
              .map((r) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 84,
                          child: Text(r.$1,
                              style: TextStyle(
                                  color: Colors.grey.shade600, fontSize: 13)),
                        ),
                        Expanded(
                          child: SelectableText(r.$2,
                              style: const TextStyle(fontSize: 13)),
                        ),
                      ],
                    ),
                  ))
              .toList(),
        ),
      ),
    );
  }
}

/// Bottom sheet to pin [packageName] onto any tile page.
///
/// Tap a page to pin (or clear that page when already pinned); long-press to
/// add one more copy. Works regardless of which page is currently selected,
/// so managing an app from the Apps tab is not tied to a stale tile page.
void showPinToPagesSheet(
  BuildContext context,
  AppState state,
  String packageName,
) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: StatefulBuilder(
        builder: (ctx, setLocal) {
          final pages = state.tilePages;
          final s = ctx.strings;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.t('固定到磁贴页'),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      s.t('点击固定/取消，长按再添加一个'),
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: pages.length,
                  itemBuilder: (context, i) {
                    final page = pages[i];
                    final count = state
                        .tilesOnPage(page)
                        .where((t) => t.packageName == packageName)
                        .length;
                    final pinned = count > 0;
                    return ListTile(
                      leading: const Icon(Icons.grid_view_rounded),
                      title: Text(page.name),
                      subtitle: count > 1
                          ? Text(s.t('已固定 {n} 份', {'n': count}))
                          : null,
                      trailing: pinned
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.push_pin,
                                  color: Colors.orange,
                                  size: 18,
                                ),
                                if (count > 1) ...[
                                  const SizedBox(width: 4),
                                  Text('×$count'),
                                ],
                              ],
                            )
                          : const Icon(Icons.add),
                      onTap: () {
                        if (pinned) {
                          state.removeTilesOnPage(packageName, page.id);
                        } else {
                          state.addTile(packageName, pageId: page.id);
                        }
                        setLocal(() {});
                      },
                      onLongPress: () {
                        state.addTile(packageName, pageId: page.id);
                        setLocal(() {});
                      },
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}
