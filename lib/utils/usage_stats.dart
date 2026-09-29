import '../models/launch_event.dart';

/// Aggregated usage for one app inside a time window.
class UsageEntry {
  final String packageName;

  /// Launches inside the window.
  final int count;

  /// Most recent launch inside the window (epoch ms).
  final int lastAt;

  const UsageEntry({
    required this.packageName,
    required this.count,
    required this.lastAt,
  });
}

/// An app that used to be opened often but has not been opened inside the
/// current window.
class NeglectedEntry {
  final String packageName;

  /// Launches recorded before the window started.
  final int pastCount;

  /// Last launch ever recorded (epoch ms).
  final int lastAt;

  const NeglectedEntry({
    required this.packageName,
    required this.pastCount,
    required this.lastAt,
  });
}

/// Pure helpers that turn the raw [LaunchEvent] log into the "usage trends"
/// lists. Keeping this free of Flutter makes it easy to test.
///
/// Only timestamped events are considered, so launches recorded before the
/// event log existed are ignored. Apps are matched against the set of
/// currently installed packages so uninstalled leftovers never show up.
///
/// "Neglected" deliberately means *was used, then stopped* rather than *least
/// used*: with hundreds of installed apps the least-used list would be nothing
/// but apps that were never opened, which is noise. Requiring a minimum number
/// of past launches keeps one-off trials out of the list.
class UsageStats {
  const UsageStats._();

  /// Apps with the most launches at/after [sinceMillis], most first.
  static List<UsageEntry> mostUsed(
    List<LaunchEvent> events, {
    required Set<String> installed,
    required int sinceMillis,
    int limit = 20,
  }) {
    final counts = <String, int>{};
    final last = <String, int>{};
    for (final e in events) {
      if (e.at < sinceMillis) continue;
      if (!installed.contains(e.packageName)) continue;
      counts[e.packageName] = (counts[e.packageName] ?? 0) + 1;
      if (e.at > (last[e.packageName] ?? 0)) last[e.packageName] = e.at;
    }
    final out = counts.keys
        .map(
          (p) => UsageEntry(
            packageName: p,
            count: counts[p]!,
            lastAt: last[p] ?? 0,
          ),
        )
        .toList()
      ..sort((a, b) {
        final c = b.count.compareTo(a.count);
        if (c != 0) return c;
        final d = b.lastAt.compareTo(a.lastAt);
        if (d != 0) return d;
        return a.packageName.compareTo(b.packageName);
      });
    return out.length > limit ? out.sublist(0, limit) : out;
  }

  /// Apps launched at least [minPastCount] times before [sinceMillis] and not
  /// at all since then, most-used-before first.
  static List<NeglectedEntry> neglected(
    List<LaunchEvent> events, {
    required Set<String> installed,
    required int sinceMillis,
    int minPastCount = 2,
    int limit = 30,
  }) {
    final before = <String, int>{};
    final after = <String, int>{};
    final last = <String, int>{};
    for (final e in events) {
      if (!installed.contains(e.packageName)) continue;
      if (e.at >= sinceMillis) {
        after[e.packageName] = (after[e.packageName] ?? 0) + 1;
      } else {
        before[e.packageName] = (before[e.packageName] ?? 0) + 1;
      }
      if (e.at > (last[e.packageName] ?? 0)) last[e.packageName] = e.at;
    }
    final out = <NeglectedEntry>[];
    before.forEach((pkg, past) {
      if (past < minPastCount) return;
      if ((after[pkg] ?? 0) > 0) return;
      out.add(
        NeglectedEntry(
          packageName: pkg,
          pastCount: past,
          lastAt: last[pkg] ?? 0,
        ),
      );
    });
    out.sort((a, b) {
      final c = b.pastCount.compareTo(a.pastCount);
      if (c != 0) return c;
      final d = b.lastAt.compareTo(a.lastAt);
      if (d != 0) return d;
      return a.packageName.compareTo(b.packageName);
    });
    return out.length > limit ? out.sublist(0, limit) : out;
  }

  /// Total launches at/after [sinceMillis] across all installed apps.
  static int launchesInRange(
    List<LaunchEvent> events, {
    required Set<String> installed,
    required int sinceMillis,
  }) {
    var n = 0;
    for (final e in events) {
      if (e.at >= sinceMillis && installed.contains(e.packageName)) n++;
    }
    return n;
  }

  /// Distinct apps launched at/after [sinceMillis].
  static int activeAppsInRange(
    List<LaunchEvent> events, {
    required Set<String> installed,
    required int sinceMillis,
  }) {
    final set = <String>{};
    for (final e in events) {
      if (e.at >= sinceMillis && installed.contains(e.packageName)) {
        set.add(e.packageName);
      }
    }
    return set.length;
  }

  /// Total apps that used to be opened but have gone quiet in the window.
  static int neglectedCount(
    List<LaunchEvent> events, {
    required Set<String> installed,
    required int sinceMillis,
    int minPastCount = 2,
  }) =>
      neglected(
        events,
        installed: installed,
        sinceMillis: sinceMillis,
        minPastCount: minPastCount,
        limit: 1 << 30,
      ).length;

  /// Packages that have never been launched from this app.
  static Set<String> neverLaunched(
    List<LaunchEvent> events, {
    required Set<String> candidates,
  }) {
    final seen = <String>{for (final e in events) e.packageName};
    return candidates.difference(seen);
  }
}