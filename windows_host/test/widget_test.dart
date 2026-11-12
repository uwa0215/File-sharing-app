import 'package:flutter_test/flutter_test.dart';
import 'package:windows_host/main.dart';

void main() {
  testWidgets('renders Mirror & Drop, Transfer Queue, and Phone Files tabs',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      const DeviceBridgeWindowsApp(enableNativeServices: false),
    );
    expect(find.text('Mirror & Drop'), findsOneWidget);
    expect(find.text('Transfer Queue (0)'), findsOneWidget);
    expect(find.text('Phone Files (0)'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
  });
}
