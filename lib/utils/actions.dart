import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_strings.dart';
import '../models/app_info.dart';
import '../models/web_app.dart';
import '../services/app_log.dart';
import '../services/icon_cache.dart';
import '../services/native_apps.dart';
import '../state/app_state.dart';
import '../widgets/app_icon.dart';

Future<void> launchApp(BuildContext context, String packageName) async {
  final state = context.read<AppState>();

  // A web entry is a website, not a package: hand it to the browser.
  final entry = state.appByPackage(packageName);
  if (entry != null && entry.isWebEntry) {
    await launchWebEntry(context, entry);
    return;
  }

  final remembered = state.metaFor(packageName).launchActivity;

  // Resolved live rather than from the scanned app list: a package can own
  // several desktop icons (on some ROMs 联系人 and 电话 are the same package
  // with two launcher activities), and some entries — the dialer, typically —
  // have no icon of their own at all.
  String? activity = remembered.isEmpty ? null : remembered;
  if (activity == null) {
    final entries = await NativeApps.launchActivities(packageName);
    if (entries.length == 1) {
      activity = entries.single.name;
    } else if (entries.length >= 2) {
      if (!context.mounted) return;
      final choice = await _showEntrySheet(
        context,
        packageName,
        state.displayNameFor(packageName),
        entries,
      );
      // Dismissed the sheet: do not launch anything.
      if (choice == null) return;
      activity = choice;
      await state.updateMeta(
        packageName,
        launchActivity: choice,
        launchEntryLabel: _entryNamed(entries, choice)?.label ?? '',
      );
    }
    // No entries reported (or none we can see): fall through to a plain launch
    // and let the native side report why it cannot work.
  }

  var outcome = await NativeApps.launchApp(packageName, activity: activity);
  if (!outcome.isOk && activity != null) {
    // The pinned entry is gone (the app was updated) or the system refused it;
    // forget the choice and retry with whatever the system defaults to.
    if (remembered.isNotEmpty) {
      await state.updateMeta(packageName, launchActivity: '');
    }
    outcome = await NativeApps.launchApp(packageName);
  }
  if (outcome.isOk) {
    await state.markLaunched(packageName);
    return;
  }
  if (!context.mounted) return;
  await _reportLaunchFailure(context, packageName, outcome);
}

