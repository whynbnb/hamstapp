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
    const units = ['B', 'KB', 'MB', 'GB'];
    double v = bytes.toDouble();
    int i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v >= 100 || i == 0 ? 0 : 1)} ${units[i]}';
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
