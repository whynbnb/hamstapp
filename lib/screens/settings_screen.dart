import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_strings.dart';
import '../services/app_log.dart';
import '../services/native_apps.dart';
import '../services/notification_badges.dart';
import '../state/app_state.dart';
import '../utils/app_exporter.dart';
import '../utils/backup_actions.dart';
import '../utils/format.dart';
import '../widgets/collapsed_nav.dart';
import '../widgets/theme_color_picker.dart';
import 'haptics_settings_screen.dart';
import 'log_screen.dart';
import 'permission_audit_screen.dart';
import 'storage_manager_screen.dart';
import 'storage_usage_screen.dart';
import 'sync_screen.dart';
import 'web_app_check_screen.dart';

/// App version shown in Settings and the About dialog.
const String kAppVersion = '1.1';

/// Project repository, opened from the About dialog.
const String kProjectUrl = 'https://github.com/whynbnb/hamstapp';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        leading: CollapsedNavScope.activeOf(context)
            ? const CollapsedNavButton()
            : null,
        title: Text(
          context.strings.t('设置'),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: ListView(
        children: [
          _SectionHeader(context.strings.t('外观')),
          ListTile(
            leading: Icon(_themeModeIcon(state.themeMode)),
            title: Text(context.strings.t('主题模式')),
            subtitle: Text(_themeModeLabel(context.strings, state.themeMode)),
            trailing: DropdownButton<AppThemeMode>(
              value: state.themeMode,
              underline: const SizedBox.shrink(),
              onChanged: (v) {
                if (v != null) state.setThemeMode(v);
              },
              items: [
                DropdownMenuItem(
                  value: AppThemeMode.system,
                  child: Text(context.strings.t('跟随系统')),
                ),
                DropdownMenuItem(
                  value: AppThemeMode.light,
                  child: Text(context.strings.t('浅色')),
                ),
                DropdownMenuItem(
                  value: AppThemeMode.dark,
                  child: Text(context.strings.t('深色')),
                ),
              ],
            ),
          ),
          ListTile(
            leading: Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: Color(state.themeColor),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.black12),
              ),
            ),
            title: Text(context.strings.t('主题色')),
            subtitle: Text(
              state.themeFollowWallpaper
                  ? context.strings.t('正在跟随壁纸取色')
                  : context.strings.t('选择一个预设色，或自定义任意颜色'),
            ),
            onTap: () => showThemeColorPicker(context, state),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.wallpaper_outlined),
            title: Text(context.strings.t('跟随壁纸取色')),
            subtitle: Text(
              context.strings.t(
                '从壁纸的主要颜色取种子色，回到前台时会重新读取（需要 Android 8.1 以上）',
              ),
            ),
            value: state.themeFollowWallpaper,
            onChanged: (v) async {
              await state.setThemeFollowWallpaper(v);
              if (!context.mounted || !v) return;
              if (state.wallpaperColors.isEmpty) {
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(
                    SnackBar(
                      content: Text(
                        context.strings.t(
                          '系统没有给出壁纸颜色，主题色保持原样（有些壁纸或系统不提供）',
                        ),
                      ),
                    ),
                  );
              }
            },
          ),
          ListTile(
            leading: Icon(_tileStyleIcon(state.tileStyle)),
            title: Text(context.strings.t('磁贴样式')),
            subtitle: Text(_tileStyleLabel(context.strings, state.tileStyle)),
            trailing: DropdownButton<TileStyle>(
              value: state.tileStyle,
              underline: const SizedBox.shrink(),
              onChanged: (v) {
                if (v != null) state.setTileStyle(v);
              },
              items: [
                DropdownMenuItem(
                  value: TileStyle.colorful,
                  child: Text(context.strings.t('多彩')),
                ),
                DropdownMenuItem(
                  value: TileStyle.glass,
                  child: Text(context.strings.t('通透')),
                ),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.translate_outlined),
            title: Text(context.strings.t('语言')),
            subtitle: Text(_languageLabel(context.strings, state.language)),
            trailing: DropdownButton<AppLanguage>(
              value: state.language,
              underline: const SizedBox.shrink(),
              onChanged: (v) {
                if (v != null) state.setLanguage(v);
              },
              items: [
                DropdownMenuItem(
                  value: AppLanguage.system,
                  child: Text(context.strings.t('跟随系统')),
                ),
                DropdownMenuItem(
                  value: AppLanguage.zh,
                  child: Text(context.strings.t('中文')),
                ),
                DropdownMenuItem(
                  value: AppLanguage.en,
                  child: const Text('English'),
                ),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.event_note_outlined),
            title: Text(context.strings.t('日期格式')),
            subtitle: Text(
              context.strings.t('示例：{sample}', {
                'sample':
                    '${state.dateStyle.sample} '
                    '${Fmt.clock(DateTime.now().millisecondsSinceEpoch)}',
              }),
            ),
            trailing: DropdownButton<DateStyle>(
              value: state.dateStyle,
              underline: const SizedBox.shrink(),
              onChanged: (v) {
                if (v != null) state.setDateStyle(v);
              },
              items: [
                // The items are today's date written each way, so no wording
                // is needed to explain them.
                for (final style in DateStyle.values)
                  DropdownMenuItem(value: style, child: Text(style.sample)),
              ],
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.schedule),
            title: Text(context.strings.t('24 小时制')),
            subtitle: Text(context.strings.t('关闭后时间显示为 1:05 PM')),
            value: state.clock24h,
            onChanged: state.setClock24h,
          ),
          const Divider(height: 1),
          _SectionHeader(context.strings.t('系统')),
          SwitchListTile(
            value: state.showSystemStatusBar,
            onChanged: (v) => state.setShowSystemStatusBar(v),
            title: Text(context.strings.t('显示系统状态栏')),
            subtitle: Text(
              context.strings.t('关闭后隐藏系统状态栏，内容更沉浸；向下滑动可临时唤出'),
            ),
            secondary: Icon(
              state.showSystemStatusBar
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
            ),
          ),
          SwitchListTile(
            value: state.rememberPosition,
            onChanged: (v) => state.setRememberPosition(v),
            title: Text(context.strings.t('记忆最后的位置')),
            subtitle: Text(
              context.strings.t('下次启动时回到上次的导航页、子标签和磁贴页'),
            ),
            secondary: const Icon(Icons.history),
          ),
          ListTile(
            leading: const Icon(Icons.vibration),
            title: Text(context.strings.t('触感反馈')),
            subtitle: Text(
              state.hapticsEnabled
                  ? context.strings.t('已开启')
                  : context.strings.t('已关闭'),
            ),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const HapticsSettingsScreen(),
              ),
            ),
          ),
          const Divider(height: 1),
          _SectionHeader(context.strings.t('导航')),
          ListTile(
            leading: Icon(_navModeIcon(state.navMode)),
            title: Text(context.strings.t('导航栏模式')),
            subtitle: Text(_navModeLabel(context.strings, state.navMode)),
            trailing: DropdownButton<NavMode>(
              value: state.navMode,
              underline: const SizedBox.shrink(),
              onChanged: (v) {
                if (v != null) state.setNavMode(v);
              },
              items: [
                DropdownMenuItem(
                  value: NavMode.auto,
                  child: Text(context.strings.t('自动')),
                ),
                DropdownMenuItem(
                  value: NavMode.bottom,
                  child: Text(context.strings.t('底部')),
                ),
                DropdownMenuItem(
                  value: NavMode.rail,
                  child: Text(context.strings.t('侧边栏')),
                ),
                DropdownMenuItem(
                  value: NavMode.collapsed,
                  child: Text(context.strings.t('折叠')),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          _SectionHeader(context.strings.t('磁贴')),
          ListTile(
            leading: const Icon(Icons.grid_view_rounded),
            title: Text(context.strings.t('新增磁贴默认大小')),
            subtitle: Text(
              context.strings.t(
                '当前 {size}×{size}，置顶新应用时使用',
                {'size': state.tileDefaultSize},
              ),
            ),
            trailing: DropdownButton<int>(
              value: state.tileDefaultSize,
              underline: const SizedBox.shrink(),
              onChanged: (v) {
                if (v != null) state.setTileDefaultSize(v);
              },
              items: const [
                DropdownMenuItem(value: 1, child: Text('1×1')),
                DropdownMenuItem(value: 2, child: Text('2×2')),
                DropdownMenuItem(value: 3, child: Text('3×3')),
                DropdownMenuItem(value: 4, child: Text('4×4')),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.swap_horiz),
            title: Text(context.strings.t('子标签切换方式')),
            subtitle: Text(
              _tileSwipeModeLabel(context.strings, state.tileSwipeMode),
            ),
            trailing: DropdownButton<TileSwipeMode>(
              value: state.tileSwipeMode,
              underline: const SizedBox.shrink(),
              onChanged: (v) {
                if (v != null) state.setTileSwipeMode(v);
              },
              items: [
                DropdownMenuItem(
                  value: TileSwipeMode.holdDrag,
                  child: Text(context.strings.t('长按拖动')),
                ),
                DropdownMenuItem(
                  value: TileSwipeMode.topLaunch,
                  child: Text(context.strings.t('上半屏启动')),
                ),
                DropdownMenuItem(
                  value: TileSwipeMode.bottomLaunch,
                  child: Text(context.strings.t('下半屏启动')),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          _SectionHeader(context.strings.t('通知')),
          SwitchListTile(
            secondary: const Icon(Icons.notifications_active_outlined),
            title: Text(context.strings.t('捕获通知')),
            subtitle: Text(
              context.strings.t('读取系统通知，用于未读角标；划掉通知不算已读，打开应用后清除'),
            ),
            value: state.notificationCapture,
            onChanged: (v) => _toggleNotificationCapture(context, state, v),
          ),
          const _NotificationStatusTile(),
          ListTile(
            leading: const Icon(Icons.grid_view_rounded),
            title: Text(context.strings.t('磁贴图标角标')),
            subtitle: Text(
              _badgeModeLabel(context.strings, state.tileBadgeMode),
            ),
            trailing: DropdownButton<NotificationBadgeMode>(
              value: state.tileBadgeMode,
              underline: const SizedBox.shrink(),
              onChanged: (v) {
                if (v != null) state.setTileBadgeMode(v);
              },
              items: _badgeModeItems(context),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.view_carousel_outlined),
            title: Text(context.strings.t('磁贴页面角标')),
            subtitle: Text(
              _badgeModeLabel(context.strings, state.pageBadgeMode),
            ),
            trailing: DropdownButton<NotificationBadgeMode>(
              value: state.pageBadgeMode,
              underline: const SizedBox.shrink(),
              onChanged: (v) {
                if (v != null) state.setPageBadgeMode(v);
              },
              items: _badgeModeItems(context),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.list_alt),
            title: Text(context.strings.t('其它位置角标')),
            subtitle: Text(
              _badgeModeLabel(context.strings, state.otherBadgeMode),
            ),
            trailing: DropdownButton<NotificationBadgeMode>(
              value: state.otherBadgeMode,
              underline: const SizedBox.shrink(),
              onChanged: (v) {
                if (v != null) state.setOtherBadgeMode(v);
              },
              items: _badgeModeItems(context),
            ),
          ),
          ListenableBuilder(
            listenable: NotificationBadges.instance,
            builder: (context, _) {
              final total = NotificationBadges.instance.total;
              if (total <= 0) return const SizedBox.shrink();
              return ListTile(
                leading: const Icon(Icons.notifications_off_outlined),
                title: Text(context.strings.t('清除全部角标')),
                subtitle: Text(
                  context.strings.t('{apps} 个应用共 {total} 条未读；滑动通知不会自动清除', {
                    'apps': NotificationBadges.instance.appCount,
                    'total': total,
                  }),
                ),
                onTap: () => _clearAllBadges(context),
              );
            },
          ),
          const Divider(height: 1),
          _SectionHeader(context.strings.t('日志')),
          SwitchListTile(
            secondary: const Icon(Icons.receipt_long_outlined),
            title: Text(context.strings.t('启用日志')),
            subtitle: Text(
              context.strings.t('记录运行日志，便于排查问题（默认关闭）'),
            ),
            value: state.loggingEnabled,
            onChanged: state.setLoggingEnabled,
          ),
          ListenableBuilder(
            listenable: AppLog.instance,
            builder: (context, _) => ListTile(
              leading: const Icon(Icons.article_outlined),
              title: Text(context.strings.t('查看日志')),
              subtitle: Text(
                state.loggingEnabled
                    ? context.strings.t('{n} 条记录 · 可按模块筛选并复制', {
                        'n': AppLog.instance.length,
                      })
                    : context.strings.t('日志未启用'),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const LogScreen()),
              ),
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.public),
            title: Text(context.strings.t('网页应用检测')),
            subtitle: Text(
              context.strings.t('查看扫描时对网页应用的识别情况（可复制）'),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const WebAppCheckScreen()),
            ),
          ),
          const Divider(height: 1),
          _SectionHeader(context.strings.t('高级')),
          ListTile(
            leading: const Icon(Icons.cloud_outlined),
            title: Text(context.strings.t('同步（FTP / Samba / WebDAV）')),
            subtitle: Text(state.remoteSource.summary),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SyncScreen()),
            ),
          ),
          const Divider(height: 1),
          _SectionHeader(context.strings.t('存储')),
          ListTile(
            leading: const Icon(Icons.storage_outlined),
            title: Text(context.strings.t('存储管理')),
            subtitle: Text(
              context.strings.t('查看占用并清理缓存（图标、APK、临时文件）'),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const StorageManagerScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.pie_chart_outline),
            title: Text(context.strings.t('应用占用')),
            subtitle: Text(context.strings.t('哪些应用最占空间（安装包/数据/缓存）')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const StorageUsageScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.image_outlined),
            title: Text(context.strings.t('刷新图标缓存')),
            subtitle: Text(
              context.strings.t('重新读取所有应用的图标，修复缺失或过期的图标'),
            ),
            onTap: () => refreshIconCache(context, state),
          ),
          const Divider(height: 1),
          _SectionHeader(context.strings.t('隐私')),
          ListTile(
            leading: const Icon(Icons.shield_outlined),
            title: Text(context.strings.t('权限体检')),
            subtitle: Text(
              context.strings.t('反查谁有麦克风、定位、无障碍、通知使用权等'),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const PermissionAuditScreen(),
              ),
            ),
          ),
          const Divider(height: 1),
          _SectionHeader(context.strings.t('数据备份')),
          ListTile(
            leading: const Icon(Icons.upload_file_outlined),
            title: Text(context.strings.t('导出数据包')),
            subtitle: Text(
              context.strings.t('把快照、磁贴、分组、备份列表等全部数据打包为单个文件'),
            ),
            onTap: () => exportData(context, state),
          ),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: Text(context.strings.t('导出应用清单')),
            subtitle: Text(
              context.strings.t('导出成 Markdown / CSV / 纯文本，带上分类、原因和备注'),
            ),
            onTap: () => exportAppList(context, state),
          ),
          ListTile(
            leading: const Icon(Icons.download_outlined),
            title: Text(context.strings.t('导入数据包')),
            subtitle: Text(
              context.strings.t('先清空当前数据，再完整导入（不支持部分导入）'),
            ),
            onTap: () => importData(context, state),
          ),
          ListTile(
            leading: Icon(
              Icons.delete_forever_outlined,
              color: Theme.of(context).colorScheme.error,
            ),
            title: Text(context.strings.t('清空数据')),
            subtitle: Text(context.strings.t('删除全部本地数据，无法恢复')),
            onTap: () => clearData(context, state),
          ),
          const Divider(height: 1),
          _SectionHeader(context.strings.t('关于')),
          ListTile(
            leading: const Icon(Icons.pets),
            title: Text(context.strings.t('囤囤 · Hamstapp')),
            subtitle: Text(context.strings.t('Android 应用管理器')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showAboutInfo(context),
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: Text(context.strings.t('版本')),
            subtitle: const Text(kAppVersion),
          ),
          const _DeviceInfoTile(),
        ],
      ),
    );
  }
}

