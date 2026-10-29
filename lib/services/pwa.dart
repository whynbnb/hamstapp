import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'app_log.dart';
import 'native_apps.dart';

/// Width icons are stored at; launcher tiles scale down from here.
const int iconTargetSize = 192;

/// Web App Manifest of a site, as described by the PWA standard.
///
/// Everything here comes out of the site's own `manifest.json` (`name`,
/// `icons`, `start_url`, `display`, the colours), so an entry added from a URL
/// shows the site's real name and icon instead of something typed by hand.
class PwaManifest {
  /// `name` — the full name, what users see in app lists.
  final String name;

  /// `short_name` — what fits under a launcher icon.
  final String shortName;

  /// `description` — used for the entry's note when present.
  final String description;

  /// `start_url`, resolved against the manifest URL.
  final String startUrl;

  /// `scope`, resolved against the manifest URL. Navigation inside it stays in
  /// the app window; anything outside goes to the browser.
  final String scope;

  /// Preferred display mode: `fullscreen`, `standalone`, `minimal-ui` or
  /// `browser`. Taken from `display_override` first, then `display`.
  final String display;

  /// `theme_color` as ARGB, or 0 when unset/unreadable.
  final int themeColor;

  /// `background_color` as ARGB, or 0 when unset/unreadable.
  final int backgroundColor;

  /// `orientation` (`portrait`, `landscape`, `any`, …), '' when unset.
  final String orientation;

  final List<PwaIcon> icons;

  /// Where the manifest was read from.
  final String manifestUrl;

  const PwaManifest({
    required this.name,
    required this.shortName,
    required this.description,
    required this.startUrl,
    required this.scope,
    required this.display,
    required this.themeColor,
    required this.backgroundColor,
    required this.orientation,
    required this.icons,
    required this.manifestUrl,
  });

  /// The name to show: per the standard `short_name` is the small-space
  /// variant, so use `name` and let the caller shorten it if it wants to.
  String get label => name.isNotEmpty ? name : shortName;

  /// Members Chromium requires for installability: name, icons and start_url.
  /// (`display` is required too, but ours always has a value.)
  bool get isInstallable =>
      label.isNotEmpty && startUrl.isNotEmpty && icons.isNotEmpty;

  /// Chrome-like icon choice: prefer a non-maskable icon of at least 192px,
  /// biggest first, and fall back to whatever is usable.
  PwaIcon? bestIcon() {
    final usable = icons.where((i) => !i.isSvg).toList();
    if (usable.isEmpty) return null;
    int rank(PwaIcon i) {
      final size = i.size == 0 ? 1 : i.size;
      // 192 and 512 are the sizes the standard asks for; anything bigger is
      // not worth downloading for a launcher icon.
      final wanted = size >= 512 ? 512 : (size >= 192 ? 192 : size);
      return wanted * 2 - (i.maskable ? 1 : 0);
    }

    usable.sort((a, b) => rank(b).compareTo(rank(a)));
    return usable.first;
  }

  /// Parses a manifest. [manifestUrl] is the manifest's own address: the
  /// standard resolves `start_url`, `scope` and icon `src` against it, not
  /// against the page.
  factory PwaManifest.parse(Map<String, dynamic> json, String manifestUrl) {
    String str(String key) {
      final value = json[key];
      return value is String ? value.trim() : '';
    }

    String resolve(String value, String fallback) {
      final raw = value.trim();
      if (raw.isEmpty) return fallback;
      return Uri.parse(manifestUrl).resolve(raw).toString();
    }

    final directory = _directoryOf(manifestUrl);
    return PwaManifest(
      name: str('name'),
      shortName: str('short_name'),
      description: str('description'),
      // start_url defaults to the page that linked the manifest; the manifest
      // URL is the closest thing we have to that.
      startUrl: resolve(str('start_url'), manifestUrl),
      scope: resolve(str('scope'), directory),
      display: _displayMode(json['display_override'], json['display']),
      themeColor: parseColor(str('theme_color')),
      backgroundColor: parseColor(str('background_color')),
      orientation: str('orientation'),
      icons: _parseIcons(json['icons'], manifestUrl),
      manifestUrl: manifestUrl,
    );
  }

