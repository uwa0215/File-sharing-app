import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:windows_host/main.dart';

void main() {
  testWidgets('renders QR scanner + transfer window and switches to USB mode', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      const DeviceBridgeWindowsApp(enableNativeServices: false),
    );

    expect(find.text('DeviceBridge'), findsOneWidget);
    expect(find.text('Scan QR Code on Other Device'), findsOneWidget);
    expect(find.text('Open Transfer Window'), findsOneWidget);
    expect(find.text('Drag & Drop Files or Folders Here'), findsOneWidget);

    // Open dedicated expandable QR Transfer Window modal.
    await tester.tap(find.text('Open Transfer Window'));
    await tester.pumpAndSettle();
    expect(find.text('QR File Transfer Window'), findsOneWidget);

    // Close modal and switch to USB Cable mode.
    await tester.tap(find.byTooltip('Close Transfer Window'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('USB Cable'));
    await tester.pumpAndSettle();
    expect(find.text('Mirror & Send to Phone'), findsOneWidget);
    expect(
      find.text(
        'Plug in your Android or iPhone via USB to browse & drag files.',
      ),
      findsOneWidget,
    );
  });
}
