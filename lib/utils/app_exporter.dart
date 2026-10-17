import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../models/app_info.dart';
import '../state/app_state.dart';
import 'format.dart';
import 'search.dart';

/// Which apps go into an exported list.
enum ExportScope {
  /// Whatever the app list currently shows: scope, filter, category and search.
  current,

  /// Every installed app.
  all,
  favorite,
  hasReason,
}

/// The file formats an exported list can take.
enum ExportFormat {
  markdown('md', 'text/markdown'),
  csv('csv', 'text/csv'),
  text('txt', 'text/plain');

  const ExportFormat(this.extension, this.mimeType);

  final String extension;
  final String mimeType;
}

/// One row of an exported app list. Flattened on purpose: formatting is a pure
/// function of these, so it can be tested without a widget tree.
class AppExportRow {
  const AppExportRow({
    required this.name,
    required this.packageName,
    required this.versionName,
    required this.versionCode,
    required this.sizeBytes,
    required this.installTime,
    required this.updateTime,
    required this.categories,
    required this.reason,
    required this.note,
    required this.installer,
    this.favorite = false,
    this.isSystem = false,
  });

  final String name;
  final String packageName;
  final String versionName;
  final int versionCode;
  final int sizeBytes;
  final int installTime;
  final int updateTime;
  final String categories;
  final String reason;
  final String note;
  final String installer;
  final bool favorite;
  final bool isSystem;
}

/// Builds the rows for [scope], in the same order the app list shows.
List<AppExportRow> exportRows(AppState state, ExportScope scope) {
  final List<AppInfo> apps = switch (scope) {
    ExportScope.current => state.visibleApps,
    ExportScope.all => List<AppInfo>.from(state.apps)
      ..sort(
        (a, b) => AppSearch.pinyinKey(
          state.displayNameFor(a.packageName),
        ).compareTo(AppSearch.pinyinKey(state.displayNameFor(b.packageName))),
      ),
    ExportScope.favorite => state.favorites,
    ExportScope.hasReason =>
      state.apps.where((a) => state.metaFor(a.packageName).reason.isNotEmpty).toList()
        ..sort(
          (a, b) => AppSearch.pinyinKey(
            state.displayNameFor(a.packageName),
          ).compareTo(AppSearch.pinyinKey(state.displayNameFor(b.packageName))),
        ),
  };

  return [
    for (final a in apps)
      () {
        final meta = state.metaFor(a.packageName);
        return AppExportRow(
          name: state.displayNameFor(a.packageName),
          packageName: a.packageName,
          versionName: a.versionName,
          versionCode: a.versionCode,
          sizeBytes: a.sizeBytes,
          installTime: a.firstInstallTime,
          updateTime: a.lastUpdateTime,
          categories: [
            for (final id in meta.categoryIds)
              if (state.categoryById(id) != null) state.categoryById(id)!.name,
          ].join('、'),
          reason: meta.reason,
          note: meta.note,
          installer: state.appFacts[a.packageName]?.installer ?? a.installer,
          favorite: meta.favorite,
          isSystem: a.isSystem,
        );
      }(),
  ];
}

/// Renders [rows] as the requested format. Pure: no I/O, no widgets.
String formatAppList(
  List<AppExportRow> rows,
  ExportFormat format, {
  required AppStrings strings,
  required String generatedAt,
  required String scopeLabel,
}) {
  switch (format) {
    case ExportFormat.markdown:
      final b = StringBuffer()
        ..writeln('# ${strings.t('囤囤 · 应用清单')}')
        ..writeln()
        ..writeln('${strings.t('导出时间')}：$generatedAt')
        ..writeln('${strings.t('范围')}：$scopeLabel')
        ..writeln(strings.t('共 {n} 个应用', {'n': rows.length}))
        ..writeln()
        ..writeln(
          '| ${strings.t('名称')} | ${strings.t('包名')} | ${strings.t('版本')} '
          '| ${strings.t('大小')} | ${strings.t('安装时间')} | ${strings.t('分类')} '
          '| ${strings.t('安装原因')} | ${strings.t('备注')} |',
        )
        ..writeln('| --- | --- | --- | --- | --- | --- | --- | --- |');
      for (final r in rows) {
        b.writeln(
          '| ${_md(r.favorite ? '⭐ ${r.name}' : r.name)} | ${_md(r.packageName)} '
          '| ${_md(_version(r))} | ${_md(Fmt.size(r.sizeBytes))} '
          '| ${_md(Fmt.dateTime(r.installTime))} | ${_md(r.categories)} '
          '| ${_md(r.reason)} | ${_md(r.note)} |',
        );
      }
      return b.toString();

    case ExportFormat.csv:
      final b = StringBuffer()
        ..writeln(
          [
            strings.t('名称'),
            strings.t('包名'),
            strings.t('版本'),
            strings.t('版本号'),
            strings.t('大小'),
            strings.t('大小（字节）'),
            strings.t('安装时间'),
            strings.t('更新时间'),
            strings.t('分类'),
            strings.t('安装原因'),
            strings.t('备注'),
            strings.t('收藏'),
            strings.t('系统应用'),
            strings.t('安装来源'),
          ].map(_csv).join(','),
        );
      for (final r in rows) {
        b.writeln(
          [
            r.name,
            r.packageName,
            r.versionName,
            '${r.versionCode}',
            Fmt.size(r.sizeBytes),
            '${r.sizeBytes}',
            Fmt.dateTime(r.installTime),
            Fmt.dateTime(r.updateTime),
            r.categories,
            r.reason,
            r.note,
            r.favorite ? '1' : '',
            r.isSystem ? '1' : '',
            r.installer,
          ].map(_csv).join(','),
        );
      }
      return b.toString();

    case ExportFormat.text:
      final b = StringBuffer()
        ..writeln(strings.t('囤囤 · 应用清单'))
        ..writeln('${strings.t('导出时间')}：$generatedAt')
        ..writeln('${strings.t('范围')}：$scopeLabel')
        ..writeln(strings.t('共 {n} 个应用', {'n': rows.length}))
        ..writeln();
      for (final r in rows) {
        b.writeln('${r.favorite ? '⭐ ' : ''}${r.name}');
        b.writeln(
          '    ${r.packageName}'
          '${r.versionName.isEmpty ? '' : ' · ${_version(r)}'}'
          '${r.sizeBytes > 0 ? ' · ${Fmt.size(r.sizeBytes)}' : ''}',
        );
        final facts = <String>[
          if (r.installTime > 0)
            strings.t('安装于 {date}', {'date': Fmt.dateTime(r.installTime)}),
          if (r.categories.isNotEmpty)
            strings.t('分类：{names}', {'names': r.categories}),
          if (r.installer.isNotEmpty)
            strings.t('安装来源：{installer}', {'installer': r.installer}),
        ];
        if (facts.isNotEmpty) b.writeln('    ${facts.join(' · ')}');
        if (r.reason.isNotEmpty) {
          b.writeln('    ${strings.t('原因')}：${_oneLine(r.reason)}');
        }
        if (r.note.isNotEmpty) {
          b.writeln('    ${strings.t('备注')}：${_oneLine(r.note)}');
        }
      }
      return b.toString();
  }
}

