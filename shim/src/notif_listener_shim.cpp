#include "notif_listener_shim.h"

#include <winrt/Windows.ApplicationModel.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Imaging.h>
#include <winrt/Windows.Storage.Streams.h>
#include <winrt/Windows.UI.Notifications.Management.h>
#include <winrt/Windows.UI.Notifications.h>

#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <functional>
#include <mutex>
#include <queue>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

namespace {

using namespace winrt;
using namespace winrt::Windows::ApplicationModel;
using namespace winrt::Windows::Foundation;
using namespace winrt::Windows::Graphics::Imaging;
using namespace winrt::Windows::Storage::Streams;
using namespace winrt::Windows::UI::Notifications;
using namespace winrt::Windows::UI::Notifications::Management;

constexpr int32_t kOk = 0;
constexpr int32_t kErrorNotInitialized = -1;
constexpr int32_t kErrorWorkerFailed = -2;
constexpr int32_t kErrorCallFailed = -3;

// 直近のエラー。解放不要の静的バッファとして返す。
std::string g_last_error;
std::mutex g_last_error_mutex;

void set_last_error(const std::string& message) {
  std::lock_guard<std::mutex> lock(g_last_error_mutex);
  g_last_error = message;
}

std::string format_exception(const hresult_error& error) {
  return "HRESULT 0x" + std::to_string(static_cast<uint32_t>(error.code())) + ": " +
         to_string(error.message());
}

// WinRT の呼び出しを引き受けるワーカースレッド。
//
// IAsyncOperation の同期待ち（get）は STA では行えない。
// 呼び出し側のスレッドを MTA に固定してしまうと、そのスレッドで動くトレイやシェル操作に影響が出る。
// そのため WinRT に触れるスレッドをこのライブラリの内部に閉じ、呼び出しはそこへ渡す。
class Worker {
 public:
  bool start() {
    std::unique_lock<std::mutex> lock(mutex_);
    if (running_) {
      return true;
    }

    ready_ = false;
    failed_ = false;
    stopping_ = false;
    thread_ = std::thread([this] { run(); });
    ready_condition_.wait(lock, [this] { return ready_ || failed_; });

    if (failed_) {
      lock.unlock();
      join();
      return false;
    }
    running_ = true;
    return true;
  }

  void stop() {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (!running_) {
        return;
      }
      stopping_ = true;
    }
    queue_condition_.notify_all();
    join();

    std::lock_guard<std::mutex> lock(mutex_);
    running_ = false;
  }

  bool running() {
    std::lock_guard<std::mutex> lock(mutex_);
    return running_;
  }

  // 呼び出しをワーカースレッドへ渡し、終わるまで待つ。
  bool invoke(const std::function<void()>& work) {
    std::unique_lock<std::mutex> lock(mutex_);
    if (!running_) {
      return false;
    }

    bool done = false;
    tasks_.push([&] {
      // 例外が抜けると待ち側が起こされないため、ここで必ず捕捉する。
      try {
        work();
      } catch (...) {
        set_last_error("ワーカースレッドで捕捉されない例外が出た");
      }
      {
        std::lock_guard<std::mutex> inner(mutex_);
        done = true;
      }
      done_condition_.notify_all();
    });
    queue_condition_.notify_one();
    done_condition_.wait(lock, [&] { return done; });
    return true;
  }

 private:
  void run() {
    try {
      init_apartment(apartment_type::multi_threaded);
    } catch (...) {
      std::lock_guard<std::mutex> lock(mutex_);
      failed_ = true;
      ready_condition_.notify_all();
      return;
    }

    {
      std::lock_guard<std::mutex> lock(mutex_);
      ready_ = true;
    }
    ready_condition_.notify_all();

    while (true) {
      std::function<void()> task;
      {
        std::unique_lock<std::mutex> lock(mutex_);
        queue_condition_.wait(lock, [this] { return stopping_ || !tasks_.empty(); });
        if (stopping_ && tasks_.empty()) {
          break;
        }
        task = tasks_.front();
        tasks_.pop();
      }
      task();
    }

    uninit_apartment();
  }

  void join() {
    if (thread_.joinable()) {
      thread_.join();
    }
  }

  std::thread thread_;
  std::mutex mutex_;
  std::condition_variable ready_condition_;
  std::condition_variable queue_condition_;
  std::condition_variable done_condition_;
  std::queue<std::function<void()>> tasks_;
  bool running_ = false;
  bool ready_ = false;
  bool failed_ = false;
  bool stopping_ = false;
};

Worker g_worker;

// アイコンの取得と base64 化は通知ごとに行うとコストが高いため、app_id をキーに覚える。
// 常駐アプリの実用上、通知を出すアプリ数は高々数十であり、上限は設けない。
std::unordered_map<std::wstring, std::string> g_icon_cache;

const char kBase64Alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

