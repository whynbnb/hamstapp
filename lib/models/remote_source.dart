import '../l10n/app_strings.dart';

/// Configuration of a remote APK source (FTP, SMB/Samba or WebDAV).
class RemoteSource {
  /// Stable id so a source can be edited/removed independently.
  String id;

  /// User-facing label shown on the sync tab.
  String name;

  String protocol; // 'ftp' | 'smb' | 'webdav'
  String host;
  int port;
  String path; // FTP/WebDAV remote dir, or SMB share[/subdir]
  String username;
  String password;
  bool anonymous;

  /// SMB domain/workgroup (optional, e.g. `WORKGROUP` or the NAS name).
  String domain;

  /// Use HTTPS/TLS (WebDAV only).
  bool secure;

  /// Keep every downloaded version instead of only the latest one. When on,
  /// an outdated cached APK is archived rather than replaced, so older builds
  /// remain available to install offline.
  bool keepAllVersions;

  RemoteSource({
    this.id = '',
    this.name = '',
    this.protocol = 'ftp',
    this.host = '',
    this.port = 21,
    this.path = '',
    this.username = '',
    this.password = '',
    this.anonymous = true,
    this.domain = '',
    this.secure = false,
    this.keepAllVersions = false,
  });

  factory RemoteSource.fromMap(Map<String, dynamic> map) {
    final protocol = map['protocol'] as String? ?? 'ftp';
    final secure = map['secure'] as bool? ?? false;
    return RemoteSource(
      id: map['id'] as String? ?? '',
      name: map['name'] as String? ?? '',
      protocol: protocol,
      host: map['host'] as String? ?? '',
      port: (map['port'] as num?)?.toInt() ?? defaultPort(protocol, secure: secure),
      path: map['path'] as String? ?? '',
      username: map['username'] as String? ?? '',
      password: map['password'] as String? ?? '',
      anonymous: map['anonymous'] as bool? ?? true,
      domain: map['domain'] as String? ?? '',
      secure: secure,
      keepAllVersions: map['keepAllVersions'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toMap() => <String, dynamic>{
        'id': id,
        'name': name,
        'protocol': protocol,
        'host': host,
        'port': port,
        'path': path,
        'username': username,
        'password': password,
        'anonymous': anonymous,
        'domain': domain,
        'secure': secure,
        'keepAllVersions': keepAllVersions,
      };

  bool get isSmb => protocol == 'smb' || protocol == 'samba';
  bool get isWebdav => protocol == 'webdav';
  bool get isFtp => !isSmb && !isWebdav;

  bool get configured => host.trim().isNotEmpty && path.trim().isNotEmpty;

  /// Default port for the selected protocol.
  static int defaultPort(String protocol, {bool secure = false}) {
    switch (protocol) {
      case 'smb':
      case 'samba':
        return 445;
      case 'webdav':
        return secure ? 443 : 80;
      default:
        return 21;
    }
  }

  String get protocolLabel {
    if (isSmb) return 'SMB';
    if (isWebdav) return secure ? 'WebDAV(HTTPS)' : 'WebDAV';
    return 'FTP';
  }

  String get displayName =>
      name.trim().isNotEmpty ? name.trim() : protocolLabel;

  String get summary {
    final s = AppStrings.current;
    if (!configured) return s.t('未配置');
    final auth = anonymous ? s.t('匿名') : username;
    return '$protocolLabel · $host:$port/$path · $auth';
  }

  /// Arguments passed to the native channel (list/download/install).
  Map<String, dynamic> toChannelArgs() => <String, dynamic>{
        'protocol': isSmb ? 'smb' : (isWebdav ? 'webdav' : 'ftp'),
        'host': host.trim(),
        'port': port,
        'path': path.trim(),
        'username': username,
        'password': password,
        'anonymous': anonymous,
        'domain': domain,
        'secure': secure,
      };

  RemoteSource copyWith({
    String? id,
    String? name,
    String? protocol,
    String? host,
    int? port,
    String? path,
    String? username,
    String? password,
    bool? anonymous,
    String? domain,
    bool? secure,
    bool? keepAllVersions,
  }) =>
      RemoteSource(
        id: id ?? this.id,
        name: name ?? this.name,
        protocol: protocol ?? this.protocol,
        host: host ?? this.host,
        port: port ?? this.port,
        path: path ?? this.path,
        username: username ?? this.username,
        password: password ?? this.password,
        anonymous: anonymous ?? this.anonymous,
        domain: domain ?? this.domain,
        secure: secure ?? this.secure,
        keepAllVersions: keepAllVersions ?? this.keepAllVersions,
      );
}
