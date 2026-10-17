import 'package:lpinyin/lpinyin.dart';

import '../models/app_info.dart';

/// Precomputed, cached search keys for an app.
class SearchFields {
  const SearchFields({
    required this.name,
    required this.pkg,
    required this.full,
    required this.initials,
  });

  /// Lowercased display name.
  final String name;

  /// Lowercased package name.
  final String pkg;

  /// Full pinyin (no tones/spaces) plus latin characters, lowercased.
  final String full;

  /// Pinyin initials plus latin characters, lowercased. e.g. 微信 -> wx.
  final String initials;
}

/// Fuzzy search over app names/packages with pinyin support.
///
/// Matches, in order of preference: exact name, name prefix/substring,
/// package, pinyin initials (e.g. `wx` -> 微信), full pinyin (`weixin`), then
/// character subsequence (e.g. `gmap` -> Google Maps). Queries are split on
/// whitespace and every token must match.
class AppSearch {
  AppSearch._();

  static final Map<String, SearchFields> _cache = <String, SearchFields>{};

  static SearchFields fieldsFor(String packageName, String appName) {
    final lowerName = appName.toLowerCase();
    final cached = _cache[packageName];
    if (cached != null && cached.name == lowerName) return cached;
    final f = SearchFields(
      name: lowerName,
      pkg: packageName.toLowerCase(),
      full: _safePinyin(appName).toLowerCase(),
      initials: _safeShortPinyin(appName).toLowerCase(),
    );
    _cache[packageName] = f;
    return f;
  }

  static void clearCache() => _cache.clear();

  /// Lowercased full pinyin (latin characters preserved) for sorting names.
  static String pinyinKey(String s) => _safePinyin(s).toLowerCase();

  static String _safePinyin(String s) {
    try {
      return PinyinHelper.getPinyinE(s, separator: '');
    } catch (_) {
      return s;
    }
  }

  static String _safeShortPinyin(String s) {
    try {
      return PinyinHelper.getShortPinyin(s);
    } catch (_) {
      return s;
    }
  }

  static bool matches(String packageName, String appName, String query) =>
      score(packageName, appName, query) != null;

  /// Relevance score (higher is better) or null when [query] does not match.
  /// An empty query scores 0 and matches everything.
  static int? score(String packageName, String appName, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return 0;
    final f = fieldsFor(packageName, appName);
    var total = 0;
    for (final token in q.split(RegExp(r'\s+'))) {
      if (token.isEmpty) continue;
      final s = _tokenScore(f, token);
      if (s == null) return null;
      total += s;
    }
    return total;
  }

  /// Filters and ranks [apps] by relevance to [query].
  static List<AppInfo> rank(List<AppInfo> apps, String query, {int? limit}) {
    final q = query.trim();
    List<AppInfo> list;
    if (q.isEmpty) {
      list = List<AppInfo>.from(apps)
        ..sort(
          (a, b) => a.appName.toLowerCase().compareTo(b.appName.toLowerCase()),
        );
    } else {
      final scored = <MapEntry<AppInfo, int>>[];
      for (final a in apps) {
        final s = score(a.packageName, a.appName, q);
        if (s != null) scored.add(MapEntry(a, s));
      }
      scored.sort((a, b) {
        final c = b.value.compareTo(a.value);
        if (c != 0) return c;
        return a.key.appName.toLowerCase().compareTo(
          b.key.appName.toLowerCase(),
        );
      });
      list = scored.map((e) => e.key).toList();
    }
    return limit == null ? list : list.take(limit).toList();
  }

  static int? _tokenScore(SearchFields f, String t) {
    if (f.name == t) return 1000;
    if (f.name.startsWith(t)) return 920 - t.length.clamp(0, 40);
    final ni = f.name.indexOf(t);
    if (ni >= 0) return 860 - ni.clamp(0, 40);
    if (f.pkg == t) return 840;
    if (f.pkg.contains(t)) return 800;
    if (f.initials == t) return 780;
    if (f.initials.startsWith(t)) return 760 - t.length.clamp(0, 30);
    if (f.initials.contains(t)) return 720;
    if (f.full.startsWith(t)) return 700 - t.length.clamp(0, 30);
    if (f.full.contains(t)) return 660;

    final fs = _subsequence(t, f.initials);
    if (fs != null) return 480 + fs;
    final ff = _subsequence(t, f.full);
    if (ff != null) return 440 + ff;
    final fn = _subsequence(t, f.name);
    if (fn != null) return 400 + fn;
    return null;
  }

