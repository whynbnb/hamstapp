import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:hamstapp/models/app_info.dart';
import 'package:hamstapp/models/app_meta.dart';
import 'package:hamstapp/models/snapshot.dart';
import 'package:hamstapp/models/tile.dart';
import 'package:hamstapp/models/tile_page.dart';
import 'package:hamstapp/services/custom_icons.dart';
import 'package:hamstapp/services/icon_cache.dart';
import 'package:hamstapp/services/storage.dart';
import 'package:hamstapp/state/app_state.dart';
import 'package:hamstapp/utils/app_health.dart';

class _MemStorage implements Storage {
  final Map<String, dynamic> _data = <String, dynamic>{};
  @override
  Future<dynamic> readJson(String name) async => _data[name];
  @override
  Future<void> writeJson(String name, dynamic data) async {
    _data[name] = data;
  }
}

AppInfo app(String pkg, String name, {int size = 0}) => AppInfo(
  packageName: pkg,
  appName: name,
  versionName: '1.0',
  versionCode: 1,
  firstInstallTime: 0,
  lastUpdateTime: 0,
  isSystem: false,
  enabled: true,
  apkPath: '',
  sizeBytes: size,
  targetSdk: 34,
  minSdk: 24,
  uid: 1,
);

/// A 1x1 transparent PNG.
final Uint8List tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6'
  'kgAAAABJRU5ErkJggg==',
);

