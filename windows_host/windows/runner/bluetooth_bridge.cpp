#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <winsock2.h>
#include <ws2bth.h>
#include <bluetoothapis.h>
#include <shellapi.h>

#include "bluetooth_bridge.h"

#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <thread>
#include <utility>
#include <variant>
#include <vector>

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

namespace {

// Standard Bluetooth SIG OBEX Object Push Profile UUID: {00001105-0000-1000-8000-00805F9B34FB}
constexpr GUID kObexObjectPushUuid = {
    0x00001105,
    0x0000,
    0x1000,
    {0x80, 0x00, 0x00, 0x80, 0x5F, 0x9B, 0x34, 0xFB}};

constexpr uint8_t kObexConnect = 0x80;
constexpr uint8_t kObexDisconnect = 0x81;
constexpr uint8_t kObexPut = 0x02;
constexpr uint8_t kObexPutFinal = 0x82;
constexpr uint8_t kObexContinue = 0x90;
constexpr uint8_t kObexSuccess = 0xA0;

std::string WideToUtf8(const std::wstring& wide) {
  if (wide.empty()) return std::string();
  const int size_needed = WideCharToMultiByte(
      CP_UTF8, 0, wide.c_str(), static_cast<int>(wide.size()), nullptr, 0,
      nullptr, nullptr);
  if (size_needed <= 0) return std::string();
  std::string out(static_cast<size_t>(size_needed), '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), static_cast<int>(wide.size()),
                      out.data(), size_needed, nullptr, nullptr);
  return out;
}

std::wstring Utf8ToWide(const std::string& utf8) {
  if (utf8.empty()) return std::wstring();
  const int size_needed = MultiByteToWideChar(
      CP_UTF8, 0, utf8.c_str(), static_cast<int>(utf8.size()), nullptr, 0);
  if (size_needed <= 0) return std::wstring();
  std::wstring out(static_cast<size_t>(size_needed), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), static_cast<int>(utf8.size()),
                      out.data(), size_needed);
  return out;
}

std::string GetStringArg(const EncodableMap& map, const char* key) {
  const auto it = map.find(EncodableValue(key));
  if (it == map.end()) return std::string();
  if (const auto* val = std::get_if<std::string>(&it->second)) {
    return *val;
  }
  return std::string();
}

bool GetBoolArg(const EncodableMap& map, const char* key, bool fallback) {
  const auto it = map.find(EncodableValue(key));
  if (it == map.end()) return fallback;
  if (const auto* val = std::get_if<bool>(&it->second)) {
    return *val;
  }
  return fallback;
}

EncodableList GetListArg(const EncodableMap& map, const char* key) {
  const auto it = map.find(EncodableValue(key));
  if (it == map.end()) return EncodableList();
  if (const auto* val = std::get_if<EncodableList>(&it->second)) {
    return *val;
  }
  return EncodableList();
}

std::string FormatBthAddr(BTH_ADDR addr) {
  char buf[32];
  std::snprintf(buf, sizeof(buf), "%012llX",
                static_cast<unsigned long long>(addr));
  return std::string(buf);
}

std::string ClassifyDeviceKind(ULONG cod) {
  const ULONG major = (cod >> 8) & 0x1F;
  if (major == 0x02) return "phone";
  if (major == 0x01) return "computer";
  if (major == 0x04) return "audio";
  return "other";
}

std::string FormatWsaError(const char* prefix, int wsa_err) {
  char buf[192];
  std::snprintf(buf, sizeof(buf), "%s (Bluetooth WSA error %d)", prefix,
                wsa_err);
  return std::string(buf);
}

void AppendU16BE(std::vector<uint8_t>* buf, uint16_t val) {
  buf->push_back(static_cast<uint8_t>((val >> 8) & 0xFF));
  buf->push_back(static_cast<uint8_t>(val & 0xFF));
}

void AppendU32BE(std::vector<uint8_t>* buf, uint32_t val) {
  buf->push_back(static_cast<uint8_t>((val >> 24) & 0xFF));
  buf->push_back(static_cast<uint8_t>((val >> 16) & 0xFF));
  buf->push_back(static_cast<uint8_t>((val >> 8) & 0xFF));
  buf->push_back(static_cast<uint8_t>(val & 0xFF));
}

