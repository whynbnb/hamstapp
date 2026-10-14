import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:hamstapp/models/web_app.dart';
import 'package:hamstapp/services/pwa.dart';
import 'package:hamstapp/services/storage.dart';
import 'package:hamstapp/state/app_state.dart';
import 'package:hamstapp/utils/actions.dart';

class _MemStorage implements Storage {
  final Map<String, dynamic> _data = <String, dynamic>{};
  @override
  Future<dynamic> readJson(String name) async => _data[name];
  @override
  Future<void> writeJson(String name, dynamic data) async {
    _data[name] = data;
  }
}

/// A square PNG of [size] pixels, built in-process: icons in tests should not
/// depend on a base64 blob being right.
Future<Uint8List> _pngBytes(int size) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
    Paint()..color = const Color(0xff336699),
  );
  final image = await recorder.endRecording().toImage(size, size);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

/// A manifest as a site would serve it.
Map<String, dynamic> _manifestJson({
  String name = 'Photos',
  String startUrl = '/app',
  String display = 'standalone',
  String scope = '/app/',
  List<Map<String, dynamic>>? icons,
}) => <String, dynamic>{
  'name': name,
  'short_name': 'Photos',
  'description': 'A photo library',
  'start_url': startUrl,
  'scope': scope,
  'display': display,
  'theme_color': '#123456',
  'background_color': '#ffffff',
  'orientation': 'portrait',
  'icons':
      icons ??
      [
        {'src': 'icon-192.png', 'sizes': '192x192', 'type': 'image/png'},
        {'src': 'icon-512.png', 'sizes': '512x512', 'type': 'image/png'},
      ],
};

const String _manifestUrl = 'https://photos.example/manifest.json';

