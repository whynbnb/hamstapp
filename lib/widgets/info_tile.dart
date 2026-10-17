import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../models/app_info.dart';
import '../models/snapshot_diff.dart';
import '../models/tile.dart';
import '../services/device_status.dart';
import '../services/local_stats.dart';
import '../services/net_speed.dart';
import '../services/native_apps.dart';
import '../services/notification_badges.dart';
import '../services/system_stats.dart';
import '../screens/apps_screen.dart';
import '../screens/backup_lists_screen.dart';
import '../screens/orphan_cache_screen.dart';
import '../screens/snapshots_screen.dart';
import '../screens/storage_usage_screen.dart';
import '../screens/usage_stats_screen.dart';
import '../state/app_state.dart';
import '../utils/actions.dart';
import '../utils/format.dart';
import 'app_icon.dart';
import 'info_tile_sheets.dart';

/// Backdrop colour of an info tile, picked so the kinds are recognisable next
/// to a board full of app-coloured tiles.
Color infoTileColor(BuildContext context, TileKind kind, {DeviceStatus? status}) {
  final scheme = Theme.of(context).colorScheme;
  switch (kind) {
    case TileKind.clock:
      return const Color(0xFF3F51B5); // indigo
    case TileKind.date:
      return const Color(0xFF00897B); // teal
    case TileKind.battery:
      final level = status?.level ?? -1;
      if (level >= 0 && level <= 15) return const Color(0xFFC62828);
      if (level >= 16 && level <= 30) return const Color(0xFFEF6C00);
      return const Color(0xFF2E7D32);
    case TileKind.storage:
      final used = status?.usedFraction ?? 0;
      if (used >= 0.92) return const Color(0xFFC62828);
      if (used >= 0.8) return const Color(0xFFEF6C00);
      return const Color(0xFF455A64);
    case TileKind.memory:
      final used = status?.memUsedFraction ?? 0;
      if (used >= 0.92) return const Color(0xFFC62828);
      if (used >= 0.8) return const Color(0xFFEF6C00);
      return const Color(0xFF00695C);
    case TileKind.screenTime:
      return const Color(0xFF5E35B1); // deep purple
    case TileKind.traffic:
      return const Color(0xFF00838F); // cyan
    case TileKind.alarm:
      return const Color(0xFF3949AB);
    case TileKind.unread:
      return scheme.error;
    case TileKind.recent:
      return const Color(0xFF37474F);
    case TileKind.frequent:
      return const Color(0xFF6D4C41);
    case TileKind.newApps:
      return const Color(0xFF2E7D32);
    case TileKind.neglected:
      return const Color(0xFF8D6E63);
    case TileKind.folder:
      return const Color(0xFF455A64);
    case TileKind.favorites:
      return const Color(0xFFF9A825);
    case TileKind.biggest:
      return const Color(0xFF4E342E);
    case TileKind.snapshot:
      return const Color(0xFF0277BD);
    case TileKind.unorganized:
      return const Color(0xFFEF6C00);
    case TileKind.cache:
      return const Color(0xFF78909C);
    case TileKind.backupList:
      return const Color(0xFF7E57C2);
    case TileKind.torch:
      return (status?.torchOn ?? false)
          ? const Color(0xFFF9A825)
          : const Color(0xFF607D8B);
    case TileKind.uptime:
      return const Color(0xFF26A69A);
    case TileKind.dial:
      return const Color(0xFF43A047);
    case TileKind.countdown:
      return const Color(0xFFD81B60);
    case TileKind.worldClock:
      return const Color(0xFF5C6BC0);
    case TileKind.note:
      return const Color(0xFFA1887F);
    case TileKind.netSpeed:
      return const Color(0xFF0097A7);
    case TileKind.overview:
      return const Color(0xFF263238);
    case TileKind.action:
      return const Color(0xFF546E7A);
    case TileKind.unknown:
      return const Color(0xFF757575);
    case TileKind.app:
      return scheme.primary;
  }
}

