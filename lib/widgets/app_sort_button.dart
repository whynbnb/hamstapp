import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../state/app_state.dart';

/// A compact "sort by … ↑/↓" menu.
///
/// Shared by a category's app list and the favorites tab. The same stored order
/// drives the collection widget, so all three agree.
class AppSortButton extends StatelessWidget {
  const AppSortButton({
    super.key,
    required this.sort,
    required this.ascending,
    required this.onChanged,
    this.manual = false,
    this.onManual,
  });

  final AppSort sort;
  final bool ascending;
  final void Function(AppSort sort, bool ascending) onChanged;

  /// When the collection can also be ordered by hand (favorites), this shows a
  /// 「手动排序」 entry and reports it as the current order.
  final bool manual;
  final VoidCallback? onManual;

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final label = manual ? s.t('手动排序') : _label(s, sort);
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return PopupMenuButton<String>(
      tooltip: s.t('排序'),
      onSelected: (value) {
        if (value == 'manual') {
          onManual?.call();
          return;
        }
        if (value == 'dir') {
          onChanged(sort, !ascending);
          return;
        }
        final picked = AppSort.values.firstWhere((e) => e.name == value);
        onChanged(
          picked,
          picked == sort ? ascending : defaultAscending(picked),
        );
      },
      itemBuilder: (_) => [
        if (onManual != null)
          CheckedPopupMenuItem<String>(
            value: 'manual',
            checked: manual,
            child: Text(s.t('手动排序')),
          ),
        for (final value in AppSort.values)
          CheckedPopupMenuItem<String>(
            value: value.name,
            checked: !manual && value == sort,
            child: Text(_label(s, value)),
          ),
        if (!manual) ...[
          const PopupMenuDivider(),
          PopupMenuItem<String>(
            value: 'dir',
            child: Text(ascending ? s.t('改为降序') : s.t('改为升序')),
          ),
        ],
      ],
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 10, 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              manual
                  ? Icons.drag_indicator
                  : (ascending
                        ? Icons.arrow_upward
                        : Icons.arrow_downward),
              size: 14,
              color: color,
            ),
            const SizedBox(width: 3),
            Text(
              manual
                  ? label
                  : '$label · ${ascending ? s.t('升序') : s.t('降序')}',
              style: TextStyle(fontSize: 12.5, color: color),
            ),
          ],
        ),
      ),
    );
  }

  static String _label(AppStrings s, AppSort sort) => switch (sort) {
    AppSort.name => s.t('按名称'),
    AppSort.installTime => s.t('按安装时间'),
    AppSort.updateTime => s.t('按更新时间'),
    AppSort.size => s.t('按大小'),
  };

  /// The same default direction the app list uses: names A→Z, dates and sizes
  /// newest/largest first.
  static bool defaultAscending(AppSort sort) => switch (sort) {
    AppSort.name => true,
    AppSort.installTime => false,
    AppSort.updateTime => false,
    AppSort.size => false,
  };
}