  static String _directoryOf(String url) {
    final i = url.lastIndexOf('/');
    return i <= 0 ? url : url.substring(0, i + 1);
  }

  /// `display_override` is a list of preferences; the first one we can honour
  /// wins, otherwise `display` applies (which itself defaults to `browser`).
  static const List<String> _modes = [
    'fullscreen',
    'standalone',
    'minimal-ui',
    'browser',
  ];

  static String _displayMode(dynamic override, dynamic display) {
    if (override is List) {
      for (final entry in override) {
        final mode = entry is String ? entry.trim().toLowerCase() : '';
        if (_modes.contains(mode)) return mode;
      }
    }
    final mode = display is String ? display.trim().toLowerCase() : '';
    return _modes.contains(mode) ? mode : 'browser';
  }

  static List<PwaIcon> _parseIcons(dynamic raw, String manifestUrl) {
    if (raw is! List) return const [];
    final out = <PwaIcon>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final src = item['src'];
      if (src is! String || src.trim().isEmpty) continue;
      out.add(
        PwaIcon(
          url: Uri.parse(manifestUrl).resolve(src.trim()).toString(),
          size: _largestSize(item['sizes']),
          type: item['type'] is String ? (item['type'] as String) : '',
          maskable: '${item['purpose'] ?? ''}'.contains('maskable'),
        ),
      );
    }
    return out;
  }

  /// `sizes` may list several ("192x192 512x512") or say "any"; the biggest
  /// square edge is what matters for picking one.
  static int _largestSize(dynamic raw) {
    if (raw is String) {
      var best = 0;
      for (final part in raw.split(RegExp(r'\s+'))) {
        final match = RegExp(r'^(\d+)x(\d+)$').firstMatch(part);
        if (match == null) continue;
        final w = int.tryParse(match.group(1)!) ?? 0;
        final h = int.tryParse(match.group(2)!) ?? 0;
        final edge = w < h ? w : h;
        if (edge > best) best = edge;
      }
      return best;
    }
    if (raw is List) {
      var best = 0;
      for (final entry in raw) {
        final size = _largestSize(entry);
        if (size > best) best = size;
      }
      return best;
    }
    return 0;
  }

  /// CSS colour → ARGB, or 0 when it cannot be read. Covers the forms a
  /// manifest actually uses: #rgb/#rgba/#rrggbb/#rrggbbaa, rgb()/rgba() and the
  /// handful of names.
  static int parseColor(String? raw) {
    if (raw == null) return 0;
    final text = raw.trim().toLowerCase();
    if (text.isEmpty) return 0;
    if (text.startsWith('#')) {
      final hex = text.substring(1);
      bool ok(String s) => RegExp('^[0-9a-f]{$s}\$').hasMatch(hex);
      String doubled() => hex.split('').map((c) => '$c$c').join();
      // #rgb / #rrggbb are opaque; #rgba / #rrggbbaa carry alpha.
      if (hex.length == 3 && ok('3')) return 0xff000000 | (int.parse(doubled(), radix: 16));
      if (hex.length == 6 && ok('6')) return 0xff000000 | (int.parse(hex, radix: 16));
      final eight = hex.length == 4 && ok('4') ? doubled() : (hex.length == 8 && ok('8') ? hex : null);
      if (eight == null) return 0;
      final rgba = int.parse(eight, radix: 16);
      // CSS writes #rrggbbaa; Flutter wants 0xaarrggbb.
      return ((rgba & 0xff) << 24) | (rgba >> 8);
    }
    final rgb = RegExp(r'^rgba?\(([^)]*)\)$').firstMatch(text);
    if (rgb != null) {
      final parts = rgb
          .group(1)!
          .split(',')
          .map((p) => p.trim())
          .toList();
      if (parts.length < 3) return 0;
      int? channel(String s) {
        if (s.endsWith('%')) {
          final pct = double.tryParse(s.substring(0, s.length - 1));
          return pct == null ? null : (pct * 255 / 100).round().clamp(0, 255);
        }
        final value = int.tryParse(s);
        return value?.clamp(0, 255);
      }

      final r = channel(parts[0]);
      final g = channel(parts[1]);
      final b = channel(parts[2]);
      if (r == null || g == null || b == null) return 0;
      final alpha = parts.length >= 4
          ? ((double.tryParse(parts[3]) ?? 1) * 255).round().clamp(0, 255)
          : 255;
      return (alpha << 24) | (r << 16) | (g << 8) | b;
    }
    const named = <String, int>{
      'black': 0xff000000,
      'white': 0xffffffff,
      'transparent': 0x00000000,
      'red': 0xffff0000,
      'green': 0xff008000,
      'blue': 0xff0000ff,
      'grey': 0xff808080,
      'gray': 0xff808080,
    };
    return named[text] ?? 0;
  }
}

