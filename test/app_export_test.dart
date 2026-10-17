import 'package:flutter_test/flutter_test.dart';

import 'package:hamstapp/l10n/app_strings.dart';
import 'package:hamstapp/models/app_info.dart';
import 'package:hamstapp/models/category.dart';
import 'package:hamstapp/services/native_apps.dart';
import 'package:hamstapp/services/storage.dart';
import 'package:hamstapp/state/app_state.dart';
import 'package:hamstapp/utils/app_exporter.dart';

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
  versionName: '1.2',
  versionCode: 12,
  firstInstallTime: 1700000000000,
  lastUpdateTime: 1700000000000,
  isSystem: false,
  enabled: true,
  apkPath: '',
  sizeBytes: size,
  targetSdk: 34,
  minSdk: 24,
  uid: 1,
);

AppExportRow row(String name, {String note = '', String reason = ''}) =>
    AppExportRow(
      name: name,
      packageName: 'com.example.$name',
      versionName: '1.2',
      versionCode: 12,
      sizeBytes: 1024 * 1024,
      installTime: 1700000000000,
      updateTime: 1700000000000,
      categories: '工具',
      reason: reason,
      note: note,
      installer: 'com.store',
    );

void main() {
  const s = AppStrings('zh');

  group('App list export', () {
    test('markdown is a table with one row per app', () {
      final out = formatAppList(
        [row('微信'), row('相机')],
        ExportFormat.markdown,
        strings: s,
        generatedAt: '2026-10-17 15:30',
        scopeLabel: '全部应用',
      );
      expect(out, contains('# 囤囤 · 应用清单'));
      expect(out, contains('| 名称 | 包名 |'));
      expect(out, contains('| 微信 | com.example.微信 |'));
      expect(out, contains('| 相机 | com.example.相机 |'));
      expect(out, contains('共 2 个应用'));
      // Title, two heading rows, the count, a blank, two table headers and one
      // row per app.
      expect(out.trim().split('\n').length, 10);
    });

    test('markdown escapes pipes and flattens newlines in a note', () {
      final out = formatAppList(
        [row('A', note: 'first | second\nthird')],
        ExportFormat.markdown,
        strings: s,
        generatedAt: '',
        scopeLabel: '',
      );
      expect(out, contains(r'first \| second third'));
      expect(out.contains('\nthird'), isFalse);
      // A literal backslash is escaped too, so it cannot eat the escape.
      final slashed = formatAppList(
        [row('A', note: r'C:\path')],
        ExportFormat.markdown,
        strings: s,
        generatedAt: '',
        scopeLabel: '',
      );
      expect(slashed, contains(r'C:\\path'));
    });

    test('csv quotes every field so commas survive', () {
      final out = formatAppList(
        [row('A', reason: '需要，常用')],
        ExportFormat.csv,
        strings: s,
        generatedAt: '',
        scopeLabel: '',
      );
      final lines = out.trim().split('\n');
      expect(lines, hasLength(2));
      expect(lines.first, contains('"名称","包名","版本","版本号"'));
      expect(lines[1], contains('"需要，常用"'));
      // The row has exactly as many fields as the header.
      expect(lines[1].split('","').length, lines.first.split('","').length);
    });

    test('plain text keeps a readable block per app', () {
      final out = formatAppList(
        [row('微信', reason: '聊天', note: '家人\n同事')],
        ExportFormat.text,
        strings: s,
        generatedAt: '2026-10-17 15:30',
        scopeLabel: '收藏',
      );
      expect(out, contains('微信'));
      expect(out, contains('com.example.微信 · 1.2 (12)'));
      expect(out, contains('分类：工具'));
      expect(out, contains('原因：聊天'));
      expect(out, contains('备注：家人 同事'));
    });
  });

  group('Export scopes', () {
    AppState stateWith() {
      final state = AppState(_MemStorage())
        ..initialized = true
        ..apps = [app('com.a', 'A', size: 10), app('com.b', 'B'), app('com.c', 'C')]
        ..categories = [
          AppCategory(id: 'c1', name: '工具', colorValue: 0, emoji: '🧰'),
        ];
      state.metaFor('com.a').favorite = true;
      state.metaFor('com.b').reason = '工作用';
      state.metaFor('com.c').categoryIds = ['c1'];
      state.appFacts = {
        'com.a': const AppFacts(installer: 'com.store', permissions: ['p']),
      };
      return state;
    }

    test('"current" follows the list filter and search', () {
      final state = stateWith();
      expect(exportRows(state, ExportScope.all), hasLength(3));
      state.filter = AppFilter.favorite;
      expect(exportRows(state, ExportScope.current).single.name, 'A');
      state.filter = AppFilter.all;
      // Searching matches package names too, so pick a letter that only one
      // package carries.
      state.query = 'B';
      expect(exportRows(state, ExportScope.current).single.name, 'B');
    });

    test('the dedicated scopes select their own apps', () {
      final state = stateWith();
      expect(exportRows(state, ExportScope.favorite).single.name, 'A');
      expect(exportRows(state, ExportScope.hasReason).single.name, 'B');
    });

    test('a row carries the categories, the installer and the notes', () {
      final state = stateWith();
      final rows = exportRows(state, ExportScope.all);
      final c = rows.firstWhere((r) => r.name == 'C');
      expect(c.categories, '工具');
      expect(c.isSystem, isFalse);
      final a = rows.firstWhere((r) => r.name == 'A');
      expect(a.favorite, isTrue);
      expect(a.installer, 'com.store');
    });
  });
}
