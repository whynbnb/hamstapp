import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_strings.dart';
import '../services/native_apps.dart';
import '../state/app_state.dart';
import '../utils/backup_actions.dart';
import '../widgets/floating_nav.dart';
import '../widgets/theme_color_picker.dart';
import 'haptics_settings_screen.dart';
import 'sync_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        leading: FloatingNavScope.activeOf(context)
            ? const FloatingNavButton()
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
            subtitle: Text(context.strings.t('选择一个预设色，或自定义任意颜色')),
            onTap: () => showThemeColorPicker(context, state),
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
                  value: NavMode.floating,
                  child: Text(context.strings.t('悬浮')),
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
          ListTile(
            leading: const Icon(Icons.image_outlined),
            title: Text(context.strings.t('刷新图标缓存')),
            subtitle: Text(
              context.strings.t('重新读取所有应用的图标，修复缺失或过期的图标'),
            ),
            onTap: () => refreshIconCache(context, state),
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
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: Text(context.strings.t('版本')),
            subtitle: const Text('1.0'),
          ),
          const _DeviceInfoTile(),
          const Divider(height: 1),
          _SectionHeader(context.strings.t('提示')),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            child: Text(
              context.strings.t(
                '磁贴：在「启动 → 磁贴」点击右上角 ✏️ 进入编辑模式，'
                '长按磁贴拖动移动、拖动右下角缩放；完成后点击右上角「完成」退出。',
              ),
              style: const TextStyle(fontSize: 13, height: 1.5),
            ),
          ),
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
    case NavMode.floating:
      return s.t('无导航栏：点右下角悬浮按钮展开导航');
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
    case NavMode.floating:
      return Icons.bubble_chart_outlined;
  }
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
