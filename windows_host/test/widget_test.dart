import 'package:flutter_test/flutter_test.dart';
import 'package:windows_host/main.dart';

void main() {
  testWidgets('renders Windows-only USB plug-and-play UI', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const DeviceBridgeWindowsApp(enableNativeServices: false),
    );
    expect(find.text('DeviceBridge USB'), findsOneWidget);
    expect(find.text('Mirror & Send to Phone'), findsOneWidget);
    expect(
      find.text(
        'Plug in your Android or iPhone via USB to browse & drag files.',
      ),
      findsOneWidget,
    );
  });
}
