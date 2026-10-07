import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_strings.dart';
import '../state/app_state.dart';
import '../widgets/collapsed_nav.dart';
import '../widgets/uninstall_reason.dart';
import 'apps_screen.dart';
import 'quick_launch_screen.dart';
import 'settings_screen.dart';
import 'snapshots_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  /// Index of the Settings tab within [destinations] below.
  static const int _settingsTab = 3;

  late int _index;

  /// Last tab that was not Settings, so leaving Settings can return to it.
  int _lastContentIndex = 0;

  bool _uninstallSheetVisible = false;
  bool _navOpen = false;

  @override
  void initState() {
    super.initState();
    _index = context.read<AppState>().lastHomeIndex.clamp(0, 3);
    if (_index != _settingsTab) _lastContentIndex = _index;
  }

  void _select(AppState state, int i, {bool forceHaptic = false}) {
    if (state.tileEditMode) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(context.strings.t('请先点击右上角「完成」结束磁贴编辑'))),
        );
      return;
    }
    if (i != _settingsTab) _lastContentIndex = i;
    if (i != _index || forceHaptic) state.haptic(HapticTrigger.mainTabs);
    state.setLastHomeIndex(i);
    setState(() => _index = i);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final s = context.strings;

    final destinations = [
      _NavItem(Icons.rocket_launch_outlined, Icons.rocket_launch, s.t('启动')),
      _NavItem(Icons.apps_outlined, Icons.apps, s.t('应用')),
      _NavItem(Icons.compare_arrows_outlined, Icons.compare_arrows, s.t('快照')),
      _NavItem(Icons.settings_outlined, Icons.settings, s.t('设置')),
    ];

    // First launch: nothing scanned yet -> kick off a scan automatically.
    if (state.initialized && state.apps.isEmpty && !state.scanning) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && state.apps.isEmpty && !state.scanning) state.scan();
      });
    }

    // After a scan detects uninstalls (current vs last snapshot) ask for reasons.
    if (state.pendingUninstalls.isNotEmpty && !_uninstallSheetVisible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || state.pendingUninstalls.isEmpty) return;
        _uninstallSheetVisible = true;
        showModalBottomSheet(
          context: context,
          isScrollControlled: true,
          builder: (_) => UninstallReasonSheet(state: state),
        ).whenComplete(() => _uninstallSheetVisible = false);
      });
    }

    const screens = [
      QuickLaunchScreen(),
      AppsScreen(),
      SnapshotsScreen(),
      SettingsScreen(),
    ];

    final mq = MediaQuery.of(context);
    final mode = state.resolvedNavMode(mq.size.width, mq.size.height);
    final collapsed = mode == NavMode.collapsed;

    // The scope lets every top-level screen render the fixed top-left button
    // without knowing about the home layout. Tapping it opens the panel;
    // long-pressing it jumps back to the Launch tab with a haptic tick.
    final body = CollapsedNavScope(
      active: collapsed,
      onOpen: () => setState(() => _navOpen = !_navOpen),
      onLongPress: () {
        setState(() => _navOpen = false);
        _select(state, 0, forceHaptic: true);
      },
      child: IndexedStack(index: _index, children: screens),
    );

    final Widget scaffold = switch (mode) {
      NavMode.rail => Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: _index,
              onDestinationSelected: (i) => _select(state, i),
              labelType: NavigationRailLabelType.all,
              destinations: [
                for (final d in destinations)
                  NavigationRailDestination(
                    icon: Icon(d.icon),
                    selectedIcon: Icon(d.selectedIcon),
                    label: Text(d.label),
                  ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: body),
          ],
        ),
      ),
      NavMode.collapsed => Scaffold(
        body: Stack(
          children: [
            Positioned.fill(child: body),
            if (_navOpen)
              _CollapsedNavOverlay(
                index: _index,
                destinations: destinations,
                onDismiss: () => setState(() => _navOpen = false),
                onSelect: (i) {
                  setState(() => _navOpen = false);
                  _select(state, i);
                },
              ),
          ],
        ),
      ),
      NavMode.auto || NavMode.bottom => Scaffold(
        body: body,
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (i) => _select(state, i),
          destinations: [
            for (final d in destinations)
              NavigationDestination(
                icon: Icon(d.icon),
                selectedIcon: Icon(d.selectedIcon),
                label: d.label,
              ),
          ],
        ),
      ),
    };

    // System back on the Settings tab returns to the tab it was opened from
    // instead of leaving the app; every other tab keeps the default behaviour.
    return PopScope(
      canPop: _index != _settingsTab,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _index != _settingsTab) return;
        _select(state, _lastContentIndex);
      },
      child: scaffold,
    );
  }
}

/// A single top-level destination, shared by all navigation presentations.
class _NavItem {
  const _NavItem(this.icon, this.selectedIcon, this.label);

  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

/// Panel revealed from the top-left button in collapsed mode. Anchored below
/// the AppBar so it never hides the header, and dismisses on any outside tap.
class _CollapsedNavOverlay extends StatelessWidget {
  const _CollapsedNavOverlay({
    required this.index,
    required this.destinations,
    required this.onSelect,
    required this.onDismiss,
  });

  final int index;
  final List<_NavItem> destinations;
  final ValueChanged<int> onSelect;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final top = MediaQuery.of(context).padding.top + kToolbarHeight + 8;

    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: onDismiss,
        child: Stack(
          children: [
            Positioned(
              left: 12,
              top: top,
              child: Material(
                color: scheme.surfaceContainerHigh,
                elevation: 8,
                borderRadius: BorderRadius.circular(18),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < destinations.length; i++)
                      _item(context, i, scheme),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _item(BuildContext context, int i, ColorScheme scheme) {
    final selected = i == index;
    final d = destinations[i];
    return InkWell(
      onTap: () => onSelect(i),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              selected ? d.selectedIcon : d.icon,
              size: 20,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Text(
              d.label,
              style: TextStyle(
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? scheme.primary : scheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
