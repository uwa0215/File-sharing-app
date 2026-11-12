import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_companion/main.dart';

void main() {
  testWidgets('renders DeviceBridge Companion shell',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      const DeviceBridgeMobileApp(enableNativeServices: false),
    );
    expect(find.text('DeviceBridge Companion'), findsOneWidget);
    expect(find.text('Incoming Transfers (0)'), findsOneWidget);
  });
}
