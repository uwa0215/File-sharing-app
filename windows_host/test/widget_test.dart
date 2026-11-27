import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:windows_host/main.dart';

void main() {
  testWidgets(
      'renders No Wi-Fi Send, USB Explorer, and QR Wi-Fi modes cleanly', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      const DeviceBridgeWindowsApp(enableNativeServices: false),
    );

    // 1. Default No Wi-Fi Send tab
    expect(find.text('DeviceBridge'), findsOneWidget);
    expect(find.text('Send Target (No Wi-Fi):'), findsOneWidget);
    expect(find.text('Select Files & Send Now'), findsOneWidget);

    // 2. Switch to USB Explorer tab
    await tester.tap(find.text('USB Explorer'));
    await tester.pumpAndSettle();
    expect(find.text('Mirror & Send to Phone'), findsOneWidget);
    expect(
      find.text(
        'Plug in your Android or iPhone via USB to browse & drag files.',
      ),
      findsOneWidget,
    );

    // 3. Switch to QR Wi-Fi tab & open dedicated Transfer Window modal
    await tester.tap(find.text('QR Wi-Fi'));
    await tester.pumpAndSettle();
    expect(find.text('Scan QR Code on Other Device'), findsOneWidget);
    expect(find.text('Open Transfer Window'), findsOneWidget);

    await tester.tap(find.text('Open Transfer Window'));
    await tester.pumpAndSettle();
    expect(find.text('QR File Transfer Window'), findsOneWidget);
  });
}
