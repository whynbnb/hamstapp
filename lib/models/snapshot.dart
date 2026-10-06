import 'dart:convert';
import 'dart:typed_data';

import 'category.dart';

/// A single app recorded inside a snapshot.
///
/// Besides install-time facts it also captures the user's annotations
/// (reason, note, categories, favorite) and uninstall records, so a snapshot
/// can fully restore the corresponding app information.
class SnapshotEntry {
  final String packageName;
  final String appName;
  final String versionName;
  final int versionCode;
  final int lastUpdateTime;
  final int firstInstallTime;
  final bool isSystem;
  final int sizeBytes;

  final String reason;
  final String note;
  final List<String> categoryIds;
  final bool favorite;
  final bool pinned;

  /// Why the app was uninstalled (empty when installed).
  final String uninstallReason;

  /// When the app was uninstalled; 0 means it was installed at snapshot time.
  final int uninstalledAt;

  /// PNG bytes of the app icon captured with the snapshot, so uninstalled apps
  /// can still be shown with their icon. Null for snapshots taken before icons
  /// were recorded (old data stays compatible).
  final Uint8List? icon;

  const SnapshotEntry({
    required this.packageName,
    required this.appName,
    required this.versionName,
    required this.versionCode,
    required this.lastUpdateTime,
    required this.firstInstallTime,
    required this.isSystem,
    required this.sizeBytes,
    this.reason = '',
    this.note = '',
    this.categoryIds = const <String>[],
    this.favorite = false,
    this.pinned = false,
    this.uninstallReason = '',
    this.uninstalledAt = 0,
    this.icon,
  });

  bool get isInstalled => uninstalledAt == 0;

  factory SnapshotEntry.fromMap(Map<String, dynamic> map) => SnapshotEntry(
        packageName: map['packageName'] as String,
        appName: map['appName'] as String? ?? '',
        versionName: map['versionName'] as String? ?? '',
        versionCode: map['versionCode'] as int? ?? 0,
        lastUpdateTime: map['lastUpdateTime'] as int? ?? 0,
        firstInstallTime: map['firstInstallTime'] as int? ?? 0,
        isSystem: map['isSystem'] as bool? ?? false,
        sizeBytes: map['sizeBytes'] as int? ?? 0,
        reason: map['reason'] as String? ?? '',
        note: map['note'] as String? ?? '',
        categoryIds: (map['categoryIds'] as List?)?.cast<String>() ?? const [],
        favorite: map['favorite'] as bool? ?? false,
        pinned: map['pinned'] as bool? ?? false,
        uninstallReason: map['uninstallReason'] as String? ?? '',
        uninstalledAt: map['uninstalledAt'] as int? ?? 0,
        icon: _decodeIcon(map['icon']),
      );

  static Uint8List? _decodeIcon(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    try {
      return base64Decode(raw);
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toMap() => {
        'packageName': packageName,
        'appName': appName,
        'versionName': versionName,
        'versionCode': versionCode,
        'lastUpdateTime': lastUpdateTime,
        'firstInstallTime': firstInstallTime,
        'isSystem': isSystem,
        'sizeBytes': sizeBytes,
        'reason': reason,
        'note': note,
        'categoryIds': categoryIds,
        'favorite': favorite,
        'pinned': pinned,
        'uninstallReason': uninstallReason,
        'uninstalledAt': uninstalledAt,
        if (icon != null) 'icon': base64Encode(icon!),
      };
}

/// A point-in-time capture of the installed app list plus the user's
/// annotations, able to restore them later.
class Snapshot {
  final String id;
  String name;
  final int createdAt;
  final List<SnapshotEntry> entries;
  final String note;

  /// Categories that existed when the snapshot was taken, so restoring on a
  /// fresh setup can recreate them.
  final List<AppCategory> categories;

  Snapshot({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.entries,
    this.note = '',
    List<AppCategory>? categories,
  }) : categories = categories ?? <AppCategory>[];

  DateTime get createdDate => DateTime.fromMillisecondsSinceEpoch(createdAt);

  int get installedCount => entries.where((e) => e.isInstalled).length;

  int get uninstalledCount => entries.length - installedCount;

  factory Snapshot.fromMap(Map<String, dynamic> map) => Snapshot(
        id: map['id'] as String,
        name: map['name'] as String? ?? '',
        createdAt: map['createdAt'] as int? ?? 0,
        note: map['note'] as String? ?? '',
        categories: (map['categories'] as List?)
                ?.map((e) =>
                    AppCategory.fromMap((e as Map).cast<String, dynamic>()))
                .toList() ??
            <AppCategory>[],
        entries: (map['entries'] as List?)
                ?.map((e) =>
                    SnapshotEntry.fromMap((e as Map).cast<String, dynamic>()))
                .toList() ??
            [],
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'createdAt': createdAt,
        'note': note,
        'categories': categories.map((c) => c.toMap()).toList(),
        'entries': entries.map((e) => e.toMap()).toList(),
      };
}
