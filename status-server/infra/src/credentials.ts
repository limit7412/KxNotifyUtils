import * as crypto from "crypto";
import * as cloudflare from "@pulumi/cloudflare";
import * as pulumi from "@pulumi/pulumi";

import { publicBucket, stateBucket } from "./delivery";
import { cloudflareAccountId, prefix } from "./settings";

// R2 の鍵（仕様書 9）。
//
// Pulumi に発行させるのは、バケット名も鍵も、そのまま Lambda の環境変数に
// なるためである（仕様書 11.7）。人が写すと、鍵を替えたときに写し忘れる。

// R2 のトークンで選べるのは Admin Read & Write、Admin Read only、
// Object Read & Write、Object Read only の四つで、書き込みのみの段階は無い。
// 書けるのは Admin Read & Write と Object Read & Write の二つで、Object 系だけが
// バケット単位に絞れる。S3 互換 API での読み書きしか要らないので、狭いほうを選ぶ。
//
// 読み取りが付くのは避けられないが、内部バケットは毎回読む（仕様書 5.2 の手順 4）
// ため、どちらにせよ要る。
//
// 鍵は一組にする。バケットごとに割れば片方が漏れたときの範囲は狭くなるが、
// どちらも同じ関数の環境変数に入るので、関数を破られたときは両方とも取られる。
// 分けて効くのは書き手を別の関数へ割ったときである（仕様書 9）。
const R2_OBJECT_READ_WRITE = "2efd5506f9c8494dacb1fa10a3e7d5b6";

// バケットは特定の管轄に作っていないので default になる。
const bucketResource = (name: string) =>
    `com.cloudflare.edge.r2.bucket.${cloudflareAccountId}_default_${name}`;

const r2Token = new cloudflare.AccountToken("r2", {
    accountId: cloudflareAccountId,
    name: `${prefix}-r2`,
    policies: [
        {
            effect: "allow",
            permissionGroups: [{ id: R2_OBJECT_READ_WRITE }],
            resources: pulumi
                .all([publicBucket.name, stateBucket.name])
                .apply(([pub, st]) =>
                    JSON.stringify({
                        [bucketResource(pub)]: "*",
                        [bucketResource(st)]: "*",
                    }),
                ),
        },
    ],
});

// S3 互換 API の資格情報はトークンから導く。
// Access Key ID はトークンの id、Secret Access Key はトークンの値の SHA-256 である。
export const r2AccessKeyId = r2Token.id;

export const r2SecretAccessKey = pulumi.secret(
    r2Token.value.apply((value) => crypto.createHash("sha256").update(value).digest("hex")),
);

export const r2Endpoint = `https://${cloudflareAccountId}.r2.cloudflarestorage.com`;