/// Runs an info tile's tap: a sheet, a screen or an action, depending on the
/// kind. App tiles never get here (they launch their app).
void handleInfoTileTap(BuildContext context, AppState state, Tile tile) {
  switch (tile.kind) {
    case TileKind.storage:
      openStorageManager(context);
    case TileKind.unread:
      showUnreadSheet(context, state);
    case TileKind.recent:
      showAppListSheet(
        context,
        state,
        tile.kind,
        apps: state.recentApps.take(20).toList(),
      );
    case TileKind.frequent:
      showAppListSheet(
        context,
        state,
        tile.kind,
        apps: frequentApps(state, tile),
      );
    case TileKind.newApps:
      showAppListSheet(
        context,
        state,
        tile.kind,
        apps: newInstallApps(state, tile.optionInt('days', 7)),
      );
    case TileKind.neglected:
      showAppListSheet(
        context,
        state,
        tile.kind,
        apps: neglectedApps(state, tile.optionInt('days', 30)),
      );
    case TileKind.folder:
      if (folderApps(state, tile).isEmpty) {
        showInfoTileSettings(context, state, tile);
      } else {
        showFolderSheet(context, state, tile);
      }
    case TileKind.favorites:
      showAppListSheet(
        context,
        state,
        tile.kind,
        apps: state.favorites,
      );
    case TileKind.biggest:
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const StorageUsageScreen()),
      );
    case TileKind.snapshot:
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const SnapshotsScreen()),
      );
    case TileKind.unorganized:
      // Same filter the 应用 page offers, so the list matches this count.
      state.filter = AppFilter.unorganized;
      state.refresh();
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const AppsScreen()),
      );
    case TileKind.cache:
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const OrphanCacheScreen()),
      );
    case TileKind.backupList:
      final listId = tile.optionString('list');
      final exists = state.backupLists.any((b) => b.id == listId);
      if (listId.isEmpty || !exists) {
        showInfoTileSettings(context, state, tile);
      } else {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => BackupListDetailScreen(listId: listId),
          ),
        );
      }
    case TileKind.torch:
      unawaited(_toggleTorch());
    case TileKind.dial:
      final number = tile.optionString('number');
      if (number.isEmpty) {
        showInfoTileSettings(context, state, tile);
      } else {
        unawaited(NativeApps.openUrl('tel:$number'));
      }
    case TileKind.countdown || TileKind.worldClock || TileKind.note:
      showInfoTileSettings(context, state, tile);
    case TileKind.traffic:
      showTrafficSheet(context);
    case TileKind.memory:
      unawaited(DeviceStatusService.instance.refresh(force: true));
    case TileKind.screenTime:
      // Without the grant there is nothing to show: offer the switch instead.
      if (!SystemStatsService.instance.screenTime.permitted) {
        unawaited(NativeApps.openUsageAccessSettings());
      } else {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const UsageStatsScreen()),
        );
      }
    case TileKind.alarm:
      unawaited(NativeApps.openNextAlarm());
    case TileKind.action:
      runInfoTileAction(context, state, tile);
    case TileKind.unknown:
      showUnsupportedTileDialog(context, state, tile);
    case TileKind.clock ||
        TileKind.date ||
        TileKind.battery ||
        TileKind.uptime ||
        TileKind.netSpeed ||
        TileKind.overview:
      break;
    case TileKind.app:
      break;
  }
}

/// Flips the camera torch and reads the new state back.
Future<void> _toggleTorch() async {
  final on = DeviceStatusService.instance.status.torchOn;
  await NativeApps.setTorch(!on);
  await DeviceStatusService.instance.refresh(force: true);
}

/// Apps installed within the last [days] days, newest first.
List<AppInfo> newInstallApps(AppState state, int days) {
  final since = DateTime.now()
      .subtract(Duration(days: days))
      .millisecondsSinceEpoch;
  return state.apps
      .where((a) => !a.isWebEntry && a.firstInstallTime >= since)
      .toList()
    ..sort((a, b) => b.firstInstallTime.compareTo(a.firstInstallTime));
}

/// Apps for a 常用 tile: the most launched, or the time-of-day suggestions.
/// Both reuse the same helpers as the 使用趋势 page, so the numbers agree.
List<AppInfo> frequentApps(AppState state, Tile tile) {
  final recommended = tile.optionString('source', 'count') == 'recommend';
  final packages = recommended
      ? [
          for (final r in state.recommendedApps(limit: 4)) r.packageName,
        ]
      : [
          for (final e in state.mostUsedApps(days: 30, limit: 4))
            e.packageName,
        ];
  return [
    for (final pkg in packages)
      if (state.appByPackage(pkg) != null) state.appByPackage(pkg)!,
  ];
}