/// One entry of the manifest's `icons` array.
class PwaIcon {
  final String url;
  final int size;
  final String type;
  final bool maskable;

  const PwaIcon({
    required this.url,
    required this.size,
    this.type = '',
    this.maskable = false,
  });

  bool get isSvg => type.contains('svg') || url.toLowerCase().endsWith('.svg');
}

/// What a site turned out to be, once fetched.
class PwaSite {
  /// Final URL after redirects.
  final String url;

  /// `<title>` of the page, used when the manifest has no name.
  final String title;

  /// `true` when the site is served over HTTPS (or localhost), which the PWA
  /// standard requires.
  final bool secure;

  /// The manifest, or null when the site does not declare one.
  final PwaManifest? manifest;

  /// Icon worth using: the manifest's choice, else the page's
  /// `apple-touch-icon`/favicon.
  final PwaIcon? icon;

  /// The page's own icon (`apple-touch-icon`/`favicon`), kept so it can be
  /// tried after the manifest's icons fail to download or decode.
  final PwaIcon? pageIcon;

  /// `<meta name="theme-color">` of the page, as ARGB (0 when absent). Sites
  /// without a manifest usually still declare this, and it is what the window
  /// host tints the status bar with.
  final int themeColor;

  const PwaSite({
    required this.url,
    required this.title,
    required this.secure,
    this.manifest,
    this.icon,
    this.pageIcon,
    this.themeColor = 0,
  });

  /// Icons worth trying, best first: the manifest's choice, the rest of the
  /// manifest, then whatever the page itself declares.
  List<PwaIcon> get iconCandidates {
    final out = <PwaIcon>[];
    void add(PwaIcon? icon) {
      if (icon == null || icon.isSvg) return;
      if (out.contains(icon)) return;
      out.add(icon);
    }

    add(manifest?.bestIcon());
    for (final icon in manifest?.icons ?? const <PwaIcon>[]) {
      add(icon);
    }
    add(pageIcon ?? icon);
    return out;
  }

  /// A site is treated as a PWA when it is served from a secure context and
  /// declares a manifest — the two things that make it installable.
  bool get isPwa => secure && manifest != null;

  /// Entry name: the manifest decides, the page title is the fallback.
  String get name {
    final fromManifest = manifest?.label ?? '';
    if (fromManifest.isNotEmpty) return fromManifest;
    return title.trim();
  }

  /// Display mode to launch with: what the manifest asks for, and a browser for
  /// anything that is not installable.
  String get display =>
      isPwa ? (manifest?.display ?? 'browser') : 'browser';

  String get startUrl {
    final declared = manifest?.startUrl ?? '';
    return declared.isNotEmpty ? declared : url;
  }
}

