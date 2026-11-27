import * as aws from "@pulumi/aws";
import * as pulumi from "@pulumi/pulumi";

import { FUNCTIONS } from "./functions";
import { onAws } from "./providers";
import { lambdaRole, schedulerRole } from "./roles";
import { prefix } from "./settings";

// 集約サーバー（仕様書 5.1）。
//
// 関数の一覧は src/functions.ts にある。ここはそれを AWS のリソースへ落とす。

/** Lambda の関数名の上限 */
const MAX_FUNCTION_NAME = 64;

/** 関数へ渡す環境変数。仕様書 11.7 の一式で、どの関数も同じものを受け取る */
export type Environment = Record<string, pulumi.Input<string>>;

export interface Compute {
    functions: aws.lambda.Function[];
    logGroups: aws.cloudwatch.LogGroup[];
}

export function createFunctions(environment: Environment): Compute {
    // backend/build.sh が作った zip をそのまま渡す。
    //
    // ディレクトリから AssetArchive を組むと実行権限が落ち、provided ランタイムが
    // bootstrap を起動できない。出来上がった zip を渡せば、モードは zip の中の
    // 記録がそのまま使われる。関数が増えても同じ zip を使い回す。
    const code = new pulumi.asset.FileArchive("../backend/bootstrap.zip");

    const logGroups: aws.cloudwatch.LogGroup[] = [];
    const functions: aws.lambda.Function[] = [];

    for (const spec of FUNCTIONS) {
        // handler 名が長いと関数名が上限を超える。
        // スタック名は settings.ts で絞ってあるが、こちらは足す人次第である。
        const functionName = `${prefix}-${spec.handler}`;
        if (functionName.length > MAX_FUNCTION_NAME) {
            throw new Error(
                `関数名 "${functionName}" が長い（${functionName.length} 文字）。` +
                    `handler 名を ${MAX_FUNCTION_NAME - prefix.length - 1} 文字までにする`,
            );
        }

        // ロググループを先に作る。Lambda に任せると保持期間が無期限になり、
        // 60 秒ごとの記録が消えずに溜まり続ける。
        const logGroup = new aws.cloudwatch.LogGroup(
            spec.handler,
            {
                name: `/aws/lambda/${prefix}-${spec.handler}`,
                retentionInDays: 14,
            },
            onAws,
        );
        logGroups.push(logGroup);

        const fn = new aws.lambda.Function(
            spec.handler,
            {
                name: functionName,
                description: spec.description,
                role: lambdaRole.arn,
                code,
                // provided ランタイムが動かすのは zip 直下の bootstrap で、
                // この文字列は _HANDLER として渡る。
                handler: spec.handler,
                runtime: "provided.al2023",
                architectures: ["arm64"],
                memorySize: spec.memorySize,
                timeout: spec.timeout,
                loggingConfig: {
                    logFormat: "Text",
                    logGroup: logGroup.name,
                },
                environment: { variables: environment },
            },
            { ...onAws, dependsOn: [logGroup] },
        );
        functions.push(fn);

        if (spec.schedule === undefined) {
            continue;
        }

        new aws.scheduler.Schedule(
            spec.handler,
            {
                name: `${prefix}-${spec.handler}`,
                description: spec.description,
                scheduleExpression: spec.schedule,
                // 揺らぎを入れない。決めた間隔で動かしたい。
                flexibleTimeWindow: { mode: "OFF" },
                target: {
                    arn: fn.arn,
                    roleArn: schedulerRole.arn,
                    // 失敗しても再試行しない（仕様書 5.3）。次の起動に任せる。
                    retryPolicy: { maximumRetryAttempts: 0 },
                },
            },
            onAws,
        );
    }

    // 権限は関数をすべて作ってからまとめて与える。
    // 関数ごとに作ると、関数を足すたびにポリシーも増える。
    new aws.iam.RolePolicy(
        "lambda-logs",
        {
            name: "logs",
            role: lambdaRole.id,
            policy: pulumi.all(logGroups.map((group) => group.arn)).apply((arns) =>
                JSON.stringify({
                    Version: "2012-10-17",
                    Statement: [
                        {
                            Effect: "Allow",
                            Action: ["logs:CreateLogStream", "logs:PutLogEvents"],
                            Resource: arns.map((arn) => `${arn}:*`),
                        },
                    ],
                }),
            ),
        },
        onAws,
    );

    new aws.iam.RolePolicy(
        "scheduler-invoke",
        {
            name: "invoke",
            role: schedulerRole.id,
            policy: pulumi.all(functions.map((fn) => fn.arn)).apply((arns) =>
                JSON.stringify({
                    Version: "2012-10-17",
                    Statement: [
                        {
                            Effect: "Allow",
                            Action: "lambda:InvokeFunction",
                            Resource: arns,
                        },
                    ],
                }),
            ),
        },
        onAws,
    );

    return { functions, logGroups };
}
