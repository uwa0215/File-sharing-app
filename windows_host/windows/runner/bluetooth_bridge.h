#ifndef RUNNER_BLUETOOTH_BRIDGE_H_
#define RUNNER_BLUETOOTH_BRIDGE_H_

#include <windows.h>

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/method_channel.h>

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <queue>
#include <string>

constexpr UINT kWmBluetoothCallback = WM_APP + 102;

// Native Win32 Bluetooth device discovery + direct OBEX Object Push (OPP) sender.
// Works completely without Wi-Fi or USB cables.
class BluetoothBridge {
 public:
  BluetoothBridge(HWND hwnd, flutter::BinaryMessenger* messenger);
  ~BluetoothBridge();

  void DrainCallbacks();

 private:
  void PostToUiThread(std::function<void()> task);
  void EmitProgress(int completed_files,
                    int total_files,
                    int64_t bytes_transferred,
                    int64_t total_bytes,
                    const std::string& current_file);
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  HWND hwnd_;
  std::shared_ptr<std::atomic<bool>> alive_;
  std::shared_ptr<std::atomic<bool>> cancel_requested_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      method_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>>
      event_channel_;

  std::mutex sink_mutex_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> event_sink_;

  std::mutex queue_mutex_;
  std::queue<std::function<void()>> callback_queue_;
};

#endif  // RUNNER_BLUETOOTH_BRIDGE_H_