/// Reads a site's manifest over the network.
///
/// The PWA standard's installability rules are what this follows: an
/// `<link rel="manifest">` in the HTML, a JSON manifest with a name and icons,
/// and a secure (HTTPS) context. Nothing here can see inside the page, so a
/// service worker is not verified — a site without one still opens in the app
/// window, it just cannot work offline.
class PwaDiscovery {
  /// Fetches [rawUrl], its manifest and the best icon it can find.
  ///
  /// Every request carries the window host's cookies for its own address, so
  /// identification sees the page a signed-in user sees instead of the
  /// login/activation page an anonymous request is bounced to. [source]
  /// overrides the address that is read (the entry still launches [rawUrl]); it
  /// may be a manifest address or a page that is only reachable once signed in.
  static Future<PwaSite?> discover(
    String rawUrl, {
    Duration timeout = const Duration(seconds: 12),
    String source = '',
  }) async {
    final url = _normalize(rawUrl);
    if (url.isEmpty) return null;
    final security = _security(url);
    final query = _normalize(source.trim().isEmpty ? rawUrl : source);
    if (query.isEmpty) return null;

    final page = await _get(query, timeout: timeout, limit: 1024 * 1024);
    if (page == null) {
      AppLog.instance.warn(LogModule.apps, '网页识别 · 读取失败 · $query');
      return null;
    }
    AppLog.instance.log(
      LogModule.apps,
      '网页识别 · 读取 · $query · ${page.withCookies ? '带登录状态' : '无登录状态'}'
          '${query == url ? '' : ' · 启动地址=$url'}',
    );
    if (page.url != query) {
      AppLog.instance.log(LogModule.apps, '网页识别 · 重定向 · $query → ${page.url}');
    }

    // A manifest address pasted as the identification address, or a site that
    // serves JSON at the root: read it directly.
    final direct = _manifestFromJson(page.text, page.url);
    if (direct != null) {
      AppLog.instance.log(LogModule.apps, '网页识别 · 清单 · ${direct.manifestUrl}');
      return PwaSite(
        url: url,
        title: '',
        secure: security.secure,
        manifest: direct,
        icon: direct.bestIcon(),
      );
    }

    // A redirect to another site is a login/activation portal, not the entry:
    // its manifest, title and colours must not be adopted. The manifest at the
    // address the user entered is still worth looking for.
    final sameSite = _sameSite(query, page.url);
    if (!sameSite) {
      AppLog.instance.log(
        LogModule.apps,
        '网页识别 · 跳到其它站点，跳过该页面的清单 · ${page.url}',
      );
    }

    PwaManifest? manifest;
    final href = sameSite ? findManifestHref(page.text, page.url) : null;
    if (href != null) {
      final json = await _get(href, timeout: timeout, limit: 512 * 1024);
      if (json != null) manifest = _decodeManifest(json.text, json.url);
    }
    if (!_usable(manifest)) {
      // The page may be a shell that builds its manifest later, or the login
      // page: the standard addresses on the entered site still deserve a try.
      manifest = await _probeManifests(url);
    }
    if (!_usable(manifest)) manifest = null;
    AppLog.instance.log(
      LogModule.apps,
      manifest == null || manifest.manifestUrl.isEmpty
          ? '网页识别 · 没有清单 · $url'
          : '网页识别 · 清单 · ${manifest.manifestUrl}',
    );

    final manifestIcon = manifest?.bestIcon();
    final pageIcon = sameSite ? findPageIcon(page.text, page.url) : null;
    return PwaSite(
      url: sameSite ? page.url : query,
      title: sameSite ? findTitle(page.text) : '',
      secure: security.secure,
      manifest: manifest,
      icon: manifestIcon ?? pageIcon,
      pageIcon: pageIcon,
      themeColor: sameSite ? findThemeColor(page.text) : 0,
    );
  }

  /// A manifest pasted (or served) as JSON; null when [text] is not one.
  static PwaManifest? _manifestFromJson(String text, String url) {
    // A UTF-8 BOM is invisible but would stop the `{` test and jsonDecode.
    final body = text.replaceFirst('\uFEFF', '').trimLeft();
    if (!body.startsWith('{')) return null;
    final manifest = _decodeManifest(body, url);
    return _usable(manifest) ? manifest : null;
  }

  /// Rejects an empty object: a random JSON endpoint is not a manifest.
  static bool _usable(PwaManifest? manifest) =>
      manifest != null &&
      (manifest.label.isNotEmpty ||
          manifest.startUrl.isNotEmpty ||
          manifest.icons.isNotEmpty);

