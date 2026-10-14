import 'package:flutter_test/flutter_test.dart';

import 'package:hamstapp/models/app_info.dart';
import 'package:hamstapp/services/storage.dart';
import 'package:hamstapp/state/app_state.dart';

class _MemStorage implements Storage {
  final Map<String, dynamic> _data = <String, dynamic>{};
  @override
  Future<dynamic> readJson(String name) async => _data[name];
  @override
  Future<void> writeJson(String name, dynamic data) async {
    _data[name] = data;
  }
}

AppInfo _app(String pkg, String name) => AppInfo(
  packageName: pkg,
  appName: name,
  versionName: '1',
  versionCode: 1,
  firstInstallTime: 0,
  lastUpdateTime: 0,
  isSystem: false,
  enabled: true,
  apkPath: '',
  sizeBytes: 0,
  targetSdk: 33,
  minSdk: 21,
  uid: 0,
);

void main() {
  test('the display name follows the pinned launcher entry', () async {
    final state = AppState(_MemStorage())
      ..apps = [_app('com.android.contacts', '联系人')];

    expect(state.displayNameFor('com.android.contacts'), '联系人');

    // 联系人 and 电话 are two entries of the same package; pinning the dialer
    // renames the app the way a launcher would.
    await state.updateMeta(
      'com.android.contacts',
      launchActivity: 'com.android.dialer.DialtactsActivity',
      launchEntryLabel: '电话',
    );
    expect(state.displayNameFor('com.android.contacts'), '电话');

    // Going back to "ask every time" restores the package's own name.
    await state.updateMeta('com.android.contacts', launchActivity: '');
    expect(state.displayNameFor('com.android.contacts'), '联系人');
  });

  test('an app can keep its own name while still pinning an entry', () async {
    final state = AppState(_MemStorage())
      ..apps = [_app('com.android.contacts', '联系人')];
    await state.updateMeta(
      'com.android.contacts',
      launchActivity: 'com.android.dialer.DialtactsActivity',
      launchEntryLabel: '电话',
    );
    expect(state.displayNameFor('com.android.contacts'), '电话');

    // "Keep the original name": the entry still starts and still supplies the
    // icon, but the name stays 联系人.
    await state.updateMeta('com.android.contacts', nameFollowsEntry: false);
    expect(state.displayNameFor('com.android.contacts'), '联系人');
    expect(
      state.metaFor('com.android.contacts').launchActivity,
      'com.android.dialer.DialtactsActivity',
    );

    await state.updateMeta('com.android.contacts', nameFollowsEntry: true);
    expect(state.displayNameFor('com.android.contacts'), '电话');
  });

  test('falls back to the last known name, then to the package', () async {
    final state = AppState(_MemStorage());
    // Never seen: the package name itself is the best we have.
    expect(state.displayNameFor('com.gone'), 'com.gone');

    await state.updateMeta('com.gone', note: 'x');
    state.metaFor('com.gone').lastKnownName = '旧应用';
    expect(state.displayNameFor('com.gone'), '旧应用');
  });

  test('sorting and search follow the pinned entry name', () async {
    final state = AppState(_MemStorage())
      ..apps = [
        _app('com.android.contacts', 'Contacts'),
        _app('com.other', 'Mail'),
      ];
    // Unpinned: sorted by the packages' own labels.
    expect(state.visibleApps.map((a) => a.packageName).toList(), [
      'com.android.contacts',
      'com.other',
    ]);

    await state.updateMeta(
      'com.android.contacts',
      launchActivity: 'com.android.dialer.DialtactsActivity',
      launchEntryLabel: 'ZPhone',
    );
    // Renamed to ZPhone, it now sorts after Mail.
    expect(state.visibleApps.map((a) => a.packageName).toList(), [
      'com.other',
      'com.android.contacts',
    ]);

    // Both names find it: the one shown, and the package's own label.
    state.query = 'ZPhone';
    expect(state.visibleApps.map((a) => a.packageName).toList(), [
      'com.android.contacts',
    ]);
    state.query = 'Contacts';
    expect(state.visibleApps.map((a) => a.packageName).toList(), [
      'com.android.contacts',
    ]);
  });
}