AppState stateWith() => AppState(_MemStorage())
  ..initialized = true
  ..apps = [app('com.a', 'A'), app('com.b', 'B'), app('com.c', 'C')]
  ..tilePages = [TilePage(id: 'p1', name: 'P1', createdAt: 0)]
  ..currentTilePageIndex = 0;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Duplicate detection', () {
    test('the same name with different signers is risky', () {
      final report = analyzeHealth(
        apps: const [
          HealthApp(packageName: 'com.mm', name: '微信', signature: 'AA'),
          HealthApp(packageName: 'com.mm.fake', name: '微信', signature: 'BB'),
        ],
        cache: const [],
      );
      expect(report.duplicates, hasLength(1));
      expect(report.duplicates.single.signatureMismatch, isTrue);
      expect(report.riskyCount, 1);
    });

    test('the same name with one signer is just a variant', () {
      final report = analyzeHealth(
        apps: const [
          HealthApp(packageName: 'com.mm', name: '微信', signature: 'AA'),
          HealthApp(packageName: 'com.mm.beta', name: '微信', signature: 'AA'),
        ],
        cache: const [],
      );
      expect(report.duplicates.single.signatureMismatch, isFalse);
      expect(report.riskyCount, 0);
    });

    test('an unknown certificate forces no verdict', () {
      final report = analyzeHealth(
        apps: const [
          HealthApp(packageName: 'com.a', name: 'Same', signature: 'AA'),
          HealthApp(packageName: 'com.b', name: 'Same'),
        ],
        cache: const [],
      );
      // Only one side reported a certificate, so there is nothing to compare.
      expect(report.duplicates.single.signatureMismatch, isFalse);
    });

    test('different names are not grouped, and single versions are ignored', () {
      final report = analyzeHealth(
        apps: const [
          HealthApp(packageName: 'com.a', name: 'A'),
          HealthApp(packageName: 'com.b', name: 'B'),
        ],
        cache: const [
          CachedVersions(packageName: 'com.a', versions: [1], bytes: 10),
        ],
      );
      expect(report.duplicates, isEmpty);
    });

    test('several cached versions become a group', () {
      final report = analyzeHealth(
        apps: const [],
        cache: const [
          CachedVersions(packageName: 'com.a', versions: [3, 1, 2], bytes: 90),
        ],
      );
      expect(report.duplicates.single.kind, DuplicateKind.cachedVersions);
      expect(report.duplicates.single.versions, [1, 2, 3]);
      expect(report.duplicates.single.bytes, 90);
    });

    test('same signer and a close name is reported as a variant', () {
      final report = analyzeHealth(
        apps: const [
          HealthApp(
            packageName: 'com.tg',
            name: 'Telegram',
            signature: 'AA',
          ),
          HealthApp(
            packageName: 'com.tg.x',
            name: 'Telegram X',
            signature: 'AA',
          ),
          HealthApp(
            packageName: 'com.other',
            name: 'Something',
            signature: 'AA',
          ),
        ],
        cache: const [],
      );
      expect(
        report.duplicates.where((g) => g.kind == DuplicateKind.similarName),
        hasLength(1),
      );
      expect(report.duplicates.first.signatureMismatch, isFalse);
    });

    test('a shared signer alone is not enough', () {
      final report = analyzeHealth(
        apps: const [
          HealthApp(packageName: 'com.a', name: 'Maps', signature: 'AA'),
          HealthApp(packageName: 'com.b', name: 'Mail', signature: 'AA'),
        ],
        cache: const [],
      );
      expect(report.duplicates, isEmpty);
    });

    test('risky groups sort first', () {
      final report = analyzeHealth(
        apps: const [
          HealthApp(packageName: 'com.1', name: 'Alias', signature: 'AA'),
          HealthApp(packageName: 'com.2', name: 'Alias', signature: 'BB'),
          HealthApp(packageName: 'com.3', name: 'Beta', signature: 'CC'),
          HealthApp(packageName: 'com.4', name: 'Beta', signature: 'CC'),
        ],
        cache: const [],
      );
      expect(report.duplicates.first.signatureMismatch, isTrue);
    });
  });

  group('Hidden apps', () {
    test('a hidden app leaves the list but is kept in its own view', () async {
      final state = stateWith();
      expect(state.visibleApps.map((a) => a.appName), ['A', 'B', 'C']);

      await state.setHidden('com.b', true);
      expect(state.visibleApps.map((a) => a.appName), ['A', 'C']);
      expect(state.hiddenApps.single.packageName, 'com.b');

      state.filter = AppFilter.hidden;
      expect(state.visibleApps.map((a) => a.appName), ['B']);

      // Nothing else about the app is lost.
      state.metaFor('com.b').reason = '留着';
      expect(state.metaFor(state.hiddenApps.single.packageName).reason, isNotEmpty);

      await state.setHidden('com.b', false);
      state.filter = AppFilter.all;
      expect(state.visibleApps, hasLength(3));
      expect(state.metaFor('com.b').reason, '留着');
    });

    test('hiding means the app is sorted out, not neglected', () {
      final meta = AppMeta(packageName: 'com.a')..hidden = true;
      expect(AppState.isUnorganized(meta), isFalse);
      expect(meta.hasUserData, isTrue);
    });

    test('the hidden flag survives a storage round trip', () {
      final meta = AppMeta(packageName: 'com.a')
        ..hidden = true
        ..customIcon = 'custom';
      final restored = AppMeta.fromMap(meta.toMap());
      expect(restored.hidden, isTrue);
      expect(restored.customIcon, 'custom');
    });
  });

  group('Custom icons', () {
    test('base64 round trip keeps every icon', () {
      CustomIcons.instance.replaceAll({'com.a': tinyPng});
      final restored = CustomIcons.fromBase64(CustomIcons.instance.toBase64());
      expect(restored['com.a'], tinyPng);
      // Broken entries are skipped, not fatal.
      expect(CustomIcons.fromBase64({'com.b': 'not-base64!!'}), isEmpty);
      expect(CustomIcons.fromBase64(null), isEmpty);
    });

    test('a chosen icon is shrunk, stored and marked', () async {
      final state = stateWith();
      final ok = await state.setCustomIcon('com.a', tinyPng);
      expect(ok, isTrue);
      expect(CustomIcons.instance.has('com.a'), isTrue);
      expect(state.metaFor('com.a').customIcon, isNotEmpty);

      await state.clearCustomIcon('com.a');
      expect(CustomIcons.instance.has('com.a'), isFalse);
      expect(state.metaFor('com.a').customIcon, isEmpty);
    });

    test('rubbish bytes are rejected without touching the icon', () async {
      final state = stateWith();
      final ok = await state.setCustomIcon(
        'com.a',
        Uint8List.fromList([1, 2, 3]),
      );
      expect(ok, isFalse);
      expect(CustomIcons.instance.has('com.a'), isFalse);
    });
  });

  group('Appearance and behaviour settings', () {
    test('font scale is clamped and persisted', () async {
      final state = stateWith();
      expect(state.fontScale, 1.0);
      await state.setFontScale(5);
      expect(state.fontScale, 1.6);
      await state.setFontScale(0.2);
      expect(state.fontScale, 0.8);
    });

    test('layout lock leaves edit mode and is remembered', () async {
      final state = stateWith();
      state.setTileEditMode(true);
      await state.setLayoutLocked(true);
      expect(state.layoutLocked, isTrue);
      expect(state.tileEditMode, isFalse);
    });

    test('the auto-snapshot interval is clamped and off by default', () async {
      final state = stateWith();
      expect(state.autoSnapshotDays, 0);
      await state.setAutoSnapshotDays(500);
      expect(state.autoSnapshotDays, 90);
    });

    test('changing the icon pack clears the icon cache', () async {
      IconCache.instance.put('com.a', tinyPng);
      final state = stateWith();
      await state.setIconPack('com.pack');
      expect(state.iconPack, 'com.pack');
      expect(IconCache.instance.length, 0);
      expect(IconCache.instance.iconPack, 'com.pack');
      await state.setIconPack('');
      expect(IconCache.instance.iconPack, '');
    });
  });

  group('Merge import', () {
    Map<String, dynamic> package() => <String, dynamic>{
      'app': 'hamstapp',
      'version': 1,
      'data': <String, dynamic>{
        'meta': {
          'com.b': {'packageName': 'com.b', 'reason': '工作', 'note': '导入的'},
          'com.new': {'packageName': 'com.new', 'favorite': true},
        },
        'categories': [
          {'id': 'c1', 'name': '工具', 'colorValue': 1, 'emoji': '🧰'},
        ],
        'snapshots': [
          Snapshot(
            id: 's1',
            name: '导入快照',
            createdAt: 1,
            entries: const <SnapshotEntry>[],
          ).toMap(),
        ],
        'backup_lists': [
          {'id': 'b1', 'name': '清单', 'packageNames': <String>[]},
        ],
        'tiles': [
          Tile(id: 't1', packageName: 'com.new', pageId: 'p1').toMap(),
        ],
        'tile_pages': [
          TilePage(id: 'p1', name: 'P1', createdAt: 0).toMap(),
        ],
        'settings': {'theme_color': 123, 'brand_new_setting': true},
        'launch_log': [],
      },
    };

    test('the preview counts what is already here', () {
      final state = stateWith();
      // A scan gives every installed app a metadata entry; the preview counts
      // by that entry.
      for (final a in state.apps) {
        state.metaFor(a.packageName);
      }
      final preview = state.mergePreview(package());
      expect(preview['应用'], (2, 1)); // com.b exists, com.new does not
      expect(preview['分组'], (1, 0));
      expect(preview['磁贴'], (1, 0));
    });

    test('merging keeps local annotations and adds what is missing', () async {
      final state = stateWith();
      // Local content wins where both sides have something.
      state.metaFor('com.b')
        ..note = '本地的'
        ..reason = '';

      final counts = await state.mergePackage(package());

      final b = state.metaFor('com.b');
      expect(b.note, '本地的'); // local wins
      expect(b.reason, '工作'); // filled in
      expect(state.metaFor('com.new').favorite, isTrue);
      expect(state.categoryById('c1')?.name, '工具');
      expect(state.snapshots.map((s) => s.id), contains('s1'));
      expect(state.tiles.map((t) => t.id), contains('t1'));
      expect(state.settings['brand_new_setting'], isTrue);
      expect(counts['应用'], 2);
      expect(counts['分组'], 1);
    });

    test('a second merge does not duplicate anything', () async {
      final state = stateWith();
      await state.mergePackage(package());
      final counts = await state.mergePackage(package());
      expect(state.snapshots.where((s) => s.id == 's1'), hasLength(1));
      expect(state.tiles.where((t) => t.id == 't1'), hasLength(1));
      expect(state.categories.where((c) => c.id == 'c1'), hasLength(1));
      expect(counts['分组'], 0);
      expect(counts['磁贴'], 0);
    });

    test('a wrong package is rejected before touching anything', () async {
      final state = stateWith();
      expect(
        () => state.mergePackage({'app': 'other'}),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('Tile batch operations', () {
    AppState withTiles() => stateWith()
      ..tiles = [
        Tile(id: 'a', packageName: 'com.a', pageId: 'p1', col: 0, row: 0),
        Tile(id: 'b', packageName: 'com.b', pageId: 'p1', col: 1, row: 0),
      ];

    test('combining two app tiles makes a folder with both', () async {
      final state = withTiles();
      final folderId = await state.combineIntoFolder('a', 'b');
      expect(folderId, isNotNull);
      final folder = state.tileById(folderId!);
      expect(folder?.kind, TileKind.folder);
      expect(folder?.optionList('apps'), containsAll(['com.a', 'com.b']));
      expect(state.tiles.where((t) => t.kind == TileKind.app), isEmpty);
      // A folder is big enough to show a grid.
      expect(folder!.w, greaterThanOrEqualTo(2));
      expect(folder.h, greaterThanOrEqualTo(2));
    });

    test('dropping onto an existing folder adds the app', () async {
      final state = stateWith()
        ..tiles = [
          Tile(
            id: 'f',
            packageName: '',
            pageId: 'p1',
            kind: TileKind.folder,
            col: 0,
            row: 0,
            w: 2,
            h: 2,
            options: {
              'apps': <String>['com.a'],
            },
          ),
          Tile(id: 'b', packageName: 'com.b', pageId: 'p1', col: 2, row: 0),
        ];
      final id = await state.combineIntoFolder('b', 'f');
      expect(id, 'f');
      expect(state.tileById('f')!.optionList('apps'), ['com.a', 'com.b']);
    });

    test('a category folder cannot take extra apps', () async {
      final state = stateWith()
        ..tiles = [
          Tile(
            id: 'f',
            packageName: '',
            pageId: 'p1',
            kind: TileKind.folder,
            options: {'category': 'c1'},
          ),
          Tile(id: 'b', packageName: 'com.b', pageId: 'p1'),
        ];
      expect(await state.combineIntoFolder('b', 'f'), isNull);
      expect(state.tiles, hasLength(2));
    });

    test('several tiles are removed and moved at once', () async {
      final state = withTiles()
        ..tilePages.add(TilePage(id: 'p2', name: 'P2', createdAt: 0));

      await state.moveTilesToPage(['a', 'b'], 'p2');
      expect(state.tileById('a')?.pageId, 'p2');
      expect(state.tileById('b')?.pageId, 'p2');

      await state.removeTiles(['a', 'b']);
      expect(state.tiles, isEmpty);
    });

    test('copying a page duplicates its tiles onto a new page', () async {
      final state = withTiles();
      final copy = await state.copyTilePage('p1');
      expect(copy, isNotNull);
      expect(state.tilePages, hasLength(2));
      final copied = state.tiles.where((t) => t.pageId == copy!.id).toList();
      expect(copied, hasLength(2));
      expect(copied.map((t) => t.packageName), containsAll(['com.a', 'com.b']));
      // The originals stay where they were.
      expect(state.tiles.where((t) => t.pageId == 'p1'), hasLength(2));
    });
  });
}
