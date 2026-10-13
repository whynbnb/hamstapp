import 'package:flutter/foundation.dart';

/// How (or whether) a notification badge is drawn.
///
/// - [count]: a pill with the unread notification count (`99+` when larger).
/// - [dot]: a plain red dot, like a launcher's "some activity" hint.
/// - [none]: no badge at all.
enum NotificationBadgeMode { count, dot, none }

/// Where a badge can appear. Each surface is configured independently.
enum NotificationBadgeSurface {
  /// The app icons drawn on the launch screen's tile board.
  tile,

  /// The row of page chips below the tile board.
  page,

  /// Everything else: lists, categories, favourites, app details, …
  list,
}

/// App-wide notification-badge state.
///
/// Like [IconCache] this is a lightweight singleton so leaf widgets
/// ([AppIcon], the page bar) can listen to it directly instead of threading the
/// state through every list / tile / grid. [AppState] owns the persisted
/// settings and the native event stream and pushes updates here.
class NotificationBadges extends ChangeNotifier {
  NotificationBadges._();

  static final NotificationBadges instance = NotificationBadges._();

  /// Largest count rendered; bigger values show as `99+`.
  static const int maxCount = 99;

  bool _capture = false;
  Map<String, int> _counts = const {};

  final Map<NotificationBadgeSurface, NotificationBadgeMode> _modes = {
    for (final surface in NotificationBadgeSurface.values)
      surface: NotificationBadgeMode.count,
  };

  /// Whether notifications are being captured (the master switch).
  bool get capture => _capture;

  /// The mode configured for one surface.
  NotificationBadgeMode modeFor(NotificationBadgeSurface surface) =>
      _modes[surface] ?? NotificationBadgeMode.count;

  NotificationBadgeMode get tileMode => modeFor(NotificationBadgeSurface.tile);
  NotificationBadgeMode get pageMode => modeFor(NotificationBadgeSurface.page);
  NotificationBadgeMode get listMode => modeFor(NotificationBadgeSurface.list);

  /// Raw per-package counts (kept even while capture is off).
  Map<String, int> get counts => _counts;

  /// Number of apps that currently have unread notifications.
  int get appCount => _counts.length;

  /// Total number of unread notifications across all apps.
  int get total => _counts.values.fold(0, (sum, c) => sum + c);

  /// Number of notifications for [packageName]; 0 when capture is off or the
  /// surface is set to [NotificationBadgeMode.none].
  int countFor(
    String packageName, {
    NotificationBadgeSurface surface = NotificationBadgeSurface.list,
  }) {
    if (!_capture) return 0;
    if (modeFor(surface) == NotificationBadgeMode.none) return 0;
    return _counts[packageName] ?? 0;
  }

  /// Whether [packageName] should show a badge on the given surface.
  bool hasBadge(
    String packageName, {
    NotificationBadgeSurface surface = NotificationBadgeSurface.list,
  }) => countFor(packageName, surface: surface) > 0;

  /// The text drawn inside a count badge (`99+` when long).
  static String labelFor(int count) =>
      count > maxCount ? '$maxCount+' : '$count';

  void setCapture(bool value) {
    if (_capture == value) return;
    _capture = value;
    notifyListeners();
  }

  void setMode(NotificationBadgeMode value, NotificationBadgeSurface surface) {
    if (_modes[surface] == value) return;
    _modes[surface] = value;
    notifyListeners();
  }

  void setCounts(Map<String, int> counts) {
    if (mapEquals(_counts, counts)) return;
    _counts = counts;
    notifyListeners();
  }

  void clear() => setCounts(const {});
}