bool SendAll(SOCKET sock, const uint8_t* data, size_t len) {
  size_t sent_total = 0;
  while (sent_total < len) {
    const int chunk = static_cast<int>(len - sent_total);
    const int n = send(sock, reinterpret_cast<const char*>(data + sent_total),
                       chunk, 0);
    if (n <= 0) return false;
    sent_total += static_cast<size_t>(n);
  }
  return true;
}

bool RecvExact(SOCKET sock, uint8_t* dst, size_t len) {
  size_t got = 0;
  while (got < len) {
    const int n = recv(sock, reinterpret_cast<char*>(dst + got),
                       static_cast<int>(len - got), 0);
    if (n <= 0) return false;
    got += static_cast<size_t>(n);
  }
  return true;
}

bool ReadObexResponse(SOCKET sock,
                      uint8_t* out_opcode,
                      std::vector<uint8_t>* out_body) {
  uint8_t header[3] = {};
  if (!RecvExact(sock, header, 3)) return false;
  *out_opcode = header[0];
  const uint16_t pkt_len =
      static_cast<uint16_t>((static_cast<uint16_t>(header[1]) << 8) | header[2]);
  out_body->clear();
  if (pkt_len > 3) {
    out_body->resize(static_cast<size_t>(pkt_len - 3));
    if (!RecvExact(sock, out_body->data(), out_body->size())) return false;
  }
  return true;
}

std::vector<uint8_t> BuildObexNameHeader(const std::wstring& file_name) {
  std::vector<uint8_t> h;
  const uint16_t total_len =
      static_cast<uint16_t>(3 + (file_name.size() + 1) * 2);
  h.push_back(0x01);  // Name (Unicode UTF-16BE)
  AppendU16BE(&h, total_len);
  for (wchar_t wc : file_name) {
    AppendU16BE(&h, static_cast<uint16_t>(wc));
  }
  AppendU16BE(&h, 0x0000);
  return h;
}

bool ListBluetoothDevicesImpl(bool include_audio,
                              bool issue_inquiry,
                              EncodableList* out_devices,
                              std::string* err) {
  BLUETOOTH_DEVICE_SEARCH_PARAMS params = {};
  params.dwSize = sizeof(params);
  params.fReturnAuthenticated = TRUE;
  params.fReturnRemembered = TRUE;
  params.fReturnConnected = TRUE;
  params.fReturnUnknown = issue_inquiry ? TRUE : FALSE;
  params.fIssueInquiry = issue_inquiry ? TRUE : FALSE;
  params.cTimeoutMultiplier = issue_inquiry ? 4 : 0;

  BLUETOOTH_DEVICE_INFO info = {};
  info.dwSize = sizeof(info);

  HBLUETOOTH_DEVICE_FIND h_find = BluetoothFindFirstDevice(&params, &info);
  if (h_find == nullptr) {
    const DWORD last_err = GetLastError();
    if (last_err == ERROR_NO_MORE_ITEMS) {
      return true;
    }
    char buf[128];
    std::snprintf(buf, sizeof(buf),
                  "Bluetooth scan unavailable (Win32 error %lu)", last_err);
    *err = std::string(buf);
    return false;
  }

  struct RawBt {
    std::string address;
    std::string name;
    std::string kind;
    bool connected;
    bool authenticated;
  };
  std::vector<RawBt> found;

  do {
    const std::string kind = ClassifyDeviceKind(info.ulClassofDevice);
    if (!include_audio && kind == "audio") {
      info.dwSize = sizeof(info);
      continue;
    }
    std::string name = WideToUtf8(std::wstring(info.szName));
    if (name.empty()) {
      name = FormatBthAddr(info.Address.ullLong);
    }
    found.push_back({
        FormatBthAddr(info.Address.ullLong),
        name,
        kind,
        info.fConnected != FALSE,
        info.fAuthenticated != FALSE,
    });
    info.dwSize = sizeof(info);
  } while (BluetoothFindNextDevice(h_find, &info));

  BluetoothFindDeviceClose(h_find);

  auto kind_rank = [](const std::string& k) -> int {
    if (k == "phone") return 0;
    if (k == "computer") return 1;
    if (k == "other") return 2;
    return 3;
  };

  std::sort(found.begin(), found.end(), [&](const RawBt& a, const RawBt& b) {
    if (kind_rank(a.kind) != kind_rank(b.kind)) {
      return kind_rank(a.kind) < kind_rank(b.kind);
    }
    if (a.connected != b.connected) return a.connected > b.connected;
    return _stricmp(a.name.c_str(), b.name.c_str()) < 0;
  });

  for (const auto& d : found) {
    EncodableMap entry;
    entry[EncodableValue("address")] = EncodableValue(d.address);
    entry[EncodableValue("name")] = EncodableValue(d.name);
    entry[EncodableValue("deviceKind")] = EncodableValue(d.kind);
    entry[EncodableValue("connected")] = EncodableValue(d.connected);
    entry[EncodableValue("authenticated")] = EncodableValue(d.authenticated);
    out_devices->push_back(EncodableValue(entry));
  }

  return true;
}

