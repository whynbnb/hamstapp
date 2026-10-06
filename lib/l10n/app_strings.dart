import 'package:flutter/material.dart';

/// Which UI language to use.
///
/// - [system]: follow the device language (Chinese when the device is Chinese,
///   otherwise English).
/// - [zh]: always Chinese.
/// - [en]: always English.
enum AppLanguage { system, zh, en }

/// Lightweight localization for the app.
///
/// Instead of generated ARB files, translations are keyed by the Chinese source
/// strings. Any missing entry falls back to the original Chinese text, so the
/// app never shows a raw key. Interpolation is done with `{name}` placeholders,
/// e.g. `t('已恢复 {count} 条应用', {'count': 3})`.
class AppStrings {
  const AppStrings(this.langCode);

  /// `'zh'` or `'en'`.
  final String langCode;

  bool get isZh => langCode == 'zh';

  /// Best-effort global instance for code that has no [BuildContext] (helpers,
  /// services, state). Widgets should prefer `context.strings` so they rebuild
  /// when the language changes.
  static AppStrings current = const AppStrings('zh');

  static AppStrings of(BuildContext context) =>
      Localizations.of<AppStrings>(context, AppStrings) ?? current;

  static const LocalizationsDelegate<AppStrings> delegate =
      _AppStringsDelegate();

  /// Translates [zh]. When the language is English, looks up the English
  /// template and replaces `{name}` placeholders from [args].
  String t(String zh, [Map<String, Object?>? args]) {
    final template = isZh ? zh : (_en[zh] ?? zh);
    return _fill(template, args);
  }

  static String _fill(String template, Map<String, Object?>? args) {
    if (args == null || args.isEmpty) return template;
    var out = template;
    args.forEach((key, value) {
      out = out.replaceAll('{$key}', '${value ?? ''}');
    });
    return out;
  }

  /// Convenience aliases used widely in the UI.
  String get appTitle => t('囤囤');
  String get appFullTitle => t('囤囤 · Hamstapp');
}

extension AppStringsContextX on BuildContext {
  AppStrings get strings => AppStrings.of(this);
}

class _AppStringsDelegate extends LocalizationsDelegate<AppStrings> {
  const _AppStringsDelegate();

  @override
  bool isSupported(Locale locale) =>
      locale.languageCode == 'zh' || locale.languageCode == 'en';

  @override
  Future<AppStrings> load(Locale locale) async {
    final strings = AppStrings(
      locale.languageCode == 'en' ? 'en' : 'zh',
    );
    AppStrings.current = strings;
    return strings;
  }

  @override
  bool shouldReload(_AppStringsDelegate old) => false;
}