/// Apps taking the most space. Defaults to APK size, which needs no
/// permission; the "with data" mode uses the system's per-app statistics and
/// falls back to APK size when that is not granted.
List<AppInfo> biggestApps(AppState state, Tile tile) {
  if (tile.optionString('mode', 'apk') == 'total') {
    final entries = BigAppsService.instance.entries;
    if (BigAppsService.instance.permitted && entries.isNotEmpty) {
      return [
        for (final e in entries.take(4))
          if (state.appByPackage(e.packageName) != null)
            state.appByPackage(e.packageName)!,
      ];
    }
  }
  final list = [...state.installedApps]
    ..sort((a, b) => b.sizeBytes.compareTo(a.sizeBytes));
  return list.take(4).toList();
}

/// Apps that used to be opened routinely but not in the last [days] days
/// (same definition as 使用趋势 → 被冷落).
List<AppInfo> neglectedApps(AppState state, int days) => [
  for (final e in state.neglectedApps(days: days, limit: 30))
    if (state.appByPackage(e.packageName) != null)
      state.appByPackage(e.packageName)!,
];

/// The live content of one info tile. Everything is drawn by Flutter — no host
/// process, no extra permission — except the readings that come from the
/// system (battery, storage, RAM, screen time, traffic).
class InfoTileContent extends StatefulWidget {
  const InfoTileContent({
    super.key,
    required this.tile,
    required this.foreground,
    this.state,
  });

  final Tile tile;

  /// Colour the text is drawn in, chosen by the tile backdrop.
  final Color foreground;

  /// The app list, needed by the tiles that show apps (recent, folders, ...).
  final AppState? state;

  @override
  State<InfoTileContent> createState() => _InfoTileContentState();
}

class _InfoTileContentState extends State<InfoTileContent> {
  Timer? _timer;