bool SendSingleObexFile(SOCKET sock,
                        uint16_t max_pkt_size,
                        const std::string& local_path,
                        const std::string& file_name,
                        const std::shared_ptr<std::atomic<bool>>& cancel,
                        int64_t* running_bytes,
                        const std::function<void(int64_t)>& on_progress,
                        std::string* err) {
  const std::wstring wide_path = Utf8ToWide(local_path);
  HANDLE h_file = CreateFileW(
      wide_path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
      FILE_ATTRIBUTE_NORMAL | FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
  if (h_file == INVALID_HANDLE_VALUE) {
    *err = "Could not open Windows file: " + file_name;
    return false;
  }

  LARGE_INTEGER file_size_li = {};
  if (!GetFileSizeEx(h_file, &file_size_li)) {
    CloseHandle(h_file);
    *err = "Failed reading size of " + file_name;
    return false;
  }

  const uint32_t file_size_u32 =
      file_size_li.QuadPart > 0xFFFFFFFFLL
          ? 0xFFFFFFFFU
          : static_cast<uint32_t>(file_size_li.QuadPart);

  const std::vector<uint8_t> name_hdr = BuildObexNameHeader(Utf8ToWide(file_name));

  int64_t remaining = file_size_li.QuadPart;
  bool first_packet = true;
  std::vector<uint8_t> packet;
  std::vector<uint8_t> chunk_buf;

  while (true) {
    if (cancel->load()) {
      CloseHandle(h_file);
      *err = "Cancelled";
      return false;
    }

    packet.clear();
    packet.push_back(0x00);  // opcode placeholder
    packet.push_back(0x00);  // length hi
    packet.push_back(0x00);  // length lo

    if (first_packet) {
      packet.insert(packet.end(), name_hdr.begin(), name_hdr.end());
      packet.push_back(0xC3);  // Length header
      AppendU32BE(&packet, file_size_u32);
      first_packet = false;
    }

    const size_t overhead = packet.size() + 3;  // +3 for Body/EndOfBody header
    const size_t max_payload =
        max_pkt_size > overhead ? static_cast<size_t>(max_pkt_size - overhead) : 64;
    const size_t want_read = remaining <= 0
                                 ? 0
                                 : std::min(max_payload, static_cast<size_t>(remaining));

    chunk_buf.resize(want_read);
    DWORD bytes_read = 0;
    if (want_read > 0) {
      if (!ReadFile(h_file, chunk_buf.data(), static_cast<DWORD>(want_read),
                    &bytes_read, nullptr)) {
        CloseHandle(h_file);
        *err = "Failed reading bytes from " + file_name;
        return false;
      }
    }

    remaining -= static_cast<int64_t>(bytes_read);
    const bool is_final = (remaining <= 0);

    packet[0] = is_final ? kObexPutFinal : kObexPut;
    packet.push_back(is_final ? 0x49 : 0x48);  // End-of-Body or Body
    AppendU16BE(&packet, static_cast<uint16_t>(3 + bytes_read));
    if (bytes_read > 0) {
      packet.insert(packet.end(), chunk_buf.begin(),
                    chunk_buf.begin() + static_cast<ptrdiff_t>(bytes_read));
    }

    const uint16_t pkt_len = static_cast<uint16_t>(packet.size());
    packet[1] = static_cast<uint8_t>((pkt_len >> 8) & 0xFF);
    packet[2] = static_cast<uint8_t>(pkt_len & 0xFF);

    if (!SendAll(sock, packet.data(), packet.size())) {
      CloseHandle(h_file);
      *err = "Bluetooth connection dropped while sending " + file_name;
      return false;
    }

    uint8_t resp_op = 0;
    std::vector<uint8_t> resp_body;
    if (!ReadObexResponse(sock, &resp_op, &resp_body)) {
      CloseHandle(h_file);
      *err = "No response from target device during " + file_name;
      return false;
    }

    if (is_final) {
      if (resp_op != kObexSuccess) {
        CloseHandle(h_file);
        *err = "Target device rejected or cancelled " + file_name;
        return false;
      }
      *running_bytes += static_cast<int64_t>(bytes_read);
      on_progress(*running_bytes);
      break;
    }

    if (resp_op != kObexContinue && resp_op != kObexSuccess) {
      CloseHandle(h_file);
      *err = "Target device declined Bluetooth transfer for " + file_name;
      return false;
    }

    *running_bytes += static_cast<int64_t>(bytes_read);
    on_progress(*running_bytes);
  }

  CloseHandle(h_file);
  return true;
}

}  // namespace