  /// The manifest addresses the standard names, tried in order.
  ///
  /// Some sites answer the document with a login/activation redirect but leave
  /// the manifest itself public; asking for it directly is what lets such an
  /// entry still get its name, icon and display mode.
  ///
  /// A single-page app often serves its shell for any unknown path, so an HTML
  /// answer is read for its own `<link rel="manifest">` rather than discarded —
  /// that is exactly how 52dmeme.com's manifest is reachable.
  static Future<PwaManifest?> _probeManifests(String url) async {
    final base = Uri.tryParse(url);
    if (base == null || !base.hasScheme) return null;
    for (final path in const [
      '/manifest.json',
      '/site.webmanifest',
      '/manifest.webmanifest',
    ]) {
      final probe = base.resolve(path).toString();
      final response = await _get(
        probe,
        timeout: const Duration(seconds: 6),
        limit: 512 * 1024,
      );
      if (response == null) continue;
      final direct = _manifestFromJson(response.text, response.url);
      if (direct != null) {
        AppLog.instance.log(LogModule.apps, '网页识别 · 在 $probe 找到清单');
        return direct;
      }
      final href = findManifestHref(response.text, response.url);
      if (href == null || href == probe) continue;
      final json = await _get(
        href,
        timeout: const Duration(seconds: 6),
        limit: 512 * 1024,
      );
      if (json == null) continue;
      final manifest = _decodeManifest(json.text, json.url);
      if (!_usable(manifest)) continue;
      AppLog.instance.log(LogModule.apps, '网页识别 · 在 $probe 的页面里找到清单 $href');
      return manifest;
    }
    return null;
  }

  /// Whether two addresses belong to the same site, treating
  /// `www.example.com` / `m.example.com` / `example.com` as one. A redirect
  /// within it is a normal move; another domain is a sign-in portal.
  static bool _sameSite(String a, String b) {
    final ha = Uri.tryParse(a)?.host ?? '';
    final hb = Uri.tryParse(b)?.host ?? '';
    if (ha.isEmpty || hb.isEmpty || ha == hb) return true;
    List<String> labels(String host) =>
        host.toLowerCase().split('.').where((e) => e.isNotEmpty).toList();
    final la = labels(ha);
    final lb = labels(hb);
    if (la.length < 2 || lb.length < 2) return false;
    return la.sublist(la.length - 2).join('.') ==
        lb.sublist(lb.length - 2).join('.');
  }

  /// `<meta name="theme-color">`, the colour a page declares for the browser
  /// chrome — the closest thing to a theme when there is no manifest.
  static int findThemeColor(String html) {
    for (final match in RegExp(
      r'<meta\b[^>]*>',
      caseSensitive: false,
    ).allMatches(html)) {
      final attrs = _attributes(match.group(0)!);
      if ((attrs['name'] ?? '').toLowerCase() != 'theme-color') continue;
      final color = PwaManifest.parseColor(attrs['content']);
      if (color != 0) return color;
    }
    return 0;
  }

  /// Downloads one image (an icon), returning its bytes and content type.
  /// [referer] is the page the icon belongs to: plenty of sites refuse to serve
  /// an icon without it.
  static Future<PwaImage?> fetchIcon(
    PwaIcon icon, {
    Duration timeout = const Duration(seconds: 12),
    String referer = '',
  }) async {
    final response = await _get(
      icon.url,
      timeout: timeout,
      limit: 4 * 1024 * 1024,
      referer: referer,
    );
    if (response == null || response.bytes.isEmpty) return null;
    return PwaImage(bytes: response.bytes, url: response.url);
  }

