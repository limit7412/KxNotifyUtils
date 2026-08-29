# 設計

このドキュメントは、コードを触る人が最初に読むものである。
何がどこにあるか、どの向きに依存してよいか、ソースやシンクを足すとき何を書くかを述べる。

## 2 つのコンポーネント

実装は言語の境界で 2 つに分かれる。

**NotifListenerShim** は、WinRT の `UserNotificationListener` を呼んでフラットな C API として公開する C++/WinRT の静的ライブラリである。
**本体** は Crystal で書かれ、トレイ常駐、ポーリング、整形、送信、SteamVR 連携を担う。

この分割はプロセスやファイルの分割ではない。
WinRT は COM ベースの ABI であり、Crystal の C FFI から直接呼ぶには HSTRING の操作や vtable の定義や非同期ハンドラの登録が要る。
WinRT への依存を C++/WinRT のライブラリに閉じ込めることで、Crystal 側は通常の C 関数呼び出しだけで済む。

シムはビルド時に本体へリンクされ、単体のファイルとしては配布されない。
配布物は `KxNotifyUtils.exe` の 1 ファイルである。

## ディレクトリ構成

```
src/
  main.cr                          composition root（build_sources / build_sinks / 依存注入）
  notify/                          中立ドメイン（他コンテキストに依存しない）
    models.cr                        Incoming、Message、Icon、DisplayHints
    repository.cr                    SourceRepository、PostRepository、IconRepository、MessageBuilder
    usecase.cr                       中継の 1 周期（フィルタ、ルール解決、fan-out）
  win_notification/                ソース実装：Windows 通知
    ffi.cr                           NotifListenerShim の lib 宣言
    ffi_client.cr                    C API を包む ShimClient 実装
    models.cr                        シムが返す JSON に対応する型、sources.windows の設定
    repository.cr                    差分検出を行う SourceRepository 実装
    usecase.cr                       Incoming とルールから Message を組み立てる
  xsoverlay/                       シンク実装：XSOverlay
    models.cr                        通知オブジェクトとエンベロープ、sinks.xsoverlay の設定
    websocket_repository.cr          WebSocket 送信
    udp_repository.cr                UDP 送信（レガシー）
  steamvr/                         SteamVR 連携
    ffi.cr                           openvr_api の lib 宣言と FnTable
    repository.cr                    OpenVR 呼び出しと vrmanifest 書き出しの抽象
    openvr_repository.cr             openvr_api.dll を動的ロードする実装
    usecase.cr                       vrmanifest の生成、登録と解除、移動の検知
  config/                          設定
    models.cr                        設定スキーマ、defaults と rules の継承解決
    repository.cr                    設定ファイルの読み書き
    usecase.cr                       検証、保存、再読み込み、反映
  runtime/                         実行環境
    paths.cr                         設定、ログ、vrmanifest の置き場所
    logging.cr                       日次ローテーションのログ
    icon_repository.cr               アイコンファイルの読み出しとキャッシュ
    win32.cr                         Win32 API の宣言
    tray.cr                          トレイアイコンとメニュー
    settings_window.cr               libui-ng による設定編集ウィンドウ
    scheduler.cr                     ポーリングと終了イベントの確認
  error/
    usecase.cr                       例外のログ記録とトレイ通知
```

## 依存の向き

依存の向きは次のとおり固定する。

- `notify` は他のどのコンテキストにも依存しない。ただし設定の型（`config/models`）だけは参照する。
- ソース実装は `SourceRepository` を継承し、`Incoming` を返す。
- シンク実装は `PostRepository` を継承し、`Message` を自分のワイヤ形式へ変換する。
- `notify/usecase` が知っているのは、`SourceRepository` の集合、ソース別の `MessageBuilder`、`PostRepository` の集合、設定スナップショットだけである。XSOverlay にも WinRT にも OpenVR にも依存しない。
- `runtime` は usecase を呼ぶだけで、ロジックを持たない。
- FFI の `lib` 宣言はコンテキスト内の `ffi.cr` に隔離し、同じコンテキストの repository だけが参照する。

この規則の目的は、テスト境界の確保と、追加のときに変更範囲を狭めることにある。
`SourceRepository` と `PostRepository` をテスト用実装に差し替えれば、フィルタも整形も fan-out も、実 XSOverlay にも実通知にも触れずに検証できる。

## 中立形式を 2 層に分ける理由

`Notify::Message` は、どのシンクでも意味を持つ**コア**（`title`、`body`、`icon`、`timeout`、`sound`、`volume`、`source_app`）と、シンクによっては解釈されない**表示ヒント**（`height`、`opacity`）に分けてある。

シンクが XSOverlay だけなら 1 層で足りる。
分けているのは、Discord webhook のようにコアしか表現できないシンクを足したときに、アダプタが「解釈できるものだけを使う」と判断できるようにするためである。
各アダプタはコアを必ず反映し、表示ヒントは自分が扱えるものだけを使う。

## 差分検出をソース側に置く理由

