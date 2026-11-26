# デプロイ元をこのリポジトリへ切り替える

集約サーバーのコードとワークフローは、limit7412/VRCServiceStatusPanel からこのリポジトリへ移した。
しかし、コードを移しただけでは、このリポジトリからデプロイできない。
AWS と Pulumi Cloud は、デプロイしてよい相手をリポジトリの名前と数値 ID で絞っており、いま通るのは元のリポジトリだけだからである。

この文書は、その切り替えで人が行う作業を、行う順に並べたものである。
切り替えが済んだら、この文書は消してよい。

## 切り替えの前後で変わらないもの

AWS と Cloudflare に作ってあるもの、Pulumi のスタック、配信の URL は変えない。
変えるのは「どのリポジトリのワークフローがそれらを更新できるか」だけである。
そのため、切り替えの途中で配信が止まることはなく、本体（`KxNotifyUtils.exe`）の利用者に見える変化も無い。

Pulumi のスタックは Pulumi Cloud にあり、リポジトリには結び付いていない。
`Pulumi.dev.yaml` と `Pulumi.prod.yaml` はそのまま移してあるので、スタックの作り直しも `pulumi stack rename` も要らない。

## 切り替えるまでの状態

切り替えが済むまで、このリポジトリの `status-server-deploy.yml` は `assume aws deploy role` の段で `Not authorized to perform sts:AssumeRoleWithWebIdentity` になって止まる。
AWS へ入る前に止まるので、実物には何も起きない。

`master` へのマージで `status-server-deploy-dev.yml` が動くのは、`status-server/` に触れた取り込みだけである。
移設の pull request そのものがこれに当たるので、手順 1 から 4 を済ませる前にマージすると、その取り込みの `dev` デプロイは一度失敗する。
失敗した実行は、手順 4 までを済ませた後で再実行すれば通る。

元のリポジトリのワークフローは、切り替えの後もアーカイブするまで動く。
二つのリポジトリが同じスタックへ出す期間を短くするため、手順 5 で `dev` が通ったら、続けて手順 6 と 7 を行う。

## 手順

### 1. このリポジトリの数値 ID を引く

OIDC トークンの `sub` には、所有者とリポジトリの数値 ID が入る形がある（`docs/aws-oidc.md` の「誰がロールを引けるか」）。

```
gh api /repos/limit7412/KxNotifyUtils --jq '"\(.owner.id) \(.id)"'
```

所有者の ID は元のリポジトリと同じ `19320218` である。
以下では、リポジトリの ID を `<リポジトリID>` と書く。

### 2. AWS の信頼ポリシーへ、このリポジトリの四つを足す

元のリポジトリの四つを残したまま、このリポジトリの四つを足す。
先に元の四つを消すと、元のリポジトリからも出せなくなり、切り替えに失敗したときに戻る先が無い。

```
repo:limit7412/KxNotifyUtils:environment:dev
repo:limit7412@19320218/KxNotifyUtils@<リポジトリID>:environment:dev
repo:limit7412/KxNotifyUtils:environment:prod
repo:limit7412@19320218/KxNotifyUtils@<リポジトリID>:environment:prod
```

`update-assume-role-policy` は信頼ポリシーを丸ごと置き換える。
足す前に `aws iam get-role` で現物を読み、`docs/aws-oidc.md` の JSON と食い違っていないことを見てから、八つ並べた JSON を流す。

```
aws iam get-role --role-name qazx7412-vrc-service-status-panel-github-deploy \
  --query Role.AssumeRolePolicyDocument

aws iam update-assume-role-policy \
  --role-name qazx7412-vrc-service-status-panel-github-deploy \
  --policy-document file://trust.json
```

デプロイロールの権限と、実行時ロールの権限境界は変えない。
どちらも作るものの名前の頭で絞ってあり、リポジトリの名前を含まない。

### 3. Pulumi Cloud の認可ポリシーへ、同じ四つを足す

Pulumi Cloud の Settings → Access Management → OIDC Issuers → `github-actions` のポリシーに、手順 2 と同じ四つの Subject を Allow で足す。
Subject の他の欄は、いまある四つと同じにする（`infra/README.md` の「手で行う作業」）。

AWS だけを足して Pulumi Cloud を足し忘れると、`assume aws deploy role` は通り、次の `authenticate to pulumi cloud` が `401: Unauthorized` で止まる。

### 4. このリポジトリに environment と Secrets を置く

Settings の Environments で `dev` と `prod` を作り、どちらも Deployment branches and tags を「Selected branches and tags」にして、ブランチ `master` だけを許す。
`prod` に required reviewers を掛けていたなら、同じように掛ける。

environment を作る前にワークフローが動くと、保護規則の無い `dev` が自動で作られる。
その場合は作られた `dev` に同じ規則を足す。

Secrets は三つである。値は元のリポジトリと同じものを入れる。
Secrets の値は GitHub から読み出せないので、ロールの ARN 以外は、控えてある値を入れ直すことになる。

| 名前 | 値 |
| --- | --- |
| `AWS_DEPLOY_ROLE_ARN` | デプロイロールの ARN。`aws iam get-role --role-name qazx7412-vrc-service-status-panel-github-deploy --query Role.Arn --output text` で引ける |
| `PULUMI_CONFIG_PASSPHRASE` | スタックの設定の暗号文を開けるパスフレーズ。元と違う値を入れると `pulumi up` が復号で止まる |
| `CLOUDFLARE_API_TOKEN` | Cloudflare プロバイダのトークン。控えが無ければ作り直す（`infra/README.md` の「Cloudflare の API トークン」） |

### 5. dev へ出して確かめる

Actions の status-server deploy を `workflow_dispatch` で開き、ref に `master` を選び、stack を `dev` のまま流す。
移設の pull request をマージしたときの `dev` デプロイが失敗で残っていれば、それを再実行してもよい。

コードは元のリポジトリの先端と同じなので、`pulumi up` の差分は出ないか、Lambda の zip の入れ替えだけになる。
バケットや関数の置き換え（replace）が差分に出たら、名前か設定が食い違っている。そのときは流さずに止めて原因を見る。

通ったら、`dev` の配信 JSON の `generated_unix` が進み続けていることを確かめる。

### 6. prod へ出す

同じワークフローを、stack に `prod` を入れて流す。
`prod` も差分が出ないことを見る。

ここで手で確かめておくのは、次に本体の正式版を公開したとき、`release.yml` が同じ経路で `prod` へ出すためである。
確かめずに正式版を公開すると、信頼設定の不備がリリースの失敗として出る。

### 7. 元のリポジトリを止める

1. 元のリポジトリの README に、移設先がこのリポジトリであることを書く
2. 元のリポジトリをアーカイブする。アーカイブするとワークフローは動かなくなる
3. AWS の信頼ポリシーと Pulumi Cloud の認可ポリシーから、元のリポジトリの四つを消す

3 を済ませると、元のリポジトリをアーカイブから戻しても、そこからは出せなくなる。

### 8. 文書と参照をこのリポジトリの名前へ直す

ここまで済んだら、次を pull request で直す。

- `docs/aws-oidc.md` と `infra/README.md` の信頼設定の節にあるリポジトリの名前と数値 ID
- 集約サーバーが上流へ名乗る User-Agent の URL（`backend/src/upstream.cr`）
- 確認用ページの下に出しているリポジトリへのリンク（`backend/web/index.html`）
- 本体の設定ウィンドウから開くリポジトリの URL（`src/service_status/models.cr`）
- `status-server/README.md` の「切り替えが済むまでは」の段落と、この文書
