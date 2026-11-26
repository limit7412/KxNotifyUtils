import * as aws from "@pulumi/aws";

import { onAws } from "./providers";
import { prefix, stack } from "./settings";

// 集約サーバーが止まったことを知らせる（仕様書 9）。
//
// これは backend の error/usecase.cr が送るアラートとは別の経路である。
// あちらは refresh が例外を出したときに関数が自分で送るので、関数が起動しない、
// Scheduler が止まる、バイナリが壊れて bootstrap が上がらない、という場合は
// 何も送られない。止まったことを知らせるには、外から見ている誰かが要る。
//
// 送り先も分ける。関数が死んでいるときに関数へ転送させる形にすると、
// 見張る側が見張られる側と同じ足場に乗ることになる。
// SNS からのメールなら AWS の中だけで完結する。

/** メトリクスの名前空間と名前。backend/src/runtime/metrics.cr と揃える */
const NAMESPACE = "VRCServiceStatusPanel";
const METRIC = "RefreshSuccess";

/** 何分止まったら知らせるか（仕様書 9） */
const WINDOW_MINUTES = 5;

export const alertTopic = new aws.sns.Topic("alerts", { name: `${prefix}-alerts` }, onAws);

// 購読はここでは作らない。届け先は手で足す（infra/README.md の「手で行う作業」）。
//
// 届け先をスタックの設定に持たせると、その値が commit される。
// このリポジトリは public なので（仕様書 9）、メールアドレスを置けばそのまま公開される。
// secret にすれば暗号文になるが、そうすると値が Output になり、
// 「設定してあれば購読を作る」という条件そのものが書けなくなる。
//
// 手作業が一つ増えるわけでもない。メールの購読は AWS から届く確認のリンクを
// 開くまで PendingConfirmation のままで、そこはどのみち人の手が要る。
// Chatbot 経由の Slack のように、メール以外へ届けたい場合の余地も残る。

export const staleAlarm = new aws.cloudwatch.MetricAlarm(
    "refresh-stale",
    {
        name: `${prefix}-refresh-stale`,
        alarmDescription: `${stack} の配信が ${WINDOW_MINUTES} 分止まっている`,

        // 一分ごとの成功の数を、欠測を 0 に埋めてから見る。
        //
        // 5 分をひとつの期間にして evaluationPeriods を 1 にすると、止まったことに
        // 気付くのが遅れる。CloudWatch は欠測があると、指定した期間より広い範囲
        // （evaluation range）まで遡って実データ点を探し、evaluationPeriods の
        // ぶんだけ見つかれば treatMissingData を使わずにその古い点で判定する。
        // 止まる直前の成功が範囲に残っているあいだ、OK のままになる。
        // https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/alarms-and-missing-data.html
        //
        // FILL で欠測を 0 に変えれば、埋めた 0 がそのまま実データ点として数えられ、
        // 遡る必要そのものが無くなる。
        metricQueries: [
            {
                id: "successes",
                expression: "FILL(m1, 0)",
                label: `${METRIC}（欠測は 0）`,
                returnData: true,
            },
            {
                id: "m1",
                metric: {
                    namespace: NAMESPACE,
                    metricName: METRIC,
                    // 名前空間が同じでもスタックが違えば別の系列になる。
                    dimensions: { Env: stack },
                    period: 60,
                    stat: "Sum",
                },
                returnData: false,
            },
        ],

        // 一分ごとの点が 5 つ続けて 1 未満なら鳴る。
        evaluationPeriods: WINDOW_MINUTES,
        datapointsToAlarm: WINDOW_MINUTES,
        threshold: 1,
        comparisonOperator: "LessThanThreshold",

        // 一度も出ていなければ FILL も埋められない。
        //
        // FILL が埋める相手はメトリクスの側にあるデータ点なので、範囲に一つも
        // 無ければ何も返さない。関数が一度も上がっていない、いちばん知りたい
        // 場合がこれにあたる。欠測を異常として扱い、INSUFFICIENT_DATA で
        // 止まらないようにする。
        treatMissingData: "breaching",

        alarmActions: [alertTopic.arn],
        // 直ったことも知らせる。鳴りっぱなしと復旧を見分けられる。
        okActions: [alertTopic.arn],
    },
    onAws,
);
