import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../models/remote_source.dart';
import '../services/remote_client.dart';
import '../state/app_state.dart';
import 'format.dart';

String _two(int n) => n.toString().padLeft(2, '0');

String _stamp(DateTime now) =>
    '${now.year}${_two(now.month)}${_two(now.day)}_'
    '${_two(now.hour)}${_two(now.minute)}';

/// Export the full data package to a user-chosen file.
Future<void> exportData(BuildContext context, AppState state) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final pkg = state.exportPackage();
    final json = const JsonEncoder.withIndent('  ').convert(pkg);
    final name = 'hamstapp_${_stamp(DateTime.now())}.json';
    final uri = await FilePicker.saveFile(
      fileName: name,
      bytes: Uint8List.fromList(utf8.encode(json)),
      mimeType: 'application/json',
      dialogTitle: AppStrings.current.t('导出囤囤数据'),
    );
    if (uri == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(AppStrings.current.t('已导出数据包'))),
      );
  } catch (e) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            AppStrings.current.t('导出失败：{error}', {'error': e}),
          ),
        ),
      );
  }
}

/// Import a data package. Shows what it holds first, and lets the user merge it
/// into the current data or replace everything.
Future<void> importData(BuildContext context, AppState state) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final files = await FilePicker.pickFiles(
      dialogTitle: AppStrings.current.t('选择囤囤数据包'),
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (files.isEmpty) return;
    final bytes = await files.first.readAsBytes();
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) {
      throw FormatException(
        AppStrings.current.t('文件内容不是有效的数据包'),
      );
    }
    if (!context.mounted) return;
    await confirmAndImport(
      context,
      state,
      decoded.cast<String, dynamic>(),
    );
  } catch (e) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            AppStrings.current.t(
              '导入失败：{error}（本地数据未改动）',
              {'error': e},
            ),
          ),
        ),
      );
  }
}

/// The import preview: what the package holds, how much of it is already here,
/// and the choice between merging and replacing.
Future<void> confirmAndImport(
  BuildContext context,
  AppState state,
  Map<String, dynamic> pkg,
) async {
  final s = AppStrings.current;
  if (pkg['app'] != 'hamstapp') {
    throw FormatException(s.t('这不是囤囤导出的数据包'));
  }
  final messenger = ScaffoldMessenger.of(context);
  final counts = state.packageCounts(pkg);
  final preview = state.mergePreview(pkg);
  final summary = counts.entries.map((e) => '${e.key} ${e.value}').join(' · ');

  final choice = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(s.t('导入数据')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(s.t('数据包内容：{summary}', {'summary': summary})),
            const SizedBox(height: 10),
            for (final entry in preview.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  '${entry.key}：${entry.value.$1}'
                  '${entry.value.$2 > 0 ? '（已存在 ${entry.value.$2}）' : ''}',
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
            const SizedBox(height: 12),
            Text(
              s.t(
                '合并会保留现在的一切，只补充本机缺少的标注、分组、快照、备份列表、磁贴与图标；'
                '同一个应用两边都有内容时，保留本机的内容。',
              ),
              style: const TextStyle(fontSize: 12.5, height: 1.4),
            ),
            const SizedBox(height: 6),
            Text(
              s.t('清空并导入会先删掉现在的全部数据，再写入数据包，无法撤销。'),
              style: TextStyle(
                fontSize: 12.5,
                height: 1.4,
                color: Theme.of(ctx).colorScheme.error,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(s.t('取消')),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, 'merge'),
          child: Text(s.t('合并导入')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, 'replace'),
          child: Text(s.t('清空并导入')),
        ),
      ],
    ),
  );
  if (choice == null) return;

  if (choice == 'merge') {
    final added = await state.mergePackage(pkg);
    final text = added.entries.map((e) => '${e.key} ${e.value}').join(' · ');
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(s.t('已合并：{summary}', {'summary': text}))),
      );
    return;
  }

  await state.importPackage(pkg);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(s.t('导入完成'))));
}

