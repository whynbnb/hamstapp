import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_strings.dart';
import '../models/app_info.dart';
import '../models/category.dart';
import '../models/web_app.dart';
import '../services/native_apps.dart';
import '../services/notification_badges.dart';
import '../state/app_state.dart';
import '../utils/actions.dart';
import '../utils/format.dart';
import '../widgets/app_facts.dart';
import '../widgets/app_icon.dart';
import '../widgets/app_tile.dart';
import '../widgets/chip_scroller.dart';
import '../widgets/web_app_editor.dart';
import 'apk_analyzer_screen.dart';

class AppDetailScreen extends StatefulWidget {
  const AppDetailScreen({
    super.key,
    required this.packageName,
    this.fromTileBoard = false,
    this.embedded = false,
  });

  final String packageName;

  /// True when the page is shown in the wide-screen side pane instead of being
  /// pushed: it then hides its own back button.
  final bool embedded;

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
  bool _identifying = false;

  /// Who would open this entry's address (an installed web app, or a browser).
  WebAppHandler? _handler;
  bool _handlerLoaded = false;

  /// The entries this package can be started through, as the system reports
  /// them; null while unknown. Fetched live (never cached) because a package
  /// can change its entries with an update.
  List<LaunchEntry>? _entries;

  @override
  void initState() {
    super.initState();
    // Capture the state now: looking it up from context during dispose() is
    // unsafe (the element is already deactivated).
    _appState = context.read<AppState>();
    final meta = _appState.metaFor(widget.packageName);
    _reason = TextEditingController(text: meta.reason);
    _note = TextEditingController(text: meta.note);
    _loadEntries();
    _loadHandler();
    // An app updated since its icon was read may carry a new one: read it now
    // so this page (and the lists behind it) never show the old version's
    // icon. Quiet and best effort.
    if (_appState.iconNeedsRefresh(widget.packageName)) {
      unawaited(_appState.refreshAppIcon(widget.packageName));
    }
  }

  Future<void> _loadEntries() async {
    // A web entry is not a package: nothing to resolve, and asking the package
    // manager about a synthetic id is pointless.
    final app = _appState.appByPackage(widget.packageName);
    if (app != null && app.isWebEntry) {
      if (mounted) setState(() => _entries = const []);
      return;
    }
    // refresh: true -> opening the page always shows the live picture, even if
    // a launch earlier in this session filled the cache.
    final list = await NativeApps.launchActivities(
      widget.packageName,
      refresh: true,
    );
    if (!mounted) return;
    setState(() => _entries = list);

    // Self-heal the stored name of a pinned entry: it may be missing (a choice
    // made before names were stored) or stale (the app was updated), and lists
    // and tiles read it to label the app.
    final meta = _appState.metaFor(widget.packageName);
    if (meta.launchActivity.isEmpty) return;
    for (final entry in list) {
      if (entry.name != meta.launchActivity) continue;
      if (entry.label != meta.launchEntryLabel) {
        await _appState.updateMeta(
          widget.packageName,
          launchActivity: meta.launchActivity,
          launchEntryLabel: entry.label,
        );
      }
      return;
    }
  }

  /// What the 启动入口 row shows for the current choice.
  String _currentEntry() {
    final s = context.strings;
    final entries = _entries ?? const <LaunchEntry>[];
    final chosen = _appState.metaFor(widget.packageName).launchActivity;
    if (chosen.isEmpty) {
      return entries.isEmpty ? s.t('系统默认') : entries.first.label;
    }
    for (final entry in entries) {
      if (entry.name == chosen) return entry.label;
    }
    return chosen.split('.').last;
  }

  /// Warning to show above the launch button, or null when nothing is off.
  String? _entryNotice(BuildContext context, AppInfo app) {
    final s = context.strings;
    // A web entry is not a package: it has no entries to speak of.
    if (app.isWebEntry) return null;
    if (!app.enabled) return s.t('这个应用已被停用，需要先在系统设置里启用');
    final entries = _entries;
    if (entries == null) return null; // Still loading.
    if (entries.isEmpty) return s.t('这个包没有可启动的入口（可能是系统组件）');
    if (!entries.any((e) => e.fromLauncher)) {
      return s.t('这个包没有桌面图标，桌面上那个同名应用是另一个包');
    }
    return null;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _appState.persistMeta();
    _reason.dispose();
    _note.dispose();
    super.dispose();
  }