String _languageLabel(AppStrings s, AppLanguage lang) {
  switch (lang) {
    case AppLanguage.system:
      return s.t('跟随系统语言');
    case AppLanguage.zh:
      return s.t('中文');
    case AppLanguage.en:
      return 'English';
  }
}

String _themeModeLabel(AppStrings s, AppThemeMode mode) {
  switch (mode) {
    case AppThemeMode.system:
      return s.t('跟随系统深浅色');
    case AppThemeMode.light:
      return s.t('始终使用浅色');
    case AppThemeMode.dark:
      return s.t('始终使用深色');
  }
}

String _tileStyleLabel(AppStrings s, TileStyle style) {
  switch (style) {
    case TileStyle.colorful:
      return s.t('每个应用一种纯色，醒目活泼');
    case TileStyle.glass:
      return s.t('毛玻璃半透明，轻盈通透');
  }
}

String _tileSwipeModeLabel(AppStrings s, TileSwipeMode mode) {
  switch (mode) {
    case TileSwipeMode.holdDrag:
      return s.t('长按磁贴空白处左右滑动切换启动子标签；直接滑动切换磁贴页');
    case TileSwipeMode.topLaunch:
      return s.t('上半屏滑动切换启动子标签，下半屏滑动切换磁贴页');
    case TileSwipeMode.bottomLaunch:
      return s.t('下半屏滑动切换启动子标签，上半屏滑动切换磁贴页');
  }
}