/// Wipe all local data after a confirmation.
Future<void> clearData(BuildContext context, AppState state) async {
  final messenger = ScaffoldMessenger.of(context);
  final scheme = Theme.of(context).colorScheme;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(AppStrings.current.t('清空数据')),
      content: Text(
        AppStrings.current.t('将删除全部应用记录、分组、快照、备份列表、磁贴与设置，且无法恢复。确定吗？'),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AppStrings.current.t('取消'))),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: scheme.error),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(AppStrings.current.t('清空')),
        ),
      ],
    ),
  );
  if (ok != true) return;
  await state.clearAllData();
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(AppStrings.current.t('已清空数据'))));
}

// ---------------------------------------------------------------- WebDAV

/// Lets the user choose one of the configured WebDAV sources (null when there
/// are none or they cancelled).
Future<RemoteSource?> _pickWebdav(
  BuildContext context,
  AppState state,
) async {
  final s = AppStrings.current;
  final sources = state.syncSources.where((x) => x.isWebdav).toList();
  if (sources.isEmpty) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(s.t('还没有 WebDAV 源：先到「同步」里添加一个')),
          ),
        );
    }
    return null;
  }
  if (sources.length == 1) return sources.first;
  return showDialog<RemoteSource>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: Text(s.t('选择 WebDAV 源')),
      children: [
        for (final source in sources)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, source),
            child: Text(
              source.name.isEmpty ? source.host : source.name,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    ),
  );
}

/// Writes the whole data package into the source's directory as a JSON file.
Future<void> backupToWebdav(BuildContext context, AppState state) async {
  final s = AppStrings.current;
  final messenger = ScaffoldMessenger.of(context);
  final source = await _pickWebdav(context, state);
  if (source == null || !context.mounted) return;
  final name = 'hamstapp_backup_${_stamp(DateTime.now())}.json';
  try {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(s.t('正在备份到「{name}」…', {'name': source.name}))),
      );
    final json = const JsonEncoder.withIndent('  ').convert(
      state.exportPackage(),
    );
    final path = await RemoteClient.putText(source, name, json);
    await state.noteWebdavBackup(path, DateTime.now());
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(s.t('已备份：{name}', {'name': name}))),
      );
  } catch (e) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(s.t('备份失败：{error}', {'error': e}))),
      );
  }
}

/// Lists the backups in the source's directory and imports the chosen one,
/// through the same preview/merge dialog as a local import.
Future<void> restoreFromWebdav(BuildContext context, AppState state) async {
  final s = AppStrings.current;
  final messenger = ScaffoldMessenger.of(context);
  final source = await _pickWebdav(context, state);
  if (source == null || !context.mounted) return;
  try {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(s.t('正在读取备份列表…'))));
    final files = await RemoteClient.listBackups(source);
    if (!context.mounted) return;
    if (files.isEmpty) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(s.t('这个目录里没有囤囤的备份'))),
        );
      return;
    }
    final chosen = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(s.t('从 WebDAV 恢复')),
        children: [
          for (final file in files)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, file),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    (file['name'] as String?) ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    '${Fmt.size((file['size'] as num?)?.toInt() ?? 0)}'
                    ' · ${Fmt.dateTime((file['modified'] as num?)?.toInt() ?? 0)}',
                    style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    if (chosen == null || !context.mounted) return;
    final text = await RemoteClient.getText(
      source,
      (chosen['path'] as String?) ?? '',
    );
    final decoded = jsonDecode(text);
    if (decoded is! Map) {
      throw FormatException(s.t('文件内容不是有效的数据包'));
    }
    if (!context.mounted) return;
    await confirmAndImport(context, state, decoded.cast<String, dynamic>());
  } catch (e) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(s.t('恢复失败：{error}', {'error': e}))),
      );
  }
}
