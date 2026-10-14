import 'app_info.dart';
import '../services/pwa.dart';

/// A website the user added to the app by hand, following the PWA standard
/// where the site supports it.
///
/// Chrome's "add to home screen" can leave nothing but a shortcut on the
/// desktop, and Android lets nobody but the launcher read or start another
/// app's shortcuts. So a web app that is not an installed package is added by
/// hand instead: it gets a synthetic package id, which is what lets it use
/// every app-shaped surface (tiles, categories, favorites, search, the usage
/// log) without any of them needing to know about it.
///
/// When the site ships a [Web App Manifest](https://developer.mozilla.org/en-US/docs/Web/Progressive_web_apps/Manifest)
/// — a PWA — its `name`, `icons`, `start_url`, `scope`, `display` and colours
/// are read once and stored here, and the entry launches in a standalone
/// window with no browser UI, the way the standard says `display: standalone`
/// should look.
class WebApp {
  /// Synthetic package ids start with this, so they cannot collide with a real
  /// package name and are recognisable from the id alone.
  static const String idPrefix = 'web:';

  /// Display modes from the standard, in fallback order.
  static const String displayFullscreen = 'fullscreen';
  static const String displayStandalone = 'standalone';
  static const String displayMinimalUi = 'minimal-ui';
  static const String displayBrowser = 'browser';

  /// How the entry opens. Everything opens in the app's own window by default —
  /// a site without a manifest is still a page that can fill a chrome-less
  /// window, and that is what a launcher-like app is for. The system browser
  /// stays available per entry.
  static const String openStandalone = 'standalone';
  static const String openBrowser = 'browser';

  final String id;
  String name;

  /// The address the entry stands for (what the user typed).
  String url;

  /// Manifest `start_url`: what is opened on launch. Falls back to [url].
  String startUrl;

  /// Manifest `scope`: navigation inside it stays in the app window.
  String scope;

  /// Manifest display mode (see the `display*` constants).
  String display;

  /// Manifest `theme_color` as ARGB, 0 when unset.
  int themeColor;

  /// Manifest `background_color` as ARGB, 0 when unset.
  int backgroundColor;

  /// Where the manifest was read from; '' when the site has none.
  String manifestUrl;

  /// The chosen icon's address, kept so it can be refetched.
  String iconUrl;

  /// How it opens: [openStandalone] (default) or [openBrowser].
  String openMode;

  /// Which app opens it when [openMode] is [openBrowser], or which app takes
  /// over links that leave the scope while running standalone. '' = whichever
  /// one the system would pick.
  String browserPackage;

  /// Label of [browserPackage], for showing the choice without querying again.
  String browserName;

  final int createdAt;

  WebApp({
    required this.id,
    required this.name,
    required this.url,
    String? startUrl,
    this.scope = '',
    this.display = displayBrowser,
    this.themeColor = 0,
    this.backgroundColor = 0,
    this.manifestUrl = '',
    this.iconUrl = '',
    this.openMode = openStandalone,
    this.browserPackage = '',
    this.browserName = '',
    this.createdAt = 0,
  }) : startUrl = startUrl ?? url;

  static bool isWebId(String packageName) => packageName.startsWith(idPrefix);

  static String newId([DateTime? now]) =>
      '$idPrefix${(now ?? DateTime.now()).millisecondsSinceEpoch.toRadixString(36)}';

  /// The site declared a manifest: that is what makes it a PWA.
  bool get isPwa => manifestUrl.isNotEmpty;

  /// It asks for a window of its own rather than a browser tab. `display`
  /// only applies to installed web apps, which is exactly how it is used here.
  bool get opensStandalone => openMode == openStandalone;

  /// The display mode to hand the window host: a manifest that says `browser`
  /// has no window of its own, and here that simply means "no chrome either".
  String get windowDisplay =>
      display == displayBrowser ? displayStandalone : display;

  /// What people type ("zhihu.com", "example.com/page") turned into a URL.
  static String normalizeUrl(String raw) {
    final text = raw.trim();
    if (text.isEmpty || text.contains('://')) return text;
    return 'https://$text';
  }

  /// The entry's address on screen: no trailing slash noise.
  String get prettyUrl => startUrl.isEmpty ? url : startUrl;

  static bool isValidUrl(String url) {
    if (!url.startsWith('http://') && !url.startsWith('https://')) return false;
    final host = Uri.tryParse(url)?.host ?? '';
    return host.isNotEmpty;
  }

  /// Picks up what the site's manifest says. [keepName] is false on add, so the
  /// site's own name wins unless the user typed one.
  void applySite(PwaSite site) {
    manifestUrl = site.manifest?.manifestUrl ?? '';
    display = site.display;
    scope = site.manifest?.scope ?? '';
    startUrl = site.startUrl;
    themeColor = site.manifest?.themeColor ?? site.themeColor;
    backgroundColor = site.manifest?.backgroundColor ?? 0;
    iconUrl = site.icon?.url ?? '';
    final siteName = site.name.trim();
    if (name.trim().isEmpty && siteName.isNotEmpty) name = siteName;
  }

  factory WebApp.fromMap(Map<dynamic, dynamic> map) {
    final url = map['url'] as String? ?? '';
    return WebApp(
      id: map['id'] as String? ?? '',
      name: map['name'] as String? ?? '',
      url: url,
      startUrl: map['startUrl'] as String? ?? url,
      scope: map['scope'] as String? ?? '',
      display: map['display'] as String? ?? displayBrowser,
      themeColor: (map['themeColor'] as num?)?.toInt() ?? 0,
      backgroundColor: (map['backgroundColor'] as num?)?.toInt() ?? 0,
      manifestUrl: map['manifestUrl'] as String? ?? '',
      iconUrl: map['iconUrl'] as String? ?? '',
      // Entries added before the window host existed have no mode stored; they
      // open in their own window too, which is what a launcher should do.
      openMode: map['openMode'] as String? ?? openStandalone,
      browserPackage: map['browserPackage'] as String? ?? '',
      browserName: map['browserName'] as String? ?? '',
      createdAt: (map['createdAt'] as num?)?.toInt() ?? 0,
    );
  }

  /// Rebuilds an entry that travelled inside a backup, where it was stored as
  /// an [AppInfo] like everything else.
  factory WebApp.fromAppInfo(AppInfo app) => WebApp(
        id: app.packageName,
        name: app.appName,
        url: app.webUrl,
        createdAt: app.firstInstallTime,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'url': url,
        'startUrl': startUrl,
        'scope': scope,
        'display': display,
        'themeColor': themeColor,
        'backgroundColor': backgroundColor,
        'manifestUrl': manifestUrl,
        'iconUrl': iconUrl,
        'openMode': openMode,
        'browserPackage': browserPackage,
        'browserName': browserName,
        'createdAt': createdAt,
      };

  /// The app-shaped view of this entry, so lists, tiles, search, categories and
  /// favorites keep working off [AppInfo] alone.
  AppInfo toAppInfo() => AppInfo(
        packageName: id,
        appName: name,
        versionName: '',
        versionCode: 0,
        firstInstallTime: createdAt,
        lastUpdateTime: createdAt,
        isSystem: false,
        enabled: true,
        apkPath: '',
        sizeBytes: 0,
        targetSdk: 0,
        minSdk: 0,
        uid: 0,
        isWebApp: true,
        webUrl: startUrl.isEmpty ? url : startUrl,
        isWebEntry: true,
      );
}
