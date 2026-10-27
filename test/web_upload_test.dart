import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:localshare/web_upload.dart';

const boundary = 'localshare-upload-test';

Stream<List<int>> multipart({
  required int declaredSize,
  required int actualSize,
  bool includeFile = true,
}) async* {
  yield utf8.encode('--$boundary\r\n'
      'Content-Disposition: form-data; name="metadata"\r\n\r\n'
      '${jsonEncode({
        'text': 'ZIP 上传',
        'attachments': [
          {
            'name': '测试.zip',
            'mimeType': 'application/zip',
            'size': declaredSize
          }
        ]
      })}\r\n');
  if (includeFile) {
    yield utf8.encode('--$boundary\r\n'
        'Content-Disposition: form-data; name="file"; filename="test.zip"\r\n'
        'Content-Type: application/zip\r\n\r\n');
    final chunk = Uint8List(64 * 1024)..fillRange(0, 64 * 1024, 0x5a);
    for (var sent = 0; sent < actualSize;) {
      final count = (actualSize - sent).clamp(0, chunk.length);
      yield count == chunk.length ? chunk : chunk.sublist(0, count);
      sent += count;
    }
    yield utf8.encode('\r\n');
  }
  yield utf8.encode('--$boundary--\r\n');
}

void main() {
  late Directory directory;
  setUp(() async {
    directory =
        await Directory.systemTemp.createTemp('localshare-upload-test-');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('streams 600 MiB through HTTP and preserves size and file bytes',
      () async {
    const size = 600 * 1024 * 1024;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final receiving = server.first.then((request) => WebUpload.receive(
          request,
          request.headers.value('content-type')!,
          directory,
        ).then((upload) async {
          request.response.statusCode = 200;
          await request.response.close();
          return upload;
        }));
    final client = HttpClient();
    try {
      final request = await client
          .postUrl(Uri.parse('http://127.0.0.1:${server.port}/upload'));
      request.headers
          .set('content-type', 'multipart/form-data; boundary=$boundary');
      await request.addStream(multipart(declaredSize: size, actualSize: size));
      final response = await request.close();
      await response.drain<void>();
      expect(response.statusCode, 200);
      final upload = await receiving;
      expect(upload.metadata['attachments'][0]['name'], '测试.zip');
      expect(await upload.files.single.length(), size);
      final file = await upload.files.single.open();
      try {
        expect(await file.read(4), [0x5a, 0x5a, 0x5a, 0x5a]);
        await file.setPosition(size - 4);
        expect(await file.read(4), [0x5a, 0x5a, 0x5a, 0x5a]);
      } finally {
        await file.close();
      }
      await upload.dispose();
      expect(await directory.list().isEmpty, isTrue);
    } finally {
      client.close(force: true);
      await server.close(force: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  for (final actual in [0, 3, 5]) {
    test('rejects incomplete or mismatched data ($actual bytes) and cleans up',
        () async {
      await expectLater(
        WebUpload.receive(multipart(declaredSize: 4, actualSize: actual),
            'multipart/form-data; boundary=$boundary', directory),
        throwsFormatException,
      );
      expect(await directory.list().isEmpty, isTrue);
    });
  }

  test('rejects missing attachment and cleans up', () async {
    await expectLater(
      WebUpload.receive(
          multipart(declaredSize: 4, actualSize: 0, includeFile: false),
          'multipart/form-data; boundary=$boundary',
          directory),
      throwsFormatException,
    );
    expect(await directory.list().isEmpty, isTrue);
  });

  test('accepts a genuinely empty file', () async {
    final upload = await WebUpload.receive(
        multipart(declaredSize: 0, actualSize: 0),
        'multipart/form-data; boundary=$boundary',
        directory);
    expect(await upload.files.single.length(), 0);
    await upload.dispose();
  });
}
