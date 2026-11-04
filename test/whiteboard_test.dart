import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:localshare/whiteboard.dart';
import 'package:shelf/shelf.dart';

void main() {
  late Directory directory;
  late WhiteboardService service;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('whiteboard-test-');
    service = WhiteboardService(directory);
  });
  tearDown(() => directory.delete(recursive: true));

  Future<Response> get() => service
      .handle(Request('GET', Uri.parse('http://localhost/api/whiteboard')));
  Future<Map<String, dynamic>> read() async =>
      jsonDecode(await (await get()).readAsString()) as Map<String, dynamic>;
  Future<Response> save(int revision,
          {List<dynamic> elements = const [],
          Map<String, dynamic> files = const {}}) =>
      service.handle(Request(
        'PUT',
        Uri.parse('http://localhost/api/whiteboard'),
        body: jsonEncode({
          'revision': revision,
          'elements': elements,
          'appState': {'viewBackgroundColor': '#fff'},
          'files': files
        }),
      ));

  test('restores drawings, background and embedded images after restart',
      () async {
    expect((await read())['revision'], 0);
    final files = {
      'image-1': {
        'id': 'image-1',
        'mimeType': 'image/png',
        'dataURL': 'data:image/png;base64,aGVsbG8='
      }
    };
    expect(
        (await save(0,
                elements: [
                  {'id': 'shape-1', 'type': 'rectangle'}
                ],
                files: files))
            .statusCode,
        200);
    service = WhiteboardService(directory);
    final restored = await read();
    expect(restored['revision'], 1);
    expect(restored['elements'][0]['id'], 'shape-1');
    expect(restored['appState']['viewBackgroundColor'], '#fff');
    expect(restored['files'], files);
  });

  test('simultaneous saves reject stale revision instead of erasing work',
      () async {
    final responses = await Future.wait([
      save(0, elements: [
        {'id': 'first'}
      ]),
      save(0, elements: [
        {'id': 'second'}
      ])
    ]);
    expect(responses.map((response) => response.statusCode), [200, 409]);
    expect((await read())['elements'][0]['id'], 'first');
    expect((await save(1)).statusCode, 200);
    expect((await read())['revision'], 2);
  });

  test('invalid input and unsupported methods leave board intact', () async {
    expect(
        (await service.handle(Request(
                'PUT', Uri.parse('http://localhost/api/whiteboard'),
                body: 'oops')))
            .statusCode,
        400);
    expect(
        (await service.handle(Request(
                'PUT', Uri.parse('http://localhost/api/whiteboard'),
                body: '{}')))
            .statusCode,
        400);
    expect(
        (await service.handle(Request(
                'DELETE', Uri.parse('http://localhost/api/whiteboard'))))
            .statusCode,
        405);
    expect((await read())['revision'], 0);
  });

  test('corrupt persisted data cannot be overwritten by a new empty board',
      () async {
    await File('${directory.path}/whiteboard_v1.json').writeAsString('broken');
    expect((await get()).statusCode, 500);
    expect((await save(0)).statusCode, 500);
    expect(await File('${directory.path}/whiteboard_v1.json').readAsString(),
        'broken');
  });

  test(
      'persists card preview and invokes card updater after the scene is saved',
      () async {
    final updates = <Map<String, dynamic>>[];
    service = WhiteboardService(directory, onSaved: (board) async {
      updates.add(board);
    });
    const preview = 'data:image/png;base64,iVBORw0KGgo=';
    final response = await service
        .handle(Request('PUT', Uri.parse('http://localhost/api/whiteboard'),
            body: jsonEncode({
              'revision': 0,
              'elements': [
                {'id': 'one'}
              ],
              'appState': {},
              'files': {},
              'previewDataURL': preview,
            })));
    expect(response.statusCode, 200);
    expect(updates.single['previewDataURL'], preview);
    expect(updates.single['revision'], 1);
    expect((await read())['previewDataURL'], preview);
    service = WhiteboardService(directory, onSaved: (board) async {
      updates.add(board);
    });
    await service.refreshCard();
    expect(updates.length, 2);
    expect(updates.last['elements'][0]['id'], 'one');
  });

  test('card update failure reports warning without losing the saved drawing',
      () async {
    service = WhiteboardService(directory, onSaved: (_) async {
      throw const FileSystemException('full');
    });
    final response = await save(0, elements: [
      {'id': 'kept'}
    ]);
    final result = jsonDecode(await response.readAsString());
    expect(response.statusCode, 200);
    expect(result['revision'], 1);
    expect(result['warning'], contains('卡片更新失败'));
    expect((await read())['elements'][0]['id'], 'kept');
  });

  test('serves bundled editor and local fonts, rejects missing assets',
      () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final index = await service
        .handle(Request('GET', Uri.parse('http://localhost/whiteboard/')));
    expect(index.statusCode, 200);
    expect(await index.readAsString(), contains('/whiteboard/assets/'));
    final font = await service.handle(Request(
        'GET',
        Uri.parse(
            'http://localhost/whiteboard/fonts/Virgil/Virgil-Regular.woff2')));
    expect(font.statusCode, 200);
    expect((await font.read().expand((chunk) => chunk).toList()).length,
        greaterThan(1000));
    expect(
        (await service.handle(Request(
                'GET', Uri.parse('http://localhost/whiteboard/missing.js'))))
            .statusCode,
        404);
  });
}
