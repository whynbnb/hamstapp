import 'package:flutter_test/flutter_test.dart';

import 'package:hamstapp/services/app_log.dart';

void main() {
  setUp(() => AppLog.instance.setEnabled(false));
  tearDown(() {
    AppLog.instance.setEnabled(false);
    AppLog.instance.clear();
  });

  test('is off by default and swallows everything', () {
    final log = AppLog.instance;
    expect(log.enabled, isFalse);
    log.log(LogModule.apps, 'should be ignored');
    log.error(LogModule.install, 'so should this');
    expect(log.isEmpty, isTrue);
    expect(log.exportText(), '(空)');
  });

  test('records and formats entries once enabled', () {
    final log = AppLog.instance
      ..setEnabled(true)
      ..clear();
    log.log(LogModule.apps, 'hello');
    log.warn(LogModule.sync, 'careful');
    log.error(LogModule.install, 'boom');

    expect(log.length, 3);
    final text = log.exportText();
    expect(text, contains('[INFO ] 应用扫描 | hello'));
    expect(text, contains('[WARN ] 同步 | careful'));
    expect(text, contains('[ERROR] 安装 | boom'));
  });

  test('keeps the newest entries when full', () {
    final log = AppLog.instance
      ..setEnabled(true)
      ..clear();
    log.log(LogModule.apps, 'first');
    for (var i = 0; i < AppLog.maxEntries; i++) {
      log.log(LogModule.apps, 'filler $i');
    }
    expect(log.length, AppLog.maxEntries);
    expect(log.exportText(), isNot(contains('first')));
  });

  test('filters by module, level and text', () {
    final log = AppLog.instance
      ..setEnabled(true)
      ..clear();
    log.log(LogModule.apps, 'scanned 12 apps');
    log.warn(LogModule.sync, 'download failed');
    log.error(LogModule.sync, 'download crashed');

    expect(log.modulesPresent(), [LogModule.apps, LogModule.sync]);
    expect(log.countFor(LogModule.sync), 2);
    expect(log.countFor(LogModule.launch), 0);

    expect(log.filtered(module: LogModule.sync).length, 2);
    expect(log.filtered(module: LogModule.apps).single.text, 'scanned 12 apps');

    expect(log.filtered(minLevel: LogLevel.warn).length, 2);
    expect(log.filtered(minLevel: LogLevel.error).single.text,
        'download crashed');

    expect(log.filtered(query: 'download').length, 2);
    expect(log.filtered(query: 'DOWN').length, 2, reason: 'case insensitive');
    expect(
      log.filtered(module: LogModule.sync, query: 'failed').single.level,
      LogLevel.warn,
    );
  });

  test('export matches the active filter', () {
    final log = AppLog.instance
      ..setEnabled(true)
      ..clear();
    log.log(LogModule.apps, 'scan line');
    log.log(LogModule.sync, 'sync line');

    expect(log.exportText(module: LogModule.apps), contains('scan line'));
    expect(log.exportText(module: LogModule.apps), isNot(contains('sync line')));
  });

  test('clear empties the log', () {
    final log = AppLog.instance
      ..setEnabled(true)
      ..clear();
    log.log(LogModule.apps, 'x');
    expect(log.isEmpty, isFalse);
    log.clear();
    expect(log.isEmpty, isTrue);
    expect(log.modulesPresent(), isEmpty);
  });
}
