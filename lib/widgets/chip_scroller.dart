import 'package:flutter/material.dart';

/// A fixed-height, horizontally scrolling row of chips.
///
/// Long chip lists (e.g. categories) would otherwise wrap onto several lines
/// and grow the surrounding layout vertically. Constraining to one line that
/// scrolls sideways keeps things compact.
class ChipScroller extends StatelessWidget {
  const ChipScroller({super.key, required this.children, this.spacing = 8});

  final List<Widget> children;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: children.length,
        separatorBuilder: (context, index) => SizedBox(width: spacing),
        itemBuilder: (context, index) => children[index],
      ),
    );
  }
}
