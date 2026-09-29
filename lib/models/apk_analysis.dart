import 'dart:typed_data';

/// One signing certificate embedded in an APK.
class ApkSigner {
  final String sha256;
  final String sha1;
  final String subject;
  final String issuer;
  final String serialNumber;
  final String signatureAlgorithm;

  /// Epoch milliseconds; 0 when unknown.
  final int notBefore;
  final int notAfter;
  final bool selfSigned;

  const ApkSigner({
    this.sha256 = '',
    this.sha1 = '',
    this.subject = '',
    this.issuer = '',
    this.serialNumber = '',
    this.signatureAlgorithm = '',
    this.notBefore = 0,
    this.notAfter = 0,
    this.selfSigned = false,
  });

  factory ApkSigner.fromMap(Map<String, dynamic> m) => ApkSigner(
        sha256: m['sha256'] as String? ?? '',
        sha1: m['sha1'] as String? ?? '',
        subject: m['subject'] as String? ?? '',
        issuer: m['issuer'] as String? ?? '',
        serialNumber: m['serialNumber'] as String? ?? '',
        signatureAlgorithm: m['signatureAlgorithm'] as String? ?? '',
        notBefore: (m['notBefore'] as num?)?.toInt() ?? 0,
        notAfter: (m['notAfter'] as num?)?.toInt() ?? 0,
        selfSigned: m['selfSigned'] as bool? ?? false,
      );
}

/// Everything we can reliably learn from an APK *file* without installing it.
class ApkAnalysis {
  final String path;
  final String fileName;
  final int size;
  final int modified;
  final String sha256;
  final String md5;

  final String packageName;
  final String appName;
  final String versionName;
  final int versionCode;
  final int minSdk;
  final int targetSdk;

  final bool debuggable;
  final bool allowBackup;
  final bool testOnly;
  final bool usesCleartextTraffic;
  final bool extractNativeLibs;

  final List<String> permissions;
  final List<String> features;
  final int activityCount;
  final int serviceCount;
  final int receiverCount;
  final int providerCount;

  final List<String> abis;
  final int nativeLibCount;
  final int dexCount;
  final int dexBytes;
  final int apkEntryCount;
  final int apkUncompressedBytes;
  final int apkCompressedBytes;
  final bool hasResourcesArsc;
  final bool hasManifest;
  final bool hasV1Signature;
  final bool hasMultipleSigners;
  final bool hasPastSigningCertificates;
  final List<ApkSigner> signers;

  final bool installed;
  final int installedVersionCode;
  final String installedVersionName;
  final bool sameSignerAsInstalled;

  final Uint8List? icon;

  const ApkAnalysis({
    required this.path,
    required this.fileName,
    required this.size,
    required this.modified,
    required this.sha256,
    required this.md5,
    required this.packageName,
    required this.appName,
    required this.versionName,
    required this.versionCode,
    required this.minSdk,
    required this.targetSdk,
    required this.debuggable,
    required this.allowBackup,
    required this.testOnly,
    required this.usesCleartextTraffic,
    required this.extractNativeLibs,
    required this.permissions,
    required this.features,
    required this.activityCount,
    required this.serviceCount,
    required this.receiverCount,
    required this.providerCount,
    required this.abis,
    required this.nativeLibCount,
    required this.dexCount,
    required this.dexBytes,
    required this.apkEntryCount,
    required this.apkUncompressedBytes,
    required this.apkCompressedBytes,
    required this.hasResourcesArsc,
    required this.hasManifest,
    required this.hasV1Signature,
    required this.hasMultipleSigners,
    required this.hasPastSigningCertificates,
    required this.signers,
    required this.installed,
    required this.installedVersionCode,
    required this.installedVersionName,
    required this.sameSignerAsInstalled,
    this.icon,
  });

  factory ApkAnalysis.fromMap(Map<String, dynamic> m) {
    List<String> strings(String key) =>
        (m[key] as List?)?.map((e) => '$e').toList(growable: false) ??
        const <String>[];
    int intOf(String key) => (m[key] as num?)?.toInt() ?? 0;
    bool boolOf(String key) => m[key] as bool? ?? false;
    return ApkAnalysis(
      path: m['path'] as String? ?? '',
      fileName: m['fileName'] as String? ?? '',
      size: intOf('size'),
      modified: intOf('modified'),
      sha256: m['sha256'] as String? ?? '',
      md5: m['md5'] as String? ?? '',
      packageName: m['packageName'] as String? ?? '',
      appName: m['appName'] as String? ?? '',
      versionName: m['versionName'] as String? ?? '',
      versionCode: intOf('versionCode'),
      minSdk: intOf('minSdk'),
      targetSdk: intOf('targetSdk'),
      debuggable: boolOf('debuggable'),
      allowBackup: boolOf('allowBackup'),
      testOnly: boolOf('testOnly'),
      usesCleartextTraffic: boolOf('usesCleartextTraffic'),
      extractNativeLibs: boolOf('extractNativeLibs'),
      permissions: strings('permissions'),
      features: strings('features'),
      activityCount: intOf('activityCount'),
      serviceCount: intOf('serviceCount'),
      receiverCount: intOf('receiverCount'),
      providerCount: intOf('providerCount'),
      abis: strings('abis'),
      nativeLibCount: intOf('nativeLibCount'),
      dexCount: intOf('dexCount'),
      dexBytes: intOf('dexBytes'),
      apkEntryCount: intOf('apkEntryCount'),
      apkUncompressedBytes: intOf('apkUncompressedBytes'),
      apkCompressedBytes: intOf('apkCompressedBytes'),
      hasResourcesArsc: boolOf('hasResourcesArsc'),
      hasManifest: boolOf('hasManifest'),
      hasV1Signature: boolOf('hasV1Signature'),
      hasMultipleSigners: boolOf('hasMultipleSigners'),
      hasPastSigningCertificates: boolOf('hasPastSigningCertificates'),
      signers: (m['signers'] as List?)
              ?.whereType<Map>()
              .map((e) => ApkSigner.fromMap(e.cast<String, dynamic>()))
              .toList(growable: false) ??
          const <ApkSigner>[],
      installed: boolOf('installed'),
      installedVersionCode: (m['installedVersionCode'] as num?)?.toInt() ?? -1,
      installedVersionName: m['installedVersionName'] as String? ?? '',
      sameSignerAsInstalled: boolOf('sameSignerAsInstalled'),
      icon: m['icon'] as Uint8List?,
    );
  }

  /// True when the APK can replace the installed app (same signer) and is a
  /// newer version — a heuristic for "update vs. reinstall".
  bool get canUpdateInstalled =>
      installed && sameSignerAsInstalled && versionCode > installedVersionCode;

  /// True when the signing certificate differs from the installed one, which
  /// blocks an in-place update.
  bool get conflictsWithInstalled =>
      installed && !sameSignerAsInstalled;
}
