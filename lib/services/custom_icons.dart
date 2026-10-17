import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// User-chosen app icons, kept in memory and persisted by [AppState] as part of
/// the local data (base64 in the `custom_icons` JSON store, so tests and the
/// export package work without touching the filesystem).
///
/// A custom icon is optional per app: when there is none, [AppIcon] falls back
/// to the launcher icon.
class CustomIcons extends ChangeNotifier {
  CustomIcons._();

  static final CustomIcons instance = CustomIcons._();

  final Map<String, Uint8List> _icons = <String, Uint8List>{};

  Uint8List? bytesFor(String packageName) => _icons[packageName];

  bool has(String packageName) => _icons.containsKey(packageName);

  Map<String, Uint8List> get all => Map<String, Uint8List>.unmodifiable(_icons);

  int get count => _icons.length;

  /// Replaces the whole set (startup, import).
  void replaceAll(Map<String, Uint8List> icons) {
    _icons
      ..clear()
      ..addAll(icons);
    notifyListeners();
  }

  void put(String packageName, Uint8List bytes) {
    _icons[packageName] = bytes;
    notifyListeners();
  }

  void remove(String packageName) {
    if (_icons.remove(packageName) == null) return;
    notifyListeners();
  }

  /// Base64 form for the data store and data packages.
  Map<String, String> toBase64() => {
        for (final e in _icons.entries) e.key: base64Encode(e.value),
      };

  /// Reads a base64 map, skipping entries that do not decode.
  static Map<String, Uint8List> fromBase64(Object? raw) {
    if (raw is! Map) return <String, Uint8List>{};
    final out = <String, Uint8List>{};
    for (final e in raw.entries) {
      try {
        final bytes = base64Decode('${e.value}');
        if (bytes.isNotEmpty) out['${e.key}'] = bytes;
      } catch (_) {
        // A corrupt entry is ignored instead of failing the whole load.
      }
    }
    return out;
  }

  /// An icon isn't square or is huge: shrink it, so a 4 MB photo does not
  /// become a permanently slow tile.
  static Future<Uint8List?> shrink(Uint8List bytes, {int size = 192}) async {
    try {
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: size,
        targetHeight: size,
      );
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      frame.image.dispose();
      codec.dispose();
      return data?.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }
}
