#include "wpd_bridge.h"

#include <PortableDevice.h>
#include <PortableDeviceApi.h>
#include <Shlwapi.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>
#include <objbase.h>
#include <wrl/client.h>

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>
#include <utility>
#include <variant>
#include <vector>

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::ComPtr;

namespace {

constexpr DWORD kMinStreamBuffer = 262144;     // 256 KB
constexpr DWORD kMaxStreamBuffer = 2097152;    // 2 MB
constexpr DWORD kEnumBatchSize = 256;

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

std::string FormatHrError(const char* prefix, HRESULT hr) {
  char buf[160];
  std::snprintf(buf, sizeof(buf), "%s (HRESULT 0x%08lX)", prefix,
                static_cast<unsigned long>(hr));
  return std::string(buf);
}

std::string GetStringArg(const EncodableMap& map, const char* key) {
  const auto it = map.find(EncodableValue(key));
  if (it == map.end()) return std::string();
  if (const auto* val = std::get_if<std::string>(&it->second)) {
    return *val;
  }
  return std::string();
}

EncodableList GetListArg(const EncodableMap& map, const char* key) {
  const auto it = map.find(EncodableValue(key));
  if (it == map.end()) return EncodableList();
  if (const auto* val = std::get_if<EncodableList>(&it->second)) {
    return *val;
  }
  return EncodableList();
}

std::wstring TrimNulls(std::wstring s) {
  while (!s.empty() && s.back() == L'\0') {
    s.pop_back();
  }
  return s;
}

bool ContainsCaseInsensitive(const std::string& haystack, const char* needle) {
  std::string lower_hay = haystack;
  std::transform(lower_hay.begin(), lower_hay.end(), lower_hay.begin(),
                 [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  std::string lower_needle(needle);
  std::transform(lower_needle.begin(), lower_needle.end(), lower_needle.begin(),
                 [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  return lower_hay.find(lower_needle) != std::string::npos;
}

HRESULT BuildClientInfo(DWORD access_flags, IPortableDeviceValues** out_info) {
  ComPtr<IPortableDeviceValues> info;
  HRESULT hr = CoCreateInstance(CLSID_PortableDeviceValues, nullptr,
                                CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&info));
  if (FAILED(hr)) return hr;
  info->SetStringValue(WPD_CLIENT_NAME, L"DeviceBridge");
  info->SetUnsignedIntegerValue(WPD_CLIENT_MAJOR_VERSION, 1);
  info->SetUnsignedIntegerValue(WPD_CLIENT_MINOR_VERSION, 0);
  info->SetUnsignedIntegerValue(WPD_CLIENT_REVISION, 0);
  info->SetUnsignedIntegerValue(WPD_CLIENT_SECURITY_QUALITY_OF_SERVICE,
                                SECURITY_IMPERSONATION);
  info->SetUnsignedIntegerValue(WPD_CLIENT_DESIRED_ACCESS, access_flags);
  *out_info = info.Detach();
  return S_OK;
}

HRESULT OpenWpdDevice(const std::wstring& device_id,
                      bool prefer_write,
                      IPortableDevice** out_device) {
  ComPtr<IPortableDevice> device;
  HRESULT hr = CoCreateInstance(CLSID_PortableDeviceFTM, nullptr,
                                CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&device));
  if (FAILED(hr)) return hr;

  if (prefer_write) {
    ComPtr<IPortableDeviceValues> rw_info;
    hr = BuildClientInfo(GENERIC_READ | GENERIC_WRITE, &rw_info);
    if (SUCCEEDED(hr)) {
      hr = device->Open(device_id.c_str(), rw_info.Get());
      if (SUCCEEDED(hr)) {
        *out_device = device.Detach();
        return S_OK;
      }
    }
  }

  ComPtr<IPortableDeviceValues> ro_info;
  hr = BuildClientInfo(GENERIC_READ, &ro_info);
  if (FAILED(hr)) return hr;
  hr = device->Open(device_id.c_str(), ro_info.Get());
  if (SUCCEEDED(hr)) {
    *out_device = device.Detach();
  }
  return hr;
}

std::string ReadWpdStringProp(IPortableDeviceValues* props,
                              REFPROPERTYKEY key) {
  if (!props) return std::string();
  PWSTR raw = nullptr;
  if (SUCCEEDED(props->GetStringValue(key, &raw)) && raw != nullptr) {
    std::string val = WideToUtf8(std::wstring(raw));
    CoTaskMemFree(raw);
    return val;
  }
  return std::string();
}

int64_t ReadWpdSizeProp(IPortableDeviceValues* props) {
  if (!props) return 0;
  ULONGLONG u64 = 0;
  if (SUCCEEDED(props->GetUnsignedLargeIntegerValue(WPD_OBJECT_SIZE, &u64))) {
    return static_cast<int64_t>(u64);
  }
  ULONG u32 = 0;
  if (SUCCEEDED(props->GetUnsignedIntegerValue(WPD_OBJECT_SIZE, &u32))) {
    return static_cast<int64_t>(u32);
  }
  return 0;
}

bool ListWpdDevicesImpl(EncodableList* out_devices, std::string* err) {
  ComPtr<IPortableDeviceManager> manager;
  HRESULT hr = CoCreateInstance(CLSID_PortableDeviceManager, nullptr,
                                CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&manager));
  if (FAILED(hr)) {
    *err = FormatHrError("Failed to create IPortableDeviceManager", hr);
    return false;
  }

  manager->RefreshDeviceList();

  DWORD count = 0;
  hr = manager->GetDevices(nullptr, &count);
  if (FAILED(hr)) {
    *err = FormatHrError("GetDevices(count) failed", hr);
    return false;
  }
  if (count == 0) {
    return true;
  }

  std::vector<PWSTR> device_ids(count, nullptr);
  hr = manager->GetDevices(device_ids.data(), &count);
  if (FAILED(hr)) {
    *err = FormatHrError("GetDevices(list) failed", hr);
    return false;
  }

  for (DWORD i = 0; i < count; ++i) {
    PWSTR id_ptr = device_ids[i];
    if (!id_ptr) continue;

    auto read_meta = [&](auto getter) -> std::string {
      DWORD len = 0;
      if (FAILED((manager.Get()->*getter)(id_ptr, nullptr, &len)) || len == 0) {
        return std::string();
      }
      std::wstring buf(len, L'\0');
      if (SUCCEEDED((manager.Get()->*getter)(id_ptr, buf.data(), &len))) {
        return WideToUtf8(TrimNulls(std::move(buf)));
      }
      return std::string();
    };

    const std::string dev_id = WideToUtf8(std::wstring(id_ptr));
    const std::string friendly =
        read_meta(&IPortableDeviceManager::GetDeviceFriendlyName);
    const std::string manufacturer =
        read_meta(&IPortableDeviceManager::GetDeviceManufacturer);
    const std::string description =
        read_meta(&IPortableDeviceManager::GetDeviceDescription);

    std::string platform_hint = "android";
    if (ContainsCaseInsensitive(manufacturer, "apple") ||
        ContainsCaseInsensitive(friendly, "iphone") ||
        ContainsCaseInsensitive(friendly, "ipad") ||
        ContainsCaseInsensitive(description, "apple")) {
      platform_hint = "ios";
    }

    EncodableMap entry;
    entry[EncodableValue("id")] = EncodableValue(dev_id);
    entry[EncodableValue("friendlyName")] =
        EncodableValue(friendly.empty() ? description : friendly);
    entry[EncodableValue("manufacturer")] = EncodableValue(manufacturer);
    entry[EncodableValue("description")] = EncodableValue(description);
    entry[EncodableValue("platformHint")] = EncodableValue(platform_hint);
    out_devices->push_back(EncodableValue(entry));

    CoTaskMemFree(id_ptr);
  }

  return true;
}

bool ListWpdChildrenImpl(const std::string& device_id,
                         const std::string& folder_object_id,
                         EncodableList* out_entries,
                         std::string* err) {
  ComPtr<IPortableDevice> device;
  HRESULT hr = OpenWpdDevice(Utf8ToWide(device_id), false, &device);
  if (FAILED(hr)) {
    *err = FormatHrError("Failed to open USB device", hr);
    return false;
  }

  ComPtr<IPortableDeviceContent> content;
  hr = device->Content(&content);
  if (FAILED(hr)) {
    *err = FormatHrError("Failed to get device content", hr);
    return false;
  }

  ComPtr<IPortableDeviceProperties> properties;
  hr = content->Properties(&properties);
  if (FAILED(hr)) {
    *err = FormatHrError("Failed to get device properties", hr);
    return false;
  }

  ComPtr<IPortableDeviceKeyCollection> keys;
  hr = CoCreateInstance(CLSID_PortableDeviceKeyCollection, nullptr,
                        CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&keys));
  if (FAILED(hr)) {
    *err = FormatHrError("Failed to create key collection", hr);
    return false;
  }
  keys->Add(WPD_OBJECT_NAME);
  keys->Add(WPD_OBJECT_ORIGINAL_FILE_NAME);
  keys->Add(WPD_OBJECT_CONTENT_TYPE);
  keys->Add(WPD_OBJECT_SIZE);

  const std::wstring parent_wide = folder_object_id.empty()
                                       ? std::wstring(WPD_DEVICE_OBJECT_ID)
                                       : Utf8ToWide(folder_object_id);

  ComPtr<IEnumPortableDeviceObjectIDs> enum_ids;
  hr = content->EnumObjects(0, parent_wide.c_str(), nullptr, &enum_ids);
  if (FAILED(hr)) {
    *err = FormatHrError("Failed to enumerate phone folder", hr);
    return false;
  }

  struct RawItem {
    std::string id;
    std::string name;
    bool is_dir;
    int64_t size_bytes;
  };
  std::vector<RawItem> items;

  std::vector<LPWSTR> obj_ids(kEnumBatchSize, nullptr);
  DWORD fetched = 0;

  while (SUCCEEDED(enum_ids->Next(kEnumBatchSize, obj_ids.data(), &fetched)) &&
         fetched > 0) {
    for (DWORD i = 0; i < fetched; ++i) {
      LPWSTR obj_id = obj_ids[i];
      if (!obj_id) continue;

      ComPtr<IPortableDeviceValues> vals;
      if (SUCCEEDED(properties->GetValues(obj_id, keys.Get(), &vals)) && vals) {
        std::string orig_name =
            ReadWpdStringProp(vals.Get(), WPD_OBJECT_ORIGINAL_FILE_NAME);
        std::string disp_name =
            ReadWpdStringProp(vals.Get(), WPD_OBJECT_NAME);
        std::string name = orig_name.empty() ? disp_name : orig_name;
        if (name.empty()) {
          name = WideToUtf8(std::wstring(obj_id));
        }

        GUID content_type = GUID_NULL;
        bool is_dir = false;
        if (SUCCEEDED(vals->GetGuidValue(WPD_OBJECT_CONTENT_TYPE,
                                         &content_type))) {
          is_dir =
              (IsEqualGUID(content_type, WPD_CONTENT_TYPE_FOLDER) != FALSE) ||
              (IsEqualGUID(content_type, WPD_CONTENT_TYPE_FUNCTIONAL_OBJECT) !=
               FALSE);
        }

        const int64_t size_bytes = is_dir ? 0 : ReadWpdSizeProp(vals.Get());
        items.push_back(
            {WideToUtf8(std::wstring(obj_id)), name, is_dir, size_bytes});
      }
      CoTaskMemFree(obj_id);
      obj_ids[i] = nullptr;
    }
    fetched = 0;
  }

  std::sort(items.begin(), items.end(), [](const RawItem& a, const RawItem& b) {
    if (a.is_dir != b.is_dir) return a.is_dir > b.is_dir;
    return _stricmp(a.name.c_str(), b.name.c_str()) < 0;
  });

  for (const auto& item : items) {
    EncodableMap map;
    map[EncodableValue("id")] = EncodableValue(item.id);
    map[EncodableValue("name")] = EncodableValue(item.name);
    map[EncodableValue("isDirectory")] = EncodableValue(item.is_dir);
    map[EncodableValue("sizeBytes")] = EncodableValue(item.size_bytes);
    out_entries->push_back(EncodableValue(map));
  }

  return true;
}

bool CopyWpdObjectToFile(IPortableDeviceResources* resources,
                         const std::string& object_id,
                         const std::string& dest_local_path,
                         std::vector<uint8_t>* reusable_buffer,
                         int64_t* out_bytes_copied,
                         std::string* err) {
  ComPtr<IStream> src_stream;
  DWORD optimal_buf = 0;
  const std::wstring obj_wide = Utf8ToWide(object_id);
  HRESULT hr = resources->GetStream(obj_wide.c_str(), WPD_RESOURCE_DEFAULT,
                                    STGM_READ, &optimal_buf, &src_stream);
  if (FAILED(hr) || !src_stream) {
    *err = FormatHrError("Failed to open file stream from phone", hr);
    return false;
  }

  const std::wstring dest_wide = Utf8ToWide(dest_local_path);
  const std::wstring part_wide = dest_wide + L".part";
  HANDLE h_file = CreateFileW(part_wide.c_str(), GENERIC_WRITE, 0, nullptr,
                              CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (h_file == INVALID_HANDLE_VALUE) {
    *err = FormatHrError("Failed to create local file",
                         HRESULT_FROM_WIN32(GetLastError()));
    return false;
  }

  const DWORD chunk_size =
      std::clamp(optimal_buf, kMinStreamBuffer, kMaxStreamBuffer);
  if (reusable_buffer->size() < chunk_size) {
    reusable_buffer->resize(chunk_size);
  }

  int64_t copied = 0;
  bool write_ok = true;

  while (true) {
    ULONG bytes_read = 0;
    hr = src_stream->Read(reusable_buffer->data(), chunk_size, &bytes_read);
    if (FAILED(hr)) {
      *err = FormatHrError("Failed reading bytes from USB phone", hr);
      write_ok = false;
      break;
    }
    if (bytes_read == 0) {
      break;
    }
    DWORD bytes_written = 0;
    if (!WriteFile(h_file, reusable_buffer->data(), bytes_read, &bytes_written,
                   nullptr) ||
        bytes_written != bytes_read) {
      *err = FormatHrError("Failed writing local file",
                           HRESULT_FROM_WIN32(GetLastError()));
      write_ok = false;
      break;
    }
    copied += static_cast<int64_t>(bytes_written);
  }

  CloseHandle(h_file);
  if (!write_ok) {
    DeleteFileW(part_wide.c_str());
    return false;
  }

  if (!MoveFileExW(part_wide.c_str(), dest_wide.c_str(),
                   MOVEFILE_REPLACE_EXISTING)) {
    *err = FormatHrError("Failed to finalize pulled file",
                         HRESULT_FROM_WIN32(GetLastError()));
    DeleteFileW(part_wide.c_str());
    return false;
  }

  *out_bytes_copied = copied;
  return true;
}

bool CopyLocalFileToWpdFolder(IPortableDeviceContent* content,
                              const std::string& target_folder_object_id,
                              const std::string& local_file_path,
                              const std::string& file_name,
                              std::vector<uint8_t>* reusable_buffer,
                              int64_t* out_bytes_copied,
                              std::string* err) {
  const std::wstring local_wide = Utf8ToWide(local_file_path);
  HANDLE h_file = CreateFileW(local_wide.c_str(), GENERIC_READ, FILE_SHARE_READ,
                              nullptr, OPEN_EXISTING,
                              FILE_ATTRIBUTE_NORMAL | FILE_FLAG_SEQUENTIAL_SCAN,
                              nullptr);
  if (h_file == INVALID_HANDLE_VALUE) {
    *err = FormatHrError("Failed to open local Windows file",
                         HRESULT_FROM_WIN32(GetLastError()));
    return false;
  }

  LARGE_INTEGER file_size_li = {};
  if (!GetFileSizeEx(h_file, &file_size_li)) {
    CloseHandle(h_file);
    *err = FormatHrError("Failed to read file size",
                         HRESULT_FROM_WIN32(GetLastError()));
    return false;
  }

  ComPtr<IPortableDeviceValues> values;
  HRESULT hr = CoCreateInstance(CLSID_PortableDeviceValues, nullptr,
                                CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&values));
  if (FAILED(hr)) {
    CloseHandle(h_file);
    *err = FormatHrError("Failed to create WPD values", hr);
    return false;
  }

  const std::wstring parent_wide = Utf8ToWide(target_folder_object_id);
  const std::wstring name_wide = Utf8ToWide(file_name);
  values->SetStringValue(WPD_OBJECT_PARENT_ID, parent_wide.c_str());
  values->SetStringValue(WPD_OBJECT_NAME, name_wide.c_str());
  values->SetStringValue(WPD_OBJECT_ORIGINAL_FILE_NAME, name_wide.c_str());
  values->SetUnsignedLargeIntegerValue(
      WPD_OBJECT_SIZE, static_cast<ULONGLONG>(file_size_li.QuadPart));
  values->SetGuidValue(WPD_OBJECT_FORMAT, WPD_OBJECT_FORMAT_UNSPECIFIED);
  values->SetGuidValue(WPD_OBJECT_CONTENT_TYPE, WPD_CONTENT_TYPE_GENERIC_FILE);

  ComPtr<IStream> dest_stream;
  DWORD optimal_buf = 0;
  hr = content->CreateObjectWithPropertiesAndData(values.Get(), &dest_stream,
                                                  &optimal_buf, nullptr);
  if (FAILED(hr) || !dest_stream) {
    CloseHandle(h_file);
    *err = FormatHrError(
        "Phone rejected file write (open a writable folder like Download, or note that iPhone PTP is read-only)",
        hr);
    return false;
  }

  const DWORD chunk_size =
      std::clamp(optimal_buf, kMinStreamBuffer, kMaxStreamBuffer);
  if (reusable_buffer->size() < chunk_size) {
    reusable_buffer->resize(chunk_size);
  }

  int64_t copied = 0;
  bool copy_ok = true;

  while (true) {
    DWORD bytes_read = 0;
    if (!ReadFile(h_file, reusable_buffer->data(), chunk_size, &bytes_read,
                  nullptr)) {
      *err = FormatHrError("Failed reading local Windows file",
                           HRESULT_FROM_WIN32(GetLastError()));
      copy_ok = false;
      break;
    }
    if (bytes_read == 0) {
      break;
    }
    ULONG bytes_written = 0;
    hr = dest_stream->Write(reusable_buffer->data(), bytes_read,
                            &bytes_written);
    if (FAILED(hr) || bytes_written != bytes_read) {
      *err = FormatHrError("Failed writing bytes to phone", hr);
      copy_ok = false;
      break;
    }
    copied += static_cast<int64_t>(bytes_written);
  }

  CloseHandle(h_file);

  if (!copy_ok) {
    dest_stream->Revert();
    return false;
  }

  hr = dest_stream->Commit(STGC_DEFAULT);
  if (FAILED(hr)) {
    *err = FormatHrError("Failed committing file on phone", hr);
    return false;
  }

  *out_bytes_copied = copied;
  return true;
}

bool PullWpdFileImpl(const std::string& device_id,
                     const std::string& object_id,
                     const std::string& dest_local_path,
                     std::string* err) {
  ComPtr<IPortableDevice> device;
  HRESULT hr = OpenWpdDevice(Utf8ToWide(device_id), false, &device);
  if (FAILED(hr)) {
    *err = FormatHrError("Failed to open USB device", hr);
    return false;
  }

  ComPtr<IPortableDeviceContent> content;
  hr = device->Content(&content);
  if (FAILED(hr)) {
    *err = FormatHrError("Failed to get device content", hr);
    return false;
  }

  ComPtr<IPortableDeviceResources> resources;
  hr = content->Transfer(&resources);
  if (FAILED(hr)) {
    *err = FormatHrError("Failed to start USB resource transfer", hr);
    return false;
  }

  std::vector<uint8_t> buffer;
  int64_t bytes_copied = 0;
  return CopyWpdObjectToFile(resources.Get(), object_id, dest_local_path,
                             &buffer, &bytes_copied, err);
}

bool PushWpdFileImpl(const std::string& device_id,
                     const std::string& target_folder_object_id,
                     const std::string& local_file_path,
                     const std::string& file_name,
                     std::string* err) {
  ComPtr<IPortableDevice> device;
  HRESULT hr = OpenWpdDevice(Utf8ToWide(device_id), true, &device);
  if (FAILED(hr)) {
    *err = FormatHrError("Failed to open USB device for writing", hr);
    return false;
  }

  ComPtr<IPortableDeviceContent> content;
  hr = device->Content(&content);
  if (FAILED(hr)) {
    *err = FormatHrError("Failed to get device content", hr);
    return false;
  }

  std::vector<uint8_t> buffer;
  int64_t bytes_copied = 0;
  return CopyLocalFileToWpdFolder(content.Get(), target_folder_object_id,
                                  local_file_path, file_name, &buffer,
                                  &bytes_copied, err);
}

bool CreateWpdFolderImpl(const std::string& device_id,
                         const std::string& parent_object_id,
                         const std::string& folder_name,
                         std::string* created_id,
                         std::string* err) {
  ComPtr<IPortableDevice> device;
  HRESULT hr = OpenWpdDevice(Utf8ToWide(device_id), true, &device);
  if (FAILED(hr)) {
    *err = FormatHrError("Failed to open USB device", hr);
    return false;
  }

  ComPtr<IPortableDeviceContent> content;
  hr = device->Content(&content);
  if (FAILED(hr)) {
    *err = FormatHrError("Failed to get device content", hr);
    return false;
  }

  ComPtr<IPortableDeviceValues> values;
  hr = CoCreateInstance(CLSID_PortableDeviceValues, nullptr,
                        CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&values));
  if (FAILED(hr)) {
    *err = FormatHrError("Failed to create WPD values", hr);
    return false;
  }

