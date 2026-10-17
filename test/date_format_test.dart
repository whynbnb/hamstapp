import 'package:flutter_test/flutter_test.dart';

import 'package:hamstapp/services/storage.dart';
import 'package:hamstapp/state/app_state.dart';
import 'package:hamstapp/utils/format.dart';

class _MemStorage implements Storage {
  final Map<String, dynamic> _data = <String, dynamic>{};
  @override
  Future<dynamic> readJson(String name) async => _data[name];
  @override
  Future<void> writeJson(String name, dynamic data) async {
    _data[name] = data;
  }
}

void main() {
  tearDown(() {
    Fmt.dateStyle = DateStyle.ymdDash;
    Fmt.clock24h = true;
  });

  test('every style formats a date the way it is written', () {
    final at = DateTime(2026, 10, 17, 9, 5).millisecondsSinceEpoch;
    for (final (style, full, short) in const [
      (DateStyle.ymdDash, '2026-10-17', '10-17'),
      (DateStyle.ymdSlash, '2026/10/17', '10/17'),
      (DateStyle.mdySlash, '10/17/2026', '10/17'),
      (DateStyle.dmySlash, '17/10/2026', '17/10'),
      (DateStyle.chinese, '2026年10月17日', '10月17日'),
    ]) {
      Fmt.dateStyle = style;
      expect(Fmt.day(at), full, reason: style.name);
      expect(Fmt.shortDate(at), short, reason: style.name);
    }
  });

  test('the time format follows the 24-hour switch', () {
    final at = DateTime(2026, 10, 17, 9, 5).millisecondsSinceEpoch;
    Fmt.clock24h = true;
    expect(Fmt.clock(at), '09:05');
    expect(Fmt.dateTime(at), '2026-10-17 09:05');
    Fmt.clock24h = false;
    expect(Fmt.clock(at), '9:05 AM');
    expect(Fmt.dateTime(at), '2026-10-17 9:05 AM');
  });

  test('unknown stored values fall back to the defaults', () {
    expect(DateStyle.byName('nonsense'), DateStyle.ymdDash);
    expect(DateStyle.byName(null), DateStyle.ymdDash);
  });

  test('the setting persists and is applied again on startup', () async {
    final storage = _MemStorage();
    final state = AppState(storage)..initialized = true;
    await state.setDateStyle(DateStyle.dmySlash);
    await state.setClock24h(false);
    expect(Fmt.dateStyle, DateStyle.dmySlash);
    expect(Fmt.clock24h, isFalse);

    // A fresh instance reads it back and pushes it into Fmt, which is what
    // every screen and tile formats with.
    Fmt.dateStyle = DateStyle.ymdDash;
    Fmt.clock24h = true;
    final reopened = AppState(storage);
    await reopened.init();
    expect(reopened.dateStyle, DateStyle.dmySlash);
    expect(reopened.clock24h, isFalse);
    expect(Fmt.dateStyle, DateStyle.dmySlash);
    expect(Fmt.clock24h, isFalse);
  });
}