String _badgeModeLabel(AppStrings s, NotificationBadgeMode mode) {
  switch (mode) {
    case NotificationBadgeMode.count:
      return s.t('数字（超过 99 显示 99+）');
    case NotificationBadgeMode.dot:
      return s.t('红点');
    case NotificationBadgeMode.none:
      return s.t('不显示');
  }
}

List<DropdownMenuItem<NotificationBadgeMode>> _badgeModeItems(
  BuildContext context,
) {
  final s = context.strings;
  return [
    DropdownMenuItem(
      value: NotificationBadgeMode.count,
      child: Text(s.t('数字')),
    ),
    DropdownMenuItem(value: NotificationBadgeMode.dot, child: Text(s.t('红点'))),
    DropdownMenuItem(
      value: NotificationBadgeMode.none,
      child: Text(s.t('不显示')),
    ),
  ];
}

/// Forgets every unread mark. Unread survives the user swiping a notification
/// away (that is how chat totals keep working), so a badge can outlive the
/// notification itself — this is the escape hatch for those.
Future<void> _clearAllBadges(BuildContext context) async {
  final state = context.read<AppState>();
  await NativeApps.clearAllNotificationMarks();
  await state.refreshNotificationCounts();
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(context.strings.t('已清除全部通知角标'))),
  );
}