  const std::wstring parent_wide = Utf8ToWide(parent_object_id);
  const std::wstring name_wide = Utf8ToWide(folder_name);
  values->SetStringValue(WPD_OBJECT_PARENT_ID, parent_wide.c_str());
  values->SetStringValue(WPD_OBJECT_NAME, name_wide.c_str());
  values->SetGuidValue(WPD_OBJECT_CONTENT_TYPE, WPD_CONTENT_TYPE_FOLDER);
  values->SetGuidValue(WPD_OBJECT_FORMAT, WPD_OBJECT_FORMAT_PROPERTIES_ONLY);

  PWSTR new_id = nullptr;
  hr = content->CreateObjectWithPropertiesOnly(values.Get(), &new_id);
  if (FAILED(hr)) {
    *err = FormatHrError("Failed creating folder on phone", hr);
    return false;
  }
  if (new_id) {
    *created_id = WideToUtf8(std::wstring(new_id));
    CoTaskMemFree(new_id);
  }
  return true;
}

}  // namespace

WpdBridge::WpdBridge(HWND hwnd, flutter::BinaryMessenger* messenger)
    : hwnd_(hwnd),
      alive_(std::make_shared<std::atomic<bool>>(true)),
      cancel_requested_(std::make_shared<std::atomic<bool>>(false)) {
  method_channel_ =
      std::make_unique<flutter::MethodChannel<EncodableValue>>(
          messenger, "devicebridge/wpd",
          &flutter::StandardMethodCodec::GetInstance());

  method_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        HandleMethodCall(call, std::move(result));
      });

  event_channel_ =
      std::make_unique<flutter::EventChannel<EncodableValue>>(
          messenger, "devicebridge/usb_events",
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

WpdBridge::~WpdBridge() {
  alive_->store(false);
  cancel_requested_->store(true);
  if (method_channel_) {
    method_channel_->SetMethodCallHandler(nullptr);
  }
  std::lock_guard<std::mutex> lock(sink_mutex_);
  event_sink_.reset();
}

void WpdBridge::NotifyUsbChanged() {
  std::lock_guard<std::mutex> lock(sink_mutex_);
  if (event_sink_) {
    event_sink_->Success(EncodableValue("device_change"));
  }
}

void WpdBridge::EmitProgress(const std::string& direction,
                             int completed_files,
                             int total_files,
                             int64_t bytes_transferred,
                             const std::string& current_file) {
  auto alive = alive_;
  PostToUiThread([this, alive, direction, completed_files, total_files,
                  bytes_transferred, current_file]() {
    if (!alive->load()) return;
    std::lock_guard<std::mutex> lock(sink_mutex_);
    if (!event_sink_) return;
    EncodableMap payload;
    payload[EncodableValue("type")] = EncodableValue("batch_progress");
    payload[EncodableValue("direction")] = EncodableValue(direction);
    payload[EncodableValue("completedFiles")] = EncodableValue(completed_files);
    payload[EncodableValue("totalFiles")] = EncodableValue(total_files);
    payload[EncodableValue("bytesTransferred")] =
        EncodableValue(bytes_transferred);
    payload[EncodableValue("currentFile")] = EncodableValue(current_file);
    event_sink_->Success(EncodableValue(payload));
  });
}

void WpdBridge::PostToUiThread(std::function<void()> task) {
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    callback_queue_.push(std::move(task));
  }
  if (hwnd_) {
    PostMessage(hwnd_, kWmWpdCallback, 0, 0);
  }
}

