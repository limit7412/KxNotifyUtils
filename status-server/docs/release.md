# 集約サーバーを出す流れ

集約サーバー（`backend/`）と配信経路（`infra/`）を、どの契機で、どこへ出すか。
本体（`KxNotifyUtils.exe`）のリリースは別の流れで、リポジトリ直下の `docs/development.md` にある。

契機は二つある。

| 契機 | 出す先 |
| --- | --- |
| `master` へのマージ | `dev` スタック |
| `status-server-deploy.yml` を手で流す | 入力で選んだスタック。`prod` へ出すのはこの経路だけである |

本体のリリースの公開では `prod` へ出さない。
本体の版は exe の版であり、集約サーバーの中身が変わっていないリリースのたびに `pulumi up` を流す理由が無い。
逆に、集約サーバーだけを直したときに、exe の版を上げなくても `prod` へ出せる。

## ワークフローの一覧

| ファイル | 起動 | 何をするか |
| --- | --- | --- |
| `status-server-backend-ci.yml` | pull request、`master` への push、手動 | `backend/` の format、lint、spec と、Lambda へ載せる形の静的ビルド |
| `status-server-infra-ci.yml` | pull request、`master` への push、手動 | `infra/` の型検査 |
| `status-server-deploy-dev.yml` | `master` への push | 集約サーバーか配信経路に触れた取り込みで、`status-server-deploy.yml` を `dev` へ向けて起こし、その時点の `master` の先端を出す |
| `status-server-deploy.yml` | `status-server-deploy-dev.yml` からの起動、手動。どちらも `workflow_dispatch` | `pulumi up`。ジョブは出す先と同じ名前の environment を参照する。手動では出す先を入力で選ぶ |

どのワークフローも `on` の `paths` ではなく、`.github/actions/changed-paths` で対象を絞る。
判定できなかった変更は、検査する側、出す側へ倒す。
`status-server-deploy-dev.yml` の対象は `status-server/backend/`、`status-server/infra/`、`status-server-deploy.yml` とそのワークフロー自身である。
force push のときは差分に巻き戻した分が出ないので、対象に触れたものとして動く。

本体のワークフロー（`ci.yml`、`prerelease.yml`、`release.yml`）とは対象のパスが重ならない。
`status-server/` だけを直した取り込みでは exe のプレリリースは作られず、`src/` だけを直した取り込みでは `dev` へ出ない。

`status-server-deploy-dev.yml` は、push されたコミットではなく、走った時点の `master` の先端を出す。
concurrency の群の中で実行の順序は保証されず、先の push の実行が後から走ることがある。
push されたコミットを出すと、後の push の内容を出した後に古い内容へ戻る。
`status-server-deploy.yml` を `master` の ref で起こすので、手順の定義も先端のものになる。

## prod へ出す手順

1. 出したい内容が `master` に入り、`dev` へのデプロイが通っていることを確かめる
2. Actions の status-server deploy を `workflow_dispatch` で開き、ref に `master` を選び、stack に `prod` を入れて流す

environment の規則が `master` だけを許すので、他の ref からは起動できない。

前の内容へ切り戻すときも ref は `master` のまま、`ref` の入力に戻したいコミットを入れる。
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
