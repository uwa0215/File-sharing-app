import 'package:flutter_test/flutter_test.dart';
import 'package:windows_host/models/usb_device_models.dart';
import 'package:windows_host/services/adb_usb_service.dart';
import 'package:windows_host/services/usb_device_manager.dart';

void main() {
  group('AdbUsbService parsers', () {
    test('parses authorized and unauthorized adb devices output', () {
      const sample = '''
List of devices attached
R58N123ABC             device product:dm1q model:SM_S911B device:dm1q transport_id:4
987654XYZ              unauthorized usb:1-2 transport_id:5
emulator-5554          offline
''';
      final parsed = AdbUsbService.parseAdbDevicesOutput(sample);
      expect(parsed.length, 2);

      expect(parsed[0].serial, 'R58N123ABC');
      expect(parsed[0].authorized, isTrue);
      expect(parsed[0].model, 'SM_S911B');

      expect(parsed[1].serial, '987654XYZ');
      expect(parsed[1].authorized, isFalse);
    });

    test('parses Android toybox ls -lAp output including spaces and symlinks', () {
      const lsOut = '''
total 64
drwxrwx--- 4 root sdcard_rw 3488 2026-11-12 09:10 ./
drwxrwx--- 4 root sdcard_rw 3488 2026-11-12 09:10 ../
drwxrwx--- 4 root sdcard_rw 3488 2026-11-12 09:10 DCIM/
drwxrwx--- 2 root sdcard_rw 3488 2026-11-12 09:10 Download/
-rw-rw---- 1 u0_a1 ext_data 4581920 2026-11-12 09:11 My Vacation Photo.jpg
-rw-rw---- 1 u0_a1 ext_data 1024 Nov 12 09:15 notes.txt
''';
      final entries = AdbUsbService.parseLsLongOutput(
        lsOut,
        parentPosixPath: '/sdcard',
      );
      expect(entries.length, 4);

      expect(entries[0].name, 'DCIM');
      expect(entries[0].isDirectory, isTrue);
      expect(entries[0].id, '/sdcard/DCIM');

      expect(entries[1].name, 'Download');
      expect(entries[1].isDirectory, isTrue);

      expect(entries[2].name, 'My Vacation Photo.jpg');
      expect(entries[2].isDirectory, isFalse);
      expect(entries[2].sizeBytes, 4581920);
      expect(entries[2].id, '/sdcard/My Vacation Photo.jpg');

      expect(entries[3].name, 'notes.txt');
      expect(entries[3].sizeBytes, 1024);
    });
  });

  group('UsbDeviceManager.mergeDevices', () {
    test('deduplicates authorized Android ADB + MTP and keeps iPhone PTP', () {
      final merged = UsbDeviceManager.mergeDevices(
        adbDevices: const [
          UsbPhoneDevice(
            id: 'adb:R58N123',
            name: 'Galaxy S23',
            manufacturer: 'samsung',
            os: MobileOs.android,
            backend: UsbBackendMode.adb,
            authorized: true,
            adbSerial: 'R58N123',
          ),
        ],
        wpdDevices: const [
          UsbPhoneDevice(
            id: 'wpd:1',
            name: 'Galaxy S23',
            manufacturer: 'Samsung Electronics',
            os: MobileOs.android,
            backend: UsbBackendMode.wpd,
            wpdDeviceId: 'wpd-id-1',
          ),
          UsbPhoneDevice(
            id: 'wpd:2',
            name: 'Apple iPhone',
            manufacturer: 'Apple Inc.',
            os: MobileOs.ios,
            backend: UsbBackendMode.wpd,
            wpdDeviceId: 'wpd-id-2',
          ),
        ],
      );

      expect(merged.length, 2);
      expect(merged[0].backend, UsbBackendMode.adb);
      expect(merged[0].canWriteFiles, isTrue);
      expect(merged[1].os, MobileOs.ios);
      expect(merged[1].backend, UsbBackendMode.wpd);
      expect(merged[1].canWriteFiles, isFalse);
    });
  });

  group('BatchTransferProgress & formatting', () {
    test('calculates fraction and formats speed/byte sizes', () {
      const progress = BatchTransferProgress(
        active: true,
        direction: UsbTransferDirection.phoneToPc,
        totalFiles: 100,
        completedFiles: 50,
        failedFiles: 0,
        totalBytes: 200 * 1024 * 1024,
        transferredBytes: 100 * 1024 * 1024,
        bytesPerSecond: 35.5 * 1024 * 1024,
        currentFileName: 'VID_0050.mp4',
      );
      expect(progress.fraction, closeTo(0.5, 0.001));
      expect(progress.formattedSpeed, '35.5 MB/s');
      expect(formatByteCount(512), '512 B');
      expect(formatByteCount(1536), '1.5 KB');
      expect(formatByteCount(5 * 1024 * 1024), '5.0 MB');
    });
  });
}

