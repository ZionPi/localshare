import 'dart:convert';
import 'dart:io';

import 'package:mime/mime.dart';

/// Stages multipart files on disk; file contents never become a large string.
class WebUpload {
  WebUpload(this.metadata, this.files, this.directory);

  final Map<String, dynamic> metadata;
  final List<File> files;
  final Directory directory;

  Future<void> dispose() => directory.delete(recursive: true);

  static Future<WebUpload> receive(
    Stream<List<int>> body,
    String contentType,
    Directory parent,
  ) async {
    final boundary = ContentType.parse(contentType).parameters['boundary'];
    if (boundary == null || boundary.isEmpty) {
      throw const FormatException('上传缺少 multipart boundary');
    }
    final directory = await parent.createTemp('web-upload-');
    try {
      Map<String, dynamic>? metadata;
      final files = <File>[];
      await for (final part in body
          .cast<List<int>>()
          .transform(MimeMultipartTransformer(boundary))) {
        if (metadata == null) {
          final bytes = <int>[];
          await for (final chunk in part) {
            if (bytes.length + chunk.length > 1024 * 1024) {
              throw const FormatException('上传元数据过大');
            }
            bytes.addAll(chunk);
          }
          metadata = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
          continue;
        }
        final entries = metadata['attachments'] as List<dynamic>;
        if (files.length >= entries.length) {
          throw const FormatException('上传附件数量不符');
        }
        final entry = entries[files.length] as Map<String, dynamic>;
        final expectedSize = entry['size'] as int;
        final file = File('${directory.path}/${files.length}');
        final sink = file.openWrite();
        try {
          await sink.addStream(part);
          await sink.flush();
        } finally {
          await sink.close();
        }
        if (expectedSize < 0 || await file.length() != expectedSize) {
          throw const FormatException('附件大小不符，请重新上传');
        }
        files.add(file);
      }
      if (metadata == null ||
          files.length != (metadata['attachments'] as List<dynamic>).length) {
        throw const FormatException('上传不完整，请重试');
      }
      return WebUpload(metadata, files, directory);
    } catch (_) {
      await directory.delete(recursive: true);
      rethrow;
    }
  }
}
