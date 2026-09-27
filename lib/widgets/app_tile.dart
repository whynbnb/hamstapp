import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../models/app_info.dart';
import '../models/category.dart';
import '../state/app_state.dart';
import '../utils/actions.dart';
import '../utils/format.dart';
import 'app_icon.dart';

class AppListTile extends StatelessWidget {
  const AppListTile({
    super.key,
    required this.app,
    required this.state,
    this.onTap,
    this.trailing,
    this.showCategories = true,
    this.showSortFact = false,
  });

  final AppInfo app;
  final AppState state;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool showCategories;

  /// When true, the value of the field the list is currently sorted by is
  /// shown under the name (install time, update time, size...).
  final bool showSortFact;

  /// The sort key's value for this app, or null for an alphabetical sort where
  /// the name itself (already the title) is the sort element.
  String? _sortFact(BuildContext context) {
    if (!showSortFact) return null;
    final s = context.strings;
    switch (state.sort) {
      case AppSort.name:
        return null;
      case AppSort.installTime:
        return s.t('安装于 {date}', {'date': Fmt.day(app.firstInstallTime)});
      case AppSort.updateTime:
        return s.t('更新于 {ago}', {'ago': Fmt.relative(app.lastUpdateTime)});
      case AppSort.size:
        return s.t('大小 {size}', {'size': Fmt.size(app.sizeBytes)});
    }
  }

  @override
  Widget build(BuildContext context) {
    final meta = state.metaFor(app.packageName);
    final cats = state.categories
        .where((c) => meta.categoryIds.contains(c.id))
        .toList();
    final fact = _sortFact(context);

    final subtitleParts = <String>[
      if (app.versionName.isNotEmpty) 'v${app.versionName}',
      if (app.isSystem) context.strings.t('系统'),
    ];

    return ListTile(
      onTap: onTap,
      leading: AppIcon(
        packageName: app.packageName,
        label: app.appName,
        size: 46,
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              app.appName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          if (meta.favorite)
            const Padding(
              padding: EdgeInsets.only(left: 4),
              child: Icon(Icons.star_rounded, size: 16, color: Colors.amber),
            ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            subtitleParts.join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
          if (fact != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                fact,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          if (meta.reason.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '💡 ${meta.reason}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
              ),
            ),
          if (showCategories && cats.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                children: cats.map((c) => CategoryChip(category: c)).toList(),
              ),
            ),
        ],
      ),
      trailing: trailing ?? _defaultTrailing(context),
    );
  }

  Widget _defaultTrailing(BuildContext context) {
    final meta = state.metaFor(app.packageName);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: meta.favorite
              ? context.strings.t('取消收藏')
              : context.strings.t('添加收藏'),
          icon: Icon(
            meta.favorite ? Icons.star_rounded : Icons.star_border_rounded,
            color: meta.favorite ? Colors.amber : Colors.grey,
          ),
          onPressed: () => state.updateMeta(app.packageName, favorite: !meta.favorite),
        ),
        IconButton(
          tooltip: context.strings.t('启动'),
          icon: const Icon(Icons.rocket_launch_outlined, size: 20),
          onPressed: () => launchApp(context, app.packageName),
        ),
      ],
    );
  }
}

class CategoryChip extends StatelessWidget {
  const CategoryChip({super.key, required this.category, this.onDeleted});

  final AppCategory category;
  final VoidCallback? onDeleted;

  @override
  Widget build(BuildContext context) {
    final color = Color(category.colorValue);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${category.emoji} ${category.name}',
              style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600)),
          if (onDeleted != null) ...[
            const SizedBox(width: 4),
            GestureDetector(
              onTap: onDeleted,
              child: Icon(Icons.close, size: 13, color: color),
            ),
          ],
        ],
      ),
    );
  }
}

String installedSummary(AppInfo app) => AppStrings.current.t(
  '安装于 {date} · 更新于 {ago}',
  {'date': Fmt.day(app.firstInstallTime), 'ago': Fmt.relative(app.lastUpdateTime)},
);
