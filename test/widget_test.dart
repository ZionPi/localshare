import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localshare/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders local share app shell', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    await tester.pumpWidget(const MyApp());
    await tester.pump();

    expect(find.text('本地分享'), findsAtLeastNWidgets(1));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byTooltip('设置'), findsOneWidget);
  });

  testWidgets('latest feedback immediately replaces rapid queued messages', (tester) async {
    late BuildContext messageContext;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) {
      messageContext = context;
      return const SizedBox();
    }))));
    showLocalShareMessage(messageContext, '正在保存');
    await tester.pump(const Duration(milliseconds: 40));
    for (var index = 0; index < 10; index++) {
      showLocalShareMessage(messageContext, '正在下载 $index');
    }
    showLocalShareMessage(messageContext, '已下载');
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('已下载'), findsOneWidget);
    expect(find.text('正在保存'), findsNothing);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
  });

}
