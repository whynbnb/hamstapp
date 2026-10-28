import 'dart:async';
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

  /// The icon pack the user chose (a package name), or '' for the launcher
  /// icons. Leaf widgets read it when they fetch a missing icon; changing it
  /// clears the cache, because every key now means a different picture.
  String iconPack = '';

  void setIconPack(String pack) {
    if (iconPack == pack) return;
    iconPack = pack;
    _bytes.clear();
    _dirty = true;
    notifyListeners();
    onDirty?.call();
  }

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
  bool _flushing = false;
  Timer? _persistTimer;

  /// Store one icon without notifying: the widget that fetched it repaints
  /// itself, so the rest of the tree does not need to rebuild.
  void put(String slotKey, Uint8List bytes) {
    if (bytes.isEmpty) return;
    final existing = _bytes[slotKey];
    // A refresh that produced the same picture must not dirty the file.
    if (existing != null && listEquals(existing, bytes)) return;
    _bytes[slotKey] = bytes;
    _schedulePersist();
  }

  /// Repaint every visible icon after a batch of [put] calls (a background
  /// refresh of several apps, where no single widget fetched the icon itself).
  void notifyUpdated() => notifyListeners();

  /// Icon loading is bursty (a list paints dozens of rows at once). Writing the
  /// whole base64 map after each one stalled the UI thread, so saves are
  /// coalesced into a single write once the burst goes quiet.
  void _schedulePersist() {
    if (onDirty == null) return;
    _dirty = true;
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 1000), _flushNow);
  }

  /// Writes pending changes now. Called when the app goes to the background
  /// and by tests, so a save is never lost to the timer.
  Future<void> flush() async {
    _persistTimer?.cancel();
    _persistTimer = null;
    await _flushNow();
  }

  Future<void> _flushNow() async {
    if (_flushing) return;
    _flushing = true;
    try {
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
    } finally {
      _flushing = false;
    }
  }

  /// Replace the whole cache and notify listeners. Used after a refresh, an
  /// import, or a full clear, where every visible icon should repaint.
  ///
  /// Cancels a pending batch save: the caller is replacing the contents, and a
  /// late write of the old map would be pointless.
  void replaceAll(Map<String, Uint8List> next) {
    _persistTimer?.cancel();
    _persistTimer = null;
    _dirty = false;
    _bytes
      ..clear()
      ..addAll(next);
    notifyListeners();
  }

  /// Drop the contents without notifying (callers notify via [replaceAll] once
  /// the replacement is ready, so icons never flash a placeholder in between).
  void clearSilent() {
    _persistTimer?.cancel();
    _persistTimer = null;
    _dirty = false;
    _bytes.clear();
  }

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
