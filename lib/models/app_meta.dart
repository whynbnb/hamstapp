/// User generated metadata for an installed package.
class AppMeta {
  String packageName;
  String reason;
  String note;
  bool favorite;
  bool pinned;
  List<String> categoryIds;
  int firstSeenAt;

  /// Last known display name, kept even after the app is uninstalled.
  String lastKnownName;

  /// Why the user removed the app.
  String uninstallReason;

  /// Timestamp when the uninstall was detected; 0 means still installed.
  int uninstalledAt;

  /// Last time the app was launched from this app; 0 means never.
  int lastLaunchedAt;

  /// How many times the app was launched from this app.
  int launchCount;

  /// Which of the package's desktop entries to start ('' = the default one,
  /// asking the user first when there are several).
  String launchActivity;

  /// Which tile page this pinned app lives on ('' = default/first page).
  String tilePageId;

  /// Tile position/size on the 6-column board. col/row of -1 means auto.
  int tileCol;
  int tileRow;
  int tileW;
  int tileH;

  AppMeta({
    required this.packageName,
    this.reason = '',
    this.note = '',
    this.favorite = false,
    this.pinned = false,
    List<String>? categoryIds,
    int? firstSeenAt,
    this.lastKnownName = '',
    this.uninstallReason = '',
    this.uninstalledAt = 0,
    this.lastLaunchedAt = 0,
    this.launchCount = 0,
    this.launchActivity = '',
    this.tilePageId = '',
    this.tileCol = -1,
    this.tileRow = -1,
    this.tileW = 1,
    this.tileH = 1,
  })  : categoryIds = categoryIds ?? <String>[],
        firstSeenAt =
            firstSeenAt ?? DateTime.now().millisecondsSinceEpoch;

  factory AppMeta.fromMap(Map<String, dynamic> map) => AppMeta(
        packageName: map['packageName'] as String,
        reason: map['reason'] as String? ?? '',
        note: map['note'] as String? ?? '',
        favorite: map['favorite'] as bool? ?? false,
        pinned: map['pinned'] as bool? ?? false,
        categoryIds: (map['categoryIds'] as List?)?.cast<String>() ?? [],
        firstSeenAt: map['firstSeenAt'] as int?,
        lastKnownName: map['lastKnownName'] as String? ?? '',
        uninstallReason: map['uninstallReason'] as String? ?? '',
        uninstalledAt: map['uninstalledAt'] as int? ?? 0,
        lastLaunchedAt: map['lastLaunchedAt'] as int? ?? 0,
        launchCount: map['launchCount'] as int? ?? 0,
        launchActivity: map['launchActivity'] as String? ?? '',
        tilePageId: map['tilePageId'] as String? ?? '',
        tileCol: map['tileCol'] as int? ?? -1,
        tileRow: map['tileRow'] as int? ?? -1,
        tileW: map['tileW'] as int? ?? 1,
        tileH: map['tileH'] as int? ?? 1,
      );

  Map<String, dynamic> toMap() => {
        'packageName': packageName,
        'reason': reason,
        'note': note,
        'favorite': favorite,
        'pinned': pinned,
        'categoryIds': categoryIds,
        'firstSeenAt': firstSeenAt,
        'lastKnownName': lastKnownName,
        'uninstallReason': uninstallReason,
        'uninstalledAt': uninstalledAt,
        'lastLaunchedAt': lastLaunchedAt,
        'launchCount': launchCount,
        'launchActivity': launchActivity,
        'tilePageId': tilePageId,
        'tileCol': tileCol,
        'tileRow': tileRow,
        'tileW': tileW,
        'tileH': tileH,
      };

  bool get isUninstalled => uninstalledAt != 0;

  bool get hasUserData =>
      reason.isNotEmpty ||
      note.isNotEmpty ||
      favorite ||
      pinned ||
      categoryIds.isNotEmpty ||
      uninstallReason.isNotEmpty;
}