  /// Fuzzy match: every character of [q] appears in [s] in order. Rewards
  /// contiguous and leading matches. Returns null when unmatched.
  static int? _subsequence(String q, String s) {
    if (q.isEmpty || s.isEmpty) return null;
    var si = 0;
    var score = 0;
    var last = -2;
    for (var qi = 0; qi < q.length; qi++) {
      final c = q.codeUnitAt(qi);
      var found = -1;
      for (var j = si; j < s.length; j++) {
        if (s.codeUnitAt(j) == c) {
          found = j;
          break;
        }
      }
      if (found < 0) return null;
      score += found == last + 1 ? 3 : 1;
      if (found == 0) score += 1;
      last = found;
      si = found + 1;
    }
    return score;
  }
}
/// A parsed search query: the free text plus the `key:value` filters the app
/// list understands. Anything that is not a known filter stays part of the
/// text, so a stray colon never breaks a search.
///
/// ```
/// size:>100m          larger than 100 MB       (< for smaller, a-b for a range)
/// installed:<7d       installed in the last 7 days (also >30d, >2026-01-01)
/// updated:<30d        updated in the last 30 days
/// cat:游戏            in a category whose name contains this
/// reason:工作         install reason contains this (bare `reason:` = has one)
/// source:none         no installer on record (side-loaded); otherwise matches
/// type:system         system apps only (type:user for user apps)
/// ```
class AppQuery {
  const AppQuery({
    this.text = '',
    this.sizeOver,
    this.sizeUnder,
    this.installedAfter,
    this.installedBefore,
    this.updatedAfter,
    this.category = '',
    this.reason = '',
    this.source = '',
    this.onlySideloaded = false,
    this.systemOnly = false,
    this.userOnly = false,
    this.hasReason = false,
    this.hasCategory = false,
    this.hasInstaller = false,
  });

  /// Free text, with every recognised filter taken out.
  final String text;

  /// Byte bounds from `size:`.
  final int? sizeOver;
  final int? sizeUnder;

  /// Epoch-millisecond bounds from `installed:` / `updated:`.
  final int? installedAfter;
  final int? installedBefore;
  final int? updatedAfter;

  final String category;
  final String reason;
  final String source;

  /// `source:none` — nothing installed the app as far as the system knows.
  final bool onlySideloaded;
  final bool systemOnly;
  final bool userOnly;
  final bool hasReason;

  /// A bare `cat:` / `source:` — "belongs to some category", "has an installer".
  final bool hasCategory;
  final bool hasInstaller;

  bool get hasFilters =>
      sizeOver != null ||
      sizeUnder != null ||
      installedAfter != null ||
      installedBefore != null ||
      updatedAfter != null ||
      category.isNotEmpty ||
      reason.isNotEmpty ||
      source.isNotEmpty ||
      onlySideloaded ||
      systemOnly ||
      userOnly ||
      hasReason ||
      hasCategory ||
      hasInstaller;

  bool get isEmpty => text.isEmpty && !hasFilters;

  /// Parses [raw]; [now] is the reference point for relative dates (`<7d`).
  factory AppQuery.parse(String raw, {required int now}) {
    final words = <String>[];
    int? sizeOver, sizeUnder, installedAfter, installedBefore, updatedAfter;
    var category = '', reason = '', source = '';
    var onlySideloaded = false, systemOnly = false, userOnly = false;
    var hasReason = false, hasCategory = false, hasInstaller = false;

    for (final token in raw.trim().split(RegExp(r'\s+'))) {
      if (token.isEmpty) continue;
      final colon = token.indexOf(':');
      if (colon <= 0) {
        words.add(token);
        continue;
      }
      final key = token.substring(0, colon).toLowerCase();
      final value = token.substring(colon + 1).trim();
      switch (key) {
        case 'size':
          final (over, under) = _parseSize(value);
          if (over == null && under == null) {
            words.add(token);
          } else {
            sizeOver = over;
            sizeUnder = under;
          }
        case 'installed':
          final window = _parseRange(value, now: now);
          if (window == null) {
            words.add(token);
          } else {
            installedAfter = window.$1;
            installedBefore = window.$2;
          }
        case 'updated':
          final window = _parseRange(value, now: now);
          if (window == null) {
            words.add(token);
          } else {
            updatedAfter = window.$1;
          }
        case 'cat':
          if (value.isEmpty) {
            hasCategory = true;
          } else {
            category = value.toLowerCase();
          }
        case 'reason':
          if (value.isEmpty) {
            hasReason = true;
          } else {
            reason = value.toLowerCase();
          }
        case 'source':
        case 'installer':
          if (value.isEmpty) {
            hasInstaller = true;
          } else if (value.toLowerCase() == 'none' ||
              value.toLowerCase() == 'sideload' ||
              value.toLowerCase() == 'unknown') {
            onlySideloaded = true;
          } else {
            source = value.toLowerCase();
          }
        case 'type':
          switch (value.toLowerCase()) {
            case 'system':
              systemOnly = true;
            case 'user':
              userOnly = true;
            default:
              words.add(token);
          }
        default:
          // Not a filter: keep it as text.
          words.add(token);
      }
    }

    return AppQuery(
      text: words.join(' '),
      sizeOver: sizeOver,
      sizeUnder: sizeUnder,
      installedAfter: installedAfter,
      installedBefore: installedBefore,
      updatedAfter: updatedAfter,
      category: category,
      reason: reason,
      source: source,
      onlySideloaded: onlySideloaded,
      systemOnly: systemOnly,
      userOnly: userOnly,
      hasReason: hasReason,
      hasCategory: hasCategory,
      hasInstaller: hasInstaller,
    );
  }