/// Turns notification capture on/off, guiding the user to the system
/// "notification access" UI the first time (the permission has no runtime
/// dialog and cannot be requested programmatically).
Future<void> _toggleNotificationCapture(
  BuildContext context,
  AppState state,
  bool value,
) async {
  await state.setNotificationCapture(value);
  if (!value) return;
  if (await state.hasNotificationAccess()) return;
  if (!context.mounted) return;
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(ctx.strings.t('需要通知使用权')),
      content: Text(
        ctx.strings.t('囤囤需要「通知使用权」才能读取其它应用的通知并在图标上显示角标。'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(ctx.strings.t('取消')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(ctx.strings.t('去开启')),
        ),
      ],
    ),
  );
  if (go == true) await state.openNotificationAccessSettings();
}

IconData _tileStyleIcon(TileStyle style) {
  switch (style) {
    case TileStyle.colorful:
      return Icons.grid_view_rounded;
    case TileStyle.glass:
      return Icons.blur_on;
  }
}

IconData _themeModeIcon(AppThemeMode mode) {
  switch (mode) {
    case AppThemeMode.system:
      return Icons.brightness_auto_outlined;
    case AppThemeMode.light:
      return Icons.light_mode_outlined;
    case AppThemeMode.dark:
      return Icons.dark_mode_outlined;
  }
}

