# 集約サーバーを出す流れ

集約サーバー（`backend/`）と配信経路（`infra/`）を、どの契機で、どこへ出すか。
本体（`KxNotifyUtils.exe`）のリリースは別の流れで、リポジトリ直下の `docs/development.md` にある。

契機は三つある。

| 契機 | 出す先 |
| --- | --- |
| `master` へのマージ | `dev` スタック |
| 本体の正式版（`X.Y.Z`）の公開 | `prod` スタック |
| `status-server-deploy.yml` を手で流す | 入力で選んだスタック |

本体のプレリリース（`X.Y.Z-testN`）では `prod` へ出さない。
`prod` へ出るのは、正式版として公開したタグの内容だけである。

集約サーバーに変更の無い正式版でも `prod` へ出す。
差分の有無を見て飛ばす形にすると、前に `prod` へ出したコミットをワークフローが覚えておく必要がある。
出しても `pulumi up` の差分は Lambda の zip の入れ替えに留まる。

**配る exe の接続先は、正式版もプレリリースも `prod` の配信である。**
exe の既定の取得先は `https://vrc-status.oxymoron.link/v1/status.json` で、ビルドの種類では変えていない。
`dev` の配信（`https://vrc-status-dev.oxymoron.link/v1/status.json`）を読ませるには、設定ファイルの `sources.service_status.feed_url` を書き換える。
そのため、プレリリースの exe が読むのは、前の正式版の時点の集約サーバーが作った配信である。
配信 JSON の形を変えるときは、この組み合わせで動くことを確かめてから `master` へ入れる。

## ワークフローの一覧

| ファイル | 起動 | 何をするか |
| --- | --- | --- |
| `status-server-backend-ci.yml` | pull request、`master` への push、手動 | `backend/` の format、lint、spec と、Lambda へ載せる形の静的ビルド |
| `status-server-infra-ci.yml` | pull request、`master` への push、手動 | `infra/` の型検査 |
| `status-server-deploy-dev.yml` | `master` への push | 集約サーバーか配信経路に触れた取り込みで、`status-server-deploy.yml` を `dev` へ向けて起こし、その時点の `master` の先端を出す |
| `release.yml` | リリースの公開（`published`）、手動 | exe と zip を添付する。正式版なら、その後で `status-server-deploy.yml` を `prod` へ向けて起こし、終わるまで待つ |
| `status-server-deploy.yml` | `status-server-deploy-dev.yml` と `release.yml` からの起動、手動。どれも `workflow_dispatch` | `pulumi up`。ジョブは出す先と同じ名前の environment を参照する。手動では出す先を入力で選ぶ |

どのワークフローも `on` の `paths` ではなく、`.github/actions/changed-paths` で対象を絞る。
判定できなかった変更は、検査する側、出す側へ倒す。
`status-server-deploy-dev.yml` の対象は `status-server/backend/`、`status-server/infra/`、`status-server-deploy.yml` とそのワークフロー自身である。
force push のときは差分に巻き戻した分が出ないので、対象に触れたものとして動く。

本体の検査とプレリリース（`ci.yml`、`prerelease.yml`）とは対象のパスが重ならない。
`status-server/` だけを直した取り込みでは exe のプレリリースは作られず、`src/` だけを直した取り込みでは `dev` へ出ない。

`status-server-deploy-dev.yml` は、push されたコミットではなく、走った時点の `master` の先端を出す。
concurrency の群の中で実行の順序は保証されず、先の push の実行が後から走ることがある。
push されたコミットを出すと、後の push の内容を出した後に古い内容へ戻る。
`status-server-deploy.yml` を `master` の ref で起こすので、手順の定義も先端のものになる。

## prod へ出す手順

1. 出したい内容が `master` に入り、`dev` へのデプロイが通っていることを確かめる
2. GitHub の Releases で、`X.Y.Z` のタグを `master` のコミットに打ち、リリースを公開する
3. `release.yml` が exe と zip を添付し、続けて `prod` へ出す

