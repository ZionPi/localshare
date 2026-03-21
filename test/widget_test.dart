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
    expect(find.text('制卡'), findsOneWidget);
    expect(find.text('搜索卡片内容或附件文件名'), findsOneWidget);
  });
}