String _navModeLabel(AppStrings s, NavMode mode) {
  switch (mode) {
    case NavMode.auto:
      return s.t('自动：平板横屏用侧边栏，手机与竖屏用底部导航');
    case NavMode.bottom:
      return s.t('正常：底部导航栏（当前默认）');
    case NavMode.rail:
      return s.t('侧边栏：左侧竖排，适合平板');
    case NavMode.collapsed:
      return s.t('折叠：点左上角按钮展开导航，长按直达启动页');
  }
}

IconData _navModeIcon(NavMode mode) {
  switch (mode) {
    case NavMode.auto:
      return Icons.auto_awesome_mosaic_outlined;
    case NavMode.bottom:
      return Icons.call_to_action_outlined;
    case NavMode.rail:
      return Icons.view_sidebar_outlined;
    case NavMode.collapsed:
      return Icons.menu;
  }
}

/// The "About" dialog: app icon, version, MIT license and a tappable link to
/// the project's GitHub repository.
Future<void> showAboutInfo(BuildContext context) {
  final s = context.strings;
  final scheme = Theme.of(context).colorScheme;
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: Image.asset(
              'assets/app_icon.png',
              width: 88,
              height: 88,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            s.t('囤囤 · Hamstapp'),
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 2),
          Text('${s.t('版本')} $kAppVersion'),
          const SizedBox(height: 14),
          Text(
            s.t('本软件以 MIT 许可证开源，可自由使用、修改与分发。'),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: 13,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 6),
          TextButton.icon(
            onPressed: () => NativeApps.openUrl(kProjectUrl),
            icon: const Icon(Icons.link, size: 18),
            label: const Text('github.com/whynbnb/hamstapp'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(s.t('关闭')),
        ),
      ],
    ),
  );
}

