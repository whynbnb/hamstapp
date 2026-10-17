import '../models/app_info.dart';
import 'search.dart';

/// How the app list is divided into sections.
enum AppGroupMode {
  /// One flat list.
  none,
  initial,
  category,
}

/// One section of the app list: a header and the apps under it.
class AppGroup {
  const AppGroup(this.label, this.apps);

  final String label;
  final List<AppInfo> apps;
}

/// Splits [apps] into sections, keeping the order they arrive in inside each
/// one (the list is already sorted the way the user asked).
///
/// [initial] groups by the first letter of the pinyin name — `微信` under `W`,
/// anything that is not a letter under `#`. [category] groups by the app's first
/// category, in [categoryOrder] (the user's own order, unnamed ones last).
List<AppGroup> groupApps(
  List<AppInfo> apps,
  AppGroupMode mode, {
  required String Function(AppInfo) nameOf,
  required List<String> Function(AppInfo) categoriesOf,
  required String uncategorizedLabel,
  List<String> categoryOrder = const <String>[],
}) {
  if (mode == AppGroupMode.none) return [AppGroup('', apps)];

  final buckets = <String, List<AppInfo>>{};
  for (final app in apps) {
    final String key;
    switch (mode) {
      case AppGroupMode.initial:
        key = _initial(nameOf(app));
      case AppGroupMode.category:
        final names = categoriesOf(app);
        key = names.isEmpty ? uncategorizedLabel : names.first;
      case AppGroupMode.none:
        key = '';
    }
    buckets.putIfAbsent(key, () => <AppInfo>[]).add(app);
  }

  final labels = buckets.keys.toList();
  switch (mode) {
    case AppGroupMode.initial:
      labels.sort((a, b) {
        if (a == '#') return 1;
        if (b == '#') return -1;
        return a.compareTo(b);
      });
    case AppGroupMode.category:
      labels.sort((a, b) {
        // The user's own category order first, then anything else by name.
        final ia = categoryOrder.indexOf(a);
        final ib = categoryOrder.indexOf(b);
        if (ia >= 0 && ib >= 0) return ia.compareTo(ib);
        if (ia >= 0) return -1;
        if (ib >= 0) return 1;
        if (a == uncategorizedLabel) return 1;
        if (b == uncategorizedLabel) return -1;
        return a.compareTo(b);
      });
    case AppGroupMode.none:
      break;
  }
  return [for (final label in labels) AppGroup(label, buckets[label]!)];
}

/// `微信` -> `W`; a digit or symbol lands under `#`.
String _initial(String name) {
  final key = AppSearch.pinyinKey(name).trim();
  if (key.isEmpty) return '#';
  final first = key[0].toUpperCase();
  return RegExp(r'[A-Z]').hasMatch(first) ? first : '#';
}