BluetoothBridge::BluetoothBridge(HWND hwnd, flutter::BinaryMessenger* messenger)
    : hwnd_(hwnd),
      alive_(std::make_shared<std::atomic<bool>>(true)),
      cancel_requested_(std::make_shared<std::atomic<bool>>(false)) {
  method_channel_ =
      std::make_unique<flutter::MethodChannel<EncodableValue>>(
          messenger, "devicebridge/bluetooth",
          &flutter::StandardMethodCodec::GetInstance());

  method_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        HandleMethodCall(call, std::move(result));
      });

  event_channel_ =
      std::make_unique<flutter::EventChannel<EncodableValue>>(
          messenger, "devicebridge/bluetooth_events",
          &flutter::StandardMethodCodec::GetInstance());

  auto handler = std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
      [this](const EncodableValue* /*arguments*/,
             std::unique_ptr<flutter::EventSink<EncodableValue>>&& events)
          -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
        std::lock_guard<std::mutex> lock(sink_mutex_);
        event_sink_ = std::move(events);
        return nullptr;
      },
      [this](const EncodableValue* /*arguments*/)
          -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
        std::lock_guard<std::mutex> lock(sink_mutex_);
        event_sink_.reset();
        return nullptr;
      });
  event_channel_->SetStreamHandler(std::move(handler));
}

BluetoothBridge::~BluetoothBridge() {
  alive_->store(false);
  cancel_requested_->store(true);
  if (method_channel_) {
    method_channel_->SetMethodCallHandler(nullptr);
  }
  std::lock_guard<std::mutex> lock(sink_mutex_);
  event_sink_.reset();
}

void BluetoothBridge::PostToUiThread(std::function<void()> task) {
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    callback_queue_.push(std::move(task));
  }
  if (hwnd_) {
    PostMessage(hwnd_, kWmBluetoothCallback, 0, 0);
  }
}

void BluetoothBridge::DrainCallbacks() {
  std::queue<std::function<void()>> local;
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    std::swap(local, callback_queue_);
  }
  while (!local.empty()) {
    auto fn = std::move(local.front());
    local.pop();
    if (fn) fn();
  }
}

void BluetoothBridge::EmitProgress(int completed_files,
                                   int total_files,
                                   int64_t bytes_transferred,
                                   int64_t total_bytes,
                                   const std::string& current_file) {
  auto alive = alive_;
  PostToUiThread([this, alive, completed_files, total_files, bytes_transferred,
                  total_bytes, current_file]() {
    if (!alive->load()) return;
    std::lock_guard<std::mutex> lock(sink_mutex_);
    if (!event_sink_) return;
    EncodableMap payload;
    payload[EncodableValue("completedFiles")] = EncodableValue(completed_files);
    payload[EncodableValue("totalFiles")] = EncodableValue(total_files);
    payload[EncodableValue("bytesTransferred")] =
        EncodableValue(bytes_transferred);
    payload[EncodableValue("totalBytes")] = EncodableValue(total_bytes);
    payload[EncodableValue("currentFile")] = EncodableValue(current_file);
    event_sink_->Success(EncodableValue(payload));
  });
}

