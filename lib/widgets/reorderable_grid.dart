import 'package:flutter/material.dart';

/// A grid whose cells can be dragged onto one another.
///
/// The standard reorderable widgets only handle lists, so this is the grid
/// counterpart: press and hold a cell, drag it onto the cell whose place it
/// should take. The callback receives adjusted indices, like
/// [ReorderableListView.onReorderItem].
class ReorderableGrid extends StatefulWidget {
  const ReorderableGrid({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    required this.onReorder,
    this.padding = const EdgeInsets.fromLTRB(16, 6, 16, 16),
    this.gridDelegate = const SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: 110,
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 0.82,
    ),
    this.feedbackSize = const Size(96, 112),
  });

  final int itemCount;
  final Widget Function(BuildContext context, int index) itemBuilder;
  final void Function(int oldIndex, int newIndex) onReorder;
  final EdgeInsets padding;
  final SliverGridDelegate gridDelegate;

  /// Size of the widget that follows the finger.
  final Size feedbackSize;

  @override
  State<ReorderableGrid> createState() => _ReorderableGridState();
}

class _ReorderableGridState extends State<ReorderableGrid> {
  /// Cell currently under the dragged item, highlighted as the drop target.
  int? _hover;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: widget.padding,
      gridDelegate: widget.gridDelegate,
      itemCount: widget.itemCount,
      itemBuilder: (context, i) {
        final cell = widget.itemBuilder(context, i);
        return DragTarget<int>(
          onWillAcceptWithDetails: (details) {
            if (details.data == i) return false;
            setState(() => _hover = i);
            return true;
          },
          onLeave: (_) {
            if (_hover == i) setState(() => _hover = null);
          },
          onAcceptWithDetails: (details) {
            final from = details.data;
            setState(() => _hover = null);
            if (from != i) widget.onReorder(from, i);
          },
          builder: (context, candidate, rejected) {
            return LongPressDraggable<int>(
              data: i,
              feedback: Material(
                type: MaterialType.transparency,
                child: SizedBox.fromSize(
                  size: widget.feedbackSize,
                  child: widget.itemBuilder(context, i),
                ),
              ),
              childWhenDragging: Opacity(opacity: 0.3, child: cell),
              onDragStarted: () => setState(() => _hover = i),
              onDragEnd: (_) => setState(() => _hover = null),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                decoration: BoxDecoration(
                  color: _hover == i
                      ? Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.14)
                      : null,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: cell,
              ),
            );
          },
        );
      },
    );
  }
}