`prod` へ出すのはそのタグの内容で、`master` の先端ではない。
exe をビルドしているあいだに `master` が進んでも、出るのは公開したタグのままである。

`release.yml` は `status-server-deploy.yml` を `master` の ref で `workflow_dispatch` として起こし、終わるまで待つ。
`workflow_call` で呼ばないのは、リリースの公開で動く実行がタグの ref を持ち、environment `prod` の規則（`master` だけ）に当たるためである。
タグのコミットを `ref` と `expected_sha` で渡し、`status-server-deploy.yml` はそれを checkout して、`master` に含まれるコミットであることを確かめてから出す。
`master` に無いコミットへ打ったタグでは、exe は添付されるが `prod` へは出ず、`release.yml` が失敗になる。
起こした実行が成功で終わらなかったときも、`release.yml` は失敗になる。

`master` の過去のコミットへ打ったタグは通る。
その場合、`prod` の集約サーバーはそのコミットの時点へ戻る。
正式版のタグは、前の正式版より新しいコミットへ打つ。

プレリリースを正式版へ昇格したときは `prod` へ出ない。
昇格では `released` しか発火せず、`release.yml` はそれを購読していない。
正式版は新しい `X.Y.Z` のタグで公開する。

集約サーバーだけを出したいときは、`status-server-deploy.yml` を手で流す。
Actions の status-server deploy を `workflow_dispatch` で開き、ref に `master` を選び、スタックを選ぶ。
environment の規則が `master` だけを許すので、他の ref からは起動できない。

前の内容へ切り戻すときも ref は `master` のまま、`ref` の入力に戻したいタグを入れる。
`status-server-deploy.yml` はその内容を checkout し、`master` に含まれるコミットであることを確かめてから出す。
`master` に入って `dev` で試したものしか出せない。

## 手で行う作業

デプロイ定義に載らず、人がリポジトリの設定として置くものが三つある。
どれも移設前のリポジトリには置いてあったもので、このリポジトリへ置き直す手順は `docs/migration.md` にある。

**environment `dev` と `prod`。**
`status-server-deploy.yml` のジョブは出す先と同じ名前の environment を参照する。
存在しない environment を参照して動かすと、保護規則の無い environment が自動で作られる。
Settings の Environments で、どちらも Deployment branches and tags を「Selected branches and tags」にし、ブランチ `master` だけを許す。

タグは許さない。
`prod` へ出す `release.yml` はリリースの公開（タグの ref）で動くが、`status-server-deploy.yml` を `master` の ref で起こすので、タグから `prod` を名乗る必要が無い。
タグを許すと、write 権限を持つ者が未レビューのコミットにタグを打ち、その ref で `status-server-deploy.yml` を手で流すだけで `prod` を名乗れる。
`master` だけなら、出る内容は `master` に限られ、`master` に入るものはブランチ保護が決める。
さらに絞るなら `prod` に required reviewers を掛ける。
ジョブは承認を待つあいだトークンを受け取らず、承認した実行だけが `prod` を名乗れる。

**OIDC の信頼設定。**
environment を参照するジョブが受け取る OIDC トークンの `sub` は `environment:<名前>` になり、ブランチもタグも含まない。
AWS の信頼ポリシーと Pulumi Cloud の認可ポリシーは、この `sub` を完全一致で通す。
`sub` にはリポジトリの名前と数値 ID が入るので、リポジトリを移したら書き換えが要る。
現物と手順は `docs/aws-oidc.md` の「誰がロールを引けるか」と、`infra/README.md` の「手で行う作業」にある。

**`master` のブランチ保護。**
`status-server-deploy-dev.yml` は検査の成功を前提にしていない。
検査は同じ push で並んで走るだけなので、`master` に何が入るかを決めるのは ruleset の側である。
集約サーバーの検査（変更の判定、format / lint / spec、static build、typecheck）を required に足すかどうかは、まだ決めていない。
