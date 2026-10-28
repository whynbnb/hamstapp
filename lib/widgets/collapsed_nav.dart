import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';

/// Exposes the "collapsed navigation" mode to the top-level screens.
///
/// When [active] is true, each screen shows a fixed menu button as its AppBar
/// leading. Tapping it calls [onOpen], which is handled by [HomeScreen] to
/// reveal the navigation panel; long-pressing it calls [onLongPress], whose
/// action is configurable (Launch, Apps, Settings, …) and may be absent. The
/// button lives in the AppBar so the collapsed state never covers page content
/// (unlike a floating button).
class CollapsedNavScope extends InheritedWidget {
  const CollapsedNavScope({
    super.key,
    required this.active,
    required this.onOpen,
    required this.onLongPress,
    required super.child,
  });

  final bool active;
  final VoidCallback onOpen;

  /// Null when the configured long-press action is 无.
  final VoidCallback? onLongPress;

  static CollapsedNavScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CollapsedNavScope>();

  static bool activeOf(BuildContext context) =>
      maybeOf(context)?.active ?? false;

  @override
  bool updateShouldNotify(CollapsedNavScope oldWidget) =>
      active != oldWidget.active ||
      onOpen != oldWidget.onOpen ||
      onLongPress != oldWidget.onLongPress;
}

/// Fixed top-left navigation button shown while [CollapsedNavScope.active].
///
/// Tap to open the navigation panel; a long press runs the action chosen in
/// Settings (or does nothing when that action is 无).
class CollapsedNavButton extends StatelessWidget {
  const CollapsedNavButton({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = CollapsedNavScope.maybeOf(context);
    if (scope == null || !scope.active) return const SizedBox.shrink();
    return IconButton(
      icon: const Icon(Icons.menu),
      tooltip: context.strings.t('导航'),
      onPressed: scope.onOpen,
      onLongPress: scope.onLongPress,
    );
  }
}