「前回から増えた通知」をどう見つけるかは、ソースごとに違う。
Windows の通知では `id` の集合を比べるが、ログファイルを読むソースなら追記部分を読み、イベントを購読するソースならバッファを持つ。

そのため差分検出は `SourceRepository#poll_new` の契約に含め、実装へ閉じている。
中立の usecase 側に置くと、ソースが増えるたびにソース固有の知識がそこへ積み上がる。

同じ理由で、整形（テンプレートの展開、表示時間の計算、アイコンの解決）もソース側の `MessageBuilder` に置いている。
`notify/usecase` に残るのはパイプラインの順序と fan-out だけである。

## 中継の流れ

新しい通知 1 件ごとに、次の順で処理する。

1. **フィルタ判定**：`filter.mode` と `filter.apps` に従い、`app_id` の前方一致で中継の可否を決める。
2. **ルール解決**：`rules` を上から評価し、最初にマッチしたものを採用する。マッチしなければ `defaults` を使う。
3. **整形**：`title_template` を展開し、本文を `max_body_length` で切り詰める。
4. **表示時間の決定**：`fixed` なら指定の秒数、`dynamic` なら文字数から計算して `min` と `max` でクランプする。
5. **表示ヒントの決定**：本文の有無と長さから高さを決め、透明度をルールから引く。
6. **アイコンの決定**：`app`、組み込みアイコン名、ファイルパスのいずれかを解決する。
7. **fan-out**：組み立てた `Message` を有効なすべてのシンクへ渡す。

あるシンクの送信が失敗しても他のシンクへの送信は続け、失敗はシンクごとにログへ残す。
送信できなかった通知はキューに溜めず破棄する。

## スレッドとファイバ

常駐の主ループは 1 本のスレッドで回る。

```
loop do
  トレイのメッセージを処理する
  libui-ng のステップを 1 回進める
  ポーリングと SteamVR のイベント確認を行う
  10 ミリ秒眠る
end
```

`GetMessage` で待たずに `PeekMessage` で読み取り、短い `sleep` を挟む。
Crystal のファイバは協調的にしか切り替わらないため、ブロックする Win32 の呼び出しで待ってしまうと、WebSocket の接続維持を担うファイバが動けなくなるからである。
`sleep` がスケジューラへ制御を返し、そこで接続の維持や再接続が進む。

この構造の結果、トレイと設定ウィンドウは同じ UI スレッドを共有する。
仕様書が未決としていた「libui-ng のメインループとトレイの共存」は、`uiMain` で待たずに `uiMainStep(0)` で 1 歩ずつ進める形で解いている。

WinRT の呼び出しだけは別である。
`IAsyncOperation` の同期待ちは STA では行えず、かといって主スレッドを MTA に固定するとトレイやシェルの操作に影響が出る。
そこでシムが内部にワーカースレッドを 1 本持ち、そこで MTA を初期化して WinRT の呼び出しを引き受ける。
本体から見ると、シムの C API はどのスレッドから呼んでも直列に処理される普通の関数である。

## 設定の反映

設定は不変のスナップショット（`Config::Root`）として持ち、反映はスナップショットの差し替えで行う。
ポーリングの 1 周期は最初にスナップショットを読み取ってから進むため、周期の途中で新旧の設定が混ざらない。

保存は全項目が検証を通ったときだけ行う。
検証は `config/usecase` にあり、`sources` と `sinks` の各セクションは、そのアダプタが登録した検証に委ねる。
アダプタを足すときは、`main.cr` で自分のセクションの検証を登録する。

## ソースを足す

1. `src/` に新しいコンテキストのディレクトリを作る。
2. `Notify::SourceRepository` を継承した repository を書く。`source_id`、`poll_new`、`poll_interval` を実装し、差分検出はこの中に閉じる。
3. `Notify::MessageBuilder` を継承した usecase を書く。`Incoming` と解決済みのルールから `Notify::Message` を組み立てる。
4. 設定型（`enabled` と個別の項目）を models に置き、`validate` を用意する。
5. `main.cr` の `build_sources` で組み立て、`register_validators` で検証を登録する。
6. 設定ファイルの `sources` に新しいキーが増える。既存のキーは変わらない。

`notify` と既存のコンテキストには手を入れない。

## シンクを足す

1. `src/` に新しいコンテキストのディレクトリを作る。
2. `Notify::PostRepository` を継承した repository を書く。`Message` のコアを必ず反映し、表示ヒントは扱えるものだけ使う。
3. 設定型と `validate` を用意する。
4. `main.cr` の `build_sinks` で組み立て、`register_validators` で検証を登録する。

## 仕様書からの変更点

仕様書（issue #1）が未決としていた点のうち、実装で決めたものを挙げる。

