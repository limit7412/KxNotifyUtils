# 集約サーバーを出す流れ

集約サーバー（`backend/`）と配信経路（`infra/`）を、どの契機で、どこへ出すか。
本体（`KxNotifyUtils.exe`）のリリースは別の流れで、リポジトリ直下の `docs/development.md` にある。

契機は二つある。

| 契機 | 出す先 |
| --- | --- |
| `master` へのマージ | `prod` スタック |
| `status-server-deploy.yml` を手で流す | 入力で選んだスタック。`dev` へはどのブランチからでも出せる |

`dev` へ自動で出る契機は無い。
`dev` は、マージの前のブランチを確かめる場所として使う。
`master` へ入った内容はそのまま `prod` へ出るので、集約サーバーを直す pull request は、マージの前に `dev` へ出して確かめる。

本体のリリースとは連動させていない。
正式版（`X.Y.Z`）を公開しても、プレリリース（`X.Y.Z-testN`）が作られても、集約サーバーは動かない。

## 配る exe がどの配信を読むか

exe の既定の取得先は `prod` の配信（`https://vrc-status.oxymoron.link/v1/status.json`）である。
正式版もプレリリースも同じで、ビルドの種類では既定を変えていない。

プレリリースと手元でビルドした exe では、設定ウィンドウの監視対象タブに「取得先」が出て、`dev` の配信（`https://vrc-status-dev.oxymoron.link/v1/status.json`）へ切り替えられる。
ブランチを `dev` へ出し、プレリリースの exe を `dev` へ向ければ、集約サーバーの変更を `prod` へ出す前に exe から確かめられる。
項目の説明は `docs/configuration.md` の `sources.service_status` にある。

## ワークフローの一覧

| ファイル | 起動 | 何をするか |
| --- | --- | --- |
| `status-server-backend-ci.yml` | pull request、`master` への push、手動 | `backend/` の format、lint、spec と、Lambda へ載せる形の静的ビルド |
| `status-server-infra-ci.yml` | pull request、`master` への push、手動 | `infra/` の型検査 |
| `status-server-deploy-prod.yml` | `master` への push | 集約サーバーか配信経路に触れた取り込みで、`status-server-deploy.yml` を `prod` へ向けて起こし、その時点の `master` の先端を出す |
| `status-server-deploy.yml` | `status-server-deploy-prod.yml` からの起動、手動。どちらも `workflow_dispatch` | `pulumi up`。ジョブは出す先と同じ名前の environment を参照する。手動では出す先を入力で選ぶ |

どのワークフローも `on` の `paths` ではなく、`.github/actions/changed-paths` で対象を絞る。
判定できなかった変更は、検査する側、出す側へ倒す。
`status-server-deploy-prod.yml` の対象は `status-server/backend/`、`status-server/infra/`、`status-server-deploy.yml` とそのワークフロー自身である。
force push のときは差分に巻き戻した分が出ないので、対象に触れたものとして動く。

本体のワークフロー（`ci.yml`、`prerelease.yml`、`release.yml`）とは対象のパスが重ならない。
`status-server/` だけを直した取り込みでは exe のプレリリースは作られず、`src/` だけを直した取り込みでは `prod` へ出ない。

`status-server-deploy-prod.yml` は、push されたコミットではなく、走った時点の `master` の先端を出す。
concurrency の群の中で実行の順序は保証されず、先の push の実行が後から走ることがある。
push されたコミットを出すと、後の push の内容を出した後に古い内容へ戻る。
`status-server-deploy.yml` を `master` の ref で起こすので、手順の定義も先端のものになる。

## dev へ出す手順

1. Actions の status-server deploy を `workflow_dispatch` で開く
2. 「Use workflow from」に、出したいブランチを選ぶ
3. stack を `dev` のまま流す

出るのは、選んだブランチの先端である。
ワークフローの定義も選んだブランチのものが使われるので、`status-server-deploy.yml` を直す変更も `dev` で確かめられる。

