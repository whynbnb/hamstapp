import 'package:flutter_test/flutter_test.dart';

import 'package:hamstapp/models/app_meta.dart';
import 'package:hamstapp/services/native_apps.dart';

void main() {
  group('AppMeta.launchActivity', () {
    test('defaults to the system entry', () {
      final meta = AppMeta(packageName: 'a.b');
      expect(meta.launchActivity, '');
      expect(AppMeta.fromMap(meta.toMap()).launchActivity, '');
    });

    test('is persisted', () {
      final meta = AppMeta(packageName: 'com.android.contacts')
        ..launchActivity = 'com.android.dialer.DialtactsActivity'
        ..launchEntryLabel = '电话'
        ..nameFollowsEntry = false;
      final back = AppMeta.fromMap(meta.toMap());
      expect(back.launchActivity, 'com.android.dialer.DialtactsActivity');
      expect(back.launchEntryLabel, '电话');
      expect(back.nameFollowsEntry, isFalse);
    });

    test('follows the entry name by default', () {
      expect(AppMeta(packageName: 'a.b').nameFollowsEntry, isTrue);
      expect(
        AppMeta.fromMap(<String, dynamic>{'packageName': 'a.b'})
            .nameFollowsEntry,
        isTrue,
      );
    });
  });

  group('LaunchOutcome', () {
    test('maps the native reason codes', () {
      expect(LaunchOutcome.byName('no_entry'), LaunchOutcome.noEntry);
      expect(LaunchOutcome.byName('disabled'), LaunchOutcome.disabled);
      expect(LaunchOutcome.byName('missing'), LaunchOutcome.missing);
      expect(LaunchOutcome.byName('blocked'), LaunchOutcome.blocked);
      expect(LaunchOutcome.byName(null), LaunchOutcome.unknown);
      expect(LaunchOutcome.byName('whatever'), LaunchOutcome.unknown);
    });

    test('only ok counts as success', () {
      expect(LaunchOutcome.ok.isOk, isTrue);
      expect(LaunchOutcome.noEntry.isOk, isFalse);
      expect(LaunchOutcome.unknown.isOk, isFalse);
    });
  });

  group('LaunchEntry', () {
    test('parses the native payload', () {
      final entry = LaunchEntry.fromMap({
        'name': 'com.android.dialer.DialtactsActivity',
        'label': '电话',
        'launcher': true,
      });
      expect(entry.name, 'com.android.dialer.DialtactsActivity');
      expect(entry.label, '电话');
      expect(entry.fromLauncher, isTrue);
    });

    test('entries found through an intent are not desktop icons', () {
      final entry = LaunchEntry.fromMap({
        'name': 'com.android.dialer.DialtactsActivity',
        'label': '电话',
        'launcher': false,
      });
      expect(entry.fromLauncher, isFalse);
    });
  });
}