/// Chinese source string -> English translation. Keyed by the exact Chinese
/// template (with `{name}` placeholders where arguments are used).
const Map<String, String> _en = <String, String>{
  // ---- common actions / words
  '取消': 'Cancel',
  '保存': 'Save',
  '删除': 'Delete',
  '删除页面': 'Delete page',
  '删除同步源': 'Delete sync source',
  '删除快照': 'Delete snapshot',
  '删除分类': 'Delete category',
  '删除当前源': 'Delete this source',
  '删除备份列表': 'Delete backup list',
  '删除全部本地数据，无法恢复': 'Delete all local data. This cannot be undone.',
  '确定': 'OK',
  '完成': 'Done',
  '创建': 'Create',
  '新建分类': 'New category',
  '新建同步源': 'New sync source',
  '新建磁贴页': 'New tile page',
  '新建备份列表': 'New backup list',
  '重命名': 'Rename',
  '重命名快照': 'Rename snapshot',
  '重命名页面': 'Rename page',
  '编辑': 'Edit',
  '编辑分类': 'Edit category',
  '编辑当前源': 'Edit this source',
  '编辑同步源': 'Edit sync source',
  '编辑磁贴': 'Edit tiles',
  '编辑磁贴（添加/拖动/缩放）': 'Edit tiles (add / drag / resize)',
  '编辑卸载原因': 'Edit uninstall reason',
  '清空': 'Clear',
  '清空并导入': 'Clear and import',
  '清空数据': 'Clear data',
  '清除': 'Clear',
  '清除原因': 'Clear reason',
  '清除该应用的自定义信息': 'Clear this app\'s custom info',
  '清除下载缓存': 'Clear download cache',
  '恢复': 'Restore',
  '恢复标注数据': 'Restore annotations',
  '刷新': 'Refresh',
  '刷新应用列表': 'Refresh app list',
  '刷新应用列表\n长按查看统计信息': 'Refresh app list\nLong-press for stats',
  '重试': 'Retry',
  '打开': 'Open',
  '安装': 'Install',
  '卸载': 'Uninstall',
  '卸载应用': 'Uninstall app',
  '添加应用': 'Add app',
  '添加卸载原因': 'Add uninstall reason',
  '添加收藏': 'Add to favorites',
  '取消收藏': 'Remove from favorites',
  '固定到磁贴': 'Pin to a tile',
  '移出列表': 'Remove from list',
  '移出分类': 'Remove from category',
  '置顶应用到磁贴': 'Pin an app to the tile board',
  '添加应用到该分类': 'Add an app to this category',
  '找到替代品': 'Found a replacement',
  '测试连接': 'Test connection',
  '导出数据包': 'Export data',
  '导入数据包': 'Import data',
  '导入数据': 'Import data',
  '导出囤囤数据': 'Export Hamstapp data',
  '选择囤囤数据包': 'Select a Hamstapp data file',
  '编辑模式：点右上角 ➕ 置顶应用，长按磁贴拖动移动，拖动右下角缩放；完成后点「完成」':
      'Edit mode: tap ➕ to pin apps, long-press a tile to move it, drag its corner to resize, then tap Done.',
  '磁贴：在「启动 → 磁贴」点击右上角 ✏️ 进入编辑模式，长按磁贴拖动移动、拖动右下角缩放；完成后点击右上角「完成」退出。':
      'Tiles: on Launch → Tiles, tap ✏️ to edit. Long-press a tile to move it, drag its corner to resize, then tap Done.',
  '长按磁贴拖动移动、拖动右下角缩放；完成后点击右上角「完成」退出。':
      'Long-press a tile to move it, drag its corner to resize, then tap Done.',
  '点右上角 ➕ 选择要置顶的应用\n长按拖动移动，拖右下角缩放':
      'Tap ➕ to pick apps to pin.\nLong-press to move, drag the corner to resize.',
  '点击安装，长按可先下载解析 APK 信息（名称/版本/包名）':
      'Tap to install; long-press to download and parse its APK info first (name / version / package).',
  '点击安装；长按或 ⋮ 可获取信息、忽略缓存重新获取或删除单项缓存':
      'Tap to install; long-press or ⋮ to load info, refresh ignoring cache, or delete a single cache entry.',
  '获取 APK 信息': 'Load APK info',
  '刷新 APK 信息': 'Refresh APK info',
  '忽略缓存重新获取': 'Re-fetch (ignore cache)',
  '删除该项缓存': 'Delete this cache',
  '已删除该项缓存（{size}）': 'Removed cache ({size})',
  '请先点击右上角「完成」结束磁贴编辑': 'Tap Done first to finish editing tiles.',

  // ---- tabs / sections
  '启动': 'Launch',
  '应用': 'Apps',
  '分类': 'Categories',
  '收藏': 'Favorites',
  '最近': 'Recent',
  '快照': 'Snapshots',
  '磁贴': 'Tiles',
  '设置': 'Settings',
  '备份': 'Backup',
  '备份列表': 'Backup lists',
  '快照与备份': 'Snapshots & backup',
  '外观': 'Appearance',
  '系统': 'System',
  '导航': 'Navigation',
  '高级': 'Advanced',
  '数据备份': 'Data backup',
  '关于': 'About',
  '提示': 'Tips',
  '分组': 'Groups',
  '排序': 'Sort',
  '筛选与排序': 'Filter & sort',
  '筛选': 'Filter',
  '正序': 'Ascending',
  '倒序': 'Descending',
  '重置': 'Reset',
  '排序 / 时间筛选': 'Sort / time filter',
  '最近 · 排序与筛选': 'Recent · sort & filter',
  '推荐': 'Recommended',
  '智能推荐': 'Smart suggestions',
  '根据常用时间段，在「最近」顶部推荐此刻可能想用的应用':
      'Suggest apps you likely need right now, based on the time of day',
  '已记录 {n} 次启动 · 当前 {m} 个推荐':
      '{n} launches recorded · {m} suggestions now',
  '清除启动记录': 'Clear launch history',
  '删除全部启动时间与次数': 'Delete all launch times and counts',
  '将删除全部启动时间记录与启动次数，且无法恢复。确定吗？':
      'This deletes all launch time records and launch counts and cannot be undone. Continue?',
  '主题模式': 'Theme mode',
  '主题色': 'Theme color',
  '磁贴样式': 'Tile style',
  '多彩': 'Colorful',
  '通透': 'Glass',
  '每个应用一种纯色，醒目活泼': 'A solid color per app, bold and lively',
  '毛玻璃半透明，轻盈通透': 'Frosted and translucent, light and airy',
  '导航栏模式': 'Navigation style',
  '显示系统状态栏': 'Show system status bar',
  '关闭后隐藏系统状态栏，内容更沉浸；向下滑动可临时唤出':
      'Hide the system status bar for a more immersive view; swipe down to reveal it temporarily.',
  '记忆最后的位置': 'Remember last position',
  '下次启动时回到上次的导航页、子标签和磁贴页':
      'Reopen on the last navigation tab, sub-tab and tile page you were on',
  '新增磁贴默认大小': 'Default size for new tiles',
  '显示应用名称': 'Show app name',
  '关闭后磁贴只显示图标': 'When off, the tile shows only its icon',
  '内边距': 'Inner padding',
  '关闭后内容填满磁贴': 'When off, content fills the tile',
  '显示边框': 'Show border',
  '关闭后只显示图标/文字，无底板': 'When off, only the icon/text shows, no backdrop',
  '触感反馈': 'Haptics',
  '启用触感反馈': 'Enable haptics',
  '切换标签或磁贴页时给出轻微震动':
      'A subtle tick when switching tabs or tile pages',
  '触发场景': 'Triggers',
  '主标签切换': 'Main tab switch',
  '启动 / 应用 / 快照 / 设置': 'Launch / Apps / Snapshots / Settings',
  '启动子标签切换': 'Launch sub-tab switch',
  '磁贴 / 分类 / 收藏 / 最近': 'Tiles / Categories / Favorites / Recent',
  '磁贴子页切换': 'Tile page switch',
  '磁贴页之间左右滑动': 'Swiping between tile pages',
  '效果': 'Effect',
  '震动效果': 'Effect',
  '震动等级': 'Strength',
  '轻触': 'Selection',
  '冲击': 'Impact',
  '振动': 'Vibrate',
  '轻触：切换标签的细微反馈': 'Selection: a subtle tick for tab switches',
  '冲击：按等级产生的敲击感': 'Impact: a knock whose strength follows the level',
  '振动：较长的持续震动': 'Vibrate: a longer, constant buzz',
  '用于「冲击」效果': 'Used by the Impact effect',
  '仅「冲击」效果生效': 'Only applies to the Impact effect',
  '测试一下': 'Try it',
  '已开启': 'On',
  '已关闭': 'Off',
  '固定到磁贴页…': 'Pin to a tile page…',
  '可固定到任意磁贴页，或长按再加一份':
      'Pin to any tile page, or long-press to add another',
  '还没有磁贴页，先在「启动 → 磁贴」新建一个吧':
      'No tile pages yet — create one under Launch → Tiles first',
  '固定到磁贴页': 'Pin to a tile page',
  '点击固定/取消，长按再添加一个': 'Tap to pin/unpin, long-press to add another',
  '已固定 {n} 份': '{n} pinned',
  '分类排序': 'Category order',
  '分类名称': 'Category name',
  '选择一个预设色，或自定义任意颜色':
      'Pick a preset, or choose any custom color',
  '自定义': 'Custom',
  '预设': 'Presets',
  '色相': 'Hue',
  '饱和度': 'Saturation',
  '明度': 'Brightness',
  '跟随系统': 'System',
  '跟随系统深浅色': 'Match system light/dark',
  '始终使用浅色': 'Always light',
  '始终使用深色': 'Always dark',
  '浅色': 'Light',
  '深色': 'Dark',
  '自动': 'Auto',
  '底部': 'Bottom',
  '侧边栏': 'Side rail',
  '悬浮': 'Floating',
  '自动：平板横屏用侧边栏，手机与竖屏用底部导航':
      'Auto: side rail on tablets in landscape, bottom bar elsewhere',
  '正常：底部导航栏（当前默认）': 'Normal: bottom navigation bar',
  '侧边栏：左侧竖排，适合平板': 'Side rail: vertical, best for tablets',
  '无导航栏：点右下角悬浮按钮展开导航':
      'No bar: tap the floating button to open navigation',
  '手动排序': 'Manual',
  '按名称': 'By name',
  '按应用数': 'By app count',
  '按时间排序': 'Sort by time',
  '按频次排序': 'Sort by frequency',
  '按更新时间': 'By update time',
  '按大小': 'By size',
  '按安装时间': 'By install time',
  '时间段': 'Time range',
  '今天': 'Today',
  '近 7 天': 'Last 7 days',
  '近 30 天': 'Last 30 days',

  // ---- usage trends
  '使用趋势': 'Usage trends',
  '最常用 / 被冷落 / 从未启动': 'Most used / neglected / never launched',
  '{n} 天': '{n} days',
  '最常用': 'Most used',
  '被冷落': 'Neglected',
  '曾经常用，近 {days} 天未打开': 'Used before, not opened in {days} days',
  '从未启动': 'Never launched',
  '已安装，但从未从囤囤启动过': 'Installed but never launched from Hamstapp',
  '近 {days} 天启动 {total} 次 · 覆盖 {active} 个应用 · 被冷落 {neglected} 个 · 从未启动 {never} 个':
      '{total} launches across {active} apps in {days} days · {neglected} neglected · {never} never launched',
  '这段时间还没有启动记录': 'No launches in this period',
  '没有长期搁置的应用': 'No long-idle apps',
  '仅显示最常用的前 {n} 个': 'Showing the top {n} by past usage',
  '所有应用都至少启动过一次': 'Every app has been launched at least once',
  '上次 {ago}': 'Last {ago}',
  '{n} 次': '{n}x',
  '曾启动 {count} 次 · 上次 {ago}': 'Launched {count} times before · last {ago}',
  '查看详情': 'View details',
  '使用记录': 'Usage',
  '清除使用记录': 'Clear usage',
  '从囤囤启动 {count} 次': 'Launched {count} times from Hamstapp',
  '还没有从囤囤启动过': 'Never launched from Hamstapp',
  '清除「{name}」的使用记录？': 'Clear usage for "{name}"?',
  '将删除该应用的启动次数与时间记录，不影响它的分类、原因和备注。':
      "Deletes this app's launch count and times. Its category, reason and note are kept.",
  '已清除「{name}」的使用记录': 'Cleared usage for "{name}"',
  '还没有启动记录': 'No launch history yet',
  '从囤囤里启动应用后，这里会统计最常用、被冷落和从未启动的应用。':
      'Apps you launch from Hamstapp are tracked here as most used, neglected and never launched.',

  // ---- apps screen
  '全部': 'All',
  '用户': 'User',
  '系统应用': 'System app',
  '搜索应用': 'Search apps',
  '搜索应用名 / 包名 / 拼音首字母':
      'Search by name / package / pinyin initials',
  '有原因': 'Has reason',
  '已分类': 'Categorized',
  '未分类': 'Uncategorized',
  '未整理': 'Unorganized',
  '已收藏': 'Favorited',
  '已卸载': 'Uninstalled',
  '未分组、无原因/备注，且未收藏、未固定到磁贴':
      'No group, reason or note, not favorited and not pinned',
  '没有匹配的应用': 'No matching apps',
  '显示未变化': 'Show unchanged',
  '隐藏未变化': 'Hide unchanged',
  '应用类型': 'App type',
  '当前设备': 'This device',

  // ---- app detail
  '应用信息': 'App info',
  '导出 APK（分享）': 'Export APK (share)',
  '找不到该应用的 APK 文件': 'No APK file found for this app',
  '导出失败，可能无法读取该应用的 APK':
      "Export failed — this app's APK may not be readable",
  '应用详情': 'App details',
  '安装原因': 'Install reason',
  '安装原因：{reason}': 'Install reason: {reason}',
  '为什么安装它？例如：薅羊毛、工作需要、朋友推荐…':
      'Why did you install it? e.g. a deal, for work, a friend recommended it…',
  '为什么卸载它？': 'Why did you uninstall it?',
  '备注': 'Note',
  '其它想记录的信息': 'Anything else to note',
  '包名：{pkg}': 'Package: {pkg}',
  '版本': 'Version',
  '版本号': 'Version code',
  '大小': 'Size',
  '安装时间': 'Install time',
  '更新时间': 'Update time',
  'APK 路径': 'APK path',
  '已安装：{name} v{version}': 'Installed: {name} v{version}',
  '已安装 {n}': '{n} installed',
  '安装于 {date} · 更新于 {ago}': 'Installed {date} · updated {ago}',
  '启动 {count} 次 · 上次 {ago}': 'Launched {count} times · last {ago}',
  '已是最新 ({version})': 'Up to date ({version})',
  '已安装更高版本 ({version})': 'Newer version installed ({version})',
  '可更新 {from} → {to}': 'Update available {from} → {to}',
  '更新（版本未知）': 'Update (version unknown)',
  '新安装': 'Newly installed',
  '更新': 'Update',
  '该应用当前不在设备上，点击记录卸载原因':
      'This app is not on the device. Tap to record an uninstall reason.',
  '点击添加卸载原因': 'Tap to add an uninstall reason',
  '已清除该应用的自定义信息': 'Cleared this app\'s custom info',

  // ---- snapshots / compare
  '创建快照': 'Create snapshot',
  '快照名称': 'Snapshot name',
  '快照 {n}': 'Snapshot {n}',
  '备份当前全部应用': 'Back up all apps now',
  '对比上次快照后发现以下应用已不在设备上，可以为它们记录卸载原因。':
      'These apps are no longer on the device compared with the last snapshot. You can record uninstall reasons for them.',
  '检测到 {n} 个应用被卸载': 'Detected {n} uninstalled apps',
  '已全部处理': 'All handled',
  '还没有快照。\n快照会记录当前安装的应用列表，\n方便以后比对新增 / 卸载 / 更新。':
      'No snapshots yet.\nA snapshot records the installed apps\nso you can compare additions / removals / updates later.',
  '与其它快照对比': 'Compare with another snapshot',
  '与「当前」对比': 'Compare with current',
  '列表差异': 'List diff',
  '新增 {n}': 'Added {n}',
  '卸载 {n}': 'Removed {n}',
  '更新 {n}': 'Updated {n}',
  '未变化 ({n})': 'Unchanged ({n})',
  '未安装 / 已卸载 ({n})': 'Missing / uninstalled ({n})',
  '共 {n} 处变化 · 新增 {a} · 卸载 {r} · 更新 {u}':
      '{n} changes · added {a} · removed {r} · updated {u}',
  '基准：{label}': 'Base: {label}',
  '对比：{label}': 'Compared with: {label}',
  '没有新增应用': 'No added apps',
  '没有卸载应用': 'No removed apps',
  '没有应用更新': 'No app updates',
  '已换设备': 'Switched devices',
  '重定向次数过多': 'Too many redirects',
  '将用「{name}」中记录的安装原因、备注、分类、收藏及卸载记录':
      'This will use the install reasons, notes, categories, favorites and uninstall records from "{name}"',
  '覆盖当前对应应用的标注数据。\n\n':
      ' and overwrite the matching apps\' annotations.\n\n',
  '此操作只恢复数据，不会安装或卸载任何应用。':
      'This only restores data; no apps will be installed or uninstalled.',
  '已恢复 {count} 条应用的标注数据': 'Restored annotations for {count} apps',

  // ---- backup lists
  '把重要 / 想长期跟踪的应用放进列表，\n随时知道它们是否还在设备上。':
      'Put important or long-term apps in a list\nto keep track of whether they are still on the device.',
  '还没有备份列表。\n把重要 / 想长期跟踪的应用放进列表，\n随时知道它们是否还在设备上。':
      'No backup lists yet.\nPut important or long-term apps in a list\nto know whether they are still on the device.',
  '共 {total} 个 · 已安装 {installed} · 缺失 {missing}':
      '{total} total · {installed} installed · {missing} missing',
  '{n} 个应用 · 已安装 {installed}': '{n} apps · {installed} installed',
  '更新于 {ago}': 'Updated {ago}',
  '安装于 {date}': 'Installed {date}',
  '大小 {size}': 'Size {size}',
  '将把当前扫描到的 {n} 个应用全部加入「{list}」，':
      'All {n} scanned apps will be added to "{list}" ',
  '并替换原有内容。': 'and replace the existing content.',
  '扫描失败：{error}': 'Scan failed: {error}',

  // ---- categories
  '例如：常用工具、必装应用': 'e.g. Utilities, Must-have',
  '颜色': 'Color',
  '图标': 'Icon',
  '自定义 Emoji': 'Custom emoji',
  '粘贴或输入一个 Emoji': 'Paste or type an emoji',
  '该分类下还没有应用\n点击右上角 ➕ 添加':
      'No apps in this category yet.\nTap ➕ to add.',
  '搜索要加入的应用': 'Search apps to add',
  '添加到「{emoji} {name}」': 'Add to "{emoji} {name}"',
  '删除「{name}」后，应用上的该分类也会移除。':
      'Deleting "{name}" also removes it from apps.',
  '还没有分类，点击「新建分类」创建一个吧':
      'No categories yet. Tap "New category" to create one.',
  '还没有分类。\n点击右上角新建一个，再到应用详情里给应用归类。':
      'No categories yet.\nCreate one from the top-right, then assign apps from their details.',
  '{n} 个分类': '{n} categories',
  '{n} 个应用': '{n} apps',
  '· 拖动行可排序': '· drag rows to reorder',

  // ---- tiles
  '页面名称': 'Page name',
  '磁贴页管理': 'Manage tile pages',
  '{n} 个磁贴': '{n} tiles',
  '将删除「{name}」，页面上的磁贴会移回第一页。确定删除吗？':
      'Delete "{name}"? Its tiles will move back to the first page.',
  '页面': 'Page',
  '页面 {n}': 'Page {n}',
  '无磁贴页': 'No tile page',
  '还没有磁贴页': 'No tile pages yet',
  '第 {index} / {total} 页': 'Page {index} / {total}',
  '尚未固定到任何磁贴页': 'Not pinned to any tile page',
  '页面上的磁贴会移回第一个页面': 'Tiles on this page move back to the first page',
  '页面上的磁贴也会一并删除': 'Tiles on this page are deleted too',
  '将删除「{name}」，页面上的磁贴也会一并删除。确定删除吗？':
      'Delete "{name}"? Its tiles will be deleted too.',
  '固定到当前页「{page}」': 'Pin to current page "{page}"',
  '当前页：{page} · 点击固定/取消，长按再添加一个':
      'Current page: {page} · tap to pin/unpin, long-press to add another',
  '当前页已有 {n} 份（可多份）': '{n} copies on this page already',
  '已固定到「{page}」': 'Pinned to "{page}"',
  '已再添加一个到「{page}」': 'Added another to "{page}"',
  '已取消固定': 'Unpinned',
  '移除该磁贴': 'Remove this tile',
  '确定移除这个磁贴吗？': 'Remove this tile?',
  '移除': 'Remove',
  '「{page}」还没有磁贴\n点击右上角 ✏️ 进入编辑，再点 ➕ 选择要置顶的应用':
      'No tiles on "{page}" yet.\nTap ✏️ to edit, then ➕ to pick apps to pin.',
  '还没有收藏的应用\n点击右上角 ➕ 添加，即可在这里一键启动':
      'No favorites yet.\nTap ➕ to add apps and launch them here.',
  '还没有启动记录\n从囤囤里启动应用后会出现在这里':
      'No launch history yet.\nApps you launch from Hamstapp will show up here.',
  '该时间段内没有启动记录\n可在右上角调整时间段':
      'No launches in this range.\nAdjust the range from the top-right.',

  // ---- sync / remote
  '同步': 'Sync',
  '同步远程 APK': 'Sync remote APKs',
  '同步（FTP / Samba / WebDAV）': 'Sync (FTP / Samba / WebDAV)',
  '远程目录': 'Remote directory',
  '共享路径': 'Share path',
  '主机': 'Host',
  '端口': 'Port',
  '用户名': 'Username',
  '密码': 'Password',
  '匿名登录': 'Anonymous',
  '匿名': 'Anonymous',
  '域 / 工作组（可选）': 'Domain / workgroup (optional)',
  '描述（可选）': 'Description (optional)',
  '选择文件': 'Choose file',
  '还没有同步源': 'No sync sources yet',
  '未配置': 'Not configured',
  '确定删除「{name}」吗？': 'Delete "{name}"?',
  '请先填写主机和路径': 'Enter the host and path first',
  '请至少填写主机和路径': 'Enter at least the host and path',
  '使用 HTTPS': 'Use HTTPS',
  '发现 {n} 个 APK': 'Found {n} APKs',
  '连接成功，发现 {n} 个 APK': 'Connected. Found {n} APKs',
  '连接失败：{error}': 'Connection failed: {error}',
  '获取信息失败：{error}': 'Failed to fetch info: {error}',
  '加载失败\n{error}': 'Load failed\n{error}',
  '下载失败': 'Download failed',
  '安装失败：{error}': 'Install failed: {error}',
  '已交给系统安装器：{path}': 'Handed to the system installer: {path}',
  '无法调起系统安装器': 'Could not open the system installer',
  '已获取 APK 信息': 'APK info loaded',
  '已缓存': 'Cached',
  '缓存版本': 'Cache retention',
  '仅保留最新版': 'Latest only',
  '全部保留': 'Keep all',
  '「仅保留最新版」用新版覆盖缓存；「全部保留」保留历史版本以便离线重装。':
      '"Latest only" replaces the cached copy; "Keep all" archives older versions for offline rollback.',
  '历史缓存': 'Archived',
  // remote APK detail
  '文件信息': 'File info',
  '文件名': 'File name',
  '相对路径': 'Relative path',
  '远程路径': 'Remote path',
  '来源': 'Source',
  '远程修改时间': 'Remote modified',
  'APK 信息': 'APK info',
  '应用名': 'App name',
  '包名': 'Package name',
  '版本名': 'Version name',
  '本地缓存': 'Local cache',
  '已安装': 'Installed',
  '历史版本': 'Version history',
  '历史版本 · {n} 个': 'Version history · {n}',
  '历史版本（先获取信息以归组）':
      'Version history (fetch info to group versions)',
  '尚未解析，点「获取信息」后可查看包名、版本等，并参与版本归组':
      'Not parsed yet. Tap "Get info" to see the package/version and join version grouping.',
  '更新 / 覆盖安装': 'Update / reinstall',
  '删除缓存': 'Delete cache',
  '安装此版本': 'Install this version',
  '无法读取缓存文件': 'Cannot read the cached file',
  '请先允许「安装未知应用」，然后重试':
      'Allow "install unknown apps" first, then retry',
  // orphan cache
  '孤包列表': 'Orphan cache',
  '共 {n} 个孤包 · {size}': '{n} orphans · {size}',
  '未知包名': 'Unknown package',
  '{n} 个版本 · {size}': '{n} versions · {size}',
  '来源：{src}': 'Source: {src}',
  '已删除的源': 'Deleted source',
  '全部删除': 'Delete all',
  '缓存文件不存在': 'Cached file not found',
  '没有孤包缓存': 'No orphan cache',
  '这里列出已缓存、但当前未安装的 APK，可离线安装或删除。':
      'Cached APKs that are not currently installed — install or delete them offline.',
  '已删除 {n} 项缓存（{size}）': 'Deleted {n} cached items ({size})',
  '没有找到 APK\n{summary}': 'No APKs found\n{summary}',
  '已清除缓存（{size}）': 'Cache cleared ({size})',
  '删除已缓存的 APK 与信息，下次安装会重新下载。':
      'Delete cached APKs and info; they will be downloaded again next time.',
  '该地址不是 WebDAV 服务，或不允许 PROPFIND':
      'This address is not a WebDAV service, or PROPFIND is not allowed',
  '路径不存在，注意大小写并确认 WebDAV 根目录':
      'Path not found; check the case and the WebDAV root',
  '需要登录，请关闭“匿名登录”并填写账号密码':
      'Login required; turn off "Anonymous" and enter credentials',
  '无权限，账号可能不允许该目录':
      'Permission denied; the account may not allow this directory',
  'HTTP {code}（重定向但无 Location）':
      'HTTP {code} (redirect without Location)',
  '读取中…': 'Loading…',
  '正在扫描已安装应用…': 'Scanning installed apps…',
  '正在扫描…': 'Scanning…',
  '未获取信息（长按解析）': 'No info (long-press to parse)',
  '不再需要': 'No longer needed',
  '太占空间': 'Takes too much space',
  '隐私担忧': 'Privacy concerns',
  '广告太多': 'Too many ads',
  '闪退/故障': 'Crashes / bugs',
  '不好用': 'Not good enough',
  'Windows 本地账户或域常需填写，Samba 一般留空':
      'Often needed for Windows local accounts or domains; usually empty for Samba',
  'SMB 可用 域\\用户名（如 WORKGROUP\\why）':
      'For SMB use DOMAIN\\username (e.g. WORKGROUP\\why)',
  'FTP anonymous / SMB 来宾 / WebDAV 无鉴权':
      'FTP anonymous / SMB guest / WebDAV no auth',
  '192.168.1.10 或 nas.local': '192.168.1.10 or nas.local',
  '例如 NAS / 路由器共享': 'e.g. NAS / router share',
  '默认 {port}': 'Default {port}',
  '支持多层目录，会自动递归查找其中的 APK':
      'Nested folders are supported; APKs are found recursively',
  '添加局域网 / NAS 上的 FTP、Samba 或 WebDAV 目录，\n自动递归查找其中的 APK 并一键安装。':
      'Add FTP, Samba or WebDAV folders on your LAN / NAS.\nAPKs are found recursively and installed with one tap.',
  '显示在同步界面的标签页上，留空则用协议名':
      'Shown as the tab label; defaults to the protocol name',
  '输入或粘贴一个远程目录地址': 'Enter or paste a remote directory URL',

  // ---- misc
  '未知': 'Unknown',
  '未知错误': 'Unknown error',
  '未命名': 'Untitled',
  '设备': 'Device',
  'Android 应用管理器': 'Android app manager',
  '囤囤': 'Hamstapp',
  '囤囤 · Hamstapp': 'Hamstapp',
  '刚刚': 'just now',
  '共 {n} 个应用（用户 {user} / 系统 {system}）':
      '{n} apps ({user} user / {system} system)',
  '安装原因：{reason}\n{note}': 'Install reason: {reason}\n{note}',
  '原因：{reason}': 'Reason: {reason}',
  '{pkg}\n该应用当前不在设备上，点击记录卸载原因':
      '{pkg}\nThis app is not on the device. Tap to record an uninstall reason.',
  '{pkg}\n点击添加卸载原因': '{pkg}\nTap to add an uninstall reason',
  '卸载于 {date}': 'Uninstalled {date}',
  '卸载记录 {n} 条 · 上次扫描 {ago}':
      '{n} uninstall records · last scan {ago}',
  '还没有卸载记录': 'No uninstall records yet',
  '{n} 分钟前': '{n} min ago',
  '{n} 小时前': '{n} h ago',
  '{n} 天前': '{n} d ago',
  '{n} 个月前': '{n} mo ago',
  '{n} 年前': '{n} y ago',
  '卸载原因 · {name}': 'Uninstall reason · {name}',
  '已导出数据包': 'Data exported',
  '导出失败：{error}': 'Export failed: {error}',
  '导入完成': 'Import complete',
  '导入失败：{error}（本地数据未改动）':
      'Import failed: {error} (local data unchanged)',
  '这不是囤囤导出的数据包': 'This is not a Hamstapp data file',
  '不是囤囤的数据包': 'Not a Hamstapp data file',
  '数据包缺少 data 内容': 'The data file is missing its "data" section',
  '文件内容不是有效的数据包': 'The file is not a valid data file',
  '导入会先清空当前全部数据，再写入数据包内容，不会进行部分导入。\n\n':
      'Import clears all current data first, then writes the file. Partial import is not supported.\n\n',
  '数据包内容：{summary}\n\n确定继续吗？':
      'File contents: {summary}\n\nContinue?',
  '将删除全部应用记录、分组、快照、备份列表、磁贴与设置，且无法恢复。确定吗？':
      'This deletes all app records, groups, snapshots, backup lists, tiles and settings. This cannot be undone. Continue?',
  '已清空数据': 'Data cleared',
  '分享快照对比': 'Share snapshot diff',
  '复制到剪贴板': 'Copy to clipboard',
  '已复制到剪贴板': 'Copied to clipboard',
  '复制失败': 'Copy failed',
  '应用已启动': 'App launched',
  '无法启动该应用（可能已禁用或没有启动入口）':
      'Could not launch the app (it may be disabled or have no launcher)',
  '无法打开应用信息页': 'Could not open the app info page',
  '尚未扫描，点击右上角刷新':
      'Not scanned yet. Tap refresh in the top-right.',
  '请先在「应用」页扫描应用列表':
      'Scan the app list on the Apps page first',
  '一个应用都没有': 'No apps at all',

  // ---- late additions
  ' · 显示 {visible} · 用时 {ms} ms · {ago}':
      ' · showing {visible} · {ms} ms · {ago}',
  ' · 缓存 {size}': ' · cache {size}',
  ' · 缺失 {n}': ' · {n} missing',
  'APK：{name}': 'APK: {name}',
  '{n} 个应用 · {date}': '{n} apps · {date}',
  '中文': '中文',
  '先清空当前数据，再完整导入（不支持部分导入）':
      'Clears all current data first, then imports the full file (partial import is not supported)',
  '右移（手动排序）': 'Move right (manual order)',
  '名称': 'Name',
  '在当前磁贴页显示': 'Show on the current tile page',
  '备份列表 {n}': 'Backup list {n}',
  '安装原因：{reason}\n{pkg}': 'Install reason: {reason}\n{pkg}',
  '实时': 'Live',
  '左移（手动排序）': 'Move left (manual order)',
  '已创建快照「{name}」': 'Created snapshot "{name}"',
  '已卸载 {n}': '{n} removed',
  '已添加 {count} 个应用 · 点击行切换':
      '{count} apps added · tap a row to toggle',
  '当前 {size}×{size}，置顶新应用时使用':
      'Currently {size}×{size}; used when pinning new apps',
  '把快照、磁贴、分组、备份列表等全部数据打包为单个文件':
      'Package snapshots, tiles, groups, backup lists and all other data into one file',
  '版本：{version}{code}': 'Version: {version}{code}',
  '确定要卸载「{name}」吗？': 'Uninstall "{name}"?',
  '语言': 'Language',
  '更多': 'More',
  '跟随系统语言': 'Follow system',
  '页面 1': 'Page 1',
  '（无磁贴页）': '(no tile page)',

  // ---- apk analyzer
  'APK 分析': 'APK analysis',
  '分析已安装的 APK': 'Analyze the installed APK',
  '分享': 'Share',
  '正在分析…': 'Analyzing…',
  '分析失败：{error}': 'Analysis failed: {error}',
  '分析失败：无法读取该文件': 'Analysis failed: could not read the file',
  '松开以分析': 'Release to analyze',
  '选择另一个 APK': 'Choose another APK',
  '将 APK 拖到这里，或点击选择': 'Drop an APK here, or tap to choose',
  '支持选择本机文件，或从文件管理器拖入':
      'Pick a local file, or drag one in from a file manager',
  '选择 APK 文件': 'Choose an APK file',
  '无法读取所选文件': 'Could not read the selected file',
  '版本：{version}（{code}）': 'Version: {version} ({code})',
  '未安装该应用': 'This app is not installed',
  '签名与已安装版本不一致，无法覆盖安装':
      'Signature differs from the installed app; cannot update in place',
  '签名一致，可覆盖安装（升级）':
      'Signature matches; can update over the installed app',
  '签名与已安装版本一致': 'Signature matches the installed app',
  '已安装版本：{version}（{code}）': 'Installed: {version} ({code})',
  '文件': 'File',
  '修改时间': 'Modified',
  '最低 SDK': 'Min SDK',
  '目标 SDK': 'Target SDK',
  '可调试': 'Debuggable',
  '允许备份': 'Allow backup',
  '仅测试': 'Test only',
  '允许明文流量': 'Cleartext traffic allowed',
  '解压原生库': 'Extract native libs',
  '组件': 'Components',
  '活动': 'Activities',
  '服务': 'Services',
  '广播接收器': 'Broadcast receivers',
  '内容提供者': 'Content providers',
  '签名与证书': 'Signature & certificates',
  'V1 签名': 'V1 signature',
  '证书数量': 'Certificates',
  '多重签名': 'Multiple signers',
  '签名轮换': 'Signing key rotation',
  '未找到签名证书（可能是未签名或解析失败）':
      'No signing certificate found (unsigned or parse failed)',
  '证书 {n}': 'Certificate {n}',
  '证书主体': 'Subject',
  '颁发者': 'Issuer',
  '序列号': 'Serial number',
  '签名算法': 'Signature algorithm',
  '自签名': 'Self-signed',
  '有效期': 'Validity',
  '{from} ~ {to}': '{from} ~ {to}',
  '权限': 'Permissions',
  '未声明任何权限': 'No permissions declared',
  '功能特性': 'Features',
  '未声明 uses-feature': 'No uses-feature declared',
  '原生库与文件结构': 'Native libs & structure',
  '原生库 ABI': 'Native ABIs',
  '原生库数量': 'Native libraries',
  'DEX 文件': 'DEX files',
  'DEX 大小': 'DEX size',
  '压缩包条目': 'Archive entries',
  '解压后大小': 'Uncompressed size',
  '包含 resources.arsc': 'Contains resources.arsc',
  '包含 AndroidManifest': 'Contains AndroidManifest',
  '已复制': 'Copied',
  '是': 'Yes',
  '否': 'No',
  '基本信息': 'Basic info',
  '已交给系统安装器': 'Handed to the system installer',
};
