// NotifListenerShim のテストハーネス（仕様書 9.1 節）。
//
// シムは静的ライブラリとして本体へ統合されるため、単体で動かすにはこの実行ファイルを使う。
// 配布物ではない。
//
// 使い方:
//   shim_harness              許可状態と通知一覧を 1 回だけ表示する
//   shim_harness leak 10000   通知一覧の取得を繰り返し、解放漏れが無いことを確かめる
#include "notif_listener_shim.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

namespace {

const char* access_status_label(int32_t code) {
  switch (code) {
    case 0: return "Allowed";
    case 1: return "Denied";
    case 2: return "Unspecified";
    // 期限切れは他の失敗と分けて出す。応答が返らなかったのか、
    // 呼び出しそのものが失敗したのかで見るところが変わる（issue #28）。
    case -4: return "Timeout";
    default: return "Error";
  }
}

enum class AccessCheck {
  Granted,  // 許可されている。通知の確認まで行える。
  Skip,     // 許可されていないだけ。環境の都合であってシムの異常ではない。
  Failed,   // 問い合わせ自体が失敗した。シムの異常として扱う。
};

// 通知アクセスの状態を確かめる。
//
// 未許可と、問い合わせの失敗は分ける。
// どちらもスキップにすると、シムが実行できない状態でも CI が通ってしまう。
AccessCheck check_notification_access() {
  int32_t status = nls_get_access_status();
  std::printf("access status: %s (%d)\n", access_status_label(status), status);
  if (status > 0) {
    status = nls_request_access();
    std::printf("after request: %s (%d)\n", access_status_label(status), status);
  }

  if (status == 0) {
    return AccessCheck::Granted;
  }
  if (status < 0) {
    std::printf("failed to query notification access (%d): %s\n", status, nls_last_error());
    return AccessCheck::Failed;
  }
  return AccessCheck::Skip;
}

int dump_once() {
  const char* json = nls_get_notifications();
  if (!json) {
    std::printf("failed to get notifications: %s\n", nls_last_error());
    return 1;
  }
  std::printf("notifications: %s\n", json);
  nls_free_string(json);
  return 0;
}

// 取得と解放を繰り返す。
// アイコンキャッシュの分だけは増えるが、それ以外に使用量が増え続けないことを確かめる。
int repeat(int iterations) {
  for (int index = 0; index < iterations; ++index) {
    const char* json = nls_get_notifications();
    if (!json) {
      std::printf("iteration %d failed: %s\n", index, nls_last_error());
      return 1;
    }
    nls_free_string(json);
  }
  std::printf("completed %d iterations\n", iterations);
  return 0;
}

}  // namespace

int main(int argc, char** argv) {
  const int32_t code = nls_init();
  if (code != 0) {
    std::printf("nls_init failed (%d): %s\n", code, nls_last_error());
    return 1;
  }

  const AccessCheck access = check_notification_access();
  if (access != AccessCheck::Granted) {
    if (access == AccessCheck::Skip) {
      std::printf("notification access is not granted; skipping the notification checks\n");
    }
    nls_shutdown();
    return access == AccessCheck::Skip ? 0 : 1;
  }

  int result = 0;
  if (argc >= 2 && std::strcmp(argv[1], "leak") == 0) {
    const int iterations = argc >= 3 ? std::atoi(argv[2]) : 10000;
    result = repeat(iterations);
  } else {
    result = dump_once();
  }

  nls_shutdown();
  return result;
}
