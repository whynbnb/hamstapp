import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_strings.dart';
import '../services/native_apps.dart';
import '../state/app_state.dart';

Future<void> launchApp(BuildContext context, String packageName) async {
  final state = context.read<AppState>();
  final app = state.appByPackage(packageName);
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
        app?.appName ?? packageName,
        entries,
      );
      // Dismissed the sheet: do not launch anything.
      if (choice == null) return;
      activity = choice;
      await state.updateMeta(packageName, launchActivity: choice);
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
  final name = state.appByPackage(packageName)?.appName;
  final label = (name == null || name.isEmpty)
      ? packageName
      : '$name（$packageName）';
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

/// Sheet listing the desktop entries of a package. Resolves to the chosen
/// activity name, `''`/`-` sentinels, or null when it was dismissed.
Future<String?> _showEntrySheet(
  BuildContext context,
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
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                ctx.strings.t('启动「{name}」的哪个入口？', {'name': appName}),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          for (final entry in entries)
            ListTile(
              leading: const Icon(Icons.apps_outlined),
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
  final name = state.appByPackage(packageName)?.appName ?? packageName;
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
    name,
    entries,
    allowAsk: true,
  );
  if (choice == null) return;
  await state.updateMeta(
    packageName,
    launchActivity: choice == _kAskEveryTime ? '' : choice,
  );
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
