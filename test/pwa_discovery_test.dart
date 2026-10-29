import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:hamstapp/models/web_app.dart';
import 'package:hamstapp/services/pwa.dart';

/// Identification makes real HTTP requests, so this suite must not create a
/// `TestWidgetsFlutterBinding` (which turns every request into a 400): keep it
/// free of `testWidgets` and a local server can answer instead.
void main() {
  test('finds a public manifest behind a login redirect', () async {
    // The shape 52dmeme.com has: `/` is bounced to an activation page with no
    // manifest, but the SPA shell (served for unknown paths) names its
    // manifest, and the manifest itself is public.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final path = request.uri.path;
      final response = request.response;
      response.headers.contentType = ContentType.html;
      if (path == '/') {
        response.statusCode = HttpStatus.found;
        response.headers.set(HttpHeaders.locationHeader, '/activate');
      } else if (path == '/activate') {
        response.write(
          '<html><head><title>邀请码激活 · 尽欢</title></head>'
          '<body>activate</body></html>',
        );
      } else if (path == '/site.webmanifest') {
        response.headers.contentType = ContentType.json;
        response.write(
          jsonEncode({
            'name': '尽欢',
            'short_name': '尽欢',
            'start_url': '/',
            'display': 'standalone',
            'theme_color': '#1F6B4F',
            'icons': [
              {
                'src': '/favicon-192.png',
                'sizes': '192x192',
                'type': 'image/png',
              },
            ],
          }),
        );
      } else {
        // Any unknown path is the app shell, which points at the manifest.
        response.write(
          '<html><head><title>尽欢</title>'
          '<link rel="manifest" href="/site.webmanifest"></head></html>',
        );
      }
      await response.close();
    });

    final origin = 'http://127.0.0.1:${server.port}/';
    final site = await PwaDiscovery.discover(origin);
    expect(site, isNotNull);
    expect(site!.name, '尽欢');
    expect(site.display, 'standalone');
    expect(site.manifest?.manifestUrl, '${origin}site.webmanifest');
    expect(site.startUrl, origin);
    // The activation page's title must not name the app.
    final entry = WebApp(id: WebApp.newId(), name: '', url: origin)
      ..applySite(site);
    expect(entry.name, '尽欢');
    expect(entry.startUrl, origin);
  });

  test('a site with its own manifest link is read without probing', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var probes = 0;
    server.listen((request) async {
      final path = request.uri.path;
      final response = request.response;
      response.headers.contentType = ContentType.html;
      if (path == '/') {
        response.write(
          '<html><head><title>Photos</title>'
          '<link rel="manifest" href="/app.webmanifest"></head></html>',
        );
      } else if (path == '/app.webmanifest') {
        response.headers.contentType = ContentType.json;
        response.write(
          jsonEncode({
            'name': 'Photos',
            'start_url': '/photos',
            'display': 'standalone',
            'icons': [
              {'src': '/icon.png', 'sizes': '192x192', 'type': 'image/png'},
            ],
          }),
        );
      } else {
        probes++;
        response.write('<html><body>no</body></html>');
      }
      await response.close();
    });

    final origin = 'http://127.0.0.1:${server.port}/';
    final site = await PwaDiscovery.discover(origin);
    expect(site, isNotNull);
    expect(site!.manifest?.name, 'Photos');
    expect(site.startUrl, '${origin}photos');
    expect(probes, 0, reason: 'a declared manifest is trusted, no guessing');
  });
}