  /// Which period the clock/date tiles have already rendered, so the timer
  /// knows when a rebuild is actually needed.
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    DeviceStatusService.instance.addListener(_onChanged);
    SystemStatsService.instance.addListener(_onChanged);
    CacheStatsService.instance.addListener(_onChanged);
    BigAppsService.instance.addListener(_onChanged);
    NetSpeedService.instance.addListener(_onChanged);
    NotificationBadges.instance.addListener(_onChanged);
    _schedule();
  }

  @override
  void didUpdateWidget(covariant InfoTileContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tile.id != widget.tile.id ||
        oldWidget.tile.kind != widget.tile.kind) {
      _timer?.cancel();
      _schedule();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    DeviceStatusService.instance.removeListener(_onChanged);
    SystemStatsService.instance.removeListener(_onChanged);
    CacheStatsService.instance.removeListener(_onChanged);
    BigAppsService.instance.removeListener(_onChanged);
    NetSpeedService.instance.removeListener(_onChanged);
    NotificationBadges.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// Wake on the next minute boundary (so the minute digit is never stale) or
  /// every minute for the readings that come from the system.
  void _schedule() {
    final kind = widget.tile.kind;
    if (kind == TileKind.clock || kind == TileKind.date) {
      final now = DateTime.now();
      final next = DateTime(now.year, now.month, now.day, now.hour, now.minute)
          .add(const Duration(minutes: 1, seconds: 1));
      _timer = Timer(next.difference(now), () {
        if (!mounted) return;
        setState(() => _now = DateTime.now());
        _schedule();
      });
      return;
    }
    if (kind == TileKind.battery ||
        kind == TileKind.storage ||
        kind == TileKind.memory ||
        kind == TileKind.alarm ||
        kind == TileKind.torch) {
      unawaited(DeviceStatusService.instance.refresh());
      _timer = Timer.periodic(const Duration(seconds: 60), (_) {
        unawaited(DeviceStatusService.instance.refresh(force: true));
      });
      return;
    }
    if (kind == TileKind.cache || kind == TileKind.biggest) {
      unawaited(CacheStatsService.instance.refresh());
      unawaited(BigAppsService.instance.refresh());
      _timer = Timer.periodic(const Duration(minutes: 5), (_) {
        unawaited(CacheStatsService.instance.refresh(force: true));
        unawaited(BigAppsService.instance.refresh(force: true));
      });
      return;
    }
    if (kind == TileKind.countdown ||
        kind == TileKind.worldClock ||
        kind == TileKind.uptime ||
        kind == TileKind.snapshot) {
      // These change slowly; a minute is plenty to stay truthful.
      _timer = Timer.periodic(const Duration(minutes: 1), (_) {
        if (mounted) setState(() {});
      });
      return;
    }
    if (kind == TileKind.screenTime || kind == TileKind.traffic) {
      unawaited(SystemStatsService.instance.refresh());
      _timer = Timer.periodic(const Duration(minutes: 5), (_) {
        unawaited(SystemStatsService.instance.refresh(force: true));
      });
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final tile = widget.tile;
    final status = DeviceStatusService.instance.status;
    final fg = widget.foreground;

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final shortest = w < h ? w : h;
        // Below this there is no room for a caption without crowding the value.
        final showCaption = tile.showLabel && h >= 54;
        final pad = tile.innerPadding
            ? (shortest * 0.08).clamp(2.0, 14.0).toDouble()
            : 2.0;

        switch (tile.kind) {
          case TileKind.clock:
            return _clock(s, fg, shortest, pad, showCaption);
          case TileKind.date:
            return _date(s, fg, shortest, pad, showCaption);
          case TileKind.battery:
            return _battery(s, fg, shortest, pad, status, showCaption);
          case TileKind.storage:
            return _ring(
              s,
              fg,
              shortest,
              pad,
              showCaption,
              '${(status.usedFraction * 100).round()}',
              status.hasStorage,
              s.t('存储 · 已用 {size}', {
                'size': Fmt.storage(status.totalBytes - status.freeBytes),
              }),
            );
          case TileKind.memory:
            return _ring(
              s,
              fg,
              shortest,
              pad,
              showCaption,
              '${(status.memUsedFraction * 100).round()}',
              status.hasMemory,
              s.t('内存 · 已用 {size}', {'size': Fmt.storage(status.memUsedBytes)}),
            );
          case TileKind.screenTime:
            final usage = SystemStatsService.instance.screenTime;
            return _value(
              s,
              fg,
              shortest,
              pad,
              showCaption,
              usage.permitted
                  ? Fmt.duration(usage.totalMillis)
                  : s.t('需要授权'),
              s.t('今日屏幕用时'),
            );
          case TileKind.traffic:
            final traffic = SystemStatsService.instance.traffic;
            return _value(
              s,
              fg,
              shortest,
              pad,
              showCaption,
              traffic.permitted
                  ? Fmt.storage(traffic.totalBytes)
                  : s.t('需要授权'),
              s.t('本月流量 · 移动 {mobile}', {
                'mobile': Fmt.storage(traffic.mobileBytes),
              }),
            );
          case TileKind.alarm:
            return _value(
              s,
              fg,
              shortest,
              pad,
              showCaption,
              status.alarmAt > 0 ? Fmt.clock(status.alarmAt) : s.t('没有闹钟'),
              status.alarmAt > 0
                  ? s.t('闹钟 · {when}', {'when': Fmt.relativeDay(status.alarmAt)})
                  : s.t('闹钟'),
            );
          case TileKind.unread:
            return _unread(s, fg, shortest, pad, showCaption);
          case TileKind.recent:
          case TileKind.frequent:
            return _appGrid(
              context,
              s,
              fg,
              shortest,
              pad,
              showCaption,
              widget.tile.kind == TileKind.frequent
                  ? (widget.state == null
                        ? null
                        : frequentApps(widget.state!, widget.tile))
                  : widget.state?.recentApps,
              widget.tile.kind == TileKind.frequent
                  ? s.t(
                      widget.tile.optionString('source', 'count') == 'recommend'
                          ? '现在推荐'
                          : '常用（30 天）',
                    )
                  : s.t('最近使用'),
              s.t('还没有启动记录'),
            );
          case TileKind.newApps:
            final days = tile.optionInt('days', 7);
            final apps = widget.state == null
                ? const <AppInfo>[]
                : newInstallApps(widget.state!, days);
            return _appGrid(
              context,
              s,
              fg,
              shortest,
              pad,
              showCaption,
              apps,
              s.t('{n} 天新装', {'n': days}),
              s.t('没有新装应用'),
            );
          case TileKind.neglected:
            final days = tile.optionInt('days', 30);
            final apps = widget.state == null
                ? const <AppInfo>[]
                : neglectedApps(widget.state!, days);
            return _value(
              s,
              fg,
              shortest,
              pad,
              showCaption,
              '${apps.length}',
              s.t('{n} 天没打开', {'n': days}),
            );
          case TileKind.folder:
            return _folder(context, s, fg, shortest, pad, showCaption);
          case TileKind.favorites:
            return _appGrid(
              context,
              s,
              fg,
              shortest,
              pad,
              showCaption,
              widget.state?.favorites,
              s.t('收藏'),
              s.t('还没有收藏'),
            );
          case TileKind.biggest:
            return _appGrid(
              context,
              s,
              fg,
              shortest,
              pad,
              showCaption,
              widget.state == null
                  ? null
                  : biggestApps(widget.state!, tile),
              s.t('占用最大'),
              s.t('没有数据'),
            );
          case TileKind.snapshot:
            return _snapshot(s, fg, shortest, pad, showCaption);
          case TileKind.unorganized:
            final count = widget.state?.unorganizedApps.length ?? 0;
            return _value(
              s,
              fg,
              shortest,
              pad,
              showCaption,
              '$count',
              count == 0 ? s.t('都整理好了') : s.t('个应用待整理'),
            );
          case TileKind.cache:
            final cache = CacheStatsService.instance;
            return _value(
              s,
              fg,
              shortest,
              pad,
              showCaption,
              Fmt.storage(cache.bytes),
              cache.count == 0
                  ? s.t('没有缓存的安装包')
                  : s.t('{n} 个安装包', {'n': cache.count}),
            );
          case TileKind.backupList:
            return _backupList(s, fg, shortest, pad, showCaption, tile);
          case TileKind.torch:
            final on = status.torchOn;
            return _iconLabel(
              s,
              fg,
              shortest,
              pad,
              on ? Icons.flashlight_on : Icons.flashlight_off,
              s.t(on ? '已开' : '已关'),
            );
          case TileKind.uptime:
            return _value(
              s,
              fg,
              shortest,
              pad,
              showCaption,
              status.hasUptime ? Fmt.spanned(status.uptimeMillis) : '--',
              s.t('已开机'),
            );
          case TileKind.dial:
            return _iconLabel(
              s,
              fg,
              shortest,
              pad,
              Icons.call,
              tile.optionString('label').isEmpty
                  ? s.t('点一下设置号码')
                  : tile.optionString('label'),
            );
          case TileKind.countdown:
            return _countdown(s, fg, shortest, pad, showCaption, tile);
          case TileKind.worldClock:
            return _worldClock(s, fg, shortest, pad, showCaption, tile);
          case TileKind.note:
            return _note(s, fg, pad, tile);
          case TileKind.netSpeed:
            final net = NetSpeedService.instance;
            return _value(
              s,
              fg,
              shortest,
              pad,
              showCaption,
              net.supported ? '↓ ${Fmt.speed(net.downBytesPerSecond)}' : s.t('不支持'),
              '↑ ${Fmt.speed(net.upBytesPerSecond)}',
            );
          case TileKind.overview:
            return _overview(s, fg, pad, status, showCaption);
          case TileKind.action:
            return _action(s, fg, shortest, pad);
          case TileKind.unknown:
            return _unsupported(s, fg, shortest, pad);
          case TileKind.app:
            return const SizedBox.shrink();
        }
      },
    );
  }

  /// Big value over a caption, scaled to fit.
  Widget _value(
    AppStrings s,
    Color fg,
    double shortest,
    double pad,
    bool showCaption,
    String value,
    String caption,
  ) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(pad),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                value,
                style: TextStyle(
                  color: fg,
                  fontWeight: FontWeight.w700,
                  fontSize: shortest * 0.34,
                  height: 1.1,
                ),
              ),
              if (showCaption)
                Text(
                  caption,
                  style: TextStyle(
                    color: fg.withValues(alpha: 0.85),
                    fontSize: shortest * 0.12,
                    height: 1.2,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Ring with the percentage inside, over a caption.
  Widget _ring(
    AppStrings s,
    Color fg,
    double shortest,
    double pad,
    bool showCaption,
    String percent,
    bool hasValue,
    String caption,
  ) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(pad),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: shortest * 0.44,
                height: shortest * 0.44,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    CircularProgressIndicator(
                      value: hasValue
                          ? (int.tryParse(percent) ?? 0) / 100
                          : 0,
                      strokeWidth: shortest * 0.05,
                      backgroundColor: fg.withValues(alpha: 0.25),
                      valueColor: AlwaysStoppedAnimation<Color>(fg),
                    ),
                    Text(
                      hasValue ? '$percent%' : '--',
                      style: TextStyle(
                        color: fg,
                        fontWeight: FontWeight.w700,
                        fontSize: shortest * 0.15,
                      ),
                    ),
                  ],
                ),
              ),
              if (showCaption)
                Text(
                  caption,
                  style: TextStyle(
                    color: fg.withValues(alpha: 0.85),
                    fontSize: shortest * 0.11,
                    height: 1.2,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _clock(
    AppStrings s,
    Color fg,
    double shortest,
    double pad,
    bool showCaption,
  ) {
    final time = '${_two(_now.hour)}:${_two(_now.minute)}';
    return Center(
      child: Padding(
        padding: EdgeInsets.all(pad),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                time,
                style: TextStyle(
                  color: fg,
                  fontWeight: FontWeight.w700,
                  fontSize: shortest * 0.42,
                  height: 1.05,
                  letterSpacing: -1,
                ),
              ),
              if (showCaption)
                Text(
                  s.t('{day} {m}/{d}', {
                    'day': _weekday(s, _now),
                    'm': _now.month,
                    'd': _now.day,
                  }),
                  style: TextStyle(
                    color: fg.withValues(alpha: 0.85),
                    fontSize: shortest * 0.14,
                    height: 1.2,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _date(
    AppStrings s,
    Color fg,
    double shortest,
    double pad,
    bool showCaption,
  ) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(pad),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${_now.day}',
                style: TextStyle(
                  color: fg,
                  fontWeight: FontWeight.w700,
                  fontSize: shortest * 0.46,
                  height: 1.0,
                ),
              ),
              if (showCaption)
                Text(
                  '${_weekday(s, _now)} · ${_now.year}/${_now.month}',
                  style: TextStyle(
                    color: fg.withValues(alpha: 0.85),
                    fontSize: shortest * 0.13,
                    height: 1.2,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Battery level, temperature, or both (the tile's own setting).
  Widget _battery(
    AppStrings s,
    Color fg,
    double shortest,
    double pad,
    DeviceStatus status,
    bool showCaption,
  ) {
    final mode = widget.tile.optionString('mode', 'level');
    final showLevel = mode != 'temp';
    final showTemp = mode != 'level' && status.hasTemp;
    return Center(
      child: Padding(
        padding: EdgeInsets.all(pad),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (showLevel)
                    Text(
                      status.hasLevel ? '${status.level}%' : '--',
                      style: TextStyle(
                        color: fg,
                        fontWeight: FontWeight.w700,
                        fontSize: shortest * 0.34,
                        height: 1.1,
                      ),
                    ),
                  if (showLevel && status.charging) ...[
                    SizedBox(width: shortest * 0.04),
                    Icon(Icons.bolt, color: fg, size: shortest * 0.22),
                  ],
                  if (showLevel && showTemp) SizedBox(width: shortest * 0.06),
                  if (showTemp)
                    Text(
                      '${status.batteryTempC.toStringAsFixed(1)}°',
                      style: TextStyle(
                        color: fg,
                        fontWeight: FontWeight.w700,
                        fontSize: shortest * (showLevel ? 0.2 : 0.34),
                        height: 1.1,
                      ),
                    ),
                ],
              ),
              if (showCaption)
                Text(
                  showTemp && !showLevel ? s.t('电池温度') : s.t('电量'),
                  style: TextStyle(
                    color: fg.withValues(alpha: 0.85),
                    fontSize: shortest * 0.13,
                    height: 1.2,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _unread(
    AppStrings s,
    Color fg,
    double shortest,
    double pad,
    bool showCaption,
  ) {
    final badges = NotificationBadges.instance;
    final total = badges.total;
    return Center(
      child: Padding(
        padding: EdgeInsets.all(pad),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$total',
                style: TextStyle(
                  color: fg,
                  fontWeight: FontWeight.w700,
                  fontSize: shortest * 0.42,
                  height: 1.05,
                ),
              ),
              if (showCaption)
                Text(
                  total <= 0
                      ? s.t('没有未读')
                      : s.t('未读 · {n} 个应用', {'n': badges.appCount}),
                  style: TextStyle(
                    color: fg.withValues(alpha: 0.85),
                    fontSize: shortest * 0.12,
                    height: 1.2,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Up to four app icons in a 2×2 block, each tappable (they launch the app
  /// when the tile itself is tapped at the edges).
  Widget _appGrid(
    BuildContext context,
    AppStrings s,
    Color fg,
    double shortest,
    double pad,
    bool showCaption,
    List<AppInfo>? apps,
    String caption,
    String emptyText,
  ) {
    final state = widget.state;
    if (apps == null || apps.isEmpty || state == null) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(pad),
          child: Text(
            emptyText,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: fg.withValues(alpha: 0.9),
              fontSize: 11.5,
            ),
          ),
        ),
      );
    }
    final shown = apps.take(4).toList();
    return Padding(
      padding: EdgeInsets.all(pad),
      child: Column(
        children: [
          Expanded(
            child: GridView.count(
              crossAxisCount: 2,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 4,
              crossAxisSpacing: 4,
              children: [
                for (final a in shown)
                  gestureLaunch(
                    context,
                    a.packageName,
                    AppIcon(
                      packageName: a.packageName,
                      label: state.displayNameFor(a.packageName),
                      showNotificationBadge: false,
                      size: (shortest * 0.28).clamp(18.0, 40.0),
                    ),
                  ),
              ],
            ),
          ),
          if (showCaption)
            Text(
              caption,
              style: TextStyle(
                color: fg.withValues(alpha: 0.9),
                fontSize: 11,
                height: 1.1,
              ),
            ),
        ],
      ),
    );
  }

  /// The apps of a folder tile (a whole category, or a hand-picked list).
  Widget _folder(
    BuildContext context,
    AppStrings s,
    Color fg,
    double shortest,
    double pad,
    bool showCaption,
  ) {
    final state = widget.state;
    final apps = folderApps(state, widget.tile);
    final name = folderName(state, widget.tile, s);
    if (apps.isEmpty) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(pad),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.folder_outlined, color: fg, size: 26),
              const SizedBox(height: 4),
              Text(
                s.t('点一下进「磁贴设置」选内容'),
                textAlign: TextAlign.center,
                style: TextStyle(color: fg.withValues(alpha: 0.9), fontSize: 11),
              ),
            ],
          ),
        ),
      );
    }
    return Stack(
      children: [
        _appGrid(context, s, fg, shortest, pad, showCaption, apps, name, name),
        if (showCaption)
          Positioned(
            right: 0,
            bottom: 0,
            child: Icon(
              Icons.folder,
              size: 14,
              color: fg.withValues(alpha: 0.9),
            ),
          ),
      ],
    );
  }

  /// The newest snapshot's age over how the device differs from it now.
  Widget _snapshot(
    AppStrings s,
    Color fg,
    double shortest,
    double pad,
    bool showCaption,
  ) {
    final state = widget.state;
    final latest = state?.latestSnapshot;
    if (state == null || latest == null) {
      return _value(
        s,
        fg,
        shortest,
        pad,
        showCaption,
        '--',
        s.t('还没有快照'),
      );
    }
    final diff = SnapshotDiff.between(latest, state.currentDeviceSnapshot());
    final parts = <String>[
      if (diff.added.isNotEmpty) s.t('新增 {n}', {'n': diff.added.length}),
      if (diff.removed.isNotEmpty) s.t('卸载 {n}', {'n': diff.removed.length}),
      if (diff.updated.isNotEmpty) s.t('更新 {n}', {'n': diff.updated.length}),
    ];
    return _value(
      s,
      fg,
      shortest,
      pad,
      showCaption,
      Fmt.relative(latest.createdAt),
      parts.isEmpty ? s.t('和现在一致') : parts.join(' · '),
    );
  }

  Widget _backupList(
    AppStrings s,
    Color fg,
    double shortest,
    double pad,
    bool showCaption,
    Tile tile,
  ) {
    final state = widget.state;
    final listId = tile.optionString('list');
    if (state == null || listId.isEmpty) {
      return _value(
        s,
        fg,
        shortest,
        pad,
        showCaption,
        '--',
        s.t('点一下选备份列表'),
      );
    }
    final list = state.backupLists.where((b) => b.id == listId).firstOrNull;
    if (list == null) {
      return _value(
        s,
        fg,
        shortest,
        pad,
        showCaption,
        '--',
        s.t('这个备份列表已删除'),
      );
    }
    final (installed, missing) = state.backupListCounts(listId);
    return _value(
      s,
      fg,
      shortest,
      pad,
      showCaption,
      missing == 0 ? s.t('齐了') : s.t('缺 {n}', {'n': missing}),
      s.t('{name} · 已装 {installed}', {
        'name': list.name,
        'installed': installed,
      }),
    );
  }

  Widget _countdown(
    AppStrings s,
    Color fg,
    double shortest,
    double pad,
    bool showCaption,
    Tile tile,
  ) {
    final title = tile.optionString('title');
    final at = tile.optionInt('date');
    if (title.isEmpty || at <= 0) {
      return _value(
        s,
        fg,
        shortest,
        pad,
        showCaption,
        '--',
        s.t('点一下设置纪念日'),
      );
    }
    final now = DateTime.now();
    final days = DateTime.fromMillisecondsSinceEpoch(at)
        .difference(DateTime(now.year, now.month, now.day))
        .inDays;
    final text = days == 0
        ? s.t('就是今天')
        : days > 0
        ? s.t('还有 {n} 天', {'n': days})
        : s.t('已过 {n} 天', {'n': -days});
    return _value(s, fg, shortest, pad, showCaption, text, title);
  }

  Widget _worldClock(
    AppStrings s,
    Color fg,
    double shortest,
    double pad,
    bool showCaption,
    Tile tile,
  ) {
    final offset = tile.optionInt('offset', 1 << 30);
    if (offset == 1 << 30) {
      return _value(
        s,
        fg,
        shortest,
        pad,
        showCaption,
        '--',
        s.t('点一下选择时区'),
      );
    }
    final at = DateTime.now().toUtc().add(Duration(minutes: offset));
    final label = tile.optionString('label');
    return _value(
      s,
      fg,
      shortest,
      pad,
      showCaption,
      '${at.hour.toString().padLeft(2, '0')}:'
          '${at.minute.toString().padLeft(2, '0')}',
      label.isEmpty ? worldClockLabel(offset) : label,
    );
  }

  Widget _note(AppStrings s, Color fg, double pad, Tile tile) {
    final text = tile.optionString('text');
    return Center(
      child: Padding(
        padding: EdgeInsets.all(pad + 2),
        child: Text(
          text.isEmpty ? s.t('点一下写点什么') : text,
          textAlign: TextAlign.center,
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: fg,
            fontSize: 13,
            height: 1.3,
            fontWeight: text.isEmpty ? FontWeight.w400 : FontWeight.w600,
          ),
        ),
      ),
    );
  }

  /// Battery / memory / storage / data as four mini cells.
  Widget _overview(
    AppStrings s,
    Color fg,
    double pad,
    DeviceStatus status,
    bool showCaption,
  ) {
    final traffic = SystemStatsService.instance.traffic;
    Widget cell(String label, String value) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: fg.withValues(alpha: 0.8),
            fontSize: 10.5,
            height: 1.1,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            color: fg,
            fontWeight: FontWeight.w700,
            fontSize: 15,
            height: 1.2,
          ),
        ),
      ],
    );
    return Padding(
      padding: EdgeInsets.all(pad + 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: cell(
                    s.t('电量'),
                    status.hasLevel ? '${status.level}%' : '--',
                  ),
                ),
                Expanded(
                  child: cell(
                    s.t('内存'),
                    status.hasMemory
                        ? '${(status.memUsedFraction * 100).round()}%'
                        : '--',
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: cell(
                    s.t('存储空间'),
                    status.hasStorage
                        ? '${(status.usedFraction * 100).round()}%'
                        : '--',
                  ),
                ),
                Expanded(
                  child: cell(
                    s.t('流量'),
                    traffic.permitted ? Fmt.storage(traffic.totalBytes) : '--',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Icon over a label, for the simple action-ish tiles.
  Widget _iconLabel(
    AppStrings s,
    Color fg,
    double shortest,
    double pad,
    IconData icon,
    String label,
  ) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(pad),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: fg, size: shortest * 0.34),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  color: fg,
                  fontWeight: FontWeight.w600,
                  fontSize: shortest * 0.14,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// A tile whose kind this build does not support: say so, and let the tap
  /// offer to remove it.
  Widget _unsupported(
    AppStrings s,
    Color fg,
    double shortest,
    double pad,
  ) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(pad),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.help_outline, color: fg, size: shortest * 0.28),
              const SizedBox(height: 4),
              Text(
                s.t('不支持的小组件'),
                style: TextStyle(
                  color: fg,
                  fontWeight: FontWeight.w600,
                  fontSize: shortest * 0.14,
                ),
              ),
              Text(
                s.t('点一下可移除'),
                style: TextStyle(
                  color: fg.withValues(alpha: 0.85),
                  fontSize: shortest * 0.11,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// A tile that runs one action: icon + label.
  Widget _action(AppStrings s, Color fg, double shortest, double pad) {
    final action = widget.tile.optionString('action', 'scan');
    return _iconLabel(
      s,
      fg,
      shortest,
      pad,
      actionIcon(action),
      s.t(actionTitle(action)),
    );
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  /// Localized short weekday, e.g. 周三 / Wed.
  static String _weekday(AppStrings s, DateTime when) {
    const keys = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return s.t(keys[when.weekday - 1]);
  }
}

/// Wraps [child] so a tap launches [packageName].
Widget gestureLaunch(
  BuildContext context,
  String packageName,
  Widget child,
) {
  return GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: () => launchApp(context, packageName),
    child: child,
  );
}