std::string to_base64(const std::vector<uint8_t>& bytes) {
  std::string encoded;
  encoded.reserve(((bytes.size() + 2) / 3) * 4);

  size_t index = 0;
  while (index + 2 < bytes.size()) {
    const uint32_t triple = (bytes[index] << 16) | (bytes[index + 1] << 8) | bytes[index + 2];
    encoded.push_back(kBase64Alphabet[(triple >> 18) & 0x3F]);
    encoded.push_back(kBase64Alphabet[(triple >> 12) & 0x3F]);
    encoded.push_back(kBase64Alphabet[(triple >> 6) & 0x3F]);
    encoded.push_back(kBase64Alphabet[triple & 0x3F]);
    index += 3;
  }

  const size_t remaining = bytes.size() - index;
  if (remaining == 1) {
    const uint32_t triple = bytes[index] << 16;
    encoded.push_back(kBase64Alphabet[(triple >> 18) & 0x3F]);
    encoded.push_back(kBase64Alphabet[(triple >> 12) & 0x3F]);
    encoded.append("==");
  } else if (remaining == 2) {
    const uint32_t triple = (bytes[index] << 16) | (bytes[index + 1] << 8);
    encoded.push_back(kBase64Alphabet[(triple >> 18) & 0x3F]);
    encoded.push_back(kBase64Alphabet[(triple >> 12) & 0x3F]);
    encoded.push_back(kBase64Alphabet[(triple >> 6) & 0x3F]);
    encoded.push_back('=');
  }
  return encoded;
}

void append_json_string(std::string& out, const std::string& value) {
  out.push_back('"');
  for (const unsigned char c : value) {
    switch (c) {
      case '"': out.append("\\\""); break;
      case '\\': out.append("\\\\"); break;
      case '\b': out.append("\\b"); break;
      case '\f': out.append("\\f"); break;
      case '\n': out.append("\\n"); break;
      case '\r': out.append("\\r"); break;
      case '\t': out.append("\\t"); break;
      default:
        if (c < 0x20) {
          char buffer[7];
          std::snprintf(buffer, sizeof(buffer), "\\u%04x", c);
          out.append(buffer);
        } else {
          out.push_back(static_cast<char>(c));
        }
    }
  }
  out.push_back('"');
}

// CreationTime を ISO 8601 の UTC 表記で書き出す。
std::string to_iso8601(const DateTime& value) {
  const time_t seconds = clock::to_time_t(value);
  tm utc{};
  if (gmtime_s(&utc, &seconds) != 0) {
    return "";
  }
  char buffer[32];
  std::strftime(buffer, sizeof(buffer), "%Y-%m-%dT%H:%M:%SZ", &utc);
  return std::string(buffer);
}

std::vector<uint8_t> read_all(const IRandomAccessStream& stream) {
  DataReader reader(stream.GetInputStreamAt(0));
  const uint32_t size = static_cast<uint32_t>(stream.Size());
  reader.LoadAsync(size).get();

  std::vector<uint8_t> bytes(size);
  if (size > 0) {
    reader.ReadBytes(array_view<uint8_t>(bytes.data(), bytes.data() + size));
  }
  return bytes;
}

// ロゴを PNG へ変換して base64 化する。
// 形式はアプリによって差があるため、いったんデコードしてから PNG で書き直す。
std::string logo_as_png_base64(const AppDisplayInfo& display_info) {
  const auto reference = display_info.GetLogo(Size(48.0f, 48.0f));
  if (!reference) {
    return "";
  }

  const auto source = reference.OpenReadAsync().get();
  const auto decoder = BitmapDecoder::CreateAsync(source).get();

  InMemoryRandomAccessStream target;
  const auto encoder = BitmapEncoder::CreateForTranscodingAsync(target, decoder).get();
  encoder.FlushAsync().get();

  return to_base64(read_all(target));
}

std::string icon_for(const std::wstring& app_id, const AppDisplayInfo& display_info) {
  const auto cached = g_icon_cache.find(app_id);
  if (cached != g_icon_cache.end()) {
    return cached->second;
  }

  std::string encoded;
  try {
    encoded = logo_as_png_base64(display_info);
  } catch (...) {
    encoded = "";
  }
  g_icon_cache.emplace(app_id, encoded);
  return encoded;
}

// ToastGeneric のバインディングからテキスト要素を取り出す。
// 1 要素目を title、2 要素目以降を改行連結して body とする。
void read_texts(const UserNotification& notification, std::string& title, std::string& body) {
  const auto content = notification.Notification();
  if (!content) {
    return;
  }
  const auto visual = content.Visual();
  if (!visual) {
    return;
  }
  const auto binding = visual.GetBinding(KnownNotificationBindings::ToastGeneric());
  if (!binding) {
    return;
  }

  const auto elements = binding.GetTextElements();
  for (uint32_t index = 0; index < elements.Size(); ++index) {
    const auto text = to_string(elements.GetAt(index).Text());
    if (index == 0) {
      title = text;
    } else {
      if (!body.empty()) {
        body.push_back('\n');
      }
      body.append(text);
    }
  }
}

