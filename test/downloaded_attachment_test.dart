import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:localshare/main.dart';

void main() {
  late Directory directory;
  late Directory originals;
  late Directory downloads;
  late CardAttachment current;
  var copies = 0;
  final contents = List<int>.generate(128, (i) => i);
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('attachment-download-');
    originals = await Directory('${directory.path}/originals').create();
    downloads = await Directory('${directory.path}/Download').create();
    final source =
        await File('${originals.path}/file-1.png').writeAsBytes(contents);
    current = CardAttachment(
        id: 'file-1',
        cardId: 'card-1',
        name: '照片.png',
        mimeType: 'image/png',
        size: contents.length,
        localPath: source.path,
        kind: AttachmentKind.image,
        createdAt: DateTime.utc(2026));
    copies = 0;
  });
  tearDown(() => directory.delete(recursive: true));
  Future<AttachmentDownloadResult> download() => downloadCardAttachment(
        current,
        originalsDirectory: originals,
        saveCopy: (source) async {
          copies++;
          final target =
              await File(source.localPath).copy('${downloads.path}/照片.png');
          return target.path;
        },
        persist: (updated) async {
          current = updated;
        },
      );

  test('download keeps original; repeated taps report existing copy', () async {
    final originalPath = current.localPath;
    final first = await download();
    expect(first.alreadyDownloaded, false);
    expect(await File(originalPath).readAsBytes(), contents);
    expect(current.localPath, originalPath);
    expect(current.inDownloads, false);
    current = CardAttachment.fromJson(current.toJson());
    final second = await download();
    expect(second.alreadyDownloaded, true);
    expect(second.path, first.path);
    expect(copies, 1);
  });

  test('deleting the download permits redownload from the retained original',
      () async {
    final first = await download();
    await File(first.path).delete();
    final second = await download();
    expect(second.alreadyDownloaded, false);
    expect(copies, 2);
    expect(await File(second.path).readAsBytes(), contents);
    expect(await File(current.localPath).readAsBytes(), contents);
  });

  test(
      'old download-as-original data is copied back before external file is deleted',
      () async {
    final external =
        await File(current.localPath).copy('${downloads.path}/旧照片.png');
    await File(current.localPath).delete();
    current = CardAttachment.fromJson(
        {...current.toJson(), 'localPath': external.path, 'inDownloads': true});
    final first = await download();
    expect(first.alreadyDownloaded, true);
    expect(current.inDownloads, false);
    expect(await File(current.localPath).readAsBytes(), contents);
    expect(await external.exists(), true);
    await external.delete();
    final second = await download();
    expect(second.alreadyDownloaded, false);
    expect(await File(second.path).readAsBytes(), contents);
  });

  test('legacy internal original is reused even if external copy is missing',
      () async {
    current = CardAttachment.fromJson({
      ...current.toJson(),
      'localPath': '${downloads.path}/missing.png',
      'inDownloads': true
    });
    final result = await download();
    expect(result.alreadyDownloaded, false);
    expect(current.inDownloads, false);
    expect(await File(result.path).readAsBytes(), contents);
  });

  test('missing legacy original reports failure and leaves metadata unchanged',
      () async {
    await File(current.localPath).delete();
    current = CardAttachment.fromJson({
      ...current.toJson(),
      'localPath': '${downloads.path}/missing.png',
      'inDownloads': true
    });
    final original = current;
    await expectLater(download(), throwsA(isA<StateError>()));
    expect(identical(original, current), true);
    expect(copies, 0);
  });

  test('failed download preserves source and does not mark it downloaded',
      () async {
    await expectLater(
        downloadCardAttachment(current,
            originalsDirectory: originals,
            saveCopy: (_) async => throw const FileSystemException('full'),
            persist: (_) async => fail('must not persist a failed copy')),
        throwsA(isA<FileSystemException>()));
    expect(current.downloadedPath, null);
    expect(await File(current.localPath).readAsBytes(), contents);
  });

  test(
      'legacy metadata still decodes and new download path survives round trip',
      () {
    final json = current.toJson()
      ..remove('inDownloads')
      ..remove('downloadedPath');
    expect(CardAttachment.fromJson(json).inDownloads, false);
    expect(CardAttachment.fromJson(json).downloadedPath, null);
    final restored = CardAttachment.fromJson(
        {...json, 'downloadedPath': '/Download/照片.png'});
    expect(CardAttachment.fromJson(restored.toJson()).downloadedPath,
        '/Download/照片.png');
  });
}
