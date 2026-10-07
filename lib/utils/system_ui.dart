import 'package:flutter/services.dart';

import '../services/native_apps.dart';

/// Show or hide the system status bar.
///
/// Hiding is handled natively (via the window insets controller) instead of
/// [SystemChrome.setEnabledSystemUIMode]: Android clears the old fullscreen
/// flags when the notification shade is pulled down, which left the bar stuck
/// on screen until the app was reopened. The native side now uses the
/// "transient bars by swipe" behavior and re-applies the hidden state whenever
/// the window regains focus, so the bar only appears briefly while swiping.
/// The bottom navigation bar is always kept visible.
Future<void> applyStatusBarVisibility(bool show) async {
  try {
    await NativeApps.setStatusBarHidden(!show);
  } catch (_) {
    // Best-effort UI tweak; ignore when no platform channel is available.
  }
  try {
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Color(0x00000000),
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
      ),
    );
  } catch (_) {
    // Ignore styling failures on platforms without a status bar.
  }
}
