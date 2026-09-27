import 'dart:convert';
import 'dart:io';

import '../l10n/app_strings.dart';
import '../models/remote_source.dart';
import 'native_apps.dart';

/// Talks to a remote APK source.
///
/// FTP and SMB go through the native bridge (commons-net / jcifs-ng); WebDAV is
/// implemented in Dart over HTTP(S). All listing is recursive and only returns
/// real `.apk` files (hidden/dot entries and other files are skipped).
class RemoteClient {
  RemoteClient._();

  static const int _maxDepth = 6;
  static const int _maxDirs = 500;

  static Future<Map<String, dynamic>> test(RemoteSource source) async {
    try {
      final files = await list(source);
      return {'ok': true, 'count': files.length};
    } catch (e) {
      return {'ok': false, 'error': '$e'};
    }
  }

  static Future<List<Map<String, dynamic>>> list(RemoteSource source) {
    if (source.isWebdav) return _webdavList(source);
    return NativeApps.remoteList(source.toChannelArgs());
  }

  /// Downloads one listed entry (or reuses the cached copy) and returns the
  /// local file path. Reports throughput via [onProgress] when provided.
  ///
  /// Pass [force] to re-download and re-parse even when an up-to-date cached
  /// copy exists (used to pick up a replaced APK).
  static Future<String> download(
    RemoteSource source,
    Map<String, dynamic> entry, {
    bool force = false,
    void Function(int received, int total)? onProgress,
  }) {
    final name = (entry['name'] as String?) ?? 'download.apk';
    return NativeApps.remoteDownload(
      source.toChannelArgs(),
      sourceId: source.id,
      remotePath: (entry['path'] as String?) ?? '',
      name: name,
      rel: (entry['rel'] as String?) ?? name,
      size: (entry['size'] as num?)?.toInt() ?? 0,
      modified: (entry['modified'] as num?)?.toInt() ?? 0,
      force: force,
      onProgress: onProgress,
    );
  }

  /// Cached APK metadata for a source, keyed by remote path.
  static Future<Map<String, Map<String, dynamic>>> cacheIndex(
      RemoteSource source) async {
    final r = await NativeApps.cacheIndex(source.id);
    final entries = (r['entries'] as List?) ?? const [];
    final out = <String, Map<String, dynamic>>{};
    for (final e in entries) {
      final m = (e as Map).cast<String, dynamic>();
      final p = m['path'] as String? ?? '';
      if (p.isNotEmpty) out[p] = m;
    }
    return out;
  }

  /// Every cached APK across all sources (each entry has a `sourceId`).
  static Future<List<Map<String, dynamic>>> cacheIndexAll() async {
    final r = await NativeApps.cacheIndexAll();
    final entries = (r['entries'] as List?) ?? const [];
    return entries
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList(growable: false);
  }

  /// Drops cached APKs whose remote file changed (size or mtime) or disappeared.
  static Future<int> pruneCache(
      RemoteSource source, List<Map<String, dynamic>> files) {
    return NativeApps.cachePrune(
      source.id,
      files
          .map((f) => {
                'path': f['path'],
                'size': f['size'],
                'modified': f['modified'],
              })
          .toList(growable: false),
    );
  }

  /// Deletes one cached APK so the next fetch re-downloads it. Returns freed
  /// bytes.
  static Future<int> deleteCache(RemoteSource source, String remotePath) {
    if (remotePath.isEmpty) return Future.value(0);
    return NativeApps.cacheDelete(source.id, remotePath);
  }

  /// Deletes the whole download cache. Returns freed bytes.
  static Future<int> clearCache() => NativeApps.cacheClear();

  // --------------------------------------------------------------- webdav

  static Uri _rootUri(RemoteSource source) {
    final scheme = source.secure ? 'https' : 'http';
    var path = source.path.trim();
    if (path.isEmpty) path = '/';
    if (!path.startsWith('/')) path = '/$path';
    // Collections must be addressed with a trailing slash; many servers answer
    // 301/404 (instead of listing) when it is missing.
    if (!path.endsWith('/')) path = '$path/';
    return Uri(
      scheme: scheme,
      host: source.host.trim(),
      port: source.port,
      path: path,
    );
  }

  static HttpClient _client() => HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..userAgent = 'Hamstapp/1.0'
    // LAN NAS boxes commonly present self-signed certificates.
    ..badCertificateCallback = (cert, host, port) => true;

  static void _applyAuth(HttpClientRequest req, RemoteSource source) {
    if (!source.anonymous && source.username.isNotEmpty) {
      final token =
          base64.encode(utf8.encode('${source.username}:${source.password}'));
      req.headers.set(HttpHeaders.authorizationHeader, 'Basic $token');
    }
  }

  static Future<List<Map<String, dynamic>>> _webdavList(
      RemoteSource source) async {
    final client = _client();
    try {
      final root = _rootUri(source);
      final rootPath = root.path;
      final rootDepth = _depthOf(rootPath);
      final out = <Map<String, dynamic>>[];
      final visited = <String>{};
      final queue = <Uri>[root];

      while (queue.isNotEmpty) {
        if (visited.length >= _maxDirs) break;
        final dir = queue.removeAt(0);
        if (!visited.add(dir.toString())) continue;

        final entries = await _propfind(client, source, dir);
        for (final e in entries) {
          final href = e['href'] as String;
          var target = dir.resolve(href);
          if (e['isDir'] == true) {
            if (!target.path.endsWith('/')) {
              target = target.replace(path: '${target.path}/');
            }
            if (_depthOf(target.path) - rootDepth <= _maxDepth) {
              queue.add(target);
            }
          } else {
            final name = e['name'] as String;
            if (name.startsWith('.') ||
                !name.toLowerCase().endsWith('.apk')) {
              continue;
            }
            final rel = Uri.decodeComponent(target.path.startsWith(rootPath)
                ? target.path.substring(rootPath.length)
                : name);
            out.add({
              'name': name,
              'rel': rel,
              'path': target.path,
              'size': e['size'] ?? 0,
              'modified': e['modified'] ?? 0,
            });
          }
        }
      }
      out.sort((a, b) => (a['rel'] as String)
          .toLowerCase()
          .compareTo((b['rel'] as String).toLowerCase()));
      return out;
    } finally {
      client.close(force: true);
    }
  }

