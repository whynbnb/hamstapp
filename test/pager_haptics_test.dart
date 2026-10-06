import 'package:flutter_test/flutter_test.dart';

import 'package:hamstapp/utils/pager_haptics.dart';

/// A tick counter plus helper to build a [PagerHaptics] around it.
({PagerHaptics haptics, int Function() count}) _make() {
  var ticks = 0;
  final h = PagerHaptics(() => ticks++)..setPageCount(1000);
  return (haptics: h, count: () => ticks);
}

void main() {
  group('PagerHaptics', () {
    test('a multi-page swipe ticks exactly once', () {
      final m = _make();
      m.haptics.align(0);

      m.haptics.beginDrag();
      m.haptics.dragTo(1); // crosses the first midpoint -> the one tick
      m.haptics.dragTo(2); // same gesture, gliding on -> no tick
      m.haptics.dragTo(3);
      m.haptics.indexChanged(3); // settling on the final page -> no tick
      m.haptics.endGesture();

      expect(m.count(), 1);
    });

    test('a fling that lands without crossing mid-drag still ticks once', () {
      final m = _make();
      m.haptics.align(0);

      m.haptics.beginDrag();
      m.haptics.dragTo(0); // finger never crossed the halfway point
      // The fling reports the pages it glides across as index changes.
      m.haptics.indexChanged(1); // first change -> the one tick
      m.haptics.indexChanged(2);
      m.haptics.indexChanged(3);
      m.haptics.endGesture();

      expect(m.count(), 1);
    });

    test('a drag that never changes page does not tick', () {
      final m = _make();
      m.haptics.align(2);

      m.haptics.beginDrag();
      m.haptics.dragTo(2);
      m.haptics.dragTo(2);
      m.haptics.indexChanged(2);
      m.haptics.endGesture();

      expect(m.count(), 0);
    });

    test('separate actions each tick once', () {
      final m = _make();
      m.haptics.align(0);

      // Swipe 0 -> 2, crossing a midpoint.
      m.haptics.beginDrag();
      m.haptics.dragTo(1);
      m.haptics.dragTo(2);
      m.haptics.indexChanged(2);
      m.haptics.endGesture();
      expect(m.count(), 1);

      // Then swipe back 2 -> 0.
      m.haptics.beginDrag();
      m.haptics.dragTo(1);
      m.haptics.dragTo(0);
      m.haptics.indexChanged(0);
      m.haptics.endGesture();
      expect(m.count(), 2);
    });

    test('a chip tap ticks now and its animation does not tick again', () {
      final m = _make();
      m.haptics.align(0);

      m.haptics.tickNow(3); // the tap itself
      // animateToPage glides the controller through every intermediate page.
      m.haptics.indexChanged(1);
      m.haptics.indexChanged(2);
      m.haptics.indexChanged(3);
      m.haptics.endGesture();

      expect(m.count(), 1);
    });

    test('two taps each tick once', () {
      final m = _make();
      m.haptics.align(0);

      m.haptics.tickNow(2);
      m.haptics.endGesture();
      m.haptics.tickNow(0);
      m.haptics.endGesture();

      expect(m.count(), 2);
    });

    test('aligning silently does not tick', () {
      final m = _make();
      m.haptics.align(0);
      m.haptics.align(3);
      m.haptics.indexChanged(3);
      expect(m.count(), 0);
    });

    test('a tap on the current page does not tick', () {
      final m = _make();
      m.haptics.align(1);
      m.haptics.tickNow(1);
      expect(m.count(), 0);
    });

    test('overscrolling past the first/last page does not tick', () {
      final m = _make();

      m.haptics
        ..align(0)
        ..setPageCount(3);
      m.haptics.beginDrag();
      m.haptics.dragTo(-1); // dragged right, past the first page
      m.haptics.dragTo(0);
      m.haptics.endGesture();
      expect(m.count(), 0);

      m.haptics
        ..align(2)
        ..setPageCount(3);
      m.haptics.beginDrag();
      m.haptics.dragTo(3); // dragged left, past the last page
      m.haptics.indexChanged(2);
      m.haptics.endGesture();
      expect(m.count(), 0);
    });
  });
}
