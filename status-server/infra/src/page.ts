import * as crypto from "crypto";
import * as fs from "fs";
import * as path from "path";
import * as aws from "@pulumi/aws";
import * as pulumi from "@pulumi/pulumi";

import { r2AccessKeyId, r2Endpoint, r2SecretAccessKey } from "./credentials";
import { publicBucket } from "./delivery";

// 確認用 HTML ページ（仕様書 6.1）。
//
// 配信 JSON は Udon 向けに整形してあり、level は数値、時刻は epoch 秒で入る。
// 人が開いて読み取れる形ではないので、同じ経路で一枚の HTML を配る。
// ページはブラウザ側から同一オリジンの v1/status.json を取り、その場で整形する。
// 集約サーバーに HTML を生成させると、生成の不具合で写しと配信物が食い違い、
// 確認のためのページが確認対象と違うものを見せることになる。

// 配信するページの中身は backend/web/ にある。
// infra/ は Pulumi の定義だけを置く場所なので、配るものはここへ持ち込まない。
// 集約サーバーの zip を ../backend から取るのと同じ形である（src/compute.ts）。
const HTML_PATH = path.join(__dirname, "..", "..", "backend", "web", "index.html");
const KEY = "index.html";

// R2 は S3 互換 API を持つが、Cloudflare プロバイダにオブジェクトを置く
// リソースが無い。AWS プロバイダの向き先を R2 のエンドポイントへ変えて使う。
//
// 鍵は集約サーバーへ渡すものと同じ一組である（仕様書 9）。
// 分けても、どちらも同じ関数の環境変数に入る以上、守れる範囲は変わらない。
const r2Provider = new aws.Provider("r2", {
    // R2 はリージョンを持たない。SigV4 の署名に使う名目上の値として auto を渡す。
    region: "auto",
    accessKey: r2AccessKeyId,
    secretKey: r2SecretAccessKey,
    // 空を明示する。CI では configure-aws-credentials が AWS_SESSION_TOKEN を
    // 置いたまま pulumi up が走るので、渡さないでおくとこのプロバイダが
    // R2 の鍵に AWS の STS のセッショントークンを添えて署名しうる。
    // R2 はそれを受け取らない。
    // Output を渡すのは、素の "" が偽値として捨てられ、渡さないのと同じに
    // なるためである（@pulumi/aws の provider は args.token を真偽で見る）。
    token: pulumi.output(""),
    endpoints: [{ s3: r2Endpoint }],
    // R2 は仮想ホスト形式のバケット名を解決しない。
    s3UsePathStyle: true,
    // 相手は AWS ではないので、AWS を前提にした確認はどれも当たらない。
    skipCredentialsValidation: true,
    skipRegionValidation: true,
    skipRequestingAccountId: true,
    skipMetadataApiCheck: true,
});

/** インライン要素の中身を、開始タグの直後から終了タグの直前まで取り出す */
function inlineBody(tag: string, html: string): string {
    const match = new RegExp(`<${tag}>([\\s\\S]*?)</${tag}>`).exec(html);
    if (match === null) {
        throw new Error(`${HTML_PATH} に <${tag}> が無い`);
    }
    return match[1];
}

function sha256Base64(body: string): string {
    return crypto.createHash("sha256").update(body, "utf8").digest("base64");
}

// CSP のハッシュを、いまの中身から計算し直して差し込む。
//
// HTML には計算済みの値が書いてあり、そのままブラウザで開ける。
// 書き換えたまま貼り替え忘れると、手元で開いたページの script が動かない。
// 配るものは常に正しくしたいので、ここで計算し直して置き換える。
// 食い違いは警告に出し、貼り替えの手がかりを残す。
function renderPage(): string {
    // 改行を LF へ揃えてから計算する。
    // HTML の構文解析は CR LF を LF へ直してから script と style の中身を読むので、
    // CRLF のまま計算した値はブラウザ側の計算と一致せず、どちらも拒まれる。
    // 揃えた本文をそのまま配るので、置いてあるものと計算の対象も一致する。
    const source = fs.readFileSync(HTML_PATH, "utf8").replace(/\r\n/g, "\n");
    let html = source;

    for (const tag of ["style", "script"]) {
        const expected = `'sha256-${sha256Base64(inlineBody(tag, source))}'`;
        const written = new RegExp(`${tag}-src ('[^']*')`).exec(source);
        if (written === null) {
            throw new Error(`${HTML_PATH} の CSP に ${tag}-src が無い`);
        }
        if (written[1] !== expected) {
            pulumi.log.warn(
                `backend/web/index.html の ${tag}-src のハッシュが中身と合っていない。` +
                    `配るものは直したが、手元で開くために ${expected} へ貼り替えること。`,
            );
            html = html.replace(written[1], expected);
        }
    }

    return html;
}

const html = renderPage();

export const indexPage = new aws.s3.BucketObject(
    "index-page",
    {
        bucket: publicBucket.name,
        key: KEY,
        content: html,
        contentType: "text/html; charset=utf-8",
        // JSON（30 秒）より長く持たせる。ページ自体はめったに変わらない（仕様書 6.1）。
        cacheControl: "public, max-age=300",
        // 中身が変われば置き直す。
        etag: crypto.createHash("md5").update(html).digest("hex"),
    },
    { provider: r2Provider },
);
