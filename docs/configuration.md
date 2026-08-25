# 設定リファレンス

設定ファイルは `%APPDATA%\KxNotifyUtils\config.json` に置く。
設定ウィンドウと同じファイルを読み書きするため、どちらで編集してもよい。
外部のエディタで書き換えたあとは、トレイメニューの「設定を再読み込み」で取り込む。

不正な JSON を読んだ場合は直前の有効な設定で動作を続け、トレイ通知でエラーを知らせる。

## 全体の構成

```json
{
  "sources": {
    "windows": {
      "enabled": true,
      "polling_interval_ms": 500
    }
  },

  "sinks": {
    "xsoverlay": {
      "enabled": true,
      "transport": "websocket",
      "websocket_port": 42070,
      "udp_port": 42069
    }
  },

  "filter": {
    "mode": "blacklist",
    "apps": ["Microsoft.Windows.Explorer"]
  },

  "defaults": {
    "timeout_mode": "dynamic",
    "timeout": 6.0,
    "dynamic_timeout": { "base": 2.0, "reading_speed": 12, "min": 3.0, "max": 15.0 },
    "max_body_length": 200,
    "title_template": "{app_name}: {title}",
    "icon": "app",
    "opacity": 1.0,
    "volume": 0.5,
    "sound": "default"
  },

  "rules": [
    {
      "match_app_id": "com.squirrel.Discord",
      "volume": 0.8,
      "sound": "C:/sounds/discord.wav"
    }
  ],

  "steamvr": {
    "auto_launch_registered": true,
    "last_exe_path": "D:/tools/KxNotifyUtils.exe",
    "auto_launch_configured": true
  },

  "log_level": "info"
}
```

`sources` と `sinks` は識別子をキーにしたオブジェクトである。
将来ソースやシンクが増えたときは新しいキーが足されるだけで、既存のキーはそのまま読める。

## sources.windows

Windows のデスクトップ通知を監視する。

- **enabled**：このソースを使うかどうか。
- **polling_interval_ms**：通知一覧を確認する間隔。100 から 5000 の範囲で指定する。既定は 500 である。

間隔を短くすると通知が出るまでの遅れは減るが、そのぶん CPU を使う。
500 ミリ秒で体感の遅れはほとんど無い。

## sinks.xsoverlay

XSOverlay へ通知を送る。

- **enabled**：このシンクを使うかどうか。
- **transport**：`websocket` または `udp`。既定は `websocket` である。
- **websocket_port**：XSOverlay の WebSocket API のポート。既定は 42070 である。
- **udp_port**：レガシーの UDP API のポート。既定は 42069 である。

`udp` は WebSocket に問題が出た場合の退避手段として残しており、恒久的な運用先としては勧めない。

有効な通知先が 1 つも無い設定は保存できない。
中継先が無いまま常駐するのは、設定を書き間違えている可能性が高いためである。

## filter

どのアプリの通知を中継するかを決める。

- **mode**：`blacklist`（挙げたアプリを落とす）または `whitelist`（挙げたアプリだけを通す）。
- **apps**：`app_id` の前方一致で比較する文字列の配列。

`app_id` は Windows がアプリに与える識別子（AppUserModelId）である。
何を書けばよいかは、設定ウィンドウのアプリ別ルールタブにある「観測した app_id」から選べる。

## defaults と rules

`defaults` はすべての通知に共通する見え方で、`rules` はアプリごとの違いである。
`rules` の各項目には `defaults` との差分だけを書けばよく、書かなかった項目は `defaults` を引き継ぐ。

`rules` は上から順に評価され、`match_app_id` が前方一致した最初のものが採用される。
順序に意味があるため、細かい条件を先に、広い条件を後に置く。

指定できる項目は次のとおりである。

- **timeout_mode**：`fixed` なら `timeout` の秒数をそのまま使い、`dynamic` なら文字数から計算する。
- **timeout**：`fixed` のときの表示時間（秒）。
- **dynamic_timeout**：`dynamic` のときの係数。`base + 文字数 / reading_speed` を `min` と `max` でクランプした値を表示時間にする。文字数は件名と本文の合計である。`min` と `max` はどちらも 0 より大きい値で指定する。`rules` では係数ごとに書け、書かなかった係数は `defaults` を引き継ぐ（例：`"dynamic_timeout": { "base": 5.0 }`）。
- **max_body_length**：本文の最大文字数。0 から 5000 の範囲で指定する。超えた分は切り詰め、末尾に省略の記号を付ける。0 を指定すると本文を載せない。無制限を表す値は無い。
- **title_template**：件名の組み立て方。`{app_name}`、`{app_id}`、`{title}`、`{body}` を展開する。
- **icon**：`app`（アプリのアイコンを使い、取れなければ `default` に落とす）、`default`、`warning`、`error`、または PNG ファイルのパス。
- **opacity**：透明度。0.0 から 1.0 で指定する。
- **volume**：通知音の音量。0.0 から 1.0 で指定する。
- **sound**：`default`、`warning`、`error`、音声ファイルのパス、または空文字列（ミュート）。

`rules` のマッチ条件は現在 `match_app_id` だけである。
ソースが増えたときにソース別のルールを書けるよう、`match_` で始まる名前を条件のために予約している。

## steamvr

- **auto_launch_registered**：SteamVR の自動起動に登録しているか。
- **last_exe_path**：前回登録したときの実行ファイルのパス。移動の検知に使う。
- **auto_launch_configured**：自動起動の登録について一度でも決着がついたか。初回の自動登録を行うかどうかの判断に使う。登録したときと、利用者が解除したときに立つ。

どれもアプリが書き込む記録であり、手で編集する項目ではない。

## log_level

`trace`、`debug`、`info`、`notice`、`warn`、`error`、`fatal`、`none` のいずれかを指定する。
既定は `info` である。

`info` では起動と終了、シンクの接続と切断、登録の操作、1 分ごとの中継件数を記録する。
`debug` を足すと、中継した通知の `app_id` と件名も記録する。
本文は個人情報を含みやすいため、`debug` でも記録しない。