  /// Downloads and normalises one icon: scaled to [target] pixels wide and
  /// re-encoded as PNG. Null when the address is not a decodable image at all
  /// (an .ico, a 404 page, an SVG the platform cannot read), so the caller can
  /// try the next candidate.
  ///
  /// Normalising is what keeps icons stable: a site may ship a 2 MB
  /// apple-touch-icon, and storing/sending/decoding that is where icons got
  /// lost or the app fell over.
  static Future<Uint8List?> fetchIconBytes(
    PwaIcon icon, {
    int target = iconTargetSize,
    Duration timeout = const Duration(seconds: 12),
    String referer = '',
  }) async {
    final image = await fetchIcon(icon, timeout: timeout, referer: referer);
    if (image == null) return null;
    return normalizeIcon(Uint8List.fromList(image.bytes), target: target);
  }

  /// The first candidate that downloads and decodes, best first.
  static Future<Uint8List?> fetchBestIcon(
    PwaSite site, {
    int target = iconTargetSize,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    for (final icon in site.iconCandidates) {
      final bytes = await fetchIconBytes(
        icon,
        target: target,
        timeout: timeout,
        referer: site.url,
      );
      if (bytes != null) return bytes;
    }
    return null;
  }

  /// Decodes, scales and re-encodes as PNG; null when it cannot be decoded.
  static Future<Uint8List?> normalizeIcon(
    Uint8List bytes, {
    int target = iconTargetSize,
  }) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: target);
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      frame.image.dispose();
      codec.dispose();
      final out = data?.buffer.asUint8List();
      return (out == null || out.isEmpty) ? null : out;
    } catch (_) {
      return null;
    }
  }

  /// `https://` is required for a PWA; `localhost`/`127.0.0.1` count as secure
  /// per the standard.
  static ({bool secure, String url}) _security(String url) {
    final uri = Uri.tryParse(url);
    final host = uri?.host ?? '';
    final local = host == 'localhost' || host == '127.0.0.1' || host == '::1';
    return (secure: url.startsWith('https://') || local, url: url);
  }

  /// Accepts what people type: "zhihu.com" becomes "https://zhihu.com".
  static String _normalize(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return '';
    if (text.contains('://')) return text;
    return 'https://$text';
  }

  /// The manifest address, or null. Matching follows the standard loosely — a
  /// `<link>` whose `rel` contains `manifest` — without needing an HTML parser.
  static String? findManifestHref(String html, String pageUrl) {
    for (final tag in _linkTags(html)) {
      final attrs = _attributes(tag);
      final rel = attrs['rel'] ?? '';
      if (!rel.toLowerCase().contains('manifest')) continue;
      final href = attrs['href'] ?? '';
      if (href.isEmpty) continue;
      return Uri.parse(pageUrl).resolve(href).toString();
    }
    return null;
  }

  /// `<title>` of the page, trimmed; '' when there is none.
  static String findTitle(String html) {
    final match = RegExp(
      r'<title[^>]*>([\s\S]*?)</title>',
      caseSensitive: false,
    ).firstMatch(html);
    return match == null ? '' : _unescape(match.group(1)!.trim());
  }

  /// The page's own icon, for sites without a manifest: `apple-touch-icon`
  /// first (it is the app-style one), then a plain `icon`.
  static PwaIcon? findPageIcon(String html, String pageUrl) {
    PwaIcon? apple;
    PwaIcon? plain;
    for (final tag in _linkTags(html)) {
      final attrs = _attributes(tag);
      final rel = (attrs['rel'] ?? '').toLowerCase();
      final href = attrs['href'] ?? '';
      if (href.isEmpty) continue;
      final url = Uri.parse(pageUrl).resolve(href).toString();
      if (apple == null && rel.contains('apple-touch-icon')) {
        apple = PwaIcon(url: url, size: _sizeHint(attrs['sizes']), type: '');
      }
      if (plain == null && rel.split(' ').contains('icon')) {
        plain = PwaIcon(url: url, size: _sizeHint(attrs['sizes']), type: '');
      }
    }
    return apple ?? plain;
  }

  static int _sizeHint(String? sizes) {
    if (sizes == null) return 0;
    final match = RegExp(r'(\d+)x(\d+)').firstMatch(sizes);
    if (match == null) return 0;
    final w = int.tryParse(match.group(1)!) ?? 0;
    final h = int.tryParse(match.group(2)!) ?? 0;
    return w < h ? w : h;
  }

  static Iterable<String> _linkTags(String html) sync* {
    for (final match in RegExp(r'<link\b[^>]*>', caseSensitive: false).allMatches(html)) {
      yield match.group(0)!;
    }
  }

  /// Attribute map of one tag, lowercased names, unquoted values accepted.
  static Map<String, String> _attributes(String tag) {
    final out = <String, String>{};
    final pattern = RegExp(
      r'([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*("([^"]*)"|' r"'([^']*)'" r'|([^\s>]+))',
    );
    for (final match in pattern.allMatches(tag)) {
      final value = match.group(3) ?? match.group(4) ?? match.group(5) ?? '';
      out[match.group(1)!.toLowerCase()] = _unescape(value);
    }
    return out;
  }

  static String _unescape(String text) => text
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');

  static PwaManifest? _decodeManifest(String text, String manifestUrl) {
    try {
      final json = jsonDecode(text);
      if (json is Map) {
        return PwaManifest.parse(json.cast<String, dynamic>(), manifestUrl);
      }
    } catch (_) {
      // Not JSON, or a manifest we cannot read: treated as "no manifest".
    }
    return null;
  }

  /// One GET with redirects, a size cap and a browser-ish user agent (some
  /// sites serve different HTML to unknown clients).
  static Future<_Fetched?> _get(
    String url, {
    required Duration timeout,
    required int limit,
    String referer = '',
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return null;
    final client = HttpClient()..connectionTimeout = timeout;
    var withCookies = false;
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      request.headers.set(HttpHeaders.acceptLanguageHeader, 'zh-CN,zh;q=0.9,en;q=0.8');
      if (referer.isNotEmpty) {
        request.headers.set(HttpHeaders.refererHeader, referer);
      }
      // Asked per request, so a cookie is only ever sent to the address it
      // belongs to. HttpOnly cookies stay invisible here; the window itself
      // still has them.
      final cookies = await NativeApps.webViewCookies(url);
      if (cookies.isNotEmpty) {
        request.headers.set(HttpHeaders.cookieHeader, cookies);
        withCookies = true;
      }
      final response = await request.close().timeout(timeout);
      if (response.statusCode >= 400) return null;
      final bytes = <int>[];
      await for (final chunk in response.timeout(timeout)) {
        bytes.addAll(chunk);
        if (bytes.length > limit) break;
      }
      final charset = response.headers.contentType?.charset;
      final text = _decode(bytes, charset);
      return _Fetched(
        bytes: bytes,
        text: text,
        url: finalUrl(url, response.redirects.map((r) => r.location)),
        withCookies: withCookies,
      );
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// The address a response ended up at.
  ///
  /// A server may send a relative `Location` (`/activate`), which Dart keeps
  /// as-is in [HttpClientResponse.redirects]; resolving each hop against the
  /// one before it is what the HTTP client itself did. Taking the raw header
  /// instead made a site's final URL look like a path, and the entry was later
  /// loaded as `file:///activate`.
  static String finalUrl(String url, Iterable<Uri> locations) {
    var current = url;
    for (final location in locations) {
      current = Uri.parse(current).resolveUri(location).toString();
    }
    return current;
  }

  /// UTF-8 unless the server says otherwise. Anything undecodable is replaced
  /// rather than failing: only ASCII-safe bits (the manifest link, the title)
  /// are read out of HTML.
  static String _decode(List<int> bytes, String? charset) {
    final name = (charset ?? 'utf-8').toLowerCase();
    if (name.contains('iso-8859') || name.contains('latin')) {
      return latin1.decode(bytes, allowInvalid: true);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  static const String _userAgent =
      'Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';
}

class PwaImage {
  final List<int> bytes;
  final String url;

  const PwaImage({required this.bytes, required this.url});
}

class _Fetched {
  final List<int> bytes;
  final String text;
  final String url;

  /// Whether the request carried the WebView's cookies.
  final bool withCookies;

  const _Fetched({
    required this.bytes,
    required this.text,
    required this.url,
    this.withCookies = false,
  });
}