  /// Re-reads the site's manifest and icon (a site may have become a PWA, or
  /// changed its name), and reports what was found.
  Future<void> _identifyEntry(AppState state) async {
    setState(() => _identifying = true);
    final site = await state.refreshWebApp(widget.packageName);
    if (!mounted) return;
    setState(() => _identifying = false);
    final s = AppStrings.current;
    final text = site == null
        ? s.t('读不到这个网址（网络或站点问题）')
        : site.isPwa
        ? s.t('已识别为 PWA · 显示模式 {mode}', {'mode': site.display})
        : s.t('这个网站没有 PWA 清单，会用浏览器打开');
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ),
      );
  }

  /// Picks how the entry opens, and which browser takes over when it does not
  /// run in the app's own window. Both the window and the browser choice are per
  /// entry, because a launcher-like app is used differently per site.
  Future<void> _pickOpenMode(AppState state, WebApp entry) async {
    final s = context.strings;
    final browsers = await NativeApps.browsers();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    s.t('打开方式'),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              // Two strategies, spelled out: an own window, or the browser.
              ListTile(
                leading: const Icon(Icons.open_in_full),
                title: Text(s.t('独立窗口（没有地址栏）')),
                subtitle: Text(s.t('用囤囤自己的窗口打开，像应用一样')),
                trailing: entry.opensStandalone ? const Icon(Icons.check) : null,
                onTap: () async {
                  await state.updateWebApp(
                    entry.id,
                    openMode: WebApp.openStandalone,
                  );
                  if (ctx.mounted) Navigator.pop(ctx);
                  setState(() {});
                },
              ),
              ListTile(
                leading: const Icon(Icons.public),
                title: Text(s.t('用浏览器打开')),
                subtitle: Text(s.t('交给浏览器；若系统里已装该网页应用，会交给它')),
                trailing: entry.opensStandalone
                    ? null
                    : const Icon(Icons.check),
                onTap: () async {
                  await state.updateWebApp(
                    entry.id,
                    openMode: WebApp.openBrowser,
                  );
                  setState(() {});
                },
              ),
              if (entry.opensStandalone)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Text(
                    s.t(
                      '窗口里点开站外链接时，会交给系统默认浏览器。想让这个入口本身就用某个浏览器打开（比如它已经在该浏览器里装成了网页应用），选上面的「用浏览器打开」再选浏览器。',
                    ),
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                )
              else ...[
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      s.t('用哪个浏览器'),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.public),
                  title: Text(s.t('系统默认')),
                  trailing: entry.browserPackage.isEmpty
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () async {
                    await state.updateWebApp(
                      entry.id,
                      browserPackage: '',
                      browserName: '',
                    );
                    if (ctx.mounted) Navigator.pop(ctx);
                    setState(() {});
                  },
                ),
                for (final browser in browsers)
                  ListTile(
                    leading: const Icon(Icons.language),
                    title: Text(browser.label),
                    subtitle: Text(
                      browser.packageName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: entry.browserPackage == browser.packageName
                        ? const Icon(Icons.check)
                        : null,
                    onTap: () async {
                      // Choosing a browser also switches the entry to browser
                      // mode: picking one has to take effect, not sit unused.
                      await state.updateWebApp(
                        entry.id,
                        openMode: WebApp.openBrowser,
                        browserPackage: browser.packageName,
                        browserName: browser.label,
                      );
                      if (ctx.mounted) Navigator.pop(ctx);
                      setState(() {});
                    },
                  ),
                if (browsers.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      s.t('没有找到能打开网页的应用'),
                      style: TextStyle(
                        fontSize: 12.5,
                        color: Colors.grey.shade700,
                      ),
                    ),
                  ),
              ],
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  /// Finds out what a tap on this entry actually does: an installed web app for
  /// the site (browser-hosted standalone window) or a browser tab.
  Future<void> _loadHandler() async {
    final web = _appState.webAppById(widget.packageName);
    if (web == null) return;
    final url = web.startUrl.isEmpty ? web.url : web.startUrl;
    final handler = await NativeApps.webAppHandler(url);
    if (!mounted) return;
    setState(() {
      _handler = handler;
      _handlerLoaded = true;
    });
  }

  /// Removes a hand-added web entry, with its tiles and metadata.
  Future<void> _removeWebEntry(AppState state) async {
    final name = state.displayNameFor(widget.packageName);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.strings.t('删除「{name}」？', {'name': name})),
        content: Text(
          ctx.strings.t('这是一个网页入口，不是已安装的应用。删除会一并移除它的磁贴、收藏和分类等记录。'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ctx.strings.t('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(ctx.strings.t('删除')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await state.removeWebApp(widget.packageName);
    if (mounted) Navigator.pop(context);
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

  /// Re-reads this app's icon from the system, ignoring the copies kept in
  /// memory and on disk. A new version (or an icon the system did not report
  /// earlier) shows up immediately, in the list too.
  Future<void> _forceRefreshIcon(AppState state) async {
    final ok = await state.refreshAppIcon(widget.packageName);
    if (!mounted) return;
    _snack(
      ok
          ? context.strings.t('图标已刷新')
          : context.strings.t('刷新失败，系统没有返回图标'),
    );
  }

  /// Lets the user pick a square image and stores it as this app's icon. The
  /// image is shrunk before it is saved, so a photo does not bloat the data.
  Future<void> _pickCustomIcon(AppState state) async {
    try {
      final picked = await FilePicker.pickFile(
        dialogTitle: context.strings.t('选择图标图片'),
        type: FileType.image,
      );
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      final ok = await state.setCustomIcon(widget.packageName, bytes);
      if (!mounted) return;
      _snack(
        ok
            ? context.strings.t('图标已更换')
            : context.strings.t('无法读取这张图片'),
      );
    } catch (e) {
      if (mounted) _snack(context.strings.t('无法读取这张图片'));
    }
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
    // For a hand-added entry, the full picture (manifest, display mode, colours).
    final webEntry = app?.isWebEntry == true
        ? state.webAppById(widget.packageName)
        : null;
    final name = state.displayNameFor(widget.packageName);
    final pinLocations = state.pinLocationsFor(widget.packageName);
    final currentPinCount = state.pinCountOnCurrentPage(widget.packageName);

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        title: Text(name, overflow: TextOverflow.ellipsis),
        actions: [
          if (app != null && !app.isWebEntry)
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
                    onSelected: (v) async {
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
                        case 'editWeb':
                          showWebAppEditor(
                            context,
                            state,
                            entry: webAppFor(state, widget.packageName),
                          );
                        case 'removeWeb':
                          _removeWebEntry(state);
                        case 'hide':
                          await state.setHidden(
                            widget.packageName,
                            !meta.hidden,
                          );
                          if (context.mounted) {
                            _snack(
                              meta.hidden
                                  ? context.strings.t('已取消隐藏')
                                  : context.strings.t('已隐藏，可在「隐藏」筛选里找到'),
                            );
                          }
                        case 'icon':
                          await _pickCustomIcon(state);
                        case 'refreshIcon':
                          await _forceRefreshIcon(state);
                        case 'resetIcon':
                          await state.clearCustomIcon(widget.packageName);
                      }
                    },
                    itemBuilder: (ctx) => app.isWebEntry
                        ? [
                            if (!app.isWebEntry)
                              PopupMenuItem(
                                value: 'icon',
                                child: ListTile(
                                  leading: const Icon(Icons.image_outlined),
                                  title: Text(ctx.strings.t('更换图标')),
                                ),
                              ),
                            PopupMenuItem(
                              value: 'hide',
                              child: ListTile(
                                leading: Icon(
                                  meta.hidden
                                      ? Icons.visibility_outlined
                                      : Icons.visibility_off_outlined,
                                ),
                                title: Text(
                                  meta.hidden
                                      ? ctx.strings.t('取消隐藏')
                                      : ctx.strings.t('隐藏应用'),
                                ),
                              ),
                            ),
                            PopupMenuItem(
                              value: 'editWeb',
                              child: ListTile(
                                leading: const Icon(Icons.edit_outlined),
                                title: Text(ctx.strings.t('编辑名称 / 网址')),
                              ),
                            ),
                            PopupMenuItem(
                              value: 'removeWeb',
                              child: ListTile(
                                leading: const Icon(Icons.delete_outline),
                                title: Text(ctx.strings.t('删除网页入口')),
                              ),
                            ),
                          ]
                        : [
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
                            PopupMenuItem(
                              value: 'icon',
                              child: ListTile(
                                leading: const Icon(Icons.image_outlined),
                                title: Text(ctx.strings.t('更换图标')),
                              ),
                            ),
                            // A custom icon wins over the launcher one, so
                            // re-reading the system icon would change nothing.
                            if (meta.customIcon.isEmpty)
                              PopupMenuItem(
                                value: 'refreshIcon',
                                child: ListTile(
                                  leading: const Icon(Icons.refresh),
                                  title: Text(ctx.strings.t('强制刷新图标')),
                                ),
                              ),
                            if (meta.customIcon.isNotEmpty)
                              PopupMenuItem(
                                value: 'resetIcon',
                                child: ListTile(
                                  leading: const Icon(Icons.restart_alt),
                                  title: Text(ctx.strings.t('恢复默认图标')),
                                ),
                              ),
                            PopupMenuItem(
                              value: 'hide',
                              child: ListTile(
                                leading: Icon(
                                  meta.hidden
                                      ? Icons.visibility_outlined
                                      : Icons.visibility_off_outlined,
                                ),
                                title: Text(
                                  meta.hidden
                                      ? ctx.strings.t('取消隐藏')
                                      : ctx.strings.t('隐藏应用'),
                                ),
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
          if (app != null && _entryNotice(context, app) != null)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.errorContainer.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 18,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _entryNotice(context, app)!,
                      style: const TextStyle(fontSize: 12.5, height: 1.35),
                    ),
                  ),
                ],
              ),
            ),
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
          if (app != null && app.isWebApp)
            Container(
              margin: const EdgeInsets.only(top: 12),
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .primaryContainer
                    .withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.public, size: 18),
                      const SizedBox(width: 6),
                      Text(
                        context.strings.t('网页应用'),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    app.isWebEntry
                        ? (webEntry == null || !webEntry.isPwa
                              ? context.strings.t(
                                  '没有 PWA 清单：打开时会交给浏览器，可以放进磁贴、收藏和分类。',
                                )
                              : context.strings.t(
                                  'PWA · 显示模式 {mode}：打开时用囤囤自己的窗口，没有地址栏。',
                                  {'mode': webEntry.display},
                                ))
                        : context.strings.t(
                            '这是把网站装成应用的 PWA，可以像普通应用一样打开、加磁贴或收藏。',
                          ),
                    style: const TextStyle(fontSize: 12.5, height: 1.35),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    app.webUrl.isEmpty
                        ? context.strings.t('网址不可用')
                        : app.webUrl,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                  ),
                  if (webEntry != null && webEntry.manifestUrl.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    SelectableText(
                      context.strings.t('清单 {url}', {
                        'url': webEntry.manifestUrl,
                      }),
                      style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600),
                    ),
                  ],
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (app.isWebEntry)
                        TextButton.icon(
                          onPressed: _identifying
                              ? null
                              : () => _identifyEntry(state),
                          icon: _identifying
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.travel_explore, size: 16),
                          label: Text(context.strings.t('重新识别')),
                        ),
                      if (app.isWebEntry)
                        TextButton.icon(
                          onPressed: () => showWebAppEditor(
                            context,
                            state,
                            entry: webAppFor(state, widget.packageName),
                          ),
                          icon: const Icon(Icons.edit_outlined, size: 16),
                          label: Text(context.strings.t('编辑')),
                        ),
                      TextButton.icon(
                        onPressed: app.webUrl.isEmpty
                            ? null
                            : () => NativeApps.openUrl(app.webUrl),
                        icon: const Icon(Icons.open_in_new, size: 16),
                        label: Text(context.strings.t('用浏览器打开')),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          if (webEntry != null)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                webEntry.opensStandalone ? Icons.open_in_full : Icons.public,
              ),
              title: Text(context.strings.t('打开方式')),
              subtitle: Text(
                webEntry.opensStandalone
                    ? context.strings.t('独立窗口（没有地址栏）')
                    : context.strings.t('用浏览器打开：{name}', {
                        'name': webEntry.browserName.isEmpty
                            ? context.strings.t('系统默认')
                            : webEntry.browserName,
                      }),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _pickOpenMode(state, webEntry),
            ),
          if (webEntry != null && _handlerLoaded)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                _handler != null && !_handler!.browser
                    ? Icons.install_mobile
                    : Icons.public,
              ),
              title: Text(context.strings.t('已安装的网页应用')),
              subtitle: Text(
                _handler != null && !_handler!.browser
                    ? context.strings.t(
                        '{label} · 点开会交给它，按浏览器的独立窗口显示（无地址栏）',
                        {'label': _handler!.label},
                      )
                    : context.strings.t(
                        '没有安装：点开只会交给浏览器开一个标签页。想要浏览器自己的独立窗口，请在 Chrome 里用「安装应用」把它装成网页应用（「添加到主屏幕」只是快捷方式，任何第三方都读不到）。',
                      ),
              ),
            ),
          if (webEntry != null && webEntry.opensStandalone)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.fullscreen),
              value: webEntry.hideStatusBar,
              onChanged: (v) => state.updateWebApp(
                webEntry.id,
                hideStatusBar: v,
              ),
              title: Text(context.strings.t('隐藏状态栏')),
              subtitle: Text(
                webEntry.hideStatusBar
                    ? context.strings.t('全屏显示，状态栏不占位置')
                    : context.strings.t('显示状态栏，网页内容不会与它重叠'),
              ),
            ),
          if (app != null &&
              _entries != null &&
              (_entries!.length >= 2 || meta.launchActivity.isNotEmpty))
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: AppIcon(
                packageName: widget.packageName,
                label: name,
                size: 36,
                activity: meta.launchActivity.isEmpty
                    ? null
                    : meta.launchActivity,
                showNotificationBadge: false,
              ),
              title: Text(context.strings.t('启动入口')),
              subtitle: Text(
                context.strings.t('当前：{entry}', {'entry': _currentEntry()}),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                await pickLaunchEntry(context, widget.packageName);
                await _loadEntries();
              },
            ),
          if (app != null &&
              _entries != null &&
              (_entries!.length >= 2 || meta.launchActivity.isNotEmpty))
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: meta.nameFollowsEntry,
              onChanged: (v) => state.updateMeta(
                widget.packageName,
                nameFollowsEntry: v,
              ),
              title: Text(context.strings.t('名称跟随入口')),
              subtitle: Text(
                meta.nameFollowsEntry
                    ? context.strings.t('用所选入口的名称（如「电话」）')
                    : context.strings.t('固定用应用原来的名称，图标仍跟随入口'),
              ),
            ),
          if (app != null)
            ListenableBuilder(
              listenable: NotificationBadges.instance,
              builder: (context, _) {
                final unread =
                    NotificationBadges.instance.counts[widget.packageName] ?? 0;
                if (unread <= 0) return const SizedBox.shrink();
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.notifications_off_outlined),
                  title: Text(context.strings.t('清除通知角标')),
                  subtitle: Text(
                    context.strings.t('当前 {n} 条未读；滑动通知不会自动清除', {
                      'n': unread,
                    }),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () =>
                      clearNotificationBadge(context, widget.packageName),
                );
              },
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
          if (app != null && !app.isWebEntry) _InfoTable(app: app),
          // Storage, permissions and signature: the three things a system app
          // manager shows and this app was missing.
          if (app != null && !app.isWebEntry) ...[
            const SizedBox(height: 12),
            AppStorageCard(packageName: widget.packageName),
            const SizedBox(height: 10),
            AppPermissionsCard(packageName: widget.packageName),
            const SizedBox(height: 10),
            AppSignatureCard(
              packageName: widget.packageName,
              appName: name,
            ),
            const SizedBox(height: 10),
            AppInstallSourceCard(packageName: widget.packageName),
          ],
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
              if (app == null || !app!.isWebEntry)
                // Selectable so the package name can be copied out when an
                // entry or a web app needs a closer look.
                SelectableText(packageName,
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
                    if (app!.isWebApp)
                      CategoryChip(
                        category: AppCategory(
                            id: '_w',
                            name: context.strings.t('网页应用'),
                            emoji: '🌐'),
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
