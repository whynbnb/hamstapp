import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hamstapp/services/icon_cache.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('an icon is fetched once and then served from the cache', (
    tester,
  ) async {
    IconCache.instance.replaceAll(<String, Uint8List>{});
    addTearDown(() => IconCache.instance.replaceAll(<String, Uint8List>{}));

    const channel = MethodChannel('hamstapp/apps');
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getAppIcon') {
        calls++;
        return _png;
      }
      return null;
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    Widget app() => const MaterialApp(
      home: Scaffold(
        body: Center(child: AppIcon(packageName: 'com.a', label: 'A')),
      ),
    );

    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(calls, 1);
    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(IconCache.instance.containsKey('com.a'), isTrue);

    // A second, freshly built icon for the same package uses the cache.
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('an icon provided as bytes is never fetched', (tester) async {
    IconCache.instance.replaceAll(<String, Uint8List>{});

    const channel = MethodChannel('hamstapp/apps');
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getAppIcon') calls++;
      return null;
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: AppIcon(packageName: 'com.a', label: 'A', bytes: _png),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(calls, 0);
    expect(find.byType(Image), findsOneWidget);
  });
}