/// Opens a hand-added web entry.
///
/// A PWA that asks for a display mode other than `browser` runs in the app's own
/// standalone window (no address bar, tinted with the manifest's `theme_color`),
/// which is what the standard says an installed web app should look like.
/// Everything else — plain websites, a manifest that asks for `browser`, an
/// address with no manifest at all — goes to the system browser.
Future<void> launchWebEntry(BuildContext context, AppInfo entry) async {
  final state = context.read<AppState>();
  final web = state.webAppById(entry.packageName);
  if (web == null || web.url.isEmpty) {
    AppLog.instance.warn(
      LogModule.launch,
      '网页入口 · 没有网址 · ${entry.packageName}',
    );
    if (context.mounted) {
      _snack(context, AppStrings.current.t('这个网页入口没有网址'));
    }
    return;
  }

  var opened = false;
  var target = web.startUrl.isEmpty ? web.url : web.startUrl;
  if (!WebApp.isValidUrl(target)) {
    // A stored `start_url` without a scheme (an older entry saved during a
    // redirect) would reach the WebView as `file:///activate`. The entry's own
    // address is always a full URL, so use that.
    AppLog.instance.warn(
      LogModule.launch,
      '网页入口 · 启动地址不是网址，改用入口地址 · ${web.name} · $target',
    );
    target = web.url;
  }
  if (!WebApp.isValidUrl(target)) {
    AppLog.instance.error(
      LogModule.launch,
      '网页入口 · 网址无效 · ${web.name} · ${web.url}',
    );
    if (context.mounted) {
      _snack(context, AppStrings.current.t('这个网页入口没有网址'));
    }
    return;
  }
  final browserLabel = web.browserPackage.isEmpty
      ? AppStrings.current.t('系统默认')
      : (web.browserName.isEmpty ? web.browserPackage : web.browserName);
  if (web.opensStandalone) {
    // The window's own log (native side) covers the page itself; these lines
    // tie an attempt to the entry, so a failure can be read without guessing
    // which website it belonged to.
    AppLog.instance.log(
      LogModule.launch,
      '网页入口 · 打开独立窗口 · ${web.name} · $target · '
          'display=${web.windowDisplay} · 状态栏=${web.hideStatusBar ? '隐藏' : '显示'}',
    );
    opened = await NativeApps.openWebApp(
      url: target,
      name: web.name,
      display: web.windowDisplay,
      scope: web.scope,
      themeColor: web.themeColor,
      backgroundColor: web.backgroundColor,
      hideStatusBar: web.hideStatusBar,
      browserPackage: web.browserPackage,
      icon: IconCache.instance[web.id],
    );
    if (!opened) {
      // The window host could not start for some reason; the browser at least
      // gets the user to the site. Say so rather than opening something else
      // silently.
      AppLog.instance.warn(
        LogModule.launch,
        '网页入口 · 独立窗口启动失败，改用浏览器 · ${web.name} · $target · '
            '浏览器=$browserLabel',
      );
      opened = await NativeApps.openUrl(target, package: web.browserPackage);
      if (opened && context.mounted) {
        _snack(context, AppStrings.current.t('独立窗口打不开，已改用浏览器'));
      }
    }
  } else {
    opened = await NativeApps.openUrl(target, package: web.browserPackage);
    if (!opened && web.browserPackage.isNotEmpty) {
      // The chosen browser may simply not handle this address; the system's
      // own choice is better than refusing to open it at all.
      AppLog.instance.warn(
        LogModule.launch,
        '网页入口 · 指定浏览器打不开，改用系统默认 · ${web.name} · '
            '${web.browserName.isEmpty ? web.browserPackage : web.browserName}',
      );
      opened = await NativeApps.openUrl(target);
    }
    AppLog.instance.log(
      LogModule.launch,
      '网页入口 · 浏览器打开 · ${web.name} · $target · 浏览器=$browserLabel'
          ' · ${opened ? '已启动' : '失败'}',
    );
  }

  if (!opened) {
    // The one line that matters when a web entry "does not open": the address,
    // the mode that was tried and the browser that was asked. The native side
    // logs the window's own reason above it.
    AppLog.instance.error(
      LogModule.launch,
      '网页入口 · 打不开 · ${web.name} · ${web.url} · '
          '独立窗口=${web.opensStandalone ? '是（${web.windowDisplay}）' : '否'} · '
          '浏览器=$browserLabel',
    );
    if (context.mounted) {
      _snack(
        context,
        AppStrings.current.t('打不开 {url}：设备上没有能处理它的应用', {
          'url': web.url,
        }),
      );
    }
    return;
  }
  await state.markLaunched(entry.packageName);
}

/// Shows a short transient message; safe to call from any launch path.
void _snack(BuildContext context, String text) {
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

/// Explains a failed launch. Includes the package name: several packages can
/// share a label (the telephony component and the dialer are both "电话"), and
/// that is usually exactly what the user needs to see to tell them apart.
Future<void> _reportLaunchFailure(
  BuildContext context,
  String packageName,
  LaunchOutcome outcome,
) async {
  final state = context.read<AppState>();
  final s = context.strings;
  final name = state.displayNameFor(packageName);
  final label = name == packageName ? packageName : '$name（$packageName）';
  final message = switch (outcome) {
    LaunchOutcome.noEntry => s.t('无法启动「{app}」：它没有可启动的入口', {'app': label}),
    LaunchOutcome.disabled => s.t('无法启动「{app}」：它已被停用，请先在系统设置中启用', {
      'app': label,
    }),
    LaunchOutcome.missing => s.t('无法启动「{app}」：未找到该应用', {'app': label}),
    LaunchOutcome.blocked => s.t('无法启动「{app}」：系统拒绝了启动请求', {'app': label}),
    _ => s.t('无法启动该应用（可能已禁用或没有启动入口）'),
  };
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
  );
}

