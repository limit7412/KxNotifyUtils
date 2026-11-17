#include "nvml_monitor.h"

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

#include <cstdio>
#include <cstring>

namespace {

// nvml.h から写した宣言。ヘッダを同梱せず、使う関数だけをここに持つ。
using NvmlDevice = void*;
using NvmlReturn = int;
constexpr NvmlReturn kNvmlSuccess = 0;

constexpr int kSensorGpu = 0;
constexpr int kThresholdShutdown = 0;
constexpr int kThresholdSlowdown = 1;
constexpr int kThresholdGpuMax = 3;

struct NvmlTemperature {
  unsigned int version;
  int sensor_type;
  int temperature;
};
// NVML_STRUCT_VERSION(Temperature, 1)
constexpr unsigned int kTemperatureVersion =
    static_cast<unsigned int>(sizeof(NvmlTemperature)) | (1U << 24U);

using InitFn = NvmlReturn (*)();
using ShutdownFn = NvmlReturn (*)();
using CountFn = NvmlReturn (*)(unsigned int*);
using HandleFn = NvmlReturn (*)(unsigned int, NvmlDevice*);
using TemperatureFn = NvmlReturn (*)(NvmlDevice, int, unsigned int*);
using TemperatureVFn = NvmlReturn (*)(NvmlDevice, NvmlTemperature*);
using ThresholdFn = NvmlReturn (*)(NvmlDevice, int, unsigned int*);
using FanFn = NvmlReturn (*)(NvmlDevice, unsigned int*);
using FanV2Fn = NvmlReturn (*)(NvmlDevice, unsigned int, unsigned int*);
using NumFansFn = NvmlReturn (*)(NvmlDevice, unsigned int*);
using ReasonsFn = NvmlReturn (*)(NvmlDevice, unsigned long long*);

struct Api {
  HMODULE module = nullptr;
  InitFn init = nullptr;
  ShutdownFn shutdown = nullptr;
  CountFn count = nullptr;
  HandleFn handle = nullptr;
  // 温度は新旧どちらかがあればよい。古い関数は廃止予定だが、広い版のドライバにある。
  TemperatureFn temperature = nullptr;
  TemperatureVFn temperature_v = nullptr;
  // ここから下は無くても動く。無ければその項目が NVM_UNKNOWN になる。
  ThresholdFn threshold = nullptr;
  FanFn fan = nullptr;
  FanV2Fn fan_v2 = nullptr;
  NumFansFn num_fans = nullptr;
  ReasonsFn reasons = nullptr;
};

constexpr unsigned int kMaxDevices = 8;
constexpr unsigned int kMaxFans = 8;

struct Device {
  NvmlDevice handle = nullptr;
  int32_t limit_gpu_max_c = NVM_UNKNOWN;
  int32_t limit_slowdown_c = NVM_UNKNOWN;
  int32_t limit_shutdown_c = NVM_UNKNOWN;
  unsigned int fan_count = 0;
};

// 温度が続けて取れなかったとき、NVML を初期化し直すまでの回数。
// ドライバを更新すると、それまでのハンドルは使えなくなる。
constexpr unsigned int kReopenAfterFailures = 10;

// 止めるときに取得スレッドの終了を待つ上限。
// NVML の中で止まっているスレッドを待ち続けると、本体の終了がそこで止まる。
constexpr DWORD kStopWaitMs = 1000;

// 取得スレッドと呼び出し側で共有する状態。
//
// デストラクタを持つ型を置かない。終了を待てなかった取得スレッドは
// プロセスの終了まで残り、静的オブジェクトの破棄と競合しうるためである。
SRWLOCK g_lock = SRWLOCK_INIT;
nvm_sample g_sample = {};
ULONGLONG g_sampled_at = 0;
char g_last_error[256] = "";

HANDLE g_thread = nullptr;
HANDLE g_stop_event = nullptr;
volatile LONG g_interval_ms = 1000;
// 止めるよう頼んだか。頼んだのに終わっていないスレッドは NVML の中で止まっている。
bool g_stop_requested = false;

nvm_sample empty_sample(int32_t state) {
  nvm_sample sample = {};
  sample.state = state;
  sample.temperature_c = NVM_UNKNOWN;
  sample.limit_gpu_max_c = NVM_UNKNOWN;
  sample.limit_slowdown_c = NVM_UNKNOWN;
  sample.limit_shutdown_c = NVM_UNKNOWN;
  sample.fan_percent = NVM_UNKNOWN;
  return sample;
}

void publish(const nvm_sample& sample) {
  AcquireSRWLockExclusive(&g_lock);
  g_sample = sample;
  g_sampled_at = GetTickCount64();
  ReleaseSRWLockExclusive(&g_lock);
}

void set_error(const char* message) {
  AcquireSRWLockExclusive(&g_lock);
  std::snprintf(g_last_error, sizeof(g_last_error), "%s", message);
  ReleaseSRWLockExclusive(&g_lock);
}

void set_error_code(const char* what, long code) {
  char buffer[256];
  std::snprintf(buffer, sizeof(buffer), "%s (%ld)", what, code);
  set_error(buffer);
}

// nvml.dll を探してロードする。
//
// 名前だけで探すのは System32 に限る。カレントディレクトリや PATH を探すと、
// そこに置かれた同名の DLL を読み込むことになる。
// 古いドライバは System32 に置かず NVSMI のフォルダに置くため、そちらは完全なパスで試す。
HMODULE load_library() {
  if (HMODULE module = LoadLibraryExW(L"nvml.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32)) {
    return module;
  }

  wchar_t path[MAX_PATH];
  const DWORD length = ExpandEnvironmentStringsW(
      L"%ProgramW6432%\\NVIDIA Corporation\\NVSMI\\nvml.dll", path, MAX_PATH);
  if (length == 0 || length > MAX_PATH) {
    return nullptr;
  }
  return LoadLibraryExW(path, nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
}

template <typename Fn>
Fn symbol(HMODULE module, const char* name) {
  return reinterpret_cast<Fn>(reinterpret_cast<void*>(GetProcAddress(module, name)));
}

bool load_api(Api& api) {
  api.module = load_library();
  if (!api.module) {
    set_error("nvml.dll was not found");
    return false;
  }

  api.init = symbol<InitFn>(api.module, "nvmlInit_v2");
  api.shutdown = symbol<ShutdownFn>(api.module, "nvmlShutdown");
  api.count = symbol<CountFn>(api.module, "nvmlDeviceGetCount_v2");
  api.handle = symbol<HandleFn>(api.module, "nvmlDeviceGetHandleByIndex_v2");
  api.temperature = symbol<TemperatureFn>(api.module, "nvmlDeviceGetTemperature");
  api.temperature_v = symbol<TemperatureVFn>(api.module, "nvmlDeviceGetTemperatureV");
  api.threshold = symbol<ThresholdFn>(api.module, "nvmlDeviceGetTemperatureThreshold");
  api.fan = symbol<FanFn>(api.module, "nvmlDeviceGetFanSpeed");
  api.fan_v2 = symbol<FanV2Fn>(api.module, "nvmlDeviceGetFanSpeed_v2");
  api.num_fans = symbol<NumFansFn>(api.module, "nvmlDeviceGetNumFans");
  // 新しいドライバでは EventReasons、古いドライバでは同じ値を ThrottleReasons が返す。
  api.reasons = symbol<ReasonsFn>(api.module, "nvmlDeviceGetCurrentClocksEventReasons");
  if (!api.reasons) {
    api.reasons = symbol<ReasonsFn>(api.module, "nvmlDeviceGetCurrentClocksThrottleReasons");
  }

  if (!api.init || !api.shutdown || !api.count || !api.handle ||
      (!api.temperature && !api.temperature_v)) {
    set_error("nvml.dll does not export the required functions");
    return false;
  }
  return true;
}

int32_t read_threshold(const Api& api, NvmlDevice device, int kind) {
  if (!api.threshold) {
    return NVM_UNKNOWN;
  }
  unsigned int value = 0;
  if (api.threshold(device, kind, &value) != kNvmlSuccess || value == 0 || value > 200) {
    return NVM_UNKNOWN;
  }
  return static_cast<int32_t>(value);
}

// NVML を初期化し、GPU を数えて、変わらない値（しきい値とファンの数）を読む。
// 戻り値は見つかった GPU の数。0 なら使えない。
unsigned int open_devices(const Api& api, Device* devices) {
  const NvmlReturn code = api.init();
  if (code != kNvmlSuccess) {
    set_error_code("nvmlInit_v2 failed", code);
    return 0;
  }

  unsigned int total = 0;
  if (api.count(&total) != kNvmlSuccess || total == 0) {
    set_error("no NVIDIA GPU was found");
    api.shutdown();
    return 0;
  }

  unsigned int found = 0;
  for (unsigned int index = 0; index < total && found < kMaxDevices; ++index) {
    Device device;
    if (api.handle(index, &device.handle) != kNvmlSuccess || !device.handle) {
      continue;
    }
    device.limit_gpu_max_c = read_threshold(api, device.handle, kThresholdGpuMax);
    device.limit_slowdown_c = read_threshold(api, device.handle, kThresholdSlowdown);
    device.limit_shutdown_c = read_threshold(api, device.handle, kThresholdShutdown);
    if (api.fan_v2 && api.num_fans) {
      unsigned int fans = 0;
      if (api.num_fans(device.handle, &fans) == kNvmlSuccess) {
        device.fan_count = fans < kMaxFans ? fans : kMaxFans;
      }
    }
    devices[found++] = device;
  }

  if (found == 0) {
    set_error("no NVIDIA GPU handle could be opened");
    api.shutdown();
  }
  return found;
}

int32_t read_temperature(const Api& api, NvmlDevice device) {
  if (api.temperature) {
    unsigned int value = 0;
    if (api.temperature(device, kSensorGpu, &value) == kNvmlSuccess && value <= 200) {
      return static_cast<int32_t>(value);
    }
  }
  if (api.temperature_v) {
    NvmlTemperature data = {};
    data.version = kTemperatureVersion;
    data.sensor_type = kSensorGpu;
    if (api.temperature_v(device, &data) == kNvmlSuccess && data.temperature >= 0 &&
        data.temperature <= 200) {
      return static_cast<int32_t>(data.temperature);
    }
  }
  return NVM_UNKNOWN;
}

int32_t read_fan(const Api& api, const Device& device) {
  int32_t highest = NVM_UNKNOWN;
  for (unsigned int fan = 0; fan < device.fan_count; ++fan) {
    unsigned int value = 0;
    if (api.fan_v2(device.handle, fan, &value) == kNvmlSuccess && value <= 200) {
      const int32_t percent = static_cast<int32_t>(value);
      highest = percent > highest ? percent : highest;
    }
  }
  if (highest != NVM_UNKNOWN || !api.fan) {
    return highest;
  }

  unsigned int value = 0;
  if (api.fan(device.handle, &value) == kNvmlSuccess && value <= 200) {
    return static_cast<int32_t>(value);
  }
  return NVM_UNKNOWN;
}

// 動作上限までの余裕。上限が返らない機種では、減速を始める温度までの余裕で代える。
// どちらも無ければ、温度が高いほど小さくなる値を返して比較だけはできるようにする。
int32_t margin_of(const Device& device, int32_t temperature) {
  const int32_t limit =
      device.limit_gpu_max_c != NVM_UNKNOWN ? device.limit_gpu_max_c : device.limit_slowdown_c;
  return limit != NVM_UNKNOWN ? limit - temperature : 1000 - temperature;
}

// 全 GPU を 1 回ずつ読む。温度が 1 台も取れなければ false を返す。
bool sample_devices(const Api& api, const Device* devices, unsigned int count, nvm_sample& out) {
  out = empty_sample(NVM_STATE_SAMPLING);
  out.device_count = count;

  bool any = false;
  int32_t worst_margin = 0;
  for (unsigned int index = 0; index < count; ++index) {
    const Device& device = devices[index];

    if (api.reasons) {
      unsigned long long reasons = 0;
      if (api.reasons(device.handle, &reasons) == kNvmlSuccess) {
        out.clock_reasons |= reasons;
        out.clock_reasons_valid = 1;
      }
    }

    const int32_t temperature = read_temperature(api, device.handle);
    if (temperature == NVM_UNKNOWN) {
      continue;
    }
    const int32_t margin = margin_of(device, temperature);
    if (any && margin >= worst_margin) {
      continue;
    }
    any = true;
    worst_margin = margin;
    out.temperature_c = temperature;
    out.limit_gpu_max_c = device.limit_gpu_max_c;
    out.limit_slowdown_c = device.limit_slowdown_c;
    out.limit_shutdown_c = device.limit_shutdown_c;
    out.fan_percent = read_fan(api, device);
  }
  return any;
}

DWORD WINAPI worker_main(LPVOID) {
  Api api;
  if (!load_api(api)) {
    publish(empty_sample(NVM_STATE_UNAVAILABLE));
    return 0;
  }

  Device devices[kMaxDevices];
  unsigned int count = open_devices(api, devices);
  if (count == 0) {
    publish(empty_sample(NVM_STATE_UNAVAILABLE));
    return 0;
  }

  unsigned int failures = 0;
  do {
    nvm_sample sample;
    if (sample_devices(api, devices, count, sample)) {
      failures = 0;
    } else if (++failures >= kReopenAfterFailures) {
      // 取れない状態が続いた。ドライバの更新などでハンドルが無効になった見込みがある。
      failures = 0;
      api.shutdown();
      count = open_devices(api, devices);
      if (count == 0) {
        publish(empty_sample(NVM_STATE_UNAVAILABLE));
        return 0;
      }
    }
    // 取れなかった周期も書く。NVML がエラーを返したことと、戻らないことは区別する。
    // 書かなければ age_ms が伸び、エラーが返っているだけの状態を応答の停止と見誤る。
    publish(sample);
  } while (WaitForSingleObject(g_stop_event, static_cast<DWORD>(g_interval_ms)) == WAIT_TIMEOUT);

  api.shutdown();
  publish(empty_sample(NVM_STATE_STOPPED));
  return 0;
}

bool thread_alive() {
  return g_thread && WaitForSingleObject(g_thread, 0) == WAIT_TIMEOUT;
}

void release_thread() {
  if (g_thread) {
    CloseHandle(g_thread);
    g_thread = nullptr;
  }
}

}  // namespace

extern "C" {

uint32_t nvm_sample_size(void) {
  return static_cast<uint32_t>(sizeof(nvm_sample));
}

int32_t nvm_start(uint32_t interval_ms) {
  const uint32_t clamped = interval_ms < 100 ? 100 : (interval_ms > 60000 ? 60000 : interval_ms);
  const LONG interval = static_cast<LONG>(clamped);
  InterlockedExchange(&g_interval_ms, interval);

  if (thread_alive()) {
    if (!g_stop_requested) {
      return 0;
    }
    // 止めるよう頼んだスレッドがまだ終わっていない。NVML の中で止まっている。
    // 同じ NVML を 2 本目のスレッドから呼ぶわけにはいかないので、立て直さない。
    set_error("the previous sampling thread is still blocked inside NVML");
    return -1;
  }
  release_thread();

  if (!g_stop_event) {
    g_stop_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!g_stop_event) {
      set_error_code("CreateEventW failed", static_cast<long>(GetLastError()));
      return -2;
    }
  }
  ResetEvent(g_stop_event);
  g_stop_requested = false;
  set_error("");
  publish(empty_sample(NVM_STATE_STARTING));

  g_thread = CreateThread(nullptr, 0, worker_main, nullptr, 0, nullptr);
  if (!g_thread) {
    set_error_code("CreateThread failed", static_cast<long>(GetLastError()));
    publish(empty_sample(NVM_STATE_STOPPED));
    return -3;
  }
  return 0;
}

void nvm_stop(void) {
  if (!g_thread) {
    return;
  }
  g_stop_requested = true;
  SetEvent(g_stop_event);
  if (WaitForSingleObject(g_thread, kStopWaitMs) == WAIT_OBJECT_0) {
    release_thread();
  }
}

int32_t nvm_read(nvm_sample* out) {
  if (!out) {
    return -1;
  }
  AcquireSRWLockShared(&g_lock);
  *out = g_sample;
  const ULONGLONG sampled_at = g_sampled_at;
  ReleaseSRWLockShared(&g_lock);

  const ULONGLONG elapsed = GetTickCount64() - sampled_at;
  out->age_ms = elapsed > 0xFFFFFFFFULL ? 0xFFFFFFFFU : static_cast<uint32_t>(elapsed);
  return 0;
}

const char* nvm_last_error(void) {
  // 書き換えは取得スレッドが行う。呼び出し側へは写しを返す。
  static char copy[sizeof(g_last_error)];
  AcquireSRWLockShared(&g_lock);
  std::memcpy(copy, g_last_error, sizeof(copy));
  ReleaseSRWLockShared(&g_lock);
  return copy;
}

}  // extern "C"

static_assert(sizeof(nvm_sample) == 48, "nvm_sample の大きさは Crystal 側の宣言と揃える");
