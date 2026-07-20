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
}