コマンドなら次のとおりである。

```
gh workflow run status-server-deploy.yml --ref <ブランチ> -f stack=dev
```

`dev` は一つしか無い。
別のブランチを出すと、前に出したブランチの内容は置き換わる。
同じスタックへの実行は直列になるが、どのブランチの内容を残すかは、最後に流した者が決めることになる。

## prod へ出す手順

`master` へマージする。
`status-server/` に触れた取り込みなら、`status-server-deploy-prod.yml` が `prod` へ出す。

手で出すこともできる。
Actions の status-server deploy を `workflow_dispatch` で開き、ref に `master` を選び、stack に `prod` を入れて流す。
`prod` へは `master` に含まれるコミットしか出せない。
environment の規則が `master` 以外からの起動を止め、ワークフローも checkout したコミットが `master` に含まれることを確かめる。

前の内容へ切り戻すときも ref は `master` のまま、`ref` の入力に戻したいコミットを入れる。
切り戻した後で `master` へ別の取り込みが入ると、その時点の先端がまた `prod` へ出る。
切り戻しを保ちたいときは、原因の変更を `master` で revert する。

## 手で行う作業

デプロイ定義に載らず、人がリポジトリの設定として置くものが三つある。
どれも移設前のリポジトリには置いてあったもので、このリポジトリへ置き直す手順は `docs/migration.md` にある。

**environment `dev` と `prod`。**
`status-server-deploy.yml` のジョブは出す先と同じ名前の environment を参照する。
存在しない environment を参照して動かすと、保護規則の無い environment が自動で作られる。
Settings の Environments で、Deployment branches and tags を次のとおりにする。

| environment | 許す ref |
| --- | --- |
| `dev` | 絞らない（No restriction） |
| `prod` | 「Selected branches and tags」で、ブランチ `master` だけ |

`prod` にタグは許さない。
タグを許すと、write 権限を持つ者が未レビューのコミットにタグを打ち、その ref で `status-server-deploy.yml` を手で流すだけで `prod` を名乗れる。
`master` だけなら、出る内容は `master` に限られ、`master` に入るものはブランチ保護が決める。
さらに絞るなら `prod` に required reviewers を掛ける。
ジョブは承認を待つあいだトークンを受け取らず、承認した実行だけが `prod` を名乗れる。
その場合、`master` へのマージのたびに承認が要る。

`dev` を絞らないので、write 権限を持つ者は、どのブランチの内容でも `dev` へ出せる。
デプロイロールは `dev` と `prod` で同じものなので（`docs/aws-oidc.md`）、`dev` を名乗れるジョブは `prod` の関数とロールにも手が届く。
`prod` を守っているのは environment の規則ではなく、write 権限を誰に渡すかである。
一人で書いているあいだはこれで足りる。書く者が増えたら、ロールをスタックごとに分ける。

**OIDC の信頼設定。**
environment を参照するジョブが受け取る OIDC トークンの `sub` は `environment:<名前>` になり、ブランチもタグも含まない。
AWS の信頼ポリシーと Pulumi Cloud の認可ポリシーは、この `sub` を完全一致で通す。
`sub` にはリポジトリの名前と数値 ID が入るので、リポジトリを移したら書き換えが要る。
現物と手順は `docs/aws-oidc.md` の「誰がロールを引けるか」と、`infra/README.md` の「手で行う作業」にある。

**`master` のブランチ保護。**
`status-server-deploy-prod.yml` は検査の成功を前提にしていない。
検査は同じ push で並んで走るだけなので、`master` に何が入るかを決めるのは ruleset の側である。
`master` へ入った内容はそのまま `prod` へ出るので、集約サーバーの検査（変更の判定、format / lint / spec、static build、typecheck）を required に足しておくほうがよい。
足していなければ、検査の落ちた内容も `prod` へ出る。
