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

## バージョンとリリース

版の source of truth はタグである。
リポジトリに書かれているバージョンは手元でビルドしたときの既定値であり、リリースの版を決めるものではない。

- `src/main.cr` の `VERSION` は環境変数 `KXNOTIFYUTILS_VERSION` から読む。渡さなければ `0.1.0-dev` になる。
- `res/kxnotifyutils.rc` のバージョン情報は、ビルドの複合アクションがワークスペース上で書き換える。コミットはしない。

タグは `X.Y.Z` を安定版、`X.Y.Z-testN` をプレリリースとする。

### プレリリース（自動）

`master` へ取り込むと `.github/workflows/prerelease.yml` が動く。
最新の安定版タグからパッチを 1 つ上げた `X.Y.(Z+1)` を次期バージョンとし、`-testN` の N を進めてタグを打ち、exe を添えたプレリリースを作る。

exe の中身が変わらない変更（spec、ドキュメント、ワークフロー自身）では作らない。
判定しているパスの一覧はワークフロー内のコメントにある。

マイナーやメジャーを上げたいプレリリースは手動で作る。

### 安定版リリース（手動）

GitHub でタグ `X.Y.Z` のリリースを作って公開すると、`.github/workflows/release.yml` が exe をビルドして添付する。

プレリリースを正式リリースへ昇格した場合は、昇格前の公開時点で exe が添付済みのため何も動かない。

### ビルド手順の置き場所

CI とリリースとプレリリースは、いずれも `.github/actions/build-windows` の複合アクションでビルドする。
手順を分けて持つと、CI が通ったのにリリースで落ちる状態が起きるため、1 か所にまとめてある。

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

最初に確かめるべきなのは通知アクセスの許可である。
`UserNotificationListener` の許可はパッケージ ID と結びついており、パッケージ化していない exe では `RequestAccessAsync` が `Denied` を返し続けることがある。
仕様書もこの問題を前提に、失敗時は Windows の設定画面へ誘導する形にしている（実装済み）。
ただし設定画面にアプリが並ばず、利用者が手で許可することもできない可能性は残っている。
先行実装の扱いは分かれており、xsoverlay-notifier は MSIX で ID を付与し、xs-notify はパッケージ化せずに `RequestAccessAsync` の結果へ依存している。
この点は [#6](https://github.com/limit7412/KxNotifyUtils/issues/6) で追う。

- **単体 exe のまま通知アクセスが `Allowed` になること**（ここが通らないと中心機能が動かない）
- テスト通知が XSOverlay に出ること、実際の通知で件名と本文とアイコンが期待どおりであること
- XSOverlay を落として再起動したときに中継が復帰し、切断中の通知が捨てられること
- SteamVR の起動で自動起動し、終了で一緒に終了すること
- SteamVR より先に手動起動した場合でも、60 秒の再試行で終了の連動が働くこと
- 実行ファイルを移動したときに vrmanifest が作り直され、次回の SteamVR 起動で新しいパスから起動すること
- 設定ウィンドウとトレイが同時に動くこと、メニューの操作中もポーリングが止まらないこと
- Explorer を再起動したあと、トレイアイコンが登録し直されること
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