void WpdBridge::DrainCallbacks() {
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

void WpdBridge::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const std::string& method = call.method_name();
  EncodableMap args;
  if (const auto* map_ptr = std::get_if<EncodableMap>(call.arguments())) {
    args = *map_ptr;
  }

  if (method == "cancelBatch") {
    cancel_requested_->store(true);
    result->Success(EncodableValue(true));
    return;
  }

  auto shared_result =
      std::shared_ptr<flutter::MethodResult<EncodableValue>>(std::move(result));
  auto alive = alive_;

  if (method == "listDevices") {
    std::thread([this, alive, shared_result]() {
      CoInitializeEx(nullptr, COINIT_MULTITHREADED);
      EncodableList devices;
      std::string err;
      const bool ok = ListWpdDevicesImpl(&devices, &err);
      CoUninitialize();
      if (!alive->load()) return;
      PostToUiThread([alive, shared_result, ok, devices = std::move(devices),
                      err = std::move(err)]() {
        if (!alive->load()) return;
        if (ok) {
          shared_result->Success(EncodableValue(devices));
        } else {
          shared_result->Error("WPD_ERROR", err);
        }
      });
    }).detach();
    return;
  }

  if (method == "listChildren") {
    const std::string device_id = GetStringArg(args, "deviceId");
    const std::string folder_id = GetStringArg(args, "folderObjectId");
    if (device_id.empty()) {
      shared_result->Error("INVALID_ARGS", "deviceId is required");
      return;
    }
    std::thread([this, alive, shared_result, device_id, folder_id]() {
      CoInitializeEx(nullptr, COINIT_MULTITHREADED);
      EncodableList entries;
      std::string err;
      const bool ok = ListWpdChildrenImpl(device_id, folder_id, &entries, &err);
      CoUninitialize();
      if (!alive->load()) return;
      PostToUiThread([alive, shared_result, ok, entries = std::move(entries),
                      err = std::move(err)]() {
        if (!alive->load()) return;
        if (ok) {
          shared_result->Success(EncodableValue(entries));
        } else {
          shared_result->Error("WPD_ERROR", err);
        }
      });
    }).detach();
    return;
  }

  if (method == "pullFile") {
    const std::string device_id = GetStringArg(args, "deviceId");
    const std::string object_id = GetStringArg(args, "objectId");
    const std::string dest_path = GetStringArg(args, "destPath");
    if (device_id.empty() || object_id.empty() || dest_path.empty()) {
      shared_result->Error("INVALID_ARGS",
                           "deviceId, objectId, and destPath are required");
      return;
    }
    std::thread([this, alive, shared_result, device_id, object_id,
                 dest_path]() {
      CoInitializeEx(nullptr, COINIT_MULTITHREADED);
      std::string err;
      const bool ok = PullWpdFileImpl(device_id, object_id, dest_path, &err);
      CoUninitialize();
      if (!alive->load()) return;
      PostToUiThread([alive, shared_result, ok, dest_path,
                      err = std::move(err)]() {
        if (!alive->load()) return;
        if (ok) {
          shared_result->Success(EncodableValue(dest_path));
        } else {
          shared_result->Error("WPD_ERROR", err);
        }
      });
    }).detach();
    return;
  }

  if (method == "pullBatch") {
    const std::string device_id = GetStringArg(args, "deviceId");
    const EncodableList items = GetListArg(args, "items");
    if (device_id.empty()) {
      shared_result->Error("INVALID_ARGS", "deviceId is required");
      return;
    }
    cancel_requested_->store(false);
    auto cancel = cancel_requested_;

    std::thread([this, alive, cancel, shared_result, device_id, items]() {
      CoInitializeEx(nullptr, COINIT_MULTITHREADED);

      ComPtr<IPortableDevice> device;
      std::string open_err;
      HRESULT hr = OpenWpdDevice(Utf8ToWide(device_id), false, &device);
      ComPtr<IPortableDeviceContent> content;
      ComPtr<IPortableDeviceResources> resources;
      if (FAILED(hr)) {
        open_err = FormatHrError("Failed to open USB device", hr);
      } else {
        hr = device->Content(&content);
        if (FAILED(hr)) {
          open_err = FormatHrError("Failed to get device content", hr);
        } else {
          hr = content->Transfer(&resources);
          if (FAILED(hr)) {
            open_err = FormatHrError("Failed to start USB transfer", hr);
          }
        }
      }

      if (!open_err.empty()) {
        CoUninitialize();
        if (!alive->load()) return;
        PostToUiThread([alive, shared_result, open_err]() {
          if (!alive->load()) return;
          shared_result->Error("WPD_ERROR", open_err);
        });
        return;
      }

      EncodableList succeeded_paths;
      EncodableList failures;
      std::vector<uint8_t> buffer;
      int64_t total_bytes = 0;
      int completed = 0;
      const int total_count = static_cast<int>(items.size());
      bool was_cancelled = false;
      auto last_emit = std::chrono::steady_clock::now();

      for (const auto& entry_val : items) {
        if (cancel->load() || !alive->load()) {
          was_cancelled = true;
          break;
        }
        const auto* item_map = std::get_if<EncodableMap>(&entry_val);
        if (!item_map) continue;
        const std::string obj_id = GetStringArg(*item_map, "objectId");
        const std::string dest_path = GetStringArg(*item_map, "destPath");
        const std::string file_name = GetStringArg(*item_map, "fileName");

        int64_t file_bytes = 0;
        std::string item_err;
        if (CopyWpdObjectToFile(resources.Get(), obj_id, dest_path, &buffer,
                                &file_bytes, &item_err)) {
          total_bytes += file_bytes;
          succeeded_paths.push_back(EncodableValue(dest_path));
        } else {
          EncodableMap fail;
          fail[EncodableValue("objectId")] = EncodableValue(obj_id);
          fail[EncodableValue("error")] = EncodableValue(item_err);
          failures.push_back(EncodableValue(fail));
        }
        completed++;

        const auto now = std::chrono::steady_clock::now();
        if (completed == total_count ||
            std::chrono::duration_cast<std::chrono::milliseconds>(now - last_emit)
                    .count() >= 80) {
          last_emit = now;
          EmitProgress("phoneToPc", completed, total_count, total_bytes,
                       file_name);
        }
      }

      CoUninitialize();
      if (!alive->load()) return;

      PostToUiThread([alive, shared_result,
                      succeeded_paths = std::move(succeeded_paths),
                      failures = std::move(failures), total_bytes,
                      was_cancelled]() {
        if (!alive->load()) return;
        EncodableMap out;
        out[EncodableValue("succeeded")] = EncodableValue(succeeded_paths);
        out[EncodableValue("failed")] = EncodableValue(failures);
        out[EncodableValue("bytesTransferred")] = EncodableValue(total_bytes);
        out[EncodableValue("cancelled")] = EncodableValue(was_cancelled);
        shared_result->Success(EncodableValue(out));
      });
    }).detach();
    return;
  }

  if (method == "pushFile") {
    const std::string device_id = GetStringArg(args, "deviceId");
    const std::string folder_id = GetStringArg(args, "targetFolderObjectId");
    const std::string local_path = GetStringArg(args, "localPath");
    const std::string file_name = GetStringArg(args, "fileName");
    if (device_id.empty() || folder_id.empty() || local_path.empty() ||
        file_name.empty()) {
      shared_result->Error(
          "INVALID_ARGS",
          "deviceId, targetFolderObjectId, localPath, and fileName required");
      return;
    }
    std::thread([this, alive, shared_result, device_id, folder_id, local_path,
                 file_name]() {
      CoInitializeEx(nullptr, COINIT_MULTITHREADED);
      std::string err;
      const bool ok = PushWpdFileImpl(device_id, folder_id, local_path,
                                      file_name, &err);
      CoUninitialize();
      if (!alive->load()) return;
      PostToUiThread([alive, shared_result, ok, err = std::move(err)]() {
        if (!alive->load()) return;
        if (ok) {
          shared_result->Success(EncodableValue(true));
        } else {
          shared_result->Error("WPD_ERROR", err);
        }
      });
    }).detach();
    return;
  }

  if (method == "pushBatch") {
    const std::string device_id = GetStringArg(args, "deviceId");
    const EncodableList items = GetListArg(args, "items");
    if (device_id.empty()) {
      shared_result->Error("INVALID_ARGS", "deviceId is required");
      return;
    }
    cancel_requested_->store(false);
    auto cancel = cancel_requested_;

    std::thread([this, alive, cancel, shared_result, device_id, items]() {
      CoInitializeEx(nullptr, COINIT_MULTITHREADED);

      ComPtr<IPortableDevice> device;
      std::string open_err;
      HRESULT hr = OpenWpdDevice(Utf8ToWide(device_id), true, &device);
      ComPtr<IPortableDeviceContent> content;
      if (FAILED(hr)) {
        open_err = FormatHrError("Failed to open USB device for writing", hr);
      } else {
        hr = device->Content(&content);
        if (FAILED(hr)) {
          open_err = FormatHrError("Failed to get device content", hr);
        }
      }

      if (!open_err.empty()) {
        CoUninitialize();
        if (!alive->load()) return;
        PostToUiThread([alive, shared_result, open_err]() {
          if (!alive->load()) return;
          shared_result->Error("WPD_ERROR", open_err);
        });
        return;
      }

      int succeeded_count = 0;
      EncodableList failures;
      std::vector<uint8_t> buffer;
      int64_t total_bytes = 0;
      int completed = 0;
      const int total_count = static_cast<int>(items.size());
      bool was_cancelled = false;
      auto last_emit = std::chrono::steady_clock::now();

      for (const auto& entry_val : items) {
        if (cancel->load() || !alive->load()) {
          was_cancelled = true;
          break;
        }
        const auto* item_map = std::get_if<EncodableMap>(&entry_val);
        if (!item_map) continue;
        const std::string folder_id =
            GetStringArg(*item_map, "targetFolderObjectId");
        const std::string local_path = GetStringArg(*item_map, "localPath");
        const std::string file_name = GetStringArg(*item_map, "fileName");

        int64_t file_bytes = 0;
        std::string item_err;
        if (CopyLocalFileToWpdFolder(content.Get(), folder_id, local_path,
                                     file_name, &buffer, &file_bytes,
                                     &item_err)) {
          total_bytes += file_bytes;
          succeeded_count++;
        } else {
          EncodableMap fail;
          fail[EncodableValue("localPath")] = EncodableValue(local_path);
          fail[EncodableValue("error")] = EncodableValue(item_err);
          failures.push_back(EncodableValue(fail));
        }
        completed++;

        const auto now = std::chrono::steady_clock::now();
        if (completed == total_count ||
            std::chrono::duration_cast<std::chrono::milliseconds>(now - last_emit)
                    .count() >= 80) {
          last_emit = now;
          EmitProgress("pcToPhone", completed, total_count, total_bytes,
                       file_name);
        }
      }

      CoUninitialize();
      if (!alive->load()) return;

      PostToUiThread([alive, shared_result, succeeded_count,
                      failures = std::move(failures), total_bytes,
                      was_cancelled]() {
        if (!alive->load()) return;
        EncodableMap out;
        out[EncodableValue("succeededCount")] = EncodableValue(succeeded_count);
        out[EncodableValue("failed")] = EncodableValue(failures);
        out[EncodableValue("bytesTransferred")] = EncodableValue(total_bytes);
        out[EncodableValue("cancelled")] = EncodableValue(was_cancelled);
        shared_result->Success(EncodableValue(out));
      });
    }).detach();
    return;
  }

  if (method == "createFolder") {
    const std::string device_id = GetStringArg(args, "deviceId");
    const std::string parent_id = GetStringArg(args, "parentObjectId");
    const std::string folder_name = GetStringArg(args, "folderName");
    if (device_id.empty() || parent_id.empty() || folder_name.empty()) {
      shared_result->Error(
          "INVALID_ARGS",
          "deviceId, parentObjectId, and folderName are required");
      return;
    }
    std::thread([this, alive, shared_result, device_id, parent_id,
                 folder_name]() {
      CoInitializeEx(nullptr, COINIT_MULTITHREADED);
      std::string created_id;
      std::string err;
      const bool ok = CreateWpdFolderImpl(device_id, parent_id, folder_name,
                                          &created_id, &err);
      CoUninitialize();
      if (!alive->load()) return;
      PostToUiThread([alive, shared_result, ok,
                      created_id = std::move(created_id),
                      err = std::move(err)]() {
        if (!alive->load()) return;
        if (ok) {
          shared_result->Success(EncodableValue(created_id));
        } else {
          shared_result->Error("WPD_ERROR", err);
        }
      });
    }).detach();
    return;
  }

  shared_result->NotImplemented();
}
