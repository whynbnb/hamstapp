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

  const DiffItem({
    required this.type,
    required this.packageName,
    required this.appName,
    this.fromVersion = '',
    this.toVersion = '',
    this.isSystem = false,
    this.sizeBytes = 0,
    this.icon,
  });
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

    final added = <DiffItem>[];
    final removed = <DiffItem>[];
    final updated = <DiffItem>[];
    final unchanged = <DiffItem>[];

    for (final entry in newMap.values) {
      final prev = oldMap[entry.packageName];
      if (prev == null) {
        added.add(DiffItem(
          type: DiffType.added,
          packageName: entry.packageName,
          appName: entry.appName,
          toVersion: entry.versionName,
          isSystem: entry.isSystem,
          sizeBytes: entry.sizeBytes,
          icon: entry.icon,
        ));
      } else if (prev.versionCode != entry.versionCode ||
          prev.versionName != entry.versionName) {
        updated.add(DiffItem(
          type: DiffType.updated,
          packageName: entry.packageName,
          appName: entry.appName,
          fromVersion: prev.versionName,
          toVersion: entry.versionName,
          isSystem: entry.isSystem,
          sizeBytes: entry.sizeBytes,
          icon: entry.icon,
        ));
      } else {
        unchanged.add(DiffItem(
          type: DiffType.unchanged,
          packageName: entry.packageName,
          appName: entry.appName,
          toVersion: entry.versionName,
          isSystem: entry.isSystem,
          sizeBytes: entry.sizeBytes,
          icon: entry.icon,
        ));
      }
    }

    for (final entry in oldMap.values) {
      if (!newMap.containsKey(entry.packageName)) {
        removed.add(DiffItem(
          type: DiffType.removed,
          packageName: entry.packageName,
          appName: entry.appName,
          fromVersion: entry.versionName,
          isSystem: entry.isSystem,
          sizeBytes: entry.sizeBytes,
          icon: entry.icon,
        ));
      }
    }

    added.sort((a, b) => a.appName.compareTo(b.appName));
    removed.sort((a, b) => a.appName.compareTo(b.appName));
    updated.sort((a, b) => a.appName.compareTo(b.appName));
    return SnapshotDiff(
      added: added,
      removed: removed,
      updated: updated,
      unchanged: unchanged,
    );
  }
}
