// NotifListenerShim: Windows の通知一覧をフラットな C API として公開する静的ライブラリ。
//
// 複合データはすべて UTF-8 の JSON 文字列で受け渡す。
// 呼び出し側の FFI 宣言がポインタと整数だけで済み、構造体のマーシャリングが不要になるためである。
//
// C++ 例外はこの境界を越えない。各関数の内部で捕捉し、エラーコードと nls_last_error に変換する。
#ifndef KXNOTIFYUTILS_NOTIF_LISTENER_SHIM_H
#define KXNOTIFYUTILS_NOTIF_LISTENER_SHIM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// 初期化。WinRT の呼び出しを担うワーカースレッドを 1 本立て、MTA で初期化する。
// 戻り値: 0 = 成功, 負値 = エラーコード
int32_t nls_init(void);

// 終了処理。ワーカースレッドを止める。
void nls_shutdown(void);

// 通知アクセスの許可状態を返す。
// 戻り値: 0 = Allowed, 1 = Denied, 2 = Unspecified, 負値 = エラー
int32_t nls_get_access_status(void);

// 通知アクセスの許可を要求する (RequestAccessAsync)。
// 戻り値: nls_get_access_status と同じ。ただし応答が期限内に返らなかった場合は -4。
// 期限を置くのは、応答が返らないと起動がそこで止まるためである（issue #28）。
// 打ち切った場合の理由は nls_last_error に残る。
// 注意: パッケージ化されていない Win32 アプリでは Denied が返り続ける既知の問題があるため、
// 本体側は失敗時に Windows 設定画面へ誘導する。
int32_t nls_request_access(void);

// 現在の通知一覧を JSON 文字列で返す。
// 戻り値: UTF-8 JSON へのポインタ。エラー時は NULL。
// 呼び出し側は使用後に nls_free_string で解放する。
const char* nls_get_notifications(void);

// nls_get_notifications が返した文字列を解放する。
void nls_free_string(const char* p);

// 直近のエラーの詳細メッセージを返す（デバッグ用、解放不要の静的バッファ）。
const char* nls_last_error(void);

#ifdef __cplusplus
}
#endif

#endif  // KXNOTIFYUTILS_NOTIF_LISTENER_SHIM_H