void append_notification(std::string& out, const UserNotification& notification) {
  std::string app_id;
  std::string app_name;
  std::string icon;

  try {
    const auto app_info = notification.AppInfo();
    if (app_info) {
      const auto model_id = app_info.AppUserModelId();
      app_id = to_string(model_id);

      const auto display_info = app_info.DisplayInfo();
      if (display_info) {
        app_name = to_string(display_info.DisplayName());
        icon = icon_for(std::wstring(model_id.c_str()), display_info);
      }
    }
  } catch (...) {
    // アプリ情報が取れない通知でも、本文だけは中継できるようにする。
  }

  std::string title;
  std::string body;
  try {
    read_texts(notification, title, body);
  } catch (...) {
  }

  out.append("{\"id\":");
  out.append(std::to_string(notification.Id()));
  out.append(",\"app_id\":");
  append_json_string(out, app_id);
  out.append(",\"app_name\":");
  append_json_string(out, app_name);
  out.append(",\"title\":");
  append_json_string(out, title);
  out.append(",\"body\":");
  append_json_string(out, body);
  out.append(",\"created_at\":");
  append_json_string(out, to_iso8601(notification.CreationTime()));
  if (!icon.empty()) {
    out.append(",\"icon_png_base64\":");
    append_json_string(out, icon);
  }
  out.push_back('}');
}

char* duplicate(const std::string& value) {
  char* buffer = static_cast<char*>(std::malloc(value.size() + 1));
  if (!buffer) {
    return nullptr;
  }
  std::memcpy(buffer, value.c_str(), value.size() + 1);
  return buffer;
}

int32_t access_status_code(UserNotificationListenerAccessStatus status) {
  switch (status) {
    case UserNotificationListenerAccessStatus::Allowed: return 0;
    case UserNotificationListenerAccessStatus::Denied: return 1;
    default: return 2;
  }
}

}  // namespace

int32_t nls_init(void) {
  if (g_worker.running()) {
    return kOk;
  }
  if (!g_worker.start()) {
    set_last_error("WinRT のワーカースレッドを開始できなかった");
    return kErrorWorkerFailed;
  }
  return kOk;
}

void nls_shutdown(void) {
  g_worker.stop();
  g_icon_cache.clear();
}

int32_t nls_get_access_status(void) {
  int32_t result = kErrorCallFailed;
  const bool dispatched = g_worker.invoke([&] {
    try {
      result = access_status_code(UserNotificationListener::Current().GetAccessStatus());
    } catch (const hresult_error& error) {
      set_last_error(format_exception(error));
      result = kErrorCallFailed;
    } catch (...) {
      set_last_error("GetAccessStatus で不明な例外が出た");
      result = kErrorCallFailed;
    }
  });

  if (!dispatched) {
    set_last_error("nls_init を先に呼ぶ必要がある");
    return kErrorNotInitialized;
  }
  return result;
}

int32_t nls_request_access(void) {
  int32_t result = kErrorCallFailed;
  const bool dispatched = g_worker.invoke([&] {
    try {
      result = access_status_code(UserNotificationListener::Current().RequestAccessAsync().get());
    } catch (const hresult_error& error) {
      set_last_error(format_exception(error));
      result = kErrorCallFailed;
    } catch (...) {
      set_last_error("RequestAccessAsync で不明な例外が出た");
      result = kErrorCallFailed;
    }
  });

  if (!dispatched) {
    set_last_error("nls_init を先に呼ぶ必要がある");
    return kErrorNotInitialized;
  }
  return result;
}

const char* nls_get_notifications(void) {
  std::string json;
  bool failed = false;

  const bool dispatched = g_worker.invoke([&] {
    try {
      const auto notifications =
          UserNotificationListener::Current().GetNotificationsAsync(NotificationKinds::Toast).get();

      json.append("{\"notifications\":[");
      for (uint32_t index = 0; index < notifications.Size(); ++index) {
        if (index > 0) {
          json.push_back(',');
        }
        append_notification(json, notifications.GetAt(index));
      }
      json.append("]}");
    } catch (const hresult_error& error) {
      set_last_error(format_exception(error));
      failed = true;
    } catch (...) {
      set_last_error("GetNotificationsAsync で不明な例外が出た");
      failed = true;
    }
  });

  if (!dispatched) {
    set_last_error("nls_init を先に呼ぶ必要がある");
    return nullptr;
  }
  if (failed) {
    return nullptr;
  }
  return duplicate(json);
}

void nls_free_string(const char* p) {
  std::free(const_cast<char*>(p));
}

const char* nls_last_error(void) {
  std::lock_guard<std::mutex> lock(g_last_error_mutex);
  return g_last_error.c_str();
}