/// Clear the app icon cache and re-read every installed app's icon, showing a
/// blocking progress dialog while it runs.
Future<void> refreshIconCache(BuildContext context, AppState state) async {
  final messenger = ScaffoldMessenger.of(context);
  final s = context.strings;
  if (state.apps.isEmpty) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(s.t('请先在「应用」页扫描应用列表'))),
      );
    return;
  }
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(ctx.strings.t('刷新图标缓存')),
      content: Text(
        ctx.strings.t('将清空缓存并重新读取 {n} 个应用的图标。', {
          'n': state.apps.length,
        }),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(ctx.strings.t('取消')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(ctx.strings.t('刷新')),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;

  final navigator = Navigator.of(context, rootNavigator: true);
  final dialog = showDialog<void>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: true,
    builder: (_) => AlertDialog(
      content: Row(
        children: [
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 16),
          Expanded(child: Text(s.t('正在刷新图标…'))),
        ],
      ),
    ),
  );
  final n = await state.refreshIconCache();
  if (navigator.canPop()) navigator.pop();
  await dialog;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(content: Text(s.t('已刷新 {n} 个应用图标', {'n': n}))),
    );
}

/// Shows whether notifications are actually being captured, and doubles as the
/// shortcut into the system notification-access UI.
class _NotificationStatusTile extends StatefulWidget {
  const _NotificationStatusTile();

  @override
  State<_NotificationStatusTile> createState() => _NotificationStatusTileState();
}

