import 'package:flutter/widgets.dart';

import '../models/app_info.dart';

/// Keeps the order of an app list or grid stable for as long as it is on
/// screen.
///
/// Launching an app rewrites the usage data behind lists such as 最近使用, which
/// would otherwise move the remaining icons right after the user tapped one —
/// reading as a mis-tap. This widget adopts the order it first saw, drops apps
/// that disappeared and appends new ones at the end (never in the middle), so
/// the positions already on screen stay put. A re-entry into the screen
/// disposes this State and therefore refreshes the order.
///
/// Pass a new [Key] when the *source* changes (sort, time range, tile option),
/// so the order starts over for the new list.
class StableAppOrder extends StatefulWidget {
  const StableAppOrder({
    super.key,
    required this.apps,
    required this.builder,
    this.limit,
  });

  /// The freshly sorted list; only its order is overridden.
  final List<AppInfo> apps;

  final Widget Function(BuildContext context, List<AppInfo> apps) builder;

  /// Caps the list *after* it has been put back in the stable order, so a new
  /// launch cannot push an icon out of a small grid.
  final int? limit;

  @override
  State<StableAppOrder> createState() => _StableAppOrderState();
}

class _StableAppOrderState extends State<StableAppOrder> {
  List<String>? _order;

  @override
  Widget build(BuildContext context) {
    var apps = _inOrder(widget.apps);
    final limit = widget.limit;
    if (limit != null && apps.length > limit) {
      apps = apps.sublist(0, limit);
    }
    return widget.builder(context, apps);
  }

  List<AppInfo> _inOrder(List<AppInfo> fresh) {
    final order = _order;
    if (order == null) {
      _order = [for (final a in fresh) a.packageName];
      return fresh;
    }
    final byPackage = {for (final a in fresh) a.packageName: a};
    final out = <AppInfo>[];
    for (final packageName in order) {
      final app = byPackage.remove(packageName);
      if (app != null) out.add(app);
    }
    // New apps join at the end instead of shifting the ones already shown.
    out.addAll(byPackage.values);
    _order = [for (final a in out) a.packageName];
    return out;
  }
}
