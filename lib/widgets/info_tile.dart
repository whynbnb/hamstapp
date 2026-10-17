import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../models/app_info.dart';
import '../models/tile.dart';
import '../services/device_status.dart';
import '../services/native_apps.dart';
import '../services/notification_badges.dart';
import '../services/system_stats.dart';
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
    case TileKind.clock || TileKind.date || TileKind.battery:
      break;
    case TileKind.app:
      break;
  }
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
        kind == TileKind.alarm) {
      unawaited(DeviceStatusService.instance.refresh());
      _timer = Timer.periodic(const Duration(seconds: 60), (_) {
        unawaited(DeviceStatusService.instance.refresh(force: true));
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

  Widget _battery(
    AppStrings s,
    Color fg,
    double shortest,
    double pad,
    DeviceStatus status,
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
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    status.hasLevel ? '${status.level}%' : '--',
                    style: TextStyle(
                      color: fg,
                      fontWeight: FontWeight.w700,
                      fontSize: shortest * 0.34,
                      height: 1.1,
                    ),
                  ),
                  if (status.charging) ...[
                    SizedBox(width: shortest * 0.04),
                    Icon(Icons.bolt, color: fg, size: shortest * 0.22),
                  ],
                ],
              ),
              if (showCaption)
                Text(
                  s.t('电量'),
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
    return Center(
      child: Padding(
        padding: EdgeInsets.all(pad),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(actionIcon(action), color: fg, size: shortest * 0.34),
              const SizedBox(height: 4),
              Text(
                s.t(actionTitle(action)),
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
