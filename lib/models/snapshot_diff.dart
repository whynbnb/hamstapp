import 'dart:typed_data';

import 'snapshot.dart';

enum DiffType { added, removed, updated, unchanged }

class DiffItem {
  final DiffType type;
  final String packageName;
  final String appName;
  final String fromVersion;
  final String toVersion;
  final bool isSystem;
  final int sizeBytes;

  /// Icon captured with the snapshot (null for older snapshots), so removed
  /// apps still show their icon in the comparison.
  final Uint8List? icon;

  // ---- what an upgrade actually changed (only filled for `updated`) ----

  /// Permissions the newer build asks for that the older one did not.
  final List<String> addedPermissions;

  /// Permissions the newer build no longer asks for.
  final List<String> removedPermissions;

  /// Signing certificate fingerprint on each side. Empty when the snapshot
  /// predates fact recording, or the system would not report one.
  final String fromSignature;
  final String toSignature;
  final bool signatureChanged;

  final int fromTargetSdk;
  final int toTargetSdk;

  /// The installing package on each side; '' means side-loaded / unknown.
  final String fromInstaller;
  final String toInstaller;

  final bool fromExternal;
  final bool toExternal;

  const DiffItem({
    required this.type,
    required this.packageName,
    required this.appName,
    this.fromVersion = '',
    this.toVersion = '',
    this.isSystem = false,
    this.sizeBytes = 0,
    this.icon,
    this.addedPermissions = const <String>[],
    this.removedPermissions = const <String>[],
    this.fromSignature = '',
    this.toSignature = '',
    this.signatureChanged = false,
    this.fromTargetSdk = 0,
    this.toTargetSdk = 0,
    this.fromInstaller = '',
    this.toInstaller = '',
    this.fromExternal = false,
    this.toExternal = false,
  });

  /// Whether anything beyond the version number changed.
  bool get hasDetails =>
      addedPermissions.isNotEmpty ||
      removedPermissions.isNotEmpty ||
      signatureChanged ||
      (fromTargetSdk > 0 &&
          toTargetSdk > 0 &&
          fromTargetSdk != toTargetSdk) ||
      fromInstaller != toInstaller ||
      fromExternal != toExternal;

  /// The part a security-minded user cares about: this update asks for more
  /// (or fewer) permissions, or the app is signed with something else now.
  bool get securityChanged =>
      addedPermissions.isNotEmpty ||
      removedPermissions.isNotEmpty ||
      signatureChanged;
}

class SnapshotDiff {
  final List<DiffItem> added;
  final List<DiffItem> removed;
  final List<DiffItem> updated;
  final List<DiffItem> unchanged;

  const SnapshotDiff({
    required this.added,
    required this.removed,
    required this.updated,
    required this.unchanged,
  });

  int get changedCount => added.length + removed.length + updated.length;

  /// Updated apps that asked for new permissions.
  int get appsWithNewPermissions =>
      updated.where((d) => d.addedPermissions.isNotEmpty).length;

  /// Updated apps whose signing certificate is not the one they had.
  int get appsWithSignatureChange =>
      updated.where((d) => d.signatureChanged).length;

  /// Updated apps whose install source changed (e.g. moved to a store, or
  /// re-installed by hand).
  int get appsWithInstallerChange => updated.where((d) => d.fromInstaller != d.toInstaller).length;

  /// Updated apps with any security-relevant change; these sort first.
  List<DiffItem> get securityUpdates =>
      updated.where((d) => d.securityChanged).toList();

