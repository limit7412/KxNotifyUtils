#!/usr/bin/env bash
# 手元からのデプロイをひと通り流す。
#
# 手で並べると、バイナリのビルドと pulumi up の二つになる。
#
# commit はしない。出来上がった Pulumi.<スタック名>.yaml をどう残すかは
# 人が決めることなので、最後に案内するだけにしてある。
#
# 使い方:
#   infra/deploy.sh                        今の設定のまま流す
#   infra/deploy.sh --yes                  以降の引数は pulumi up へ渡る
#
# 相手のスタックは pulumi stack select で先に決める。--stack は受け付けない。
#
# AWS の鍵は AWS_* で渡す。状態は Pulumi Cloud にあり、バックエンドは
# この変数を見ないので、切り分けは要らない（#23）。

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)

pulumi_args=()

while [ $# -gt 0 ]; do
    case "$1" in
        -h | --help)
            awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
            exit 0
            ;;
        # --stack を通すと、pulumi up だけがそちらを見て、設定の読み書きは
        # 選ばれているスタックを見る。相手は一つに決める。
        --stack | --stack=* | -s | -s?*)
            echo "--stack は受け付けない。pulumi stack select <名前> で先に決める" >&2
            exit 2
            ;;
        *)
            pulumi_args+=("$1")
            shift
            ;;
    esac
done

need() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "$1 が要る" >&2
        exit 1
    fi
}

need pulumi
need npm
need docker
need zip

# Cloudflare のトークンは設定に入れず、環境変数で渡す（#24）。
# ここで見ないと、bootstrap.zip を作ったあとの
# pulumi up まで進んでから、プロバイダの初期化で落ちる。
if [ -z "${CLOUDFLARE_API_TOKEN:-}" ]; then
    echo "CLOUDFLARE_API_TOKEN が要る。履歴にも呼び出し元のシェルにも残さないよう、" >&2
    echo "export せずに、この呼び出しにだけ渡す" >&2
    echo "  printf 'CLOUDFLARE_API_TOKEN: '; read -rs cloudflare_token && echo" >&2
    echo "  CLOUDFLARE_API_TOKEN=\"\$cloudflare_token\" \"$here/deploy.sh\"" >&2
    exit 1
fi

# 受け取ったらすぐ環境から外し、pulumi へ渡すときだけ戻す。
#
# 渡ってきたまま進むと、npm ci が動かす依存パッケージのインストールスクリプトや、
# build.sh が起こす docker まで、このトークンを見られる。
# README が「実質的に管理者相当」と書いている資格情報なので、Pulumi と無関係な
# コードへ渡す理由が無い。
#
# 呼び出し元が export していた場合、こちらで外せるのはこのプロセスから先だけである。
# 呼び出し元のシェルには残るので、案内のほうは export しない形にしてある。
cloudflare_token="$CLOUDFLARE_API_TOKEN"
unset CLOUDFLARE_API_TOKEN

cd "$here"

stack=$(pulumi stack --show-name 2>/dev/null || true)
if [ -z "$stack" ]; then
    echo "スタックが選ばれていない。pulumi stack select <名前> を先に実行する" >&2
    exit 1
fi
echo "==> スタック: $stack"

# 設定の読み出し。未設定なら pulumi config get は非ゼロで終わる。
config_get() {
    pulumi config get "$1" 2>/dev/null || true
}

if [ ! -d node_modules ]; then
    echo "==> 依存を入れる"
    npm ci
fi

echo "==> bootstrap.zip を作る"
"$repo/backend/build.sh"

echo "==> pulumi up"
CLOUDFLARE_API_TOKEN="$cloudflare_token" pulumi up "${pulumi_args[@]+"${pulumi_args[@]}"}"

cat <<EOF

できあがり。設定が変わっていれば commit する。

    git -C "$repo" add infra/Pulumi.$stack.yaml
EOF
