import * as cloudflare from "@pulumi/cloudflare";

import {
    bucketLocation,
    cloudflareAccountId,
    publicBucketName,
    stateBucketName,
} from "./settings";

// 配信と内部の保存先（仕様書 6）。

// バケットを消すと配信も履歴も失う。protect を付けて、
// destroy や置き換えを伴う変更が誤って通らないようにする。
export const publicBucket = new cloudflare.R2Bucket(
    "public",
    {
        accountId: cloudflareAccountId,
        name: publicBucketName,
        location: bucketLocation,
    },
    { protect: true },
);

export const stateBucket = new cloudflare.R2Bucket(
    "state",
    {
        accountId: cloudflareAccountId,
        name: stateBucketName,
        location: bucketLocation,
    },
    { protect: true },
);

// Cache Rules はここでは作らない。
//
// 配信 JSON は .json なので、既定ではキャッシュの対象にならない（仕様書 6）。
// 対象へ入れるには Cache Rules が要る。
// ところが http_request_cache_settings の kind: "zone" の ruleset は、
// ゾーンに一つしか置けない。
//
// dev と prod は同じゾーンへ配信するので、スタックごとに持たせると二つ目が
// 400 で落ちる（#45）。import で相乗りさせることもできない。
// rules はスタックごとに全体を書き下す形であり、後から流したほうが
// もう片方の規則を消す。
//
// ゾーンに一つしか置けない共有資源であって、スタックの寿命とは合わない。
// AWS の OIDC プロバイダを Pulumi に載せていないのと同じ扱いにした
// （docs/aws-oidc.md の「Pulumi に載せない理由」）。
// 手で作り、規則にすべてのスタックの配信ホストを並べる。
// 手順は infra/README.md の「手で行う作業」にある。

// カスタムドメインはここでは作らない。
//
// cloudflare_r2_custom_domain には、作成の約一分後に enabled が false へ戻る
// 不具合がある（cloudflare/terraform-provider-cloudflare#6578）。Pulumi の
// Cloudflare プロバイダは同じ Terraform プロバイダを包んだものなので、
// 同じ挙動になる。配信そのものが止まる箇所であり、載せる利より害が大きい。
//
// 当面はダッシュボードから繋ぐ。手順は infra/README.md にある。
// 不具合が直れば、ここに R2CustomDomain を足すだけで済む。
