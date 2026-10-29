import 'package:flutter/material.dart';

import 'app_icon.dart';

/// The icon-over-name cell shared by the favorites grid and a category's grid
/// view (and by the draggable grid).
class AppIconTile extends StatelessWidget {
  const AppIconTile({
    super.key,
    required this.packageName,
    required this.label,
    this.onTap,
    this.onLongPress,
    this.iconSize = 56,
  });

  final String packageName;
  final String label;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AppIcon(packageName: packageName, label: label, size: iconSize),
          const SizedBox(height: 8),
          Text(
            label,
            maxLines: 2,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }
}