class _NotificationStatusTileState extends State<_NotificationStatusTile>
    with WidgetsBindingObserver {
  /// Whether notification access is granted; null while the first check runs.
  bool? _granted;

  /// Latest native diagnostics (see [AppState.notificationDiagnostics]).
  Map<String, dynamic> _diag = const {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-check on return from the system settings screen.
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    final app = context.read<AppState>();
    bool granted;
    try {
      granted = await NativeApps.hasNotificationAccess();
    } catch (_) {
      granted = false;
    }
    final diag = await app.notificationDiagnostics();
    if (!mounted) return;
    final changed = _granted != granted;
    setState(() {
      _granted = granted;
      _diag = diag;
    });
    if (changed && granted) {
      // Access was just granted: start pulling counts.
      await app.syncNotificationBadges();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final scheme = Theme.of(context).colorScheme;
    final capturing = context.watch<AppState>().notificationCapture;
    final granted = _granted;
    final connected = _diag['connected'] == true;
    final events = (_diag['events'] as num?)?.toInt() ?? 0;

    final IconData icon;
    final Color? iconColor;
    final Widget subtitle;
    if (!capturing) {
      icon = Icons.notifications_off_outlined;
      iconColor = null;
      subtitle = Text(s.t('未开启：打开上面的开关即可开始捕获'));
    } else if (granted != true) {
      icon = Icons.error_outline;
      iconColor = scheme.error;
      subtitle = Text(
        granted == null
            ? s.t('正在检查…')
            : s.t('未授权 · 点击前往系统设置开启'),
      );
    } else if (!connected) {
      icon = Icons.sync_problem;
      iconColor = scheme.error;
      subtitle = Text(s.t('已授权，但通知服务未连接 · 点此修复'));
    } else {
      icon = Icons.notifications_active;
      iconColor = scheme.primary;
      subtitle = ListenableBuilder(
        listenable: NotificationBadges.instance,
        builder: (context, _) => Text(
          s.t('正在捕获 · {n} 个应用有未读（事件 {events}）', {
            'n': NotificationBadges.instance.appCount,
            'events': events,
          }),
        ),
      );
    }

    return ListTile(
      leading: Icon(icon, color: iconColor),
      title: Text(s.t('状态')),
      subtitle: subtitle,
      trailing: IconButton(
        icon: const Icon(Icons.article_outlined),
        tooltip: s.t('查看通知日志'),
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                const LogScreen(initialModule: LogModule.notifications),
          ),
        ),
      ),
      onTap: () async {
        final app = context.read<AppState>();
        if (granted != true) {
          await app.openNotificationAccessSettings();
        } else {
          // A rebind alone cannot force the system to re-bind a listener it
          // dropped, so when it is missing walk the user through re-granting.
          await app.syncNotificationBadges();
          if (!connected && mounted) await _showReconnectHelp();
        }
        await _check();
      },
    );
  }

  Future<void> _showReconnectHelp() async {
    final s = context.strings;
    final app = context.read<AppState>();
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.t('通知服务未连接')),
        content: Text(
          s.t(
            '系统没有把通知监听服务绑定给囤囤。在接下来的系统设置里，把「囤囤」的通知使用权关掉再打开即可恢复。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(s.t('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(s.t('去设置')),
          ),
        ],
      ),
    );
    if (go == true) await app.openNotificationAccessSettings();
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

class _DeviceInfoTile extends StatelessWidget {
  const _DeviceInfoTile();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>>(
      future: NativeApps.getDeviceInfo(),
      builder: (context, snap) {
        final info = snap.data;
        final text = info == null
            ? context.strings.t('读取中…')
            : '${info['manufacturer']} ${info['model']} · Android ${info['androidVersion']} (API ${info['sdkInt']})';
        return ListTile(
          leading: const Icon(Icons.phone_android),
          title: Text(context.strings.t('设备')),
          subtitle: Text(text),
        );
      },
    );
  }
}
