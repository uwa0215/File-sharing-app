import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:windows_host/main.dart';

void main() {
  testWidgets(
      'renders unified Easy Transfer (QR + USB + Bluetooth) and USB Explorer cleanly',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      const DeviceBridgeWindowsApp(enableNativeServices: false),
    );

    // 1. Unified Easy Transfer dashboard has QR Code + Target Chips + Drop Window
    expect(find.text('DeviceBridge'), findsOneWidget);
    expect(find.text('Scan QR Code to Connect'), findsOneWidget);
    expect(find.text('QR Code Session'), findsOneWidget);
    expect(find.text('Drag & Drop Files or Folders Here'), findsOneWidget);
    expect(find.text('Open Transfer Window'), findsOneWidget);

    // 2. Open expandable QR File Transfer Window modal
    await tester.tap(find.text('Open Transfer Window'));
    await tester.pumpAndSettle();
    expect(find.text('QR File Transfer Window'), findsOneWidget);

    await tester.tap(find.byTooltip('Close Transfer Window'));
    await tester.pumpAndSettle();

    // 3. Switch to USB Explorer
    await tester.tap(find.text('USB Explorer'));
    await tester.pumpAndSettle();
    expect(find.text('Mirror & Send to Phone'), findsOneWidget);
  });
}
