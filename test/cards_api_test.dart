import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localshare/main.dart';

void main() {
  test('public cards include archived cards and omit local paths and chat', () {
    final now = DateTime.utc(2026, 1, 1);
    final attachment = CardAttachment(
      id: 'file-1',
      cardId: 'card-1',
      name: '报告.pdf',
      mimeType: 'application/pdf',
      size: 42,
      localPath: '/private/report.pdf',
      kind: AttachmentKind.document,
      createdAt: now,
    );
    CardItem card(String id, {DateTime? archivedAt, List<String>? files}) =>
        CardItem(
            id: id,
            text: '内容',
            createdAt: now,
            updatedAt: now,
            archivedAt: archivedAt,
            attachmentIds: files);
    final result = buildPublicCardsResponse([
      card('card-1', files: ['file-1']),
      card('card-2', archivedAt: now),
    ], {
      'file-1': attachment
    });
    final cards = result['cards'] as List;
    expect(cards.length, 2);
    expect(cards[1]['archived'], isTrue);
    expect(cards[0]['attachments'][0]['downloadUrl'], '/files/file-1');
    expect(jsonEncode(result), isNot(contains('/private/report.pdf')));
    expect(result.containsKey('chatMessages'), isFalse);
    expect(buildPublicCardsResponse([], {})['cards'], isEmpty);
  });

  testWidgets('API page displays the current URL and unavailable state',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: LocalShareApiPage(baseAddress: 'http://192.168.1.2:8080')));
    expect(find.text('http://192.168.1.2:8080/api/v1/cards'), findsOneWidget);
    await tester.pumpWidget(
        const MaterialApp(home: LocalShareApiPage(baseAddress: null)));
    expect(find.textContaining('服务未启动'), findsOneWidget);
  });
}