- **CRT のリンク設定**：シムは静的 CRT（`/MT`）でビルドする。リンク時に `RuntimeLibrary` の食い違いを見るのは、その記録を持つオブジェクト同士である。Crystal が生成するオブジェクトはこの記録を持たない。記録を持つのは uing が配る `ui.lib` とシムだけで、`ui.lib` は静的 CRT でビルドされている。そのためシムが合わせる相手は Crystal ではなく `ui.lib` になる。本体を `--static` でビルドすると Crystal 側も静的 CRT（`libcmt.lib`）を要求するため、三者が揃う。uing がリンク行へ足す `/NODEFAULTLIB:LIBCMT` が外すのは既定ライブラリの一覧であり、Crystal が絶対パスで明示的に渡す `libcmt.lib` はその対象にならない。
- **exe を 1 ファイルにするためのリンク**：本体は `--static` でビルドする。Crystal の Windows 配布物は依存ライブラリを静的版（`lib/z.lib` など）とインポートライブラリ（`lib/z-dynamic.lib` など）の両方で持ち、コンパイラは `--static` なら `-static`、既定では `-dynamic` を付けた名前を先に探す。`-static` 版は配布物に無いため `--static` では素の名前、つまり静的版へ落ちる。付けないと `zlib1.dll` や `libcrypto-3-x64.dll` を要求する exe になる。手元では Crystal がそれらの DLL を exe の隣へ複製するので動いてしまい、exe だけを配ったときに初めて起動しない。CI はビルド後に `dumpbin /dependents` で実際の依存を見て、同梱前提の DLL が残っていれば落とす。
- **uing の静的リンク**：uing 0.2.0 は libui-ng の静的ライブラリを postinstall で取得し、そのままリンクする。fork も設定の上書きも要らなかった。
- **libui-ng とトレイの共存**：`uiMainStep(0)` を主ループから呼ぶ形で、UI スレッド 1 本に収めた。専用スレッドへの分離はしていない。
- **openvr のインターフェースバージョン**：`IVRSystem_026` と `IVRApplications_008` に固定した。FnTable の並びは `openvr_capi.h` から機械的に写している。起動時に `VR_IsInterfaceVersionValid` で検証し、通らなければ SteamVR 連携を無効にして常駐を続ける。
- **OpenVR の初期化の種別**：`VRApplication_Background` で初期化する。SteamVR が動いていないときに SteamVR を起こさず、初期化のほうを失敗させる種別はこれだけである。`VRApplication_Overlay` では、設定を見たいだけの手動起動でも SteamVR が起動してしまう（issue #12）。本ツールが OpenVR に求めるのは vrmanifest の登録と自動起動の設定、そして `VREvent_Quit` の受け取りだけで、オーバーレイの描画は行わないため `IVROverlay` を使っていない。この 3 つはいずれも Background で足りる。SteamVR が動いていないことは `VRInitError_Init_NoServerForBackgroundApp` という初期化の失敗として表れるので、この番号だけは異常として扱わず、60 秒ごとの再試行を続ける。vrmanifest に書く `is_dashboard_overlay` はこれとは別物であり、そのままにしてある。あちらは SteamVR がアプリをどう分類し、自動起動でどう扱うかを決めるもので、アプリ自身が `VR_Init` へ渡す種別とは関係しない。
- **openvrpaths.vrpath の形式差**：`runtime` 配列を一次の情報源とし、読めない場合は `%ProgramFiles(x86)%\Steam\steamapps\common\SteamVR` を試すフォールバックを足した。
- **アプリ別ルールの一覧ウィジェット**：Table と編集フォームの組み合わせにした。並べ替えに意味があるため、上下の移動ボタンを付けている。当初はドロップダウンと編集フォームの組み合わせで始めたが、一覧なのに開くまで全体が見えず、上下の移動ボタンを押しても結果がその場で見えなかったため Table へ移した（issue #36）。先勝ちマッチのため並び順そのものが設定の意味を持つのに、その並びが隠れていたことになる。列は「順 / match_app_id / 上書き」の 3 つで、どのルールが実質空なのかも一覧から分かる。Table はモデルベースであり、行数とセルの中身は `SettingsWindow` が持つルールの配列から読み、行の増減は通知で伝える。
- **アプリケーションマニフェスト**：本体からは埋め込まない。Common Controls v6 の宣言は uing が埋め込むマニフェストが持っており、同じ RT_MANIFEST リソースを重ねると衝突する。DPI awareness は起動時に `SetProcessDpiAwarenessContext` を呼んで設定する。
- **THIRD-PARTY-NOTICES の埋め込み**：`.res` ではなくコンパイル時の `read_file` で実行ファイルへ取り込む。埋め込む先が exe である点は変わらず、リソースの ID を管理せずに済む。
- **シムのスレッド契約**：仕様書は「`nls_init` を呼んだスレッドと同じスレッドから全 API を呼ぶ」としていたが、シムが内部にワーカースレッドを持つ形に変えた。本体側はどのスレッドから呼んでもよい。

残っているのは、実機でしか確かめられない項目である。
表示の高さの係数、アイコンの見え方、同一アプリの連投を抑えるかどうかは、XSOverlay の実表示を見てから決める。
