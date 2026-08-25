# 開発ガイド

## ビルド（Windows）

必要なものは次のとおりである。

- Visual Studio 2022 以降の C++ ビルドツール（`cmake` と `rc.exe` に PATH が通っていること）
- Crystal の Windows 版（MSVC ツールチェーン）

```powershell
pwsh scripts/build.ps1
```

このスクリプトは順に、シムの静的ライブラリをビルドし、リソースをコンパイルし、shard を取得し、本体をリンクする。
出来上がるのは `KxNotifyUtils.exe` の 1 ファイルである。

手で行う場合は次のようになる。

```powershell
cmake -S shim -B shim/build -A x64
cmake --build shim/build --config Release
rc.exe /nologo /fo res\kxnotifyutils.res res\kxnotifyutils.rc
shards install
crystal build src/main.cr -o KxNotifyUtils.exe --release --no-debug `
  --link-flags "/LIBPATH:$PWD\shim\build\Release $PWD\res\kxnotifyutils.res"
```

`--no-debug` を外すと uing が libui-ng の debug 版を選ぶ。
uing はデバッグ情報の有無で libui-ng の release と debug を選び分けており、Crystal はデバッグ情報を既定で出すため、`--release` だけでは debug 版が使われる。

シムの CRT は静的（`/MT`）に固定してある。
uing が配る `ui.lib` が静的 CRT でビルドされており、そこに合わせないとリンク時に `RuntimeLibrary` の食い違いで止まる。
理由は `docs/architecture.md` の「仕様書からの変更点」に書いた。

`openvr_api.dll` はリンクしない。
SteamVR がインストールしたものを実行時に探してロードする。

## テスト

### 単体テスト

```
crystal spec
```

外部境界をテスト用実装に差し替えているため、XSOverlay も SteamVR も Windows の通知も要らない。
差し替えの実装は `spec/support/fakes.cr` にある。

送信まわりだけは実際のソケットを相手にする。
`spec/xsoverlay/transport_spec.cr` はローカルに WebSocket サーバと UDP の受け口を立て、送ったものが届くこと、切断したら再接続することを確かめる。

### シムのテストハーネス

シムは静的ライブラリとして本体へ統合されるため、単体で動かすには専用の実行ファイルを使う。

```powershell
./shim/build/Release/shim_harness.exe            # 許可状態と通知一覧を表示する
./shim/build/Release/shim_harness.exe leak 10000 # 取得と解放を繰り返す
```

`leak` は解放漏れの確認に使う。
アイコンのキャッシュ分だけは増えるが、それ以外に使用量が増え続けないことを見る。

## Linux で確認できること

開発の主な確認は Linux 上でも行える。

```
shards install
crystal tool format --check src spec
crystal spec
crystal build --cross-compile --target x86_64-pc-windows-msvc src/main.cr -o kx
```

最後のクロスコンパイルは、リンクを行わずに Windows 向けの意味解析だけを走らせる。
FFI の宣言、トレイ、設定ウィンドウなど、Linux では実行できないコードもここで型検査される。
実行ファイルはできないので、動作の確認には Windows が要る。

CI もこの 2 段構成を採っている。
Linux のジョブで書式と単体テストとクロスコンパイルを回し、Windows のジョブでシムを含む実際のビルドと単体テストを行う。

`shards install` は CI で試し直すようにしてある。
uing の postinstall が libui-ng の静的ライブラリを GitHub から取得しており、この取得は落ちることがあるためである。
落ちたとき shards は `Failed postinstall of uing on crystal run download.cr:` とだけ出して理由を残さないので、失敗の見分けがつきにくい。
`lib` を消してから取り直せば通る。

## 実機でしか確かめられないこと

次の項目は、SteamVR と XSOverlay と HMD が揃った環境でないと確認できない。

- テスト通知が XSOverlay に出ること、実際の通知で件名と本文とアイコンが期待どおりであること
- XSOverlay を落として再起動したときに中継が復帰し、切断中の通知が捨てられること
- SteamVR の起動で自動起動し、終了で一緒に終了すること
- SteamVR より先に手動起動した場合でも、60 秒の再試行で終了の連動が働くこと
- 実行ファイルを移動したときに vrmanifest が作り直され、次回の SteamVR 起動で新しいパスから起動すること
- 設定ウィンドウとトレイが同時に動くこと、メニューの操作中もポーリングが止まらないこと
- 表示の高さの係数とアイコンの見え方

高さの係数は `WinNotification::MessageBuilder` の `HEIGHT_PER_CHAR` などにある。
実表示を見て調整する前提の仮の値である。

## アイコンを作り直す

トレイと実行ファイルのアイコンは生成物をリポジトリに含めている。
作り直す場合は次を実行する。

```
python3 tools/generate_icon.py
```

外部ライブラリを使わずに PNG を組み立て、PNG 形式のエントリを持つ ICO として書き出す。
