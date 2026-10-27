import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localshare/attachment_filename.dart';

void main() {
  test('long Chinese names use a short disk name and preserve the extension',
      () async {
    const name = '贯彻以客户为中心理念，依托现金管理产品深耕对公客户-- .ppt';
    const id = 'file-1793171234567890-123456789';
    final stored = buildStoredFileName(name, id);
    expect(stored, '$id.ppt');
    final directory = await Directory.systemTemp.createTemp('attachment-name-');
    try {
      final file = File('${directory.path}/$stored');
      await file.writeAsString('content');
      expect(await file.readAsString(), 'content');
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('extensions are bounded and cannot contain path separators', () {
    expect(buildStoredFileName('file.${'x' * 100}', 'file-1'), 'file-1');
    expect(buildStoredFileName('file.txt/other', 'file-2'), 'file-2');
    expect(buildStoredFileName('file.TXT', 'file-3'), 'file-3.TXT');
  });
}
