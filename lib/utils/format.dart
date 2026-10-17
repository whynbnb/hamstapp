import 'package:intl/intl.dart';

import '../l10n/app_strings.dart';

/// How dates are written across the app. Chosen in Settings → 外观, applied to
/// [Fmt] at startup and on change, so one setting covers every screen and tile.
enum DateStyle {
  /// 2026-10-17
  ymdDash('yyyy-MM-dd', 'MM-dd'),

  /// 2026/10/17
  ymdSlash('yyyy/MM/dd', 'MM/dd'),

  /// 10/17/2026
  mdySlash('MM/dd/yyyy', 'MM/dd'),

  /// 17/10/2026
  dmySlash('dd/MM/yyyy', 'dd/MM'),

  /// 2026年10月17日
  chinese('yyyy年M月d日', 'M月d日');

  const DateStyle(this.pattern, this.shortPattern);

  /// Full date pattern.
  final String pattern;

  /// Month/day only, for tight spots (tile captions).
  final String shortPattern;

  static DateStyle byName(String? name) => DateStyle.values.firstWhere(
    (style) => style.name == name,
    orElse: () => DateStyle.ymdDash,
  );

  /// Today's date written this way, so the settings picker needs no wording.
  String get sample => DateFormat(pattern).format(DateTime.now());
}

class Fmt {
  /// How dates are written; set from the user's setting by [AppState].
  static DateStyle dateStyle = DateStyle.ymdDash;

  /// Whether times are written 24-hour (off means `1:05 PM`).
  static bool clock24h = true;

  /// Formatters are cached per pattern: these run inside list rows and tiles.
  static final Map<String, DateFormat> _formats = <String, DateFormat>{};

  static DateFormat _format(String pattern) =>
      _formats.putIfAbsent(pattern, () => DateFormat(pattern));

  static String get _timePattern => clock24h ? 'HH:mm' : 'h:mm a';

  static String dateTime(int millis) => millis <= 0
      ? AppStrings.current.t('未知')
      : '${day(millis)} ${clock(millis)}';

  static String day(int millis) => millis <= 0
      ? AppStrings.current.t('未知')
      : _format(dateStyle.pattern)
          .format(DateTime.fromMillisecondsSinceEpoch(millis));

  /// Month/day only, in the same order as the full date.
  static String shortDate(int millis) => millis <= 0
      ? ''
      : _format(dateStyle.shortPattern)
          .format(DateTime.fromMillisecondsSinceEpoch(millis));

  static String size(int bytes) {
    if (bytes <= 0) return AppStrings.current.t('未知');
    return _bytes(bytes);
  }

  /// Like [size] but reads empty as `0 B`. For the storage report, where
  /// nothing used is a real answer rather than missing data.
  static String storage(int bytes) => bytes <= 0 ? '0 B' : _bytes(bytes);

  static String _bytes(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB'];
    double v = bytes.toDouble();
    int i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v >= 100 || i == 0 ? 0 : 1)} ${units[i]}';
  }

  /// Short weekday keys, indexed by `DateTime.weekday - 1`.
  static const List<String> kWeekdayKeys = [
    '周一',
    '周二',
    '周三',
    '周四',
    '周五',
    '周六',
    '周日',
  ];

  /// `07:30` (or `7:30 AM`) for a timestamp.
  static String clock(int millis) {
    if (millis <= 0) return '--:--';
    return _format(_timePattern)
        .format(DateTime.fromMillisecondsSinceEpoch(millis));
  }

  /// `今天` / `明天` / `周三` / `10/20` for a timestamp.
  static String relativeDay(int millis) {
    final t = DateTime.fromMillisecondsSinceEpoch(millis);
    final now = DateTime.now();
    final days = DateTime(t.year, t.month, t.day)
        .difference(DateTime(now.year, now.month, now.day))
        .inDays;
    final s = AppStrings.current;
    if (days == 0) return s.t('今天');
    if (days == 1) return s.t('明天');
    if (days > 1 && days < 7) return s.t(kWeekdayKeys[t.weekday - 1]);
    return shortDate(millis);
  }

  /// `3 天 4 小时` / `5 小时 20 分` / `42 分钟` — for an elapsed time.
  static String spanned(int millis) {
    final s = AppStrings.current;
    final minutes = millis ~/ 60000;
    if (minutes < 1) return s.t('不到 1 分钟');
    final days = minutes ~/ (60 * 24);
    final hours = (minutes ~/ 60) % 24;
    if (days > 0) {
      return hours > 0
          ? s.t('{d} 天 {h} 小时', {'d': days, 'h': hours})
          : s.t('{d} 天', {'d': days});
    }
    return duration(millis);
  }

  /// `2.3 MB/秒` for a throughput in bytes per second.
  static String speed(int bytesPerSecond) {
    if (bytesPerSecond <= 0) return '0 B/s';
    return '${storage(bytesPerSecond)}/s';
  }

  /// `3 小时 42 分` / `42 分钟` / `不到 1 分钟`.
  static String duration(int millis) {
    final s = AppStrings.current;
    final minutes = millis ~/ 60000;
    if (minutes < 1) return s.t('不到 1 分钟');
    final h = minutes ~/ 60;
    final m = minutes % 60;
    if (h == 0) return s.t('{m} 分钟', {'m': m});
    return s.t('{h} 小时 {m} 分', {'h': h, 'm': m});
  }

  static String relative(int millis) {
    if (millis <= 0) return AppStrings.current.t('未知');
    final diff = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(millis),
    );
    final t = AppStrings.current;
    if (diff.inDays >= 365) {
      return t.t('{n} 年前', {'n': (diff.inDays / 365).floor()});
    }
    if (diff.inDays >= 30) {
      return t.t('{n} 个月前', {'n': (diff.inDays / 30).floor()});
    }
    if (diff.inDays >= 1) return t.t('{n} 天前', {'n': diff.inDays});
    if (diff.inHours >= 1) return t.t('{n} 小时前', {'n': diff.inHours});
    if (diff.inMinutes >= 1) return t.t('{n} 分钟前', {'n': diff.inMinutes});
    return t.t('刚刚');
  }
}
