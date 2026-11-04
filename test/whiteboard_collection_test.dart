import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:localshare/main.dart';
import 'package:localshare/whiteboard.dart';
import 'package:shelf/shelf.dart';

void main() {
  late Directory directory;
  late WhiteboardService service;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('board-collection-');
    service = WhiteboardService(directory);
  });
  tearDown(() => directory.delete(recursive: true));
  Future<Response> request(String method, String path,
          [Map<String, dynamic>? data]) =>
      service.handle(Request(method, Uri.parse('http://localhost$path'),
          body: data == null ? null : jsonEncode(data)));
  Future<Map<String, dynamic>> json(Response response) async =>
      jsonDecode(await response.readAsString()) as Map<String, dynamic>;
  Future<Map<String, dynamic>> catalog() async =>
      json(await request('GET', '/api/whiteboards'));
  Future<Map<String, dynamic>> create(String name) async {
    final index = await catalog();
    final response = await request('POST', '/api/whiteboards',
        {'name': name, 'selectionRevision': index['selectionRevision']});
    expect(response.statusCode, 201);
    return json(response);
  }

  Future<Response> save(String id, int revision, String content,
          {bool preview = false}) =>
      request('PUT', '/api/whiteboards/$id', {
        'revision': revision,
        'elements': [
          {'id': content}
        ],
        'appState': {},
        'files': {},
        if (preview) 'previewDataURL': 'data:image/png;base64,iVBORw0KGgo=',
      });

  test('migration preserves the original canvas bytes and identity', () async {
    final legacy = jsonEncode({
      'revision': 7,
      'elements': [
        {'id': 'original'}
      ],
      'appState': {'viewBackgroundColor': '#ccc'},
      'files': {}
    });
    final original = File('${directory.path}/whiteboard_v1.json');
    await original.writeAsString(legacy);
    final index = await catalog();
    expect(index['activeId'], 'default');
    expect(index['boards'].length, 1);
    expect(await original.readAsString(), legacy);
    final first = await json(await request('GET', '/api/whiteboards/default'));
    expect(first['revision'], 7);
    expect(first['elements'][0]['id'], 'original');
    expect(first['id'], 'default');
    expect(first['name'], '画布 1');
  });

  test(
      'late saves remain bound to their original board after selection changes',
      () async {
    expect((await save('default', 0, 'first')).statusCode, 200);
    final next = await create('第二张图');
    final id = next['activeId'] as String;
    expect(id, isNot('default'));
    expect((await save('default', 1, 'late-original')).statusCode, 200);
    expect((await save(id, 0, 'second')).statusCode, 200);
    service = WhiteboardService(directory);
    final first = await json(await request('GET', '/api/whiteboards/default'));
    final second = await json(await request('GET', '/api/whiteboards/$id'));
    expect(first['elements'][0]['id'], 'late-original');
    expect(first['revision'], 2);
    expect(second['elements'][0]['id'], 'second');
    expect(second['revision'], 1);
    expect((await catalog())['activeId'], id);
    // Old web clients using the v1 endpoint must remain bound to the old board.
    expect(
        (await json(await request('GET', '/api/whiteboard')))['id'], 'default');
  });

  test(
      'rename updates the matching card callback without renaming another board',
      () async {
    final updates = <Map<String, dynamic>>[];
    service = WhiteboardService(directory, onSaved: (board) async {
      updates.add(board);
    });
    await save('default', 0, 'old', preview: true);
    final next = await create('新白板');
    final id = next['activeId'] as String;
    await save(id, 0, 'new', preview: true);
    final renamed =
        await request('PATCH', '/api/whiteboards/$id', {'name': '草图 A'});
    expect(renamed.statusCode, 200);
    expect(updates.last['id'], id);
    expect(updates.last['name'], '草图 A');
    expect(updates.last['revision'], 1);
    expect(
        (await json(await request('GET', '/api/whiteboards/default')))['name'],
        '画布 1');
    updates.clear();
    service = WhiteboardService(directory, onSaved: (board) async {
      updates.add(board);
    });
    await service.refreshCard();
    expect(updates.map((board) => board['id']), ['default', id]);
  });

  test('stale selection requests cannot create or activate another board',
      () async {
    final index = await catalog();
    final next = await create('第二块');
    expect(
        (await request('POST', '/api/whiteboards/default/activate',
                {'selectionRevision': index['selectionRevision']}))
            .statusCode,
        409);
    expect(
        (await request('POST', '/api/whiteboards', {
          'name': '过期请求',
          'selectionRevision': index['selectionRevision']
        }))
            .statusCode,
        409);
    expect((await catalog())['activeId'], next['activeId']);
    expect((await catalog())['boards'].length, 2);
    expect(
        (await request('POST', '/api/whiteboards/default/activate',
                {'selectionRevision': next['selectionRevision']}))
            .statusCode,
        200);
    expect((await catalog())['activeId'], 'default');
  });

  test('unknown boards, invalid names and corrupt index do not erase drawings',
      () async {
    await save('default', 0, 'keep');
    expect((await request('GET', '/api/whiteboards/missing')).statusCode, 404);
    expect(
        (await request('PATCH', '/api/whiteboards/default', {'name': ' '}))
            .statusCode,
        400);
    await File('${directory.path}/whiteboards/index_v2.json')
        .writeAsString('broken');
    service = WhiteboardService(directory);
    expect((await request('GET', '/api/whiteboards')).statusCode, 500);
    expect(
        (await request('POST', '/api/whiteboards',
                {'name': 'new', 'selectionRevision': 0}))
            .statusCode,
        500);
    final original = jsonDecode(
        await File('${directory.path}/whiteboard_v1.json').readAsString());
    expect(original['elements'][0]['id'], 'keep');
  });

  test('board card identity and name survive persistence and public payload',
      () {
    final now = DateTime.now();
    final card = CardItem(
        id: 'localshare-whiteboard-board-a',
        text: '',
        createdAt: now,
        updatedAt: now,
        source: 'whiteboard',
        whiteboardId: 'board-a',
        whiteboardName: '草图 A');
    final restored = CardItem.fromJson(card.toJson());
    expect(restored.whiteboardId, 'board-a');
    expect(restored.whiteboardName, '草图 A');
    expect(restored.toPublicJson({})['whiteboardName'], '草图 A');
    expect(restored.text, isEmpty);
  });
}
