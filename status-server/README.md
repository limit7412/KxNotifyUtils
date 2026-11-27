# status-server

外部サービスの状態を集めて配信する集約サーバーと、その配信経路である。
本体（`KxNotifyUtils.exe`）の `src/service_status` は、ここが配る JSON（`https://vrc-status.oxymoron.link/v1/status.json`）を読んで通知を出す。

もとは [limit7412/VRCServiceStatusPanel](https://github.com/limit7412/VRCServiceStatusPanel) にあり、2026 年 11 月にファイル単位でここへ移した。
コミット履歴は移していないので、移設より前の経緯は元のリポジトリを見る。
元のリポジトリにあった VRChat ワールド用の Unity アセット（VPM パッケージ）は作らないことにしたため、移していない。

## 何がどこにあるか

| 場所 | 何 |
| --- | --- |
| `backend/` | 集約サーバー。Crystal で書いた Lambda で、各サービスの状態を取得して JSON にまとめ、R2 へ置く |
| `backend/web/index.html` | 配信 JSON を読んで表示する確認用ページ。配信バケットへ一緒に上げる |
| `infra/` | デプロイ定義。Pulumi で AWS（Lambda、Scheduler、アラーム）と Cloudflare（R2）を作る。詳細は `infra/README.md` |
| `docs/aws-oidc.md` | GitHub Actions が AWS へ入るための OIDC とロールの記録 |
| `docs/release.md` | どの契機でどこへ出すか |

本体とは shard も依存も別である。
`backend/` は独自の `shard.yml` を持ち、Crystal のコマンドは `status-server/backend/` を作業ディレクトリにして走らせる。
リポジトリ直下の `crystal spec` と `crystal tool format --check src spec` は、ここを対象にしない。

## 手元で検査する

```
cd status-server/backend
shards install
crystal tool format --check
crystal spec
```

```
cd status-server/infra
npm ci
npm run typecheck
```

Lambda へ載せる zip は `status-server/backend/build.sh` が作る。docker が要る。

## 文書とコメントの読み方

この下の文書とコメントは、移設の前に書いたものをほぼそのまま持ってきている。
そのため、次の三つは元のリポジトリを指している。

- **`#22` のような番号**は、元のリポジトリの issue と pull request の番号である。このリポジトリの同じ番号とは関係が無い。
- **「仕様書」**は、元のリポジトリの issue #1 にある。「仕様書 5.1」のような章番号はその文書のものである。
- **`docs/…`、`infra/…`、`backend/…` のようなパス**は、`status-server/` から見た相対パスである。

ワークフローの名前は移設のときに変えた。文書に古い名前が残っていたら、次のとおり読み替える。

| 元の名前 | いまの名前 |
| --- | --- |
| `backend-ci.yml` | `status-server-backend-ci.yml` |
| `infra-ci.yml` | `status-server-infra-ci.yml` |
| `deploy-dev.yml` | `status-server-deploy-prod.yml`（出す先も `dev` から `prod` に変えた） |
| `deploy.yml` | `status-server-deploy.yml` |

AWS と Cloudflare に作ったものの名前（`qazx7412-vrc-service-status-panel-…`）と、配信の URL は移設の後も変えない。
名前は置き換えでしか変えられず、変えるとバケットも関数も作り直しになる（`infra/README.md` の「名前の付け方」）。
