import 'package:flutter_test/flutter_test.dart';
import 'package:localshare/main.dart';

void main() {
  test('download location survives a state round trip', () {
    final attachment = CardAttachment(
      id: 'file-1', cardId: 'card-1', name: '报告.ppt',
      mimeType: 'application/vnd.ms-powerpoint', size: 42,
      localPath: '/storage/emulated/0/Download/报告.ppt',
      kind: AttachmentKind.document, createdAt: DateTime.utc(2026),
      inDownloads: true,
    );
    final restored = CardAttachment.fromJson(attachment.toJson());
    expect(restored.localPath, attachment.localPath);
    expect(restored.name, attachment.name);
    expect(restored.inDownloads, isTrue);
    final legacy = attachment.toJson()..remove('inDownloads');
    expect(CardAttachment.fromJson(legacy).inDownloads, isFalse);
  });
}