  static SnapshotDiff between(Snapshot older, Snapshot newer) {
    // Presence comparison is based on installed entries only: an app that is
    // recorded as uninstalled in a snapshot is treated as absent.
    final oldMap = {
      for (final e in older.entries)
        if (e.isInstalled) e.packageName: e,
    };
    final newMap = {
      for (final e in newer.entries)
        if (e.isInstalled) e.packageName: e,
    };

    // Permission/signature facts only exist in snapshots taken by 1.1+.
    // Reading the empty fields of an older snapshot would look like every app
    // suddenly dropped all its permissions, so those comparisons are skipped
    // unless both sides carry facts.
    final facts = older.hasFacts && newer.hasFacts;

    final added = <DiffItem>[];
    final removed = <DiffItem>[];
    final updated = <DiffItem>[];
    final unchanged = <DiffItem>[];

    for (final entry in newMap.values) {
      final prev = oldMap[entry.packageName];
      if (prev == null) {
        added.add(
          DiffItem(
            type: DiffType.added,
            packageName: entry.packageName,
            appName: entry.appName,
            toVersion: entry.versionName,
            isSystem: entry.isSystem,
            sizeBytes: entry.sizeBytes,
            icon: entry.icon,
          ),
        );
        continue;
      }

      var details = _details(prev, entry, facts);
      final versionChanged =
          prev.versionCode != entry.versionCode ||
          prev.versionName != entry.versionName;
      if (versionChanged || details.hasDetails) {
        updated.add(
          DiffItem(
            type: DiffType.updated,
            packageName: entry.packageName,
            appName: entry.appName,
            fromVersion: prev.versionName,
            toVersion: entry.versionName,
            isSystem: entry.isSystem,
            sizeBytes: entry.sizeBytes,
            icon: entry.icon,
            addedPermissions: details.addedPermissions,
            removedPermissions: details.removedPermissions,
            fromSignature: details.fromSignature,
            toSignature: details.toSignature,
            signatureChanged: details.signatureChanged,
            fromTargetSdk: details.fromTargetSdk,
            toTargetSdk: details.toTargetSdk,
            fromInstaller: details.fromInstaller,
            toInstaller: details.toInstaller,
            fromExternal: details.fromExternal,
            toExternal: details.toExternal,
          ),
        );
      } else {
        unchanged.add(
          DiffItem(
            type: DiffType.unchanged,
            packageName: entry.packageName,
            appName: entry.appName,
            toVersion: entry.versionName,
            isSystem: entry.isSystem,
            sizeBytes: entry.sizeBytes,
            icon: entry.icon,
          ),
        );
      }
    }

    for (final entry in oldMap.values) {
      if (!newMap.containsKey(entry.packageName)) {
        removed.add(
          DiffItem(
            type: DiffType.removed,
            packageName: entry.packageName,
            appName: entry.appName,
            fromVersion: entry.versionName,
            isSystem: entry.isSystem,
            sizeBytes: entry.sizeBytes,
            icon: entry.icon,
          ),
        );
      }
    }

    added.sort((a, b) => a.appName.compareTo(b.appName));
    removed.sort((a, b) => a.appName.compareTo(b.appName));
    // Security-relevant upgrades first: they are the reason to look at all.
    updated.sort((a, b) {
      final c = (b.securityChanged ? 1 : 0).compareTo(a.securityChanged ? 1 : 0);
      if (c != 0) return c;
      return a.appName.compareTo(b.appName);
    });
    return SnapshotDiff(
      added: added,
      removed: removed,
      updated: updated,
      unchanged: unchanged,
    );
  }

  /// The detailed difference between two entries, or an empty one when there is
  /// nothing to report (or nothing trustworthy to compare).
  static DiffItem _details(SnapshotEntry prev, SnapshotEntry entry, bool facts) {
    if (!facts) {
      return const DiffItem(type: DiffType.updated, packageName: '', appName: '');
    }
    final before = prev.permissions.toSet();
    final after = entry.permissions.toSet();
    return DiffItem(
      type: DiffType.updated,
      packageName: entry.packageName,
      appName: entry.appName,
      addedPermissions: (after.difference(before).toList()..sort()),
      removedPermissions: (before.difference(after).toList()..sort()),
      fromSignature: prev.signature,
      toSignature: entry.signature,
      // A certificate that was not recorded cannot be compared; an empty one
      // that shows up later is not a change either.
      signatureChanged: prev.signature.isNotEmpty &&
          entry.signature.isNotEmpty &&
          prev.signature != entry.signature,
      fromTargetSdk: prev.targetSdk,
      toTargetSdk: entry.targetSdk,
      fromInstaller: prev.installer,
      toInstaller: entry.installer,
      fromExternal: prev.external,
      toExternal: entry.external,
    );
  }
}