/// Sheet listing the entries of a package. Resolves to the chosen activity
/// name, `''`/`-` sentinels, or null when it was dismissed.
Future<String?> _showEntrySheet(
  BuildContext context,
  String packageName,
  String appName,
  List<LaunchEntry> entries, {
  bool allowAsk = false,
}) {
  return showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ctx.strings.t('启动「{name}」的哪个入口？', {'name': appName}),
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  ctx.strings.t('每个入口有各自的图标，选哪个就用哪个的图标'),
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(ctx).colorScheme.outline,
                  ),
                ),
              ],
            ),
          ),
          for (final entry in entries)
            ListTile(
              leading: AppIcon(
                packageName: packageName,
                label: entry.label,
                size: 36,
                activity: entry.name,
                showNotificationBadge: false,
              ),
              title: Text(entry.label),
              subtitle: Text(
                entry.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => Navigator.pop(ctx, entry.name),
            ),
          if (allowAsk)
            ListTile(
              leading: const Icon(Icons.help_outline),
              title: Text(ctx.strings.t('每次询问')),
              onTap: () => Navigator.pop(ctx, _kAskEveryTime),
            ),
        ],
      ),
    ),
  );
}

/// Sentinel for "do not remember a choice" in the entry picker.
const String _kAskEveryTime = '-';

/// Picks and remembers which desktop entry of [packageName] to start.
Future<void> pickLaunchEntry(BuildContext context, String packageName) async {
  final state = context.read<AppState>();
  final name = state.displayNameFor(packageName);
  final entries = await NativeApps.launchActivities(packageName);
  if (!context.mounted) return;
  if (entries.length < 2) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          entries.isEmpty
              ? context.strings.t('该应用没有可启动的入口')
              : context.strings.t('该应用只有一个启动入口'),
        ),
      ),
    );
    return;
  }
  final choice = await _showEntrySheet(
    context,
    packageName,
    name,
    entries,
    allowAsk: true,
  );
  if (choice == null) return;
  if (choice == _kAskEveryTime) {
    await state.updateMeta(packageName, launchActivity: '');
    return;
  }
  await state.updateMeta(
    packageName,
    launchActivity: choice,
    launchEntryLabel: _entryNamed(entries, choice)?.label ?? '',
  );
}

/// The entry named [activityName] in [entries], or null.
LaunchEntry? _entryNamed(List<LaunchEntry> entries, String activityName) {
  for (final entry in entries) {
    if (entry.name == activityName) return entry;
  }
  return null;
}

/// Forgets an app's unread marks, clearing its badge. Unread marks survive the
/// user swiping the notification away by design, so this is the manual escape
/// hatch for a badge that will not clear on its own.
Future<void> clearNotificationBadge(
  BuildContext context,
  String packageName,
) async {
  final state = context.read<AppState>();
  await NativeApps.clearNotificationMark(packageName);
  await state.refreshNotificationCounts();
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(context.strings.t('已清除该应用的通知角标'))),
  );
}

Future<void> openAppInfo(BuildContext context, String packageName) async {
  final ok = await NativeApps.openAppInfo(packageName);
  if (!context.mounted) return;
  if (!ok) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.strings.t('无法打开应用信息页'))),
    );
  }
}

Future<void> uninstallApp(
  BuildContext context,
  String packageName,
  String name,
) async {
  final strings = context.strings;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(strings.t('卸载应用')),
      content: Text(strings.t('确定要卸载「{name}」吗？', {'name': name})),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(strings.t('取消')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(strings.t('卸载')),
        ),
      ],
    ),
  );
  if (confirmed != true) return;
  if (!context.mounted) return;
  await NativeApps.uninstallApp(packageName);
}
