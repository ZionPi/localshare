import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:mime/mime.dart';
import 'package:shelf/shelf.dart';

/// A shared selection and independently persisted canvases. The original v1
/// file remains the default canvas, so migration never moves or erases it.
class WhiteboardService {
  WhiteboardService(this.directory, {this.onSaved});
  final Directory directory;
  final Future<void> Function(Map<String, dynamic>)? onSaved;
  Map<String, dynamic>? _index;
  final Map<String, Map<String, dynamic>> _cache = {};
  Future<void> _pending = Future<void>.value();
  Future<Archive>? _assets;
  static const maxBytes = 32 * 1024 * 1024;

  static bool handles(String path) =>
      path == 'api/whiteboard' ||
      path == 'api/whiteboards' ||
      path.startsWith('api/whiteboards/') ||
      path == 'whiteboard' ||
      path.startsWith('whiteboard/');

  File get _indexFile => File('${directory.path}/whiteboards/index_v2.json');
  File _boardFile(String id) => File(id == 'default'
      ? '${directory.path}/whiteboard_v1.json'
      : '${directory.path}/whiteboards/$id.json');

  Future<T> _serialized<T>(Future<T> Function() action) async {
    final previous = _pending;
    final done = Completer<void>();
    _pending = done.future;
    try {
      await previous;
      return await action();
    } finally {
      done.complete();
    }
  }

