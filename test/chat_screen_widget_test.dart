import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:errand/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('ErrandApp builds ChatScreen without ParentDataWidget errors', (tester) async {
    await tester.pumpWidget(const ErrandApp());
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 10));
  });
}
