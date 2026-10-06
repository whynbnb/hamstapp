import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../models/tile_page.dart';
import '../state/app_state.dart';

/// Asks the user to confirm deleting a tile page. Returns true when confirmed.
Future<bool> confirmDeleteTilePage(
  BuildContext context,
  AppState state,
  TilePage page,
) async {
  final s = context.strings;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(s.t('删除页面')),
      content: Text(
        s.t('将删除「{name}」，页面上的磁贴会移回第一页。确定删除吗？', {
          'name': page.name,
        }),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(s.t('取消')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(s.t('删除')),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// Manages the tile pages (the bottom sub-tabs): rename them and change their
/// order. Reached from the tile board's edit mode.
class TilePagesScreen extends StatelessWidget {
  const TilePagesScreen({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          s.t('磁贴页管理'),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          final pages = state.tilePages;
          return ReorderableListView.builder(
            buildDefaultDragHandles: false,
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: pages.length,
            onReorderItem: state.reorderTilePage,
            itemBuilder: (context, i) {
              final page = pages[i];
              return ListTile(
                key: ValueKey(page.id),
                leading: ReorderableDragStartListener(
                  index: i,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4),
                    child: Icon(Icons.drag_handle),
                  ),
                ),
                title: Text(
                  page.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  s.t('{n} 个磁贴', {'n': state.pinCountOnPage(page)}),
                ),
                onTap: () => _rename(context, page),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: s.t('重命名页面'),
                      icon: const Icon(Icons.drive_file_rename_outline),
                      onPressed: () => _rename(context, page),
                    ),
                    IconButton(
                      tooltip: s.t('删除页面'),
                      icon: const Icon(Icons.delete_outline),
                      onPressed: pages.length > 1
                          ? () => _delete(context, page)
                          : null,
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _rename(BuildContext context, TilePage page) async {
    final s = context.strings;
    final controller = TextEditingController(text: page.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.t('重命名页面')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: s.t('页面名称')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(s.t('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(s.t('保存')),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      await state.renameTilePage(page.id, name);
    }
  }

  Future<void> _delete(BuildContext context, TilePage page) async {
    // Second confirmation before deleting a page.
    if (await confirmDeleteTilePage(context, state, page)) {
      await state.deleteTilePage(page.id);
    }
  }
}
