import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:hamstapp/models/app_info.dart';
import 'package:hamstapp/models/tile.dart';
import 'package:hamstapp/models/tile_page.dart';
import 'package:hamstapp/screens/quick_launch_screen.dart';
import 'package:hamstapp/services/notification_badges.dart';
import 'package:hamstapp/services/storage.dart';
import 'package:hamstapp/state/app_state.dart';
import 'package:hamstapp/widgets/app_icon.dart';

/// A valid 1x1 transparent PNG, so `Image.memory` can actually decode it.
final Uint8List _png = Uint8List.fromList(const <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

class _MemStorage implements Storage {
  final Map<String, dynamic> _data = <String, dynamic>{};
  @override
  Future<dynamic> readJson(String name) async => _data[name];
  @override
  Future<void> writeJson(String name, dynamic data) async {
    _data[name] = data;
  }
}

/// Restores the shared singleton between tests.
void _resetBadges() {
  final badges = NotificationBadges.instance
    ..setCapture(false)
    ..clear();
  for (final surface in NotificationBadgeSurface.values) {
    badges.setMode(NotificationBadgeMode.count, surface);
  }
}

AppInfo _ai(String pkg, String name) => AppInfo(
  packageName: pkg,
  appName: name,
  versionName: '1',
  versionCode: 1,
  firstInstallTime: 0,
  lastUpdateTime: 0,
  isSystem: false,
  enabled: true,
  apkPath: '',
  sizeBytes: 0,
  targetSdk: 33,
  minSdk: 21,
  uid: 0,
);

Widget _icon({
  double size = 48,
  String pkg = 'com.a',
  bool showBadge = true,
}) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: AppIcon(
        packageName: pkg,
        label: 'A',
        size: size,
        bytes: _png,
        showNotificationBadge: showBadge,
      ),
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NotificationBadges', () {
    test('labelFor caps at 99+', () {
      expect(NotificationBadges.labelFor(1), '1');
      expect(NotificationBadges.labelFor(99), '99');
      expect(NotificationBadges.labelFor(100), '99+');
      expect(NotificationBadges.labelFor(4200), '99+');
    });

    test('counts are suppressed while capture is off', () {
      addTearDown(_resetBadges);
      final b = NotificationBadges.instance;
      b.setCounts({'com.a': 3});
      expect(b.countFor('com.a'), 0, reason: 'off by default');
      expect(b.hasBadge('com.a'), isFalse);
      b.setCapture(true);
      expect(b.countFor('com.a'), 3);
      expect(b.hasBadge('com.a'), isTrue);
      expect(b.countFor('com.b'), 0);
      b.setCapture(false);
      expect(b.countFor('com.a'), 0);
      expect(b.counts['com.a'], 3, reason: 'raw counts are kept when hidden');
    });

    test('modes are tracked per surface', () {
      addTearDown(_resetBadges);
      final b = NotificationBadges.instance
        ..setCapture(true)
        ..setCounts({'com.a': 2});

      b.setMode(NotificationBadgeMode.dot, NotificationBadgeSurface.tile);
      expect(b.modeFor(NotificationBadgeSurface.tile), NotificationBadgeMode.dot);
      expect(
        b.modeFor(NotificationBadgeSurface.list),
        NotificationBadgeMode.count,
      );

      b.setMode(NotificationBadgeMode.none, NotificationBadgeSurface.list);
      expect(
        b.countFor('com.a', surface: NotificationBadgeSurface.list),
        0,
      );
      expect(
        b.countFor('com.a', surface: NotificationBadgeSurface.tile),
        2,
        reason: 'tile still shows',
      );
      expect(
        b.countFor('com.a', surface: NotificationBadgeSurface.page),
        2,
        reason: 'page bar defaults to the same',
      );
    });

    test('exposes aggregate counts', () {
      addTearDown(_resetBadges);
      final b = NotificationBadges.instance
        ..setCapture(true)
        ..setCounts({'com.a': 2, 'com.b': 3});
      expect(b.appCount, 2);
      expect(b.total, 5);
    });

    test('notifies only on real changes', () {
      addTearDown(_resetBadges);
      final b = NotificationBadges.instance;
      var notifications = 0;
      void listener() => notifications++;
      b.addListener(listener);
      addTearDown(() => b.removeListener(listener));

      b.setCounts({'com.a': 1});
      b.setCounts({'com.a': 1});
      expect(notifications, 1);

      b.setMode(NotificationBadgeMode.dot, NotificationBadgeSurface.list);
      b.setMode(NotificationBadgeMode.dot, NotificationBadgeSurface.list);
      expect(notifications, 2);
    });
  });

  group('AppIcon badge', () {
    testWidgets('hidden while capture is off, shown once enabled', (
      tester,
    ) async {
      _resetBadges();
      addTearDown(_resetBadges);
      NotificationBadges.instance.setCounts({'com.a': 5});

      await tester.pumpWidget(_icon());
      await tester.pumpAndSettle();
      expect(find.byType(IconNotificationBadge), findsNothing);

      NotificationBadges.instance.setCapture(true);
      await tester.pump();
      expect(find.byType(IconNotificationBadge), findsOneWidget);
      expect(find.text('5'), findsOneWidget);
    });

    testWidgets('shows 99+ for large counts', (tester) async {
      _resetBadges();
      addTearDown(_resetBadges);
      NotificationBadges.instance
        ..setCapture(true)
        ..setCounts({'com.a': 128});

      await tester.pumpWidget(_icon());
      await tester.pumpAndSettle();
      expect(find.text('99+'), findsOneWidget);
    });

    testWidgets('dot mode draws no number', (tester) async {
      _resetBadges();
      addTearDown(_resetBadges);
      NotificationBadges.instance
        ..setCapture(true)
        ..setMode(NotificationBadgeMode.dot, NotificationBadgeSurface.list)
        ..setCounts({'com.a': 7});

      await tester.pumpWidget(_icon());
      await tester.pumpAndSettle();
      expect(find.byType(IconNotificationBadge), findsOneWidget);
      expect(find.text('7'), findsNothing);
    });

    testWidgets('a hidden surface suppresses only that surface', (
      tester,
    ) async {
      _resetBadges();
      addTearDown(_resetBadges);
      NotificationBadges.instance
        ..setCapture(true)
        ..setMode(NotificationBadgeMode.none, NotificationBadgeSurface.list)
        ..setCounts({'com.a': 4});

      await tester.pumpWidget(_icon());
      await tester.pumpAndSettle();
      expect(find.byType(IconNotificationBadge), findsNothing);
    });

    testWidgets('showNotificationBadge: false draws nothing', (tester) async {
      _resetBadges();
      addTearDown(_resetBadges);
      NotificationBadges.instance
        ..setCapture(true)
        ..setCounts({'com.a': 4});

      await tester.pumpWidget(_icon(showBadge: false));
      await tester.pumpAndSettle();
      expect(find.byType(IconNotificationBadge), findsNothing);
    });

    testWidgets('the bubble sits on the tile corner, not on the icon', (
      tester,
    ) async {
      _resetBadges();
      addTearDown(_resetBadges);
      // Let the tile icon resolve so pumpAndSettle is not blocked by a spinner.
      const channel = MethodChannel('hamstapp/apps');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getAppIcon') return _png;
        return null;
      });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      final state = AppState(_MemStorage())
        ..initialized = true
        ..apps = [_ai('com.a', 'A')]
        ..tilePages = [TilePage(id: 'p1', name: 'P1', createdAt: 0)]
        ..tiles = [
          Tile(
            id: 't1',
            packageName: 'com.a',
            pageId: 'p1',
            col: 0,
            row: 0,
            w: 2,
            h: 2,
          ),
        ]
        ..currentTilePageIndex = 0;
      NotificationBadges.instance
        ..setCapture(true)
        ..setMode(NotificationBadgeMode.count, NotificationBadgeSurface.tile)
        ..setMode(NotificationBadgeMode.none, NotificationBadgeSurface.page)
        ..setMode(NotificationBadgeMode.none, NotificationBadgeSurface.list)
        ..setCounts({'com.a': 3});

      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: const MaterialApp(home: QuickLaunchScreen()),
        ),
      );
      await tester.pumpAndSettle();

      final tile = find.byKey(const ValueKey('t1'));
      final badge = find.byType(IconNotificationBadge);
      expect(badge, findsOneWidget);
      expect(find.text('3'), findsOneWidget);

      final tileRect = tester.getRect(tile);
      final badgeRect = tester.getRect(badge);
      final iconRect = tester.getRect(
        find.descendant(of: tile, matching: find.byType(AppIcon)),
      );

      // The bubble hugs the tile's top-right corner, so it lies to the right of
      // the centred icon (the bug put it on the icon instead).
      expect(badgeRect.right, greaterThan(iconRect.right));
      expect((tileRect.right - badgeRect.right).abs(), lessThan(8));
      expect((badgeRect.top - tileRect.top).abs(), lessThan(8));
    });

    testWidgets('the page chip shows the page total on the page surface', (
      tester,
    ) async {
      _resetBadges();
      addTearDown(_resetBadges);
      const channel = MethodChannel('hamstapp/apps');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getAppIcon') return _png;
        return null;
      });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      final state = AppState(_MemStorage())
        ..initialized = true
        ..apps = [_ai('com.a', 'A')]
        ..tilePages = [TilePage(id: 'p1', name: 'P1', createdAt: 0)]
        ..tiles = [
          Tile(
            id: 't1',
            packageName: 'com.a',
            pageId: 'p1',
            col: 0,
            row: 0,
            w: 2,
            h: 2,
          ),
        ]
        ..currentTilePageIndex = 0;
      // Only the page surface is on, so the single '3' can only be its badge.
      NotificationBadges.instance
        ..setCapture(true)
        ..setMode(NotificationBadgeMode.none, NotificationBadgeSurface.tile)
        ..setMode(NotificationBadgeMode.none, NotificationBadgeSurface.list)
        ..setMode(NotificationBadgeMode.count, NotificationBadgeSurface.page)
        ..setCounts({'com.a': 3});

      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: const MaterialApp(home: QuickLaunchScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(IconNotificationBadge), findsNothing);
      expect(find.text('3'), findsOneWidget);

      // Turning the page surface off removes it again.
      NotificationBadges.instance.setMode(
        NotificationBadgeMode.none,
        NotificationBadgeSurface.page,
      );
      await tester.pump();
      expect(find.text('3'), findsNothing);
    });

    testWidgets('no badge for a package without notifications', (tester) async {
      _resetBadges();
      addTearDown(_resetBadges);
      NotificationBadges.instance
        ..setCapture(true)
        ..setCounts({'com.other': 9});

      await tester.pumpWidget(_icon());
      await tester.pumpAndSettle();
      expect(find.byType(IconNotificationBadge), findsNothing);
    });

    testWidgets('no badge on icons too small to read', (tester) async {
      _resetBadges();
      addTearDown(_resetBadges);
      NotificationBadges.instance
        ..setCapture(true)
        ..setCounts({'com.a': 4});

      await tester.pumpWidget(_icon(size: 16));
      await tester.pumpAndSettle();
      expect(find.byType(IconNotificationBadge), findsNothing);
    });
  });

  group('AppState wiring', () {
    test('settings round-trip and drive the shared state', () async {
      _resetBadges();
      addTearDown(_resetBadges);
      final state = AppState(_MemStorage());

      expect(state.notificationCapture, isFalse);
      expect(state.tileBadgeMode, NotificationBadgeMode.count);
      expect(state.pageBadgeMode, NotificationBadgeMode.count);
      expect(state.otherBadgeMode, NotificationBadgeMode.count);

      await state.setNotificationCapture(true);
      expect(state.notificationCapture, isTrue);
      expect(NotificationBadges.instance.capture, isTrue);

      await state.setTileBadgeMode(NotificationBadgeMode.dot);
      expect(state.tileBadgeMode, NotificationBadgeMode.dot);
      expect(
        NotificationBadges.instance.tileMode,
        NotificationBadgeMode.dot,
        reason: 'the change reaches the leaf widgets',
      );

      await state.setOtherBadgeMode(NotificationBadgeMode.none);
      expect(
        NotificationBadges.instance.listMode,
        NotificationBadgeMode.none,
      );

      await state.setPageBadgeMode(NotificationBadgeMode.dot);
      expect(state.pageBadgeMode, NotificationBadgeMode.dot);
      expect(NotificationBadges.instance.pageMode, NotificationBadgeMode.dot);

      await state.setNotificationCapture(false);
      expect(NotificationBadges.instance.capture, isFalse);
    });

    test('legacy settings migrate to the split ones', () async {
      _resetBadges();
      addTearDown(_resetBadges);
      final storage = _MemStorage();
      await storage.writeJson('settings', {
        'notification_badges': true,
        'notification_badge_style': 'dot',
      });

      final state = AppState(storage);
      await state.init();

      expect(state.notificationCapture, isTrue);
      expect(state.tileBadgeMode, NotificationBadgeMode.dot);
      expect(state.otherBadgeMode, NotificationBadgeMode.dot);
    });

    test('refreshNotificationCounts pulls the native map', () async {
      _resetBadges();
      addTearDown(_resetBadges);
      const channel = MethodChannel('hamstapp/apps');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getNotificationCounts') {
          return <String, int>{'com.a': 2};
        }
        return null;
      });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      final state = AppState(_MemStorage());
      await state.setNotificationCapture(true);
      NotificationBadges.instance.clear();

      await state.refreshNotificationCounts();
      expect(NotificationBadges.instance.countFor('com.a'), 2);

      // Turning capture off clears everything again.
      await state.setNotificationCapture(false);
      expect(NotificationBadges.instance.countFor('com.a'), 0);
    });
  });
}