void main() {
  group('Web App Manifest', () {
    test('reads the members the standard requires, resolving URLs', () {
      final manifest = PwaManifest.parse(_manifestJson(), _manifestUrl);

      expect(manifest.name, 'Photos');
      expect(manifest.shortName, 'Photos');
      expect(manifest.description, 'A photo library');
      // start_url, scope and icon srcs resolve against the manifest, not the page.
      expect(manifest.startUrl, 'https://photos.example/app');
      expect(manifest.scope, 'https://photos.example/app/');
      expect(manifest.icons.first.url, 'https://photos.example/icon-192.png');
      expect(manifest.display, 'standalone');
      expect(manifest.themeColor, 0xff123456);
      expect(manifest.backgroundColor, 0xffffffff);
      expect(manifest.orientation, 'portrait');
      expect(manifest.isInstallable, isTrue);
    });

    test('display_override wins, unknown modes fall back to browser', () {
      final overridden = PwaManifest.parse(
        _manifestJson()..['display_override'] = ['minimal-ui', 'standalone'],
        _manifestUrl,
      );
      expect(overridden.display, 'minimal-ui');

      // An unsupported override entry is skipped, not honoured blindly.
      final skipped = PwaManifest.parse(
        _manifestJson()..['display_override'] = ['window-controls-overlay'],
        _manifestUrl,
      );
      expect(skipped.display, 'standalone');

      final missing = PwaManifest.parse(
        _manifestJson(display: 'nonsense'),
        _manifestUrl,
      );
      expect(missing.display, 'browser');
    });

    test('picks the icon a launcher would', () {
      final manifest = PwaManifest.parse(
        _manifestJson(
          icons: [
            {'src': 'a.svg', 'sizes': 'any', 'type': 'image/svg+xml'},
            {'src': 'small.png', 'sizes': '48x48', 'type': 'image/png'},
            {'src': 'mid.png', 'sizes': '192x192', 'type': 'image/png'},
            {'src': 'big-maskable.png', 'sizes': '512x512', 'purpose': 'maskable'},
            {'src': 'big.png', 'sizes': '512x512', 'type': 'image/png'},
          ],
        ),
        _manifestUrl,
      );
      // 512 beats 192, and a plain icon beats a maskable one of the same size.
      expect(manifest.bestIcon()!.url, 'https://photos.example/big.png');

      // Several sizes in one entry: the biggest square edge counts.
      final multi = PwaManifest.parse(
        _manifestJson(
          icons: [
            {'src': 'multi.png', 'sizes': '96x96 256x256', 'type': 'image/png'},
          ],
        ),
        _manifestUrl,
      );
      expect(multi.bestIcon()!.size, 256);

      // Nothing usable (SVG only) means no icon to show, though the manifest
      // itself is still valid — the standard allows "sizes: any" SVG icons.
      final svgOnly = PwaManifest.parse(
        _manifestJson(
          icons: [
            {'src': 'a.svg', 'sizes': 'any', 'type': 'image/svg+xml'},
          ],
        ),
        _manifestUrl,
      );
      expect(svgOnly.bestIcon(), isNull);
      expect(svgOnly.isInstallable, isTrue);
    });

    test('reads colours in the forms manifests use', () {
      expect(PwaManifest.parseColor('#fff'), 0xffffffff);
      expect(PwaManifest.parseColor('#0a0b0c'), 0xff0a0b0c);
      expect(PwaManifest.parseColor('#0a0b0c80'), 0x800a0b0c);
      expect(PwaManifest.parseColor('rgb(18, 52, 86)'), 0xff123456);
      expect(PwaManifest.parseColor('rgba(18,52,86,0.5)'), 0x80123456);
      expect(PwaManifest.parseColor('white'), 0xffffffff);
      expect(PwaManifest.parseColor('var(--x)'), 0);
      expect(PwaManifest.parseColor(''), 0);
      expect(PwaManifest.parseColor(null), 0);
    });
  });

  group('icon handling', () {
    test('tries the manifest icons first, then the page icon', () {
      final manifest = PwaManifest.parse(
        _manifestJson(
          icons: [
            {'src': 'a.svg', 'sizes': 'any', 'type': 'image/svg+xml'},
            {'src': 'mid.png', 'sizes': '192x192', 'type': 'image/png'},
            {'src': 'big.png', 'sizes': '512x512', 'type': 'image/png'},
          ],
        ),
        _manifestUrl,
      );
      final site = PwaSite(
        url: 'https://photos.example/',
        title: 'Photos',
        secure: true,
        manifest: manifest,
        icon: manifest.bestIcon(),
        pageIcon: const PwaIcon(
          url: 'https://photos.example/touch.png',
          size: 180,
        ),
      );
      // Best manifest icon, then the rest, then the page's own; SVG skipped.
      expect(site.iconCandidates.map((i) => i.url).toList(), [
        'https://photos.example/big.png',
        'https://photos.example/mid.png',
        'https://photos.example/touch.png',
      ]);
    });

    test('normalises an icon into something small and PNG', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final source = await _pngBytes(256);
      final out = await PwaDiscovery.normalizeIcon(source, target: 48);
      expect(out, isNotNull);
      // Re-encoded as PNG (the signature), so nothing downstream has to guess.
      expect(out!.sublist(0, 4), [0x89, 0x50, 0x4e, 0x47]);
      // And scaled: a 1024² apple-touch-icon never reaches the cache or the
      // window host at full size, which is what used to break icons and crash.
      final decoded = await decodeImageFromList(out);
      expect(decoded.width, 48);
    });

    test('refuses bytes that are not an image', () async {
      final notAnImage = Uint8List.fromList(
        utf8.encode('<html><body>404</body></html>'),
      );
      expect(await PwaDiscovery.normalizeIcon(notAnImage), isNull);
    });
  });

  group('finding a manifest in HTML', () {
    const page = 'https://photos.example/gallery/';

    test('handles attribute order, quoting and relative hrefs', () {
      expect(
        PwaDiscovery.findManifestHref(
          '<link rel="manifest" href="/manifest.json">',
          page,
        ),
        'https://photos.example/manifest.json',
      );
      expect(
        PwaDiscovery.findManifestHref(
          "<link href='app.webmanifest' rel='manifest'>",
          page,
        ),
        'https://photos.example/gallery/app.webmanifest',
      );
      expect(
        PwaDiscovery.findManifestHref(
          '<link rel="stylesheet" href="x.css"><link rel=manifest href=../m.json>',
          page,
        ),
        'https://photos.example/m.json',
      );
    });

    test('is null when the page does not declare one', () {
      expect(
        PwaDiscovery.findManifestHref(
          '<link rel="icon" href="/favicon.ico">',
          page,
        ),
        isNull,
      );
      expect(PwaDiscovery.findManifestHref('', page), isNull);
    });

    test('reads the title and the page icon', () {
      expect(
        PwaDiscovery.findTitle('<html><head><title> 相册 &amp; 图库 </title>'),
        '相册 & 图库',
      );
      expect(PwaDiscovery.findTitle('<html>'), '');

      final icon = PwaDiscovery.findPageIcon(
        '<link rel="icon" href="/favicon.ico" sizes="48x48">'
        '<link rel="apple-touch-icon" href="/touch.png" sizes="180x180">',
        page,
      );
      // The app-style icon wins; a plain favicon is the fallback.
      expect(icon!.url, 'https://photos.example/touch.png');
      expect(icon.size, 180);
    });
  });

  group('a web entry built from a manifest', () {
    test('is a PWA that opens standalone, and keeps what it read', () {
      final manifest = PwaManifest.parse(_manifestJson(), _manifestUrl);
      final site = PwaSite(
        url: 'https://photos.example/',
        title: 'Photos',
        secure: true,
        manifest: manifest,
        icon: manifest.bestIcon(),
      );

      final entry = WebApp(id: WebApp.newId(), name: '', url: site.url)
        ..applySite(site);

      expect(entry.isPwa, isTrue);
      expect(entry.opensStandalone, isTrue);
      // The site names itself: the typed name being empty is not a problem.
      expect(entry.name, 'Photos');
      expect(entry.startUrl, 'https://photos.example/app');
      expect(entry.display, 'standalone');
      expect(entry.themeColor, 0xff123456);

      final back = WebApp.fromMap(entry.toMap());
      expect(back.manifestUrl, _manifestUrl);
      expect(back.startUrl, 'https://photos.example/app');
      expect(back.display, 'standalone');
      expect(back.themeColor, 0xff123456);
      expect(back.iconUrl, 'https://photos.example/icon-512.png');
      expect(back.isPwa, isTrue);
    });

    test('a manifest asking for a browser tab still opens in a window', () {
      // `display: browser` says "no window of its own" for an *installed* app.
      // Here the entry decides, and the default is its own window: a site
      // without one still fills a chrome-less window fine.
      final manifest = PwaManifest.parse(
        _manifestJson(display: 'browser'),
        _manifestUrl,
      );
      final entry = WebApp(id: WebApp.newId(), name: 'x', url: 'https://a.example/')
        ..applySite(
          PwaSite(
            url: 'https://a.example/',
            title: '',
            secure: true,
            manifest: manifest,
          ),
        );
      expect(entry.isPwa, isTrue);
      expect(entry.opensStandalone, isTrue);
      expect(entry.windowDisplay, 'standalone');
      expect(entry.display, 'browser');

      // The user can still send it to a browser, and pick which one.
      entry.openMode = WebApp.openBrowser;
      entry.browserPackage = 'com.android.chrome';
      expect(entry.opensStandalone, isFalse);
      final back = WebApp.fromMap(entry.toMap());
      expect(back.openMode, WebApp.openBrowser);
      expect(back.browserPackage, 'com.android.chrome');
    });

    test('a site without a manifest opens in a window too', () {
      final entry = WebApp(id: WebApp.newId(), name: 'x', url: 'https://a.example/page')
        ..applySite(
          const PwaSite(
            url: 'https://a.example/page',
            title: 'a',
            secure: true,
            themeColor: 0xff112233,
          ),
        );
      expect(entry.isPwa, isFalse);
      expect(entry.opensStandalone, isTrue);
      expect(entry.startUrl, 'https://a.example/page');
      // Without a manifest the page's own theme-color becomes the window tint.
      expect(entry.themeColor, 0xff112233);
    });

    test('entries saved before the window host existed default to it', () {
      // No openMode key: whatever an older build stored.
      final back = WebApp.fromMap(<String, dynamic>{
        'id': 'web:1',
        'name': 'Photos',
        'url': 'https://photos.example/',
        'createdAt': 1,
      });
      expect(back.openMode, WebApp.openStandalone);
      expect(back.opensStandalone, isTrue);
      expect(back.browserPackage, isEmpty);
    });

    test('http is not a secure context, so it cannot be a PWA', () {
      final site = const PwaSite(
        url: 'http://a.example/',
        title: 'a',
        secure: false,
        manifest: null,
      );
      expect(site.isPwa, isFalse);
      expect(site.display, 'browser');
    });
  });

  group('launching', () {
    Future<AppState> stateWith(
      WidgetTester tester,
      Map<String, dynamic>? json, {
      String display = 'standalone',
    }) async {
      final state = AppState(_MemStorage())..initialized = true;
      PwaSite? site;
      if (json != null) {
        final manifest = PwaManifest.parse(json, _manifestUrl);
        site = PwaSite(
          url: 'https://photos.example/',
          title: 'Photos',
          secure: true,
          manifest: manifest,
          icon: manifest.bestIcon(),
        );
      } else {
        site = const PwaSite(
          url: 'https://photos.example/',
          title: 'Photos',
          secure: true,
        );
      }
      await state.addWebApp(url: 'https://photos.example/', site: site);
      return state;
    }

    testWidgets('a PWA opens in the app window the manifest asks for', (
      tester,
    ) async {
      const channel = MethodChannel('hamstapp/apps');
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return true;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );

      final state = await stateWith(tester, _manifestJson());
      final id = state.webApps.single.id;
      expect(state.webApps.single.opensStandalone, isTrue);

      late BuildContext ctx;
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(
            home: Builder(
              builder: (c) {
                ctx = c;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      await launchApp(ctx, id);

      // The manifest's start_url, display mode and colours reach the host; the
      // system browser is not involved.
      expect(calls.map((c) => c.method), isNot(contains('openUrl')));
      final open = calls.singleWhere((c) => c.method == 'openWebApp');
      final args = (open.arguments as Map).cast<String, dynamic>();
      expect(args['url'], 'https://photos.example/app');
      expect(args['display'], 'standalone');
      expect(args['themeColor'], 0xff123456);
      expect(args['backgroundColor'], 0xffffffff);
      expect(args['scope'], 'https://photos.example/app/');
      expect(state.metaFor(id).launchCount, 1);
    });

    testWidgets('an entry set to use a browser hands it the chosen browser', (
      tester,
    ) async {
      const channel = MethodChannel('hamstapp/apps');
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return true;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );

      // A site without a manifest, sent to a specific browser by the user.
      final state = await stateWith(tester, null);
      final id = state.webApps.single.id;
      expect(state.webApps.single.opensStandalone, isTrue);
      await state.updateWebApp(
        id,
        openMode: WebApp.openBrowser,
        browserPackage: 'com.android.chrome',
        browserName: 'Chrome',
      );
      expect(state.webApps.single.opensStandalone, isFalse);

      late BuildContext ctx;
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(
            home: Builder(
              builder: (c) {
                ctx = c;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      await launchApp(ctx, id);

      expect(calls.map((c) => c.method), isNot(contains('openWebApp')));
      final open = calls.singleWhere((c) => c.method == 'openUrl');
      final args = (open.arguments as Map).cast<String, dynamic>();
      expect(args['url'], 'https://photos.example/');
      expect(args['package'], 'com.android.chrome');
    });

    testWidgets('a site without a manifest opens in the app window', (
      tester,
    ) async {
      const channel = MethodChannel('hamstapp/apps');
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return true;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );

      final state = await stateWith(tester, null);
      final id = state.webApps.single.id;

      late BuildContext ctx;
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(
            home: Builder(
              builder: (c) {
                ctx = c;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      await launchApp(ctx, id);

      expect(calls.map((c) => c.method), isNot(contains('openUrl')));
      final open = calls.singleWhere((c) => c.method == 'openWebApp');
      final args = (open.arguments as Map).cast<String, dynamic>();
      expect(args['url'], 'https://photos.example/');
      expect(args['display'], 'standalone');
    });
  });
}
