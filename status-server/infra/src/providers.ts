import * as aws from "@pulumi/aws";

import { awsRegion } from "./settings";

// リージョンだけを固定する。資格情報は AWS プロバイダの既定の探索順に任せる。
//
// 状態を R2 へ置いていたころは、バックエンドが AWS_ACCESS_KEY_ID と
// AWS_SECRET_ACCESS_KEY から R2 の鍵を読むため、AWS 側の鍵を DEPLOY_AWS_* で
// 渡して envVarMappings で写していた。状態が Pulumi Cloud へ移り、
// バックエンドが AWS_* を見なくなったので、その切り分けは要らない（#23）。
export const awsProvider = new aws.Provider("aws", { region: awsRegion });

/** AWS 側のリソースにはこれを渡す。Cloudflare 側には要らない */
export const onAws = { provider: awsProvider };
