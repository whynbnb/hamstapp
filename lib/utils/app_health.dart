/// Findings for the "整理与体检" screen: apps that look like each other, and
/// packages with several downloaded versions.
///
/// Pure functions and small inputs on purpose — the screen only has to supply
/// the current list and the download-cache index.
library;

/// The facts the duplicate check needs about one installed app.
class HealthApp {
  const HealthApp({
    required this.packageName,
    required this.name,
    this.signature = '',
    this.isSystem = false,
  });

  final String packageName;
  final String name;

  /// SHA-256 of the signing certificate; '' when it was not recorded.
  final String signature;
  final bool isSystem;
}

/// One package with more than one downloaded APK.
class CachedVersions {
  const CachedVersions({
    required this.packageName,
    required this.versions,
    this.bytes = 0,
  });

  final String packageName;

  /// versionCodes of the cached files.
  final List<int> versions;
  final int bytes;
}

enum DuplicateKind {
  /// Several packages with the same display name.
  sameName,

  /// Same certificate, different package, names close to each other. Usually
  /// one developer's variants (Lite / Pro), which is why it is informational
  /// rather than risky.
  similarName,

  /// Several cached APKs of one package.
  cachedVersions,
}

class DuplicateGroup {
  const DuplicateGroup({
    required this.kind,
    required this.label,
    this.apps = const <HealthApp>[],
    this.signatureMismatch = false,
    this.versions = const <int>[],
    this.bytes = 0,
  });

  final DuplicateKind kind;

  /// The shared app name, or the package for a cache-only group.
  final String label;

  final List<HealthApp> apps;

  /// Same name, different certificates: at least one of them is not the app it
  /// claims to be.
  final bool signatureMismatch;

  final List<int> versions;
  final int bytes;
}

class AppHealthReport {
  const AppHealthReport({required this.duplicates, required this.riskyCount});

  final List<DuplicateGroup> duplicates;

  /// Groups with mismatched certificates — the ones worth looking at first.
  final int riskyCount;

  int get groupCount => duplicates.length;
}

/// Groups installed apps by name and collects the packages that have several
/// versions in the download cache. Certificates are only compared when both
/// sides reported one.
AppHealthReport analyzeHealth({
  required List<HealthApp> apps,
  required List<CachedVersions> cache,
}) {
  final groups = <DuplicateGroup>[];

  final byName = <String, List<HealthApp>>{};
  for (final app in apps) {
    final key = app.name.trim().toLowerCase();
    if (key.isEmpty) continue;
    byName.putIfAbsent(key, () => <HealthApp>[]).add(app);
  }
  for (final entry in byName.entries) {
    if (entry.value.length < 2) continue;
    final signatures = entry.value
        .map((a) => a.signature)
        .where((s) => s.isNotEmpty)
        .toSet();
    final apps = List<HealthApp>.from(entry.value)
      ..sort((a, b) => a.packageName.compareTo(b.packageName));
    groups.add(
      DuplicateGroup(
        kind: DuplicateKind.sameName,
        label: apps.first.name,
        apps: apps,
        signatureMismatch: signatures.length > 1,
      ),
    );
  }

  // Same signer + a name one edit away: "X" / "X Lite", "Telegram" / "Telegram
  // X". System apps share the platform key, so they are skipped.
  final bySignature = <String, List<HealthApp>>{};
  for (final app in apps) {
    if (app.signature.isEmpty || app.isSystem) continue;
    bySignature.putIfAbsent(app.signature, () => <HealthApp>[]).add(app);
  }
  for (final group in bySignature.values) {
    if (group.length < 2) continue;
    final taken = <String>{};
    for (var i = 0; i < group.length; i++) {
      if (taken.contains(group[i].packageName)) continue;
      final cluster = <HealthApp>[group[i]];
      for (var j = i + 1; j < group.length; j++) {
        if (taken.contains(group[j].packageName)) continue;
        if (!_similarNames(group[i].name, group[j].name)) continue;
        cluster.add(group[j]);
        taken.add(group[j].packageName);
      }
      if (cluster.length > 1) {
        groups.add(
          DuplicateGroup(
            kind: DuplicateKind.similarName,
            label: cluster.first.name,
            apps: cluster,
          ),
        );
      }
    }
  }

  for (final cached in cache) {
    final versions = cached.versions.toSet().toList()..sort();
    if (versions.length < 2) continue;
    groups.add(
      DuplicateGroup(
        kind: DuplicateKind.cachedVersions,
        label: cached.packageName,
        versions: versions,
        bytes: cached.bytes,
      ),
    );
  }

  // Risky groups first, then by label, so the screen opens on what matters.
  groups.sort((a, b) {
    final byRisk =
        (b.signatureMismatch ? 1 : 0).compareTo(a.signatureMismatch ? 1 : 0);
    if (byRisk != 0) return byRisk;
    return a.label.toLowerCase().compareTo(b.label.toLowerCase());
  });

  return AppHealthReport(
    duplicates: groups,
    riskyCount: groups.where((g) => g.signatureMismatch).length,
  );
}

/// Whether two display names look like variants of one app. Equal names are
/// handled by the name grouping, so they are not "similar" here.
bool _similarNames(String a, String b) {
  final x = a.trim().toLowerCase();
  final y = b.trim().toLowerCase();
  if (x.isEmpty || y.isEmpty || x == y) return false;
  if (x.contains(y) || y.contains(x)) return true;
  // A single typo is enough for a variant, but only on names long enough that
  // one character actually means something ("Maps" / "Mail" is not a variant).
  final longest = x.length > y.length ? x.length : y.length;
  if (longest < 4) return false;
  return _editDistance(x, y) <= 1;
}

int _editDistance(String a, String b) {
  if (a == b) return 0;
  var previous = List<int>.generate(b.length + 1, (i) => i);
  var current = List<int>.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    current[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      final deletion = previous[j] + 1;
      final insertion = current[j - 1] + 1;
      final substitution = previous[j - 1] + cost;
      current[j] = deletion < insertion
          ? (deletion < substitution ? deletion : substitution)
          : (insertion < substitution ? insertion : substitution);
    }
    final swap = previous;
    previous = current;
    current = swap;
  }
  return previous[b.length];
}
