import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Process-wide app-icon cache (icon slot -> PNG bytes).
///
/// A slot is a package name, or `package|activity` when the user pinned one of
/// the package's several launcher entries (its entries can have their own
/// icons). Kept outside the widget tree so a widget can paint a cached icon
/// without a [BuildContext] or a provider lookup. [AppState] hydrates it from
/// disk at startup, mirrors each app's pinned entry, and persists additions; a
/// bulk replace (e.g. the settings "refresh icon cache" action or a data
/// import) notifies listeners so every visible icon repaints with the new
/// bytes.
class IconCache extends ChangeNotifier {
  IconCache._();

  static final IconCache instance = IconCache._();

  /// Canonical pixel size icons are fetched and cached at; widgets scale down.
  static const int fetchSize = 192;

  final Map<String, Uint8List> _bytes = <String, Uint8List>{};

  /// Which launcher entry's icon to show per package, when the user pinned one
  /// of several. Owned by [AppState] (it mirrors each app's pinned entry), kept
  /// here so leaf widgets can resolve an icon without a provider lookup.
  final Map<String, String> _activities = <String, String>{};

  /// Cache slot for a package: its own icon, or — when an entry is pinned (or
  /// passed explicitly) — that entry's icon, which can differ (the dialer and
  /// contacts tabs of one package each have their own).
  String slotFor(String packageName, [String? activity]) {
    final chosen = (activity ?? _activities[packageName] ?? '').trim();
    return chosen.isEmpty ? packageName : '$packageName|$chosen';
  }

  /// The entry whose icon [packageName] shows; '' for the app's own icon.
  String activityFor(String packageName) => _activities[packageName] ?? '';

  /// Replaces the package -> entry map (entries with no pinned choice are
  /// absent). Notifies so visible icons re-resolve.
  void setActivities(Map<String, String> next) {
    if (mapEquals(_activities, next)) return;
    _activities
      ..clear()
      ..addAll(next);
    notifyListeners();
  }

  /// The entry part of a slot key (`package|activity`), or null for a plain
  /// package slot. Used to fetch the icon that matches the slot.
  static String? slotActivity(String slotKey) {
    final i = slotKey.indexOf('|');
    if (i < 0) return null;
    final activity = slotKey.substring(i + 1);
    return activity.isEmpty ? null : activity;
  }

  Uint8List? operator [](String slotKey) => _bytes[slotKey];

  bool containsKey(String slotKey) => _bytes.containsKey(slotKey);

  int get length => _bytes.length;

  /// Total size of the cached icon data, for the storage screen.
  int get byteCount =>
      _bytes.values.fold<int>(0, (sum, bytes) => sum + bytes.length);

  /// Persistence hook installed by [AppState]. Called (coalesced) after a
  /// silent [put] so an on-demand fetch is written to disk and survives a
  /// restart. Null outside the running app (e.g. in some tests).
  Future<void> Function()? onDirty;

  bool _dirty = false;
  Future<void>? _flush;

  /// Store one icon without notifying: the widget that fetched it repaints
  /// itself, so the rest of the tree does not need to rebuild.
  void put(String slotKey, Uint8List bytes) {
    if (bytes.isEmpty) return;
    _bytes[slotKey] = bytes;
    _schedulePersist();
  }

  void _schedulePersist() {
    if (onDirty == null) return;
    _dirty = true;
    _flush ??= Future.microtask(_runFlush);
  }

  Future<void> _runFlush() async {
    while (_dirty) {
      _dirty = false;
      final hook = onDirty;
      if (hook == null) break;
      try {
        await hook();
      } catch (_) {
        // A failed write must not wedge later flushes.
      }
    }
    _flush = null;
  }

  /// Replace the whole cache and notify listeners. Used after a refresh, an
  /// import, or a full clear, where every visible icon should repaint.
  void replaceAll(Map<String, Uint8List> next) {
    _bytes
      ..clear()
      ..addAll(next);
    notifyListeners();
  }

  /// Drop the contents without notifying (callers notify via [replaceAll] once
  /// the replacement is ready, so icons never flash a placeholder in between).
  void clearSilent() => _bytes.clear();

  /// JSON-safe view (base64) for persistence / export.
  Map<String, String> toJson() =>
      _bytes.map((k, v) => MapEntry(k, base64Encode(v)));

  /// Parse a persisted/exported icon map, skipping corrupt entries.
  static Map<String, Uint8List> decode(Object? raw) {
    final out = <String, Uint8List>{};
    if (raw is Map) {
      raw.forEach((k, v) {
        if (k is! String || v is! String || v.isEmpty) return;
        try {
          out[k] = base64Decode(v);
        } catch (_) {
          // Ignore a corrupt entry rather than dropping the whole cache.
        }
      });
    }
    return out;
  }
}
