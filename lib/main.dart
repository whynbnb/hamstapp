import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'l10n/app_strings.dart';
import 'screens/home_screen.dart';
import 'services/storage.dart';
import 'state/app_state.dart';
import 'utils/system_ui.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final storage = await Storage.instance();
  final state = AppState(storage);
  await state.init();
  await applyStatusBarVisibility(state.showSystemStatusBar);
  runApp(HamstappApp(state: state));
}

class HamstappApp extends StatelessWidget {
  const HamstappApp({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const _AppRoot(),
    );
  }
}

class _AppRoot extends StatelessWidget {
  const _AppRoot();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return MaterialApp(
      onGenerateTitle: (context) => context.strings.appTitle,
      debugShowCheckedModeBanner: false,
      locale: state.locale,
      supportedLocales: const [Locale('zh'), Locale('en')],
      localizationsDelegates: const [
        AppStrings.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      themeMode: _themeMode(state.themeMode),
      theme: _buildTheme(
        Brightness.light,
        Color(state.themeColor),
        compact: state.compactDensity,
      ),
      darkTheme: _buildTheme(
        Brightness.dark,
        Color(state.themeColor),
        compact: state.compactDensity,
      ),
      // One text scale for the whole app. The device's own scale is kept as a
      // factor, so an accessibility setting is not overridden — it is added to.
      builder: (context, child) {
        if (child == null) return const SizedBox.shrink();
        final media = MediaQuery.of(context);
        final system = media.textScaler.scale(14) / 14;
        return MediaQuery(
          data: media.copyWith(
            textScaler: TextScaler.linear(system * state.fontScale),
          ),
          child: child,
        );
      },
      home: const HomeScreen(),
    );
  }

  ThemeMode _themeMode(AppThemeMode mode) {
    switch (mode) {
      case AppThemeMode.system:
        return ThemeMode.system;
      case AppThemeMode.light:
        return ThemeMode.light;
      case AppThemeMode.dark:
        return ThemeMode.dark;
    }
  }
}

ThemeData _buildTheme(
  Brightness brightness,
  Color seed, {
  bool compact = false,
}) {
  final scheme = ColorScheme.fromSeed(
    seedColor: seed,
    brightness: brightness,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    visualDensity: compact ? VisualDensity.compact : VisualDensity.standard,
    scaffoldBackgroundColor: brightness == Brightness.light
        ? const Color(0xFFF7F6F3)
        : null,
    appBarTheme: AppBarTheme(
      centerTitle: false,
      backgroundColor: brightness == Brightness.light
          ? const Color(0xFFF7F6F3)
          : scheme.surface,
      surfaceTintColor: Colors.transparent,
    ),
    listTileTheme: const ListTileThemeData(
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 2),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: brightness == Brightness.light
          ? Colors.white
          : scheme.surface,
      elevation: 1,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    ),
  );
}
