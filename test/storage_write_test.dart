import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:hamstapp/services/storage.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('hamstapp_storage_');
  });

  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {
      // Best effort.
    }
  });

  test('overlapping saves of one file keep it readable and ordered', () async {
    final storage = Storage.at(dir);
    await Future.wait([
      for (var i = 0; i < 25; i++) storage.writeJson('settings', {'n': i}),
    ]);

    // The document exists, is valid JSON, and the last save won.
    final file = File('${dir.path}/settings.json');
    expect(file.existsSync(), isTrue);
    expect(jsonDecode(file.readAsStringSync()), {'n': 24});
    expect(await storage.readJson('settings'), {'n': 24});

    // No scratch files are left behind.
    final leftovers = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.tmp'))
        .toList();
    expect(leftovers, isEmpty);
  });

  test('a failing writer does not wedge later saves', () async {
    final storage = Storage.at(dir);
    final cyclic = <String, dynamic>{};
    cyclic['self'] = cyclic;
    await expectLater(
      storage.writeJson('bad', cyclic),
      throwsA(isA<JsonUnsupportedObjectError>()),
    );

    await storage.writeJson('bad', {'ok': true});
    expect(await storage.readJson('bad'), {'ok': true});
  });
}