void BluetoothBridge::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const std::string& method = call.method_name();
  EncodableMap args;
  if (const auto* map_ptr = std::get_if<EncodableMap>(call.arguments())) {
    args = *map_ptr;
  }

  if (method == "cancelSend") {
    cancel_requested_->store(true);
    result->Success(EncodableValue(true));
    return;
  }

  if (method == "openReceiveWizard") {
    ShellExecuteW(nullptr, L"open", L"fsquirt.exe", L"-receive", nullptr,
                  SW_SHOWNORMAL);
    result->Success(EncodableValue(true));
    return;
  }

  if (method == "openBluetoothSettings") {
    ShellExecuteW(nullptr, L"open", L"ms-settings:bluetooth", nullptr, nullptr,
                  SW_SHOWNORMAL);
    result->Success(EncodableValue(true));
    return;
  }

  auto shared_result =
      std::shared_ptr<flutter::MethodResult<EncodableValue>>(std::move(result));
  auto alive = alive_;

  if (method == "listDevices") {
    const bool include_audio = GetBoolArg(args, "includeAudio", false);
    const bool issue_inquiry = GetBoolArg(args, "inquiry", false);
    std::thread([this, alive, shared_result, include_audio, issue_inquiry]() {
      EncodableList devices;
      std::string err;
      const bool ok = ListBluetoothDevicesImpl(include_audio, issue_inquiry,
                                               &devices, &err);
      if (!alive->load()) return;
      PostToUiThread([alive, shared_result, ok, devices = std::move(devices),
                      err = std::move(err)]() {
        if (!alive->load()) return;
        if (ok) {
          shared_result->Success(EncodableValue(devices));
        } else {
          shared_result->Error("BT_ERROR", err);
        }
      });
    }).detach();
    return;
  }

  if (method == "sendBatch") {
    const std::string address_hex = GetStringArg(args, "address");
    const EncodableList items = GetListArg(args, "items");
    if (address_hex.empty() || items.empty()) {
      shared_result->Error("INVALID_ARGS", "address and items are required");
      return;
    }

    cancel_requested_->store(false);
    auto cancel = cancel_requested_;

    std::thread([this, alive, cancel, shared_result, address_hex, items]() {
      WSADATA wsa = {};
      if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
        if (!alive->load()) return;
        PostToUiThread([alive, shared_result]() {
          if (!alive->load()) return;
          shared_result->Error("BT_ERROR", "WSAStartup failed for Bluetooth.");
        });
        return;
      }

      SOCKET sock = socket(AF_BTH, SOCK_STREAM, BTHPROTO_RFCOMM);
      if (sock == INVALID_SOCKET) {
        const std::string err =
            FormatWsaError("Failed to create Bluetooth RFCOMM socket",
                           WSAGetLastError());
        WSACleanup();
        if (!alive->load()) return;
        PostToUiThread([alive, shared_result, err]() {
          if (!alive->load()) return;
          shared_result->Error("BT_ERROR", err);
        });
        return;
      }

      DWORD timeout_ms = 25000;
      setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO,
                 reinterpret_cast<const char*>(&timeout_ms),
                 sizeof(timeout_ms));
      setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO,
                 reinterpret_cast<const char*>(&timeout_ms),
                 sizeof(timeout_ms));

      SOCKADDR_BTH sab = {};
      sab.addressFamily = AF_BTH;
      sab.btAddr = static_cast<BTH_ADDR>(
          std::strtoull(address_hex.c_str(), nullptr, 16));
      sab.serviceClassId = kObexObjectPushUuid;
      sab.port = 0;

      if (connect(sock, reinterpret_cast<SOCKADDR*>(&sab), sizeof(sab)) ==
          SOCKET_ERROR) {
        const std::string err = FormatWsaError(
            "Could not connect to device Bluetooth OBEX service (ensure it is paired & Bluetooth is ON; iPhones block Bluetooth file transfer)",
            WSAGetLastError());
        closesocket(sock);
        WSACleanup();
        if (!alive->load()) return;
        PostToUiThread([alive, shared_result, err]() {
          if (!alive->load()) return;
          shared_result->Error("BT_CONNECT_ERROR", err);
        });
        return;
      }

      // Send OBEX CONNECT (version 1.0, max packet 16384 bytes)
      const uint8_t obex_connect[] = {kObexConnect, 0x00, 0x07, 0x10,
                                      0x00,         0x40, 0x00};
      uint8_t conn_op = 0;
      std::vector<uint8_t> conn_body;
      if (!SendAll(sock, obex_connect, sizeof(obex_connect)) ||
          !ReadObexResponse(sock, &conn_op, &conn_body) ||
          conn_op != kObexSuccess) {
        closesocket(sock);
        WSACleanup();
        if (!alive->load()) return;
        PostToUiThread([alive, shared_result]() {
          if (!alive->load()) return;
          shared_result->Error("BT_OBEX_ERROR",
                               "Bluetooth OBEX handshake rejected by device.");
        });
        return;
      }

      uint16_t max_pkt_size = 8192;
      if (conn_body.size() >= 4) {
        const uint16_t peer_max = static_cast<uint16_t>(
            (static_cast<uint16_t>(conn_body[2]) << 8) | conn_body[3]);
        max_pkt_size = std::clamp<uint16_t>(peer_max, 512, 16384);
      }

      int64_t total_batch_bytes = 0;
      for (const auto& entry_val : items) {
        const auto* item_map = std::get_if<EncodableMap>(&entry_val);
        if (!item_map) continue;
        const std::string local_path = GetStringArg(*item_map, "localPath");
        WIN32_FILE_ATTRIBUTE_DATA fad = {};
        if (GetFileAttributesExW(Utf8ToWide(local_path).c_str(),
                                 GetFileExInfoStandard, &fad)) {
          LARGE_INTEGER li = {};
          li.HighPart = static_cast<LONG>(fad.nFileSizeHigh);
          li.LowPart = fad.nFileSizeLow;
          total_batch_bytes += li.QuadPart;
        }
      }

      int succeeded_count = 0;
      int completed = 0;
      const int total_count = static_cast<int>(items.size());
      int64_t bytes_transferred = 0;
      EncodableList failures;
      bool was_cancelled = false;
      auto last_emit = std::chrono::steady_clock::now();

      for (const auto& entry_val : items) {
        if (cancel->load() || !alive->load()) {
          was_cancelled = true;
          break;
        }
        const auto* item_map = std::get_if<EncodableMap>(&entry_val);
        if (!item_map) continue;
        const std::string local_path = GetStringArg(*item_map, "localPath");
        const std::string file_name = GetStringArg(*item_map, "fileName");

        std::string item_err;
        const bool ok = SendSingleObexFile(
            sock, max_pkt_size, local_path, file_name, cancel,
            &bytes_transferred,
            [&](int64_t running) {
              const auto now = std::chrono::steady_clock::now();
              if (std::chrono::duration_cast<std::chrono::milliseconds>(
                      now - last_emit)
                      .count() >= 100) {
                last_emit = now;
                EmitProgress(completed, total_count, running, total_batch_bytes,
                             file_name);
              }
            },
            &item_err);

        if (ok) {
          succeeded_count++;
        } else if (cancel->load()) {
          was_cancelled = true;
          break;
        } else {
          EncodableMap fail;
          fail[EncodableValue("fileName")] = EncodableValue(file_name);
          fail[EncodableValue("error")] = EncodableValue(item_err);
          failures.push_back(EncodableValue(fail));
        }
        completed++;
        EmitProgress(completed, total_count, bytes_transferred,
                     total_batch_bytes, file_name);
      }

      const uint8_t obex_disconnect[] = {kObexDisconnect, 0x00, 0x03};
      SendAll(sock, obex_disconnect, sizeof(obex_disconnect));
      closesocket(sock);
      WSACleanup();

      if (!alive->load()) return;
      PostToUiThread([alive, shared_result, succeeded_count,
                      failures = std::move(failures), bytes_transferred,
                      was_cancelled]() {
        if (!alive->load()) return;
        EncodableMap out;
        out[EncodableValue("succeededCount")] = EncodableValue(succeeded_count);
        out[EncodableValue("failed")] = EncodableValue(failures);
        out[EncodableValue("bytesTransferred")] =
            EncodableValue(bytes_transferred);
        out[EncodableValue("cancelled")] = EncodableValue(was_cancelled);
        shared_result->Success(EncodableValue(out));
      });
    }).detach();
    return;
  }

  shared_result->NotImplemented();
}