  /// Whether one app passes every filter. [categoryNames] is the app's
  /// categories joined, [installerLabel] the install source as shown.
  bool matches({
    required int sizeBytes,
    required int firstInstallTime,
    required int lastUpdateTime,
    required bool isSystem,
    required String categoryNames,
    required String reason,
    required String installerLabel,
    required bool sideloaded,
  }) {
    if (systemOnly && !isSystem) return false;
    if (userOnly && isSystem) return false;
    if (sizeOver != null && sizeBytes <= sizeOver!) return false;
    if (sizeUnder != null && sizeBytes >= sizeUnder!) return false;
    if (installedAfter != null && firstInstallTime < installedAfter!) {
      return false;
    }
    if (installedBefore != null &&
        firstInstallTime > 0 &&
        firstInstallTime > installedBefore!) {
      return false;
    }
    if (updatedAfter != null && lastUpdateTime < updatedAfter!) return false;
    if (hasCategory && categoryNames.trim().isEmpty) return false;
    if (category.isNotEmpty &&
        !categoryNames.toLowerCase().contains(category)) {
      return false;
    }
    if (hasReason && reason.isEmpty) return false;
    if (reason.isNotEmpty && !reason.toLowerCase().contains(reason)) {
      return false;
    }
    if (hasInstaller && installerLabel.trim().isEmpty) return false;
    if (onlySideloaded && !sideloaded) return false;
    if (source.isNotEmpty && !installerLabel.toLowerCase().contains(source)) {
      return false;
    }
    return true;
  }

  /// `>100m`, `<500k`, `10m-2g`; no unit means megabytes.
  static (int?, int?) _parseSize(String raw) {
    final value = raw.trim().toLowerCase();
    if (value.isEmpty) return (null, null);
    final range = RegExp(r'^([0-9.]+)([a-z]*)-([0-9.]+)([a-z]*)$').firstMatch(value);
    if (range != null) {
      final low = _bytes(range.group(1), range.group(2));
      final high = _bytes(range.group(3), range.group(4));
      if (low == null || high == null) return (null, null);
      return (low, high);
    }
    final bound = RegExp(r'^([<>]=?|)([0-9.]+)([a-z]*)$').firstMatch(value);
    if (bound == null) return (null, null);
    final bytes = _bytes(bound.group(2), bound.group(3));
    if (bytes == null) return (null, null);
    return switch (bound.group(1)) {
      '>' || '>=' => (bytes, null),
      '<' || '<=' => (null, bytes),
      _ => (null, null),
    };
  }

  static int? _bytes(String? number, String? unit) {
    final value = double.tryParse(number ?? '');
    if (value == null) return null;
    final factor = switch ((unit ?? '').toLowerCase()) {
      '' || 'm' || 'mb' => 1024 * 1024,
      'k' || 'kb' => 1024,
      'g' || 'gb' => 1024 * 1024 * 1024,
      'b' => 1,
      _ => 0,
    };
    if (factor == 0) return null;
    return (value * factor).round();
  }

  /// `>2026-01-01`, `<7d`, `<24h`, `30d-7d` — returns (after, before).
  static (int?, int?)? _parseRange(String raw, {required int now}) {
    final value = raw.trim().toLowerCase();
    if (value.isEmpty) return null;

    (int?, int?)? one(String v) {
      final relative = RegExp(r'^([<>]=?)([0-9.]+)([dhw])$').firstMatch(v);
      if (relative != null) {
        final amount = double.tryParse(relative.group(2)!);
        if (amount == null) return null;
        final unit = relative.group(3)!;
        final span = Duration(
          hours: unit == 'h' ? amount.round() : 0,
          days: unit == 'd' ? amount.round() : (unit == 'w' ? amount.round() * 7 : 0),
        );
        final cutoff = now - span.inMilliseconds;
        // `installed:<7d` reads as "within the last 7 days", so `<` keeps the
        // newer side, while `>30d` keeps what is older than that.
        return relative.group(1)!.startsWith('<')
            ? (cutoff, null)
            : (null, cutoff);
      }
      final date = RegExp(r'^([<>]=?)(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(v);
      if (date != null) {
        final millis = DateTime(
          int.parse(date.group(2)!),
          int.parse(date.group(3)!),
          int.parse(date.group(4)!),
        ).millisecondsSinceEpoch;
        return date.group(1)!.startsWith('>') ? (millis, null) : (null, millis);
      }
      return null;
    }

    final parts = value.split('-');
    if (parts.length == 2 && parts.every((p) => p.isNotEmpty)) {
      // A range such as `>2024-01-01-<2025-01-01` is ambiguous with dates, so
      // only the plain two-sided form `a-b` of the same kind is accepted.
      final left = one(parts[0]);
      final right = one(parts[1]);
      if (left != null && right != null) {
        return (left.$1 ?? right.$1, left.$2 ?? right.$2);
      }
    }
    return one(value);
  }
}
