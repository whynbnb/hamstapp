import 'package:flutter/widgets.dart';

/// Emits at most one haptic tick per user action on a pager or tab strip.
///
/// A single swipe (or tap) that changes the selected page/tab must produce
/// exactly one tick, no matter how many pages the drag or its settling fling
/// glides across. Emitting one tick per page boundary made fast swipes buzz
/// several times in a row ("连续震动"), because:
///
///  * a drag is delivered as a stream of [ScrollUpdateNotification]s, one per
///    frame, so `pixels / viewport` crosses several midpoints in one gesture;
///  * after the finger lifts, the fling keeps scrolling and the old code kept
///    treating it as a drag until the very last `ScrollEndNotification`.
///
/// The tick still fires as early as the gesture commits to a new page (when the
/// drag crosses the halfway point), so it stays immediate rather than waiting
/// for the snap to finish.
///
/// The callers feed a pager's [ScrollNotification]s through [handleScroll] and
/// its index changes through [indexChanged]/[tickNow]. The primitive methods
/// ([beginDrag], [dragTo], [endGesture]) are exposed so the state machine can be
/// tested without a widget tree.
class PagerHaptics {
  PagerHaptics(this.onTick);

  /// Called when a tick should be played, at most once per action.
  final VoidCallback onTick;

  /// Index the pager is currently on, as far as we last knew.
  int _current = 0;

  /// Number of pages in the pager, used to clamp drag predictions so an
  /// overscroll past the first/last page does not look like a page change.
  int _pageCount = 1;

  /// Whether a tick has already played for the in-progress action. Cleared when
  /// the gesture (including its settling fling) is fully over.
  bool _ticked = false;

  /// Whether the current scroll activity began as a finger drag.
  bool _dragging = false;

  /// Minimum per-frame ballistic movement (logical px) that counts as a flick
  /// strong enough to change the page.
  static const double _flickDelta = 6;

  /// Keep the drag prediction clamp in step with the pager's page count.
  void setPageCount(int count) {
    _pageCount = count < 1 ? 1 : count;
  }

  int _clamp(int index) {
    if (index < 0) return 0;
    final last = _pageCount - 1;
    return index > last ? last : index;
  }

  /// Sync to [index] without playing a tick (initial state, structural jumps).
  void align(int index) {
    _current = index;
    _ticked = false;
    _dragging = false;
  }

  /// The user directly selected [index] (e.g. tapped a chip): play one tick
  /// now, and arm the guard so the follow-up animation does not tick again.
  void tickNow(int index) {
    if (index == _current) return;
    _current = index;
    _ticked = true;
    onTick();
  }

  /// The controller's index changed (tap, swipe settling, or programmatic).
  ///
  /// Plays a tick only if this action has not ticked yet, which covers the case
  /// where the finger lifted before crossing a midpoint but the fling still
  /// lands on a different page.
  void indexChanged(int index) {
    if (index == _current) return;
    _current = index;
    if (_ticked) return;
    _ticked = true;
    onTick();
  }

  /// The user's finger started dragging the pager: arm one tick.
  void beginDrag() => _ticked = false;

  /// The drag currently predicts [nearest] as the target page. Ticks once, the
  /// first time the prediction differs from the current page.
  void dragTo(int nearest) {
    final target = _clamp(nearest);
    if (_ticked || target == _current) return;
    _ticked = true;
    onTick();
  }

  /// The gesture (drag + its settling fling) is fully over.
  void endGesture() {
    _ticked = false;
    _dragging = false;
  }

  /// Feed a horizontal scroll notification from the pager.
  void handleScroll(ScrollNotification n) {
    if (n is ScrollStartNotification) {
      // A new drag re-arms the guard; the ballistic phase (dragDetails == null)
      // must not, otherwise it would tick again while settling.
      if (n.dragDetails != null) {
        beginDrag();
        _dragging = true;
      }
    } else if (n is ScrollUpdateNotification) {
      final vp = n.metrics.viewportDimension;
      if (n.dragDetails != null) {
        // Finger down: tick as soon as the drag commits to another page.
        _dragging = true;
        if (_ticked || vp <= 0) return;
        dragTo((n.metrics.pixels / vp).round());
      } else {
        // First ballistic frame after the finger lifted. A quick flick will
        // change the page, so tick now rather than waiting for the settle
        // animation to reach the halfway point.
        if (_dragging && !_ticked && vp > 0) {
          final delta = n.scrollDelta ?? 0;
          if (delta.abs() >= _flickDelta) {
            // Mirror PageScrollPhysics: a flick nudges the page by half before
            // rounding, so this predicts the page it will actually settle on.
            final page = n.metrics.pixels / vp;
            final target = _clamp((page + (delta < 0 ? -0.5 : 0.5)).round());
            if (target != _current) {
              _ticked = true;
              onTick();
            }
          }
        }
        _dragging = false;
      }
    } else if (n is ScrollEndNotification) {
      // The settling fling finished: ready for the next action. The finger-up
      // event does not carry a drag end here, so only the final idle end clears.
      if (n.dragDetails == null) endGesture();
      _dragging = false;
    }
  }
}
