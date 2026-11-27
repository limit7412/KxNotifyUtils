import * as pulumi from "@pulumi/pulumi";

import { alertTopic, staleAlarm } from "./src/alarm";
import { createFunctions, Environment } from "./src/compute";
import { r2AccessKeyId, r2Endpoint, r2SecretAccessKey } from "./src/credentials";
import { publicBucket, stateBucket } from "./src/delivery";
import { indexPage } from "./src/page";
import {
    alertWebhookUrl,
    boothProbeItemId,
    deliveryHost,
    stack,
    youtubeProbeVideoId,
} from "./src/settings";

// 集約サーバー（Lambda）と配信経路（R2）をひとつの定義にまとめる。
//
// 両側を分けないのは、片側の値をもう片側が使うためである。R2 のバケット名も、
// トークンから導いた鍵も、そのまま Lambda の環境変数になる（仕様書 11.7）。
// 分けて書くと、その受け渡しを人が写すことになり、鍵を替えたときに写し忘れる。
//
// 中身は src/ にある。
//
//   settings.ts     スタックごとの設定
//   providers.ts    AWS プロバイダ（リージョンを固定する）
//   delivery.ts     R2 のバケット（仕様書 6）
//   credentials.ts  R2 の S3 互換トークンと、そこから導く鍵（仕様書 9）
//   page.ts         確認用 HTML ページ（仕様書 6.1）
//   functions.ts    関数の一覧。増やすときはここ
//   roles.ts        実行時のロール
//   compute.ts      Lambda、ロググループ、Scheduler（仕様書 5.1）
//   alarm.ts        止まったことを知らせる SNS とアラーム（仕様書 9）
//
// このファイルは、それらを繋いで出力を並べるだけである。

// 仕様書 11.7 が挙げる環境変数。関数はどれも同じものを受け取る。
// main.cr は欠けていれば起動時に落とす。
const environment: Environment = {
    ENV: stack,
    R2_ENDPOINT: r2Endpoint,
    R2_PUBLIC_BUCKET: publicBucket.name,
    R2_STATE_BUCKET: stateBucket.name,
    R2_ACCESS_KEY_ID: r2AccessKeyId,
    R2_SECRET_ACCESS_KEY: r2SecretAccessKey,
    YOUTUBE_PROBE_VIDEO_ID: youtubeProbeVideoId,
    BOOTH_PROBE_ITEM_ID: boothProbeItemId,
    ALERT_WEBHOOK_URL: alertWebhookUrl,
};

const compute = createFunctions(environment);

// ---------------------------------------------------------------------------
// 出力
// ---------------------------------------------------------------------------

export const publicBucketOut = publicBucket.name;
export const stateBucketOut = stateBucket.name;
export const r2EndpointOut = r2Endpoint;
export const functionNames = pulumi.all(compute.functions.map((fn) => fn.name));
export const logGroupNames = pulumi.all(compute.logGroups.map((group) => group.name));
// カスタムドメインを手で繋ぐときの相手。
export const deliveryUrl = `https://${deliveryHost}/v1/status.json`;
// 人が開いて状態を読み取るページ（仕様書 6.1）。
export const pageUrl = `https://${deliveryHost}/index.html`;
export const pageKey = indexPage.key;
// 届け先を手で足すときの相手（infra/README.md の「手で行う作業」）。
export const alertTopicArn = alertTopic.arn;
export const staleAlarmName = staleAlarm.name;