  Future<void> _write(File file, Map<String, dynamic> value) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(value), flush: true);
    await temporary.rename(file.path);
  }

  Map<String, dynamic> _empty() =>
      {'revision': 0, 'elements': [], 'appState': {}, 'files': {}};
  Future<Map<String, dynamic>> _read(String id) async {
    if (_cache[id] != null) return _cache[id]!;
    final file = _boardFile(id);
    if (!await file.exists()) {
      if (id == 'default') return _empty();
      throw const FormatException('Missing board file');
    }
    final board = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if (board['revision'] is! int ||
        board['elements'] is! List ||
        board['appState'] is! Map ||
        board['files'] is! Map) {
      throw const FormatException('Invalid board file');
    }
    _remember(id, board);
    return board;
  }

  void _remember(String id, Map<String, dynamic> board) {
    _cache.remove(id);
    _cache[id] = board;
    if (_cache.length > 3) _cache.remove(_cache.keys.first);
  }

  Future<Map<String, dynamic>> _loadIndex() async {
    if (_index != null) return _index!;
    if (await _indexFile.exists()) {
      final index =
          jsonDecode(await _indexFile.readAsString()) as Map<String, dynamic>;
      final boards = index['boards'] as List;
      if (boards.isEmpty ||
          index['selectionRevision'] is! int ||
          !boards.every(
              (b) => b is Map && _validId(b['id']) && b['name'] is String) ||
          !boards.any((b) => b['id'] == index['activeId'])) {
        throw const FormatException('Invalid board index');
      }
      return _index = index;
    }
    await _read('default'); // Fail safely if the original canvas is damaged.
    final now = DateTime.now().toIso8601String();
    final index = <String, dynamic>{
      'version': 2,
      'activeId': 'default',
      'selectionRevision': 0,
      'boards': [
        {'id': 'default', 'name': '画布 1', 'createdAt': now}
      ]
    };
    await _write(_indexFile, index);
    return _index = index;
  }

  bool _validId(dynamic id) =>
      id is String && RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(id);
  Map<String, dynamic>? _metadata(Map<String, dynamic> index, String id) {
    for (final value in index['boards'] as List) {
      if (value['id'] == id) return Map<String, dynamic>.from(value as Map);
    }
    return null;
  }

  Map<String, dynamic> _decorate(
          Map<String, dynamic> board, Map<String, dynamic> metadata) =>
      {...board, 'id': metadata['id'], 'name': metadata['name']};

  Future<void> refreshCard() => _serialized(() async {
        final index = await _loadIndex();
        for (final entry in index['boards'] as List) {
          final board = await _read(entry['id'] as String);
          if (board['previewDataURL'] is String) {
            await onSaved?.call(
                _decorate(board, Map<String, dynamic>.from(entry as Map)));
          }
        }
      });

  Future<void> activateBoard(String id) => _serialized(() async {
        final index = await _loadIndex();
        if (_metadata(index, id) == null) throw StateError('白板不存在');
        await _activate(index, id);
      });

  Future<Map<String, dynamic>> _activate(
      Map<String, dynamic> index, String id) async {
    if (index['activeId'] == id) return index;
    final next = {
      ...index,
      'activeId': id,
      'selectionRevision': (index['selectionRevision'] as int) + 1
    };
    await _write(_indexFile, next);
    _index = next;
    return next;
  }

  Response _json(int status, Map<String, dynamic> data) =>
      Response(status, body: jsonEncode(data), headers: {
        'content-type': 'application/json; charset=utf-8',
        'cache-control': 'no-store'
      });

  Future<Map<String, dynamic>> _body(Request request) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in request.read()) {
      if (bytes.length + chunk.length > maxBytes) {
        throw const _RequestError(413, '白板超过 32 MB，请减少插入的图片');
      }
      bytes.add(chunk);
    }
    try {
      final data = jsonDecode(utf8.decode(bytes.takeBytes()));
      if (data is! Map<String, dynamic>) throw const FormatException();
      return data;
    } on FormatException {
      throw const _RequestError(400, '白板数据格式错误');
    }
  }

  String _name(dynamic value) {
    if (value is! String || value.trim().isEmpty || value.trim().length > 80) {
      throw const _RequestError(400, '名称请填写 1 到 80 个字');
    }
    return value.trim();
  }

  Future<Response> handle(Request request) async {
    if (!request.url.path.startsWith('api/')) return _asset(request);
    return _serialized(() async {
      try {
        return await _api(request);
      } on _RequestError catch (error) {
        return _json(error.status, {'error': error.message});
      } catch (_) {
        return _json(500, {'error': '无法读取或保存白板，请稍后重试'});
      }
    });
  }

  Future<Response> _api(Request request) async {
    final path = request.url.path;
    final index = await _loadIndex();
    if (path == 'api/whiteboards') {
      if (request.method == 'GET') return _json(200, index);
      if (request.method != 'POST') {
        return Response(405, headers: {'allow': 'GET, POST'});
      }
      final data = await _body(request);
      if (data['selectionRevision'] != index['selectionRevision']) {
        throw const _RequestError(409, '当前白板已变化，请重试');
      }
      final name = _name(data['name']);
      final id =
          'board-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
      await _write(_boardFile(id), _empty());
      final next = {
        ...index,
        'activeId': id,
        'selectionRevision': (index['selectionRevision'] as int) + 1,
        'boards': [
          ...index['boards'] as List,
          {
            'id': id,
            'name': name,
            'createdAt': DateTime.now().toIso8601String()
          }
        ]
      };
      await _write(_indexFile, next);
      _index = next;
      return _json(201, next);
    }
    final segments = path.split('/');
    final legacy = path == 'api/whiteboard';
    if (!legacy &&
        (segments.length < 3 ||
            segments[1] != 'whiteboards' ||
            !_validId(segments[2]))) {
      return Response.notFound('Not found');
    }
    final id = legacy ? 'default' : segments[2];
    final metadata = _metadata(index, id);
    if (metadata == null) return _json(404, {'error': '白板不存在'});
    if (!legacy && segments.length == 4 && segments[3] == 'activate') {
      if (request.method != 'POST') {
        return Response(405, headers: {'allow': 'POST'});
      }
      final data = await _body(request);
      if (data['selectionRevision'] != index['selectionRevision']) {
        throw const _RequestError(409, '当前白板已变化，请重试');
      }
      return _json(200, await _activate(index, id));
    }
    if (!legacy && segments.length != 3) return Response.notFound('Not found');
    final current = await _read(id);
    if (request.method == 'GET') {
      if (request.url.queryParameters['revision'] ==
          current['revision'].toString()) {
        return Response(204, headers: {'cache-control': 'no-store'});
      }
      return _json(200, _decorate(current, metadata));
    }
    if (request.method == 'PATCH' && !legacy) {
      final data = await _body(request);
      final renamed = {...metadata, 'name': _name(data['name'])};
      final next = {
        ...index,
        'boards': [
          for (final entry in index['boards'] as List)
            entry['id'] == id ? renamed : entry
        ]
      };
      await _write(_indexFile, next);
      _index = next;
      return _withCard(next, _decorate(current, renamed));
    }
    if (request.method != 'PUT') {
      return Response(405,
          headers: {'allow': legacy ? 'GET, PUT' : 'GET, PUT, PATCH'});
    }
    final data = await _body(request);
    if (data['revision'] is! int ||
        data['elements'] is! List ||
        data['appState'] is! Map ||
        data['files'] is! Map) {
      throw const _RequestError(400, '白板数据格式错误');
    }
    if (data['revision'] != current['revision']) {
      throw const _RequestError(409, '白板已在其他页面修改，请先导出当前内容，再重新载入');
    }
    final preview = data['previewDataURL'];
    if (preview != null &&
        (preview is! String ||
            !preview.startsWith('data:image/png;base64,') ||
            preview.length > 8 * 1024 * 1024)) {
      throw const _RequestError(400, '白板预览图片格式错误或超过 8 MB');
    }
    final next = <String, dynamic>{
      'revision': (current['revision'] as int) + 1,
      'elements': data['elements'],
      'appState': data['appState'],
      'files': data['files'],
      if (preview != null) 'previewDataURL': preview
    };
    await _write(_boardFile(id), next);
    _remember(id, next);
    return _withCard({'revision': next['revision']}, _decorate(next, metadata));
  }

  Future<Response> _withCard(
      Map<String, dynamic> result, Map<String, dynamic> board) async {
    try {
      await onSaved?.call(board);
    } catch (_) {
      return _json(200, {...result, 'warning': '白板已保存，但卡片更新失败，请稍后重试'});
    }
    return _json(200, result);
  }

  Future<Response> _asset(Request request) async {
    if (request.method != 'GET' && request.method != 'HEAD') {
      return Response(405, headers: {'allow': 'GET, HEAD'});
    }
    var path = request.url.path;
    path = path == 'whiteboard' || path == 'whiteboard/'
        ? 'index.html'
        : path.substring('whiteboard/'.length);
    if (path.split('/').any((part) => part == '..' || part.isEmpty) ||
        path.contains('\\')) {
      return Response.notFound('Not found');
    }
    try {
      final archive = await (_assets ??= _loadAssets());
      final asset = archive.findFile(path);
      if (asset == null || !asset.isFile) return Response.notFound('Not found');
      return Response.ok(
        request.method == 'HEAD' ? null : asset.content as List<int>,
        headers: {
          'content-type': lookupMimeType(path) ?? 'application/octet-stream',
          'cache-control':
              path == 'index.html' ? 'no-cache' : 'public, max-age=86400',
          'x-content-type-options': 'nosniff',
        },
      );
    } catch (_) {
      _assets = null;
      return Response.internalServerError(body: '无法加载白板资源');
    }
  }

  Future<Archive> _loadAssets() async {
    final data = await rootBundle.load('assets/whiteboard.zip');
    return ZipDecoder().decodeBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
  }
}

class _RequestError implements Exception {
  const _RequestError(this.status, this.message);
  final int status;
  final String message;
}
