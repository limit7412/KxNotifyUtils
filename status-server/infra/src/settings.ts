import * as pulumi from "@pulumi/pulumi";

// スタックごとの設定をここで一度だけ読む。
// 値の意味と既定は Pulumi.yaml の config に書いてある。

const config = new pulumi.Config();

/** スタック名の上限。下の checkStackName に導き方を書いてある */
const MAX_STACK_NAME = 16;

/**
 * スタック名を物理名に使えるか確かめる。
 *
 * Pulumi のスタック名はここより緩く、大文字も `_` も長い名前も通る。
 * そのまま物理名にすると、R2 は `_` を受け付けず、AWS と R2 は長さで弾く。
 * どちらも実際に作りに行くまで分からないので、ここで止める。
 *
 * いちばん厳しいのは `qazx7412-vrc-service-status-panel-<スタック名>-scheduler` で、
 * IAM ロール名の上限 64 文字のうち頭と接尾で 44 文字を使うため 20 文字まで置ける。
 * 16 文字にしてあるのは、関数名（同じ 64 文字の上限を handler 名と分け合う）に
 * 余りを残すためである。
 */
function checkStackName(name: string): string {
    if (!/^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/.test(name)) {
        throw new Error(
            `スタック名 "${name}" は物理名に使えない。` +
                "小文字、数字、ハイフンだけで、先頭と末尾は小文字か数字にする",
        );
    }
    if (name.length > MAX_STACK_NAME) {
        throw new Error(
            `スタック名 "${name}" が長い（${name.length} 文字）。` +
                `${MAX_STACK_NAME} 文字までにする`,
        );
    }
    return name;
}

export const stack = checkStackName(pulumi.getStack());

/**
 * リソース名の頭。
 *
 * 作成者の名前から始めるのは、同じ AWS / Cloudflare アカウントに置いた
 * 他のものと見分けるためである。スタック名まで含めるので、dev と prod を
 * 並べても衝突しない。デプロイロールの権限もこの頭で絞ってある。
 *
 * 長さの上限がいちばん厳しいのは Lambda の関数名で 64 文字である。
 * この頭とスタック名で 40 文字ほど使うため、handler 名に使えるのは
 * 20 文字ほどになる。
 */
export const prefix = `qazx7412-vrc-service-status-panel-${stack}`;

// 明示したプロバイダはスタック設定の aws:region を自動では読まないため、
// ここで取り出しておく。既定は仕様書 5.1 の東京である。
export const awsRegion = new pulumi.Config("aws").get("region") ?? "ap-northeast-1";

export const cloudflareAccountId = config.require("cloudflareAccountId");
export const deliveryHost = config.require("deliveryHost");

// この定義からは読まない。Cache Rules もカスタムドメインも手で作るためである
// （infra/README.md の「手で行う作業」）。
// それでも設定に残してあるのは、その手作業がどのゾーンに触るのかを、
// スタックごとに記録しておく先がここしかないからである。
export const deliveryZoneId = config.require("deliveryZoneId");

// バケットも同じ頭で揃える。スタック名まで入れるのは、同じアカウントで
// dev と prod を並べたときに、名前が同じだと後から作るほうが既存のものと
// ぶつかり、通ってしまえば配信も内部の記録も互いに上書きし合うためである。
// 名前を決めたい場合は publicBucket / stateBucket で明示する。
export const publicBucketName = config.get("publicBucket") || `${prefix}-public`;
export const stateBucketName = config.get("stateBucket") || `${prefix}-state`;
export const bucketLocation = config.get("bucketLocation") ?? "apac";

export const youtubeProbeVideoId = config.require("youtubeProbeVideoId");
export const boothProbeItemId = config.require("boothProbeItemId");

export const alertWebhookUrl = config.requireSecret("alertWebhookUrl");

// 実行時ロールに付ける上限。AWS CLI で作ってあり、中身は docs/aws-oidc.md にある。
//
// 上限を決める場所を CI の届かないところへ置きたいので、ここでは作らない。
// 同じプログラムに置くと、CI が自分を縛っている上限を書き換えられる。
//
// 持つのは ARN ではなく名前である。ARN にはアカウント ID が入り、この設定は
// commit され、リポジトリは public だからである（#26）。ARN は roles.ts が
// いま繋いでいるアカウントから組む。
//
// 手元からしかデプロイしないなら空でよい。CI からデプロイする場合は、
// デプロイロールが境界付きのロールしか作れないため、空だと CreateRole で止まる。
export const workloadBoundaryName = config.get("workloadBoundaryName") || undefined;
