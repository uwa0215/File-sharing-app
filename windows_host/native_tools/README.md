# DeviceBridge Windows Sidecar Binaries

Place the prebuilt Windows x64 binaries and their required runtime DLLs in the
subdirectories below before running `flutter build windows --release` and
compiling `installer/devicebridge.iss`:

```text
native_tools/
├── android/
│   ├── adb.exe
│   ├── AdbWinApi.dll
│   ├── AdbWinUsbApi.dll
│   ├── scrcpy.exe
│   ├── scrcpy-server
│   └── (SDL2.dll, avcodec-*.dll, avformat-*.dll, avutil-*.dll, swresample-*.dll, libusb-1.0.dll)
├── ios/
│   ├── iproxy.exe
│   ├── libimobiledevice-1.0.dll
│   ├── libusbmuxd-2.0.dll
│   ├── libplist-2.0.dll
│   ├── libimobiledevice-glue-1.0.dll
│   └── (libcrypto-*.dll, libssl-*.dll)
├── airplay/
│   ├── uxplay.exe
│   └── (GStreamer Windows runtime DLLs / plugins)
└── LICENSES/
    └── NOTICE.txt
```

`windows/CMakeLists.txt` automatically copies this folder into `<Release>/tools/`.
At runtime, `NativeToolsLocator` resolves executables from `<exe_dir>/tools/`,
`native_tools/` during development, or `PATH` as a fallback.