  static int _depthOf(String path) =>
      path.split('/').where((s) => s.isNotEmpty).length;

  static Future<List<Map<String, dynamic>>> _propfind(
      HttpClient client, RemoteSource source, Uri uri) async {
    var target = uri;
    for (var attempt = 0; attempt <= 5; attempt++) {
      final req = await client.openUrl('PROPFIND', target)
        ..followRedirects = false
        ..persistentConnection = false
        ..headers.set('Depth', '1')
        ..headers.contentLength = 0;
      _applyAuth(req, source);
      final resp = await req.close();
      final bytes = <int>[];
      await for (final chunk in resp) {
        bytes.addAll(chunk);
      }
      final code = resp.statusCode;
      if (code >= 300 && code < 400) {
        final loc = resp.headers.value(HttpHeaders.locationHeader);
        if (loc == null || attempt == 5) {
          throw HttpException(
            AppStrings.current.t(
              'HTTP {code}（重定向但无 Location）',
              {'code': code},
            ),
            uri: target,
          );
        }
        target = target.resolve(loc);
        continue;
      }
      if (code >= 400) {
        throw HttpException(
          'HTTP $code ${resp.reasonPhrase}${_hint(code)}${_snippet(bytes)}',
          uri: target,
        );
      }
      return parseWebdavEntries(utf8.decode(bytes, allowMalformed: true));
    }
    throw HttpException(
      AppStrings.current.t('重定向次数过多'),
      uri: target,
    );
  }

  static String _hint(int code) {
    switch (code) {
      case 401:
        return '（${AppStrings.current.t('需要登录，请关闭“匿名登录”并填写账号密码')}）';
      case 403:
        return '（${AppStrings.current.t('无权限，账号可能不允许该目录')}）';
      case 404:
        return '（${AppStrings.current.t('路径不存在，注意大小写并确认 WebDAV 根目录')}）';
      case 405:
        return '（${AppStrings.current.t('该地址不是 WebDAV 服务，或不允许 PROPFIND')}）';
      default:
        return '';
    }
  }

  static String _snippet(List<int> bytes) {
    final text = utf8.decode(bytes, allowMalformed: true).trim();
    if (text.isEmpty) return '';
    final short = text.length > 200 ? '${text.substring(0, 200)}…' : text;
    return ' · $short';
  }

  // --------------------------------------------------------------- parsing

  /// Last path segment of an already percent-decoded path.
  static String _basename(String path) {
    final parts = path.trim().split('/').where((s) => s.isNotEmpty).toList();
    return parts.isEmpty ? '' : parts.last;
  }

  /// Parses a WebDAV `multistatus` XML body into raw entries (files and
  /// collections). Prefix-agnostic because servers use D:, d:, lp1: or none.
  static List<Map<String, dynamic>> parseWebdavEntries(String xml) {
    final out = <Map<String, dynamic>>[];
    final blocks = xml.split(
        RegExp(r'</[a-zA-Z0-9]*:?response\s*>', caseSensitive: false));
    final hrefRe = RegExp(r'<[a-zA-Z0-9]*:?href[^>]*>(.*?)</[a-zA-Z0-9]*:?href>',
        caseSensitive: false, dotAll: true);
    final lenRe = RegExp(r'<[a-zA-Z0-9]*:?getcontentlength[^>]*>\s*(\d+)',
        caseSensitive: false);
    final modRe = RegExp(
        r'<[a-zA-Z0-9]*:?getlastmodified[^>]*>(.*?)</',
        caseSensitive: false,
        dotAll: true);

    for (final block in blocks) {
      final href = hrefRe.firstMatch(block)?.group(1);
      if (href == null) continue;
      final decoded = Uri.decodeComponent(href.trim());
      final name = _basename(decoded);
      if (name.isEmpty) continue;
      out.add({
        'href': decoded,
        'name': name,
        'isDir': decoded.endsWith('/'),
        'size': int.tryParse(lenRe.firstMatch(block)?.group(1) ?? '') ?? 0,
        'modified': _parseHttpDate(modRe.firstMatch(block)?.group(1)),
      });
    }
    return out;
  }

  /// Files-only view of [parseWebdavEntries] (kept for callers/tests).
  static List<Map<String, dynamic>> parseWebdavListing(String xml) {
    final out = <Map<String, dynamic>>[];
    for (final e in parseWebdavEntries(xml)) {
      if (e['isDir'] == true) continue;
      final name = e['name'] as String;
      if (name.startsWith('.') || !name.toLowerCase().endsWith('.apk')) {
        continue;
      }
      out.add({
        'name': name,
        'size': e['size'],
        'path': e['href'],
        'modified': e['modified'],
      });
    }
    out.sort((a, b) => (a['name'] as String)
        .toLowerCase()
        .compareTo((b['name'] as String).toLowerCase()));
    return out;
  }

  static int _parseHttpDate(String? raw) {
    if (raw == null) return 0;
    try {
      return HttpDate.parse(raw.trim()).millisecondsSinceEpoch;
    } catch (_) {
      return 0;
    }
  }
}
