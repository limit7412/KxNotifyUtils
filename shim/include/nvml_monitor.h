// NVML の計測値を別スレッドで取り、最後に取れた値を返す。
//
// NVIDIA の GPU が応答を止めると、NVML の呼び出しは戻らなくなる。
// 本体の主ループは 1 本のスレッドで回っており、そこで NVML を呼ぶと、
// GPU が止まった時点でトレイも設定ウィンドウも通知の中継も止まる。
// そのため NVML に触れるスレッドをこのライブラリの内部に閉じ、
// 本体からは待ちの無い nvm_read だけを呼ぶ。
//
// nvml.dll はリンクしない。NVIDIA のドライバが入れたものを実行時に探してロードする。
// 見つからない環境では NVM_STATE_UNAVAILABLE を返し、それ以外の影響は無い。
#ifndef KXNOTIFYUTILS_NVML_MONITOR_H
#define KXNOTIFYUTILS_NVML_MONITOR_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// 取得スレッドが動いていない。
#define NVM_STATE_STOPPED 0
// 取得スレッドは動いているが、まだ 1 回も取れていない。
// NVML の初期化が戻らない場合もこの状態にとどまる。
#define NVM_STATE_STARTING 1
// 取れている。値は直近の取得のものである。
#define NVM_STATE_SAMPLING 2
// NVML を使えない。nvml.dll が無い、初期化に失敗した、GPU が 1 台も無い、のいずれかである。
// 理由は nvm_last_error に残る。
#define NVM_STATE_UNAVAILABLE 3

// 値が取れなかった項目に入れる値。
#define NVM_UNKNOWN (-1)

// 直近の計測値。GPU が複数ある場合は、動作上限までの余裕が最も小さい 1 台の値である。
typedef struct nvm_sample {
  int32_t state;
  // 直近の取得からの経過ミリ秒。取得スレッドが NVML の中で止まると増え続ける。
  uint32_t age_ms;
  uint32_t device_count;
  // GPU の温度（℃）。
  int32_t temperature_c;
  // 温度のしきい値（℃）。順に、動作上限、減速を始める温度、停止する温度。
  // 機種とドライバによって返らないものがあり、その場合は NVM_UNKNOWN になる。
  int32_t limit_gpu_max_c;
  int32_t limit_slowdown_c;
  int32_t limit_shutdown_c;
  // ファンへの指示値（%）。複数ある場合は最大のもの。実測の回転数ではない。
  int32_t fan_percent;
  // クロックを制限している理由のビットマスク。全 GPU の論理和。
  uint64_t clock_reasons;
  // clock_reasons が取れたか。0 なら取れておらず、clock_reasons は 0 である。
  int32_t clock_reasons_valid;
  int32_t reserved;
} nvm_sample;

// nvm_sample の大きさを返す。呼び出し側の宣言と食い違っていないかの確認に使う。
uint32_t nvm_sample_size(void);

// 取得スレッドを立てる。既に動いていれば間隔だけを差し替える。
// 戻り値: 0 = 成功, 負値 = 失敗（理由は nvm_last_error）
int32_t nvm_start(uint32_t interval_ms);

// 取得スレッドを止める。
// スレッドが NVML の中で止まっている場合は、終わるのを待たずに戻る。
void nvm_stop(void);

// 直近の計測値を out へ書く。待ちは無い。
// 戻り値: 0 = 成功, 負値 = out が NULL
int32_t nvm_read(nvm_sample* out);

// 直近のエラーの詳細メッセージを返す（解放不要の静的バッファ）。
const char* nvm_last_error(void);

#ifdef __cplusplus
}
#endif

#endif  // KXNOTIFYUTILS_NVML_MONITOR_H
