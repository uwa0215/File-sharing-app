#ifndef RUNNER_WPD_BRIDGE_H_
#define RUNNER_WPD_BRIDGE_H_

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

constexpr UINT kWmWpdCallback = WM_APP + 101;

// Native Win32 Windows Portable Devices (WPD / MTP / Apple PTP) bridge +
// USB hardware change event notifier exposed to Flutter via Method/Event channels.
class WpdBridge {
 public:
  WpdBridge(HWND hwnd, flutter::BinaryMessenger* messenger);
  ~WpdBridge();

  void NotifyUsbChanged();
  void DrainCallbacks();

 private:
  void PostToUiThread(std::function<void()> task);
  void EmitProgress(const std::string& direction,
                    int completed_files,
                    int total_files,
                    int64_t bytes_transferred,
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

#endif  // RUNNER_WPD_BRIDGE_H_
