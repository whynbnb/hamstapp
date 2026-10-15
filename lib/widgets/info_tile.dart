import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../models/tile.dart';
import '../services/device_status.dart';
import '../services/native_apps.dart';
import '../services/notification_badges.dart';
import '../utils/format.dart';

/// Backdrop colour of an info tile, picked so the five kinds are recognisable
/// next to a board full of app-coloured tiles.
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
    case TileKind.unread:
      return scheme.error;
    case TileKind.app:
      return scheme.primary;
  }
}

/// The live content of one info tile: a clock, a date, the battery, the data
/// volume or the unread summary. Everything is drawn by Flutter — no host, no
/// permission — except the battery/storage reading, which the native side
/// supplies once a minute.
class InfoTileContent extends StatefulWidget {
  const InfoTileContent({
    super.key,
    required this.tile,
    required this.foreground,
  });

  final Tile tile;

  /// Colour the text is drawn in, chosen by the tile backdrop.
  final Color foreground;

  @override
  State<InfoTileContent> createState() => _InfoTileContentState();
}

class _InfoTileContentState extends State<InfoTileContent> {
  Timer? _timer;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    DeviceStatusService.instance.addListener(_onChanged);
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
    NotificationBadges.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// Wake on the next minute boundary (so the minute digit is never stale) or
  /// once a minute for the readings that come from the system.
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
    if (kind == TileKind.battery || kind == TileKind.storage) {
      unawaited(DeviceStatusService.instance.refresh());
      _timer = Timer.periodic(const Duration(seconds: 60), (_) {
        unawaited(DeviceStatusService.instance.refresh(force: true));
      });
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
            return _storage(s, fg, shortest, pad, status, showCaption);
          case TileKind.unread:
            return _unread(s, fg, shortest, pad, showCaption);
          case TileKind.app:
            return const SizedBox.shrink();
        }
      },
    );
  }

  /// `HH:mm` with the weekday and numeric date under it.
  Widget _clock(
    AppStrings s,
    Color fg,
    double shortest,
    double pad,
    bool showCaption,
  ) {
    final time =
        '${_two(_now.hour)}:${_two(_now.minute)}';
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

  /// The day of the month, big, with the weekday and the month under it.
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
    final level = status.level;
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
                    status.hasLevel ? '$level%' : '--',
                    style: TextStyle(
                      color: fg,
                      fontWeight: FontWeight.w700,
                      fontSize: shortest * 0.34,
                      height: 1.1,
                    ),
                  ),
                  if (status.charging) ...[
                    SizedBox(width: shortest * 0.04),
                    Icon(
                      Icons.bolt,
                      color: fg,
                      size: shortest * 0.22,
                    ),
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

  Widget _storage(
    AppStrings s,
    Color fg,
    double shortest,
    double pad,
    DeviceStatus status,
    bool showCaption,
  ) {
    final used = status.hasStorage
        ? (status.totalBytes - status.freeBytes)
        : 0;
    final percent = status.hasStorage
        ? (status.usedFraction * 100).round()
        : 0;
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
                      value: status.hasStorage ? status.usedFraction : 0,
                      strokeWidth: shortest * 0.05,
                      backgroundColor: fg.withValues(alpha: 0.25),
                      valueColor: AlwaysStoppedAnimation<Color>(fg),
                    ),
                    Text(
                      status.hasStorage ? '$percent%' : '--',
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
                  s.t('存储 · 已用 {size}', {'size': Fmt.storage(used)}),
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

  static String _two(int v) => v.toString().padLeft(2, '0');

  /// Localized short weekday, e.g. 周三 / Wed.
  static String _weekday(AppStrings s, DateTime when) {
    const keys = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return s.t(keys[when.weekday - 1]);
  }
}
