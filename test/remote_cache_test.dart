import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamstapp/models/remote_source.dart';
import 'package:hamstapp/services/remote_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('hamstapp/apps');
  final calls = <MethodCall>[];

  final source = RemoteSource(
    id: 'src1',
    protocol: 'webdav',
    host: 'nas',
    port: 80,
    path: '/apks',
    anonymous: true,
  );

  Map<Object?, Object?> argsOf(MethodCall call) =>
      (call.arguments as Map).cast<Object?, Object?>();

  MethodCall callTo(String method) =>
      calls.firstWhere((c) => c.method == method);

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'remoteDownload':
          return '/cache/x.apk';
        case 'cachePrune':
          return 7;
        case 'cacheDelete':
          return 1234;
        case 'cacheIndexAll':
          return {
            'entries': [
              {
                'sourceId': 'src1',
                'path': '/apks/a.apk',
                'packageName': 'com.a',
                'versionCode': 2,
                'size': 10,
                'localPath': '/cache/a.apk',
              },
              {
                'sourceId': 'src2',
                'path': '/apks/b.apk',
                'packageName': 'com.b',
                'versionCode': 1,
                'size': 20,
                'localPath': '/cache/b.apk',
              },
            ],
            'totalBytes': 30,
          };
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('download reuses cache by default and forces when asked', () async {
    final entry = {
      'name': 'app.apk',
      'rel': 'dir/app.apk',
      'path': '/apks/dir/app.apk',
      'size': 42,
      'modified': 1700000000000,
    };

    await RemoteClient.download(source, entry);
    final plain = argsOf(callTo('remoteDownload'));
    expect(plain['force'], isFalse);
    expect(plain['sourceId'], 'src1');
    expect(plain['remotePath'], '/apks/dir/app.apk');
    expect(plain['modified'], 1700000000000);

    calls.clear();
    await RemoteClient.download(source, entry, force: true);
    expect(argsOf(callTo('remoteDownload'))['force'], isTrue);
  });

  test('pruneCache forwards remote mtime so same-size updates are dropped',
      () async {
    final freed = await RemoteClient.pruneCache(source, [
      {
        'path': '/apks/dir/app.apk',
        'size': 42,
        'modified': 1700000000000,
      },
    ]);
    expect(freed, 7);
    final entries =
        argsOf(callTo('cachePrune'))['entries'] as List<dynamic>;
    expect(entries, hasLength(1));
    expect((entries.first as Map)['modified'], 1700000000000);
  });

  test('deleteCache removes a single entry and reports freed bytes', () async {
    final freed = await RemoteClient.deleteCache(source, '/apks/dir/app.apk');
    expect(freed, 1234);
    final args = argsOf(callTo('cacheDelete'));
    expect(args['sourceId'], 'src1');
    expect(args['remotePath'], '/apks/dir/app.apk');
  });

  test('deleteCache with an empty path is a no-op', () async {
    final freed = await RemoteClient.deleteCache(source, '');
    expect(freed, 0);
    expect(calls, isEmpty);
  });

  test('cacheIndexAll parses every cached entry with its source', () async {
    final list = await RemoteClient.cacheIndexAll();
    expect(list, hasLength(2));
    expect(list.first['sourceId'], 'src1');
    expect(list.first['packageName'], 'com.a');
    expect(list[1]['packageName'], 'com.b');
  });
}