String _version(AppExportRow r) =>
    r.versionName.isEmpty ? '${r.versionCode}' : '${r.versionName} (${r.versionCode})';

/// Markdown table cell: pipes and newlines would break the table. The
/// backslash is escaped first, otherwise the one added for a pipe would be
/// escaped a second time and the pipe would split the cell again.
String _md(String text) =>
    _oneLine(text).replaceAll(r'\', r'\\').replaceAll('|', r'\|');

/// One line, no matter what the user typed into a note.
String _oneLine(String text) =>
    text.replaceAll('\r\n', ' ').replaceAll('\n', ' ').replaceAll('\r', ' ').trim();

/// CSV field: always quoted, so commas and Chinese punctuation are safe.
String _csv(String value) => '"${value.replaceAll('"', '""')}"';

/// Asks for a format and scope, then writes the list to a file the user picks.
Future<void> exportAppList(BuildContext context, AppState state) async {
  final s = AppStrings.current;
  final choice = await showDialog<(ExportScope, ExportFormat)>(
    context: context,
    builder: (ctx) => _ExportDialog(state: state),
  );
  if (choice == null || !context.mounted) return;
  final (scope, format) = choice;

  final messenger = ScaffoldMessenger.of(context);
  final now = DateTime.now();
  final rows = exportRows(state, scope);
  if (rows.isEmpty) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(s.t('这个范围里没有应用'))));
    return;
  }
  final text = formatAppList(
    rows,
    format,
    strings: s,
    generatedAt: Fmt.dateTime(now.millisecondsSinceEpoch),
    scopeLabel: exportScopeLabel(s, state, scope),
  );
  final name =
      'hamstapp_apps_${now.year}${_two(now.month)}${_two(now.day)}_'
      '${_two(now.hour)}${_two(now.minute)}.${format.extension}';

  try {
    // A BOM makes Excel open a UTF-8 CSV with Chinese text correctly.
    final bytes = Uint8List.fromList(
      format == ExportFormat.csv
          ? <int>[0xEF, 0xBB, 0xBF, ...utf8.encode(text)]
          : utf8.encode(text),
    );
    final uri = await FilePicker.saveFile(
      fileName: name,
      bytes: bytes,
      mimeType: format.mimeType,
      dialogTitle: s.t('导出应用清单'),
    );
    if (uri == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(s.t('已导出 {n} 个应用到 {name}', {
            'n': rows.length,
            'name': name,
          })),
        ),
      );
  } catch (e) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(s.t('导出失败：{error}', {'error': e}))),
      );
  }
}

String exportScopeLabel(AppStrings s, AppState state, ExportScope scope) {
  switch (scope) {
    case ExportScope.current:
      return s.t('当前筛选结果');
    case ExportScope.all:
      return s.t('全部应用');
    case ExportScope.favorite:
      return s.t('收藏');
    case ExportScope.hasReason:
      return s.t('有安装原因');
  }
}

String _two(int n) => n.toString().padLeft(2, '0');

class _ExportDialog extends StatefulWidget {
  const _ExportDialog({required this.state});

  final AppState state;

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  ExportScope _scope = ExportScope.current;
  ExportFormat _format = ExportFormat.markdown;

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final counts = <ExportScope, int>{
      for (final scope in ExportScope.values)
        scope: exportRows(widget.state, scope).length,
    };
    return AlertDialog(
      title: Text(s.t('导出应用清单')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              s.t('导出成一份可读的清单，带上分类、原因和备注。'),
              style: const TextStyle(fontSize: 12.5, height: 1.35),
            ),
            const SizedBox(height: 12),
            Text(
              s.t('范围'),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final scope in ExportScope.values)
                  ChoiceChip(
                    label: Text(
                      '${exportScopeLabel(s, widget.state, scope)}'
                      '（${counts[scope]}）',
                    ),
                    selected: _scope == scope,
                    onSelected: (_) => setState(() => _scope = scope),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              s.t('格式'),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              children: [
                for (final format in ExportFormat.values)
                  ChoiceChip(
                    label: Text(format.name.toUpperCase()),
                    selected: _format == format,
                    onSelected: (_) => setState(() => _format = format),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(s.t('取消')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, (_scope, _format)),
          child: Text(s.t('导出')),
        ),
      ],
    );
  }
}
