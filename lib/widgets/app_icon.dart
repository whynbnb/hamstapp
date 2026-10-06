import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/icon_cache.dart';
import '../services/native_apps.dart';

/// Shows an app icon, preferring the app's persistent [IconCache] so a
/// previously seen icon paints immediately instead of flashing a loading
/// spinner. A cache miss is fetched from the native side once and remembered.
class AppIcon extends StatefulWidget {
  const AppIcon({
    super.key,
    required this.packageName,
    required this.label,
    this.size = 44,
    this.bytes,
  });

  final String packageName;
  final String label;
  final double size;

  /// Pre-decoded icon bytes (e.g. read from a downloaded APK). When set the
  /// icon is not fetched from the native side.
  final Uint8List? bytes;

  @override
  State<AppIcon> createState() => _AppIconState();
}

class _AppIconState extends State<AppIcon> {
  Uint8List? _bytes;
  bool _loading = false;

  /// Whether a native fetch has already been kicked off for this package, so a
  /// rebuild does not queue a second one.
  bool _requested = false;

  @override
  void initState() {
    super.initState();
    _loading = widget.bytes == null;
    // Repaint when the shared cache is replaced (e.g. the settings "refresh
    // icon cache" action or a data import).
    IconCache.instance.addListener(_onCacheChanged);
    _resolve();
  }

  @override
  void didUpdateWidget(covariant AppIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.packageName != widget.packageName ||
        oldWidget.bytes != widget.bytes) {
      _bytes = widget.bytes;
      _loading = widget.bytes == null;
      _requested = false;
      _resolve();
    }
  }

  @override
  void dispose() {
    IconCache.instance.removeListener(_onCacheChanged);
    super.dispose();
  }

  void _onCacheChanged() {
    if (!mounted) return;
    setState(_resolve);
  }

  /// Decide what to paint for the current package. Called outside build, so it
  /// assigns fields directly.
  void _resolve() {
    if (widget.bytes != null) {
      _bytes = widget.bytes;
      _loading = false;
      _requested = false;
      return;
    }
    final cached = IconCache.instance[widget.packageName];
    if (cached != null) {
      _bytes = cached;
      _loading = false;
      return;
    }
    // Not cached: fetch once and remember it.
    if (_requested) return;
    _requested = true;
    _loading = true;
    _fetch();
  }

  Future<void> _fetch() async {
    Uint8List? bytes;
    try {
      bytes = await NativeApps.getAppIcon(
        widget.packageName,
        size: IconCache.fetchSize,
      );
    } catch (_) {
      bytes = null;
    }
    if (!mounted) return;
    if (bytes != null && bytes.isNotEmpty) {
      IconCache.instance.put(widget.packageName, bytes);
    }
    setState(() {
      _bytes = bytes;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes ?? widget.bytes;
    final radius = BorderRadius.circular(widget.size * 0.26);
    if (bytes != null) {
      return ClipRRect(
        borderRadius: radius,
        child: Image.memory(
          bytes,
          width: widget.size,
          height: widget.size,
          gaplessPlayback: true,
          filterQuality: FilterQuality.low,
        ),
      );
    }
    return Container(
      width: widget.size,
      height: widget.size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: radius,
        color: _colorFor(widget.label),
      ),
      child: _loading
          ? SizedBox(
              width: widget.size * 0.4,
              height: widget.size * 0.4,
              child: const CircularProgressIndicator(strokeWidth: 2),
            )
          : Text(
              widget.label.isEmpty ? '?' : widget.label.characters.first,
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: widget.size * 0.45,
              ),
            ),
    );
  }

  Color _colorFor(String label) {
    final hash = label.codeUnits.fold<int>(0, (p, c) => p * 31 + c);
    final hue = (hash % 360).abs().toDouble();
    return HSLColor.fromAHSL(1, hue, 0.55, 0.55).toColor();
  }
}
