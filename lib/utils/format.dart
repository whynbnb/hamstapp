import 'package:intl/intl.dart';

import '../l10n/app_strings.dart';

class Fmt {
  static final DateFormat _date = DateFormat('yyyy-MM-dd HH:mm');
  static final DateFormat _day = DateFormat('yyyy-MM-dd');

  static String dateTime(int millis) => millis <= 0
      ? AppStrings.current.t('未知')
      : _date.format(DateTime.fromMillisecondsSinceEpoch(millis));

  static String day(int millis) => millis <= 0
      ? AppStrings.current.t('未知')
      : _day.format(DateTime.fromMillisecondsSinceEpoch(millis));

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

  /// `07:30` for a timestamp.
  static String clock(int millis) {
    final t = DateTime.fromMillisecondsSinceEpoch(millis);
    return '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';
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
    return '${t.month}/${t.day}';
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
