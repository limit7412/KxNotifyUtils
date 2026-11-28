#!/usr/bin/env bash
# 失敗の通知の送信先（alertWebhookUrl）が、今も受け取れる状態かを確かめる。
#
# 送信先が消えても、関数は失敗するまで何も送らないので、気付く機会が無い。
# 気付くのは refresh が落ちて通知が断られたときで、その通知は人へ届いていない（#83）。
# 失敗を待たずに、こちらから送信先へ問い合わせる。
#
# Discord の webhook は、同じ URL への GET にその webhook の情報を返す。
# メッセージは送られない。消えていれば 404、トークンが違えば 401 である。
# https://discord.com/developers/docs/resources/webhook#get-webhook-with-token
#
# 使い方:
#   infra/check-alert-webhook.sh <スタック名>
#
# 終了コード:
#   0  受け取れる。または、どちらとも決められなかった（警告を出す）
#   1  送信先が無い（401、403、404）
#   2  使い方の誤り、または設定から URL を読めなかった
#
# URL は表示しない。URL を知っていれば誰でもそこへ投稿できるためである。
# 応答の本文にもトークンが入っているので、読まずに捨てる。
#
# 設定の復号に PULUMI_CONFIG_PASSPHRASE が要る。

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)

# 応答を待つ上限。関数が送信を諦める 5 秒（backend/src/error/usecase.cr）より
# 長く取る。ここは一度きりの問い合わせで、待っても失うものが無い。
timeout_seconds=10

case "${1:-}" in
    -h | --help)
        awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
        exit 0
        ;;
    "")
        echo "スタック名を渡す。例: infra/check-alert-webhook.sh dev" >&2
        exit 2
        ;;
esac

stack=$1

# GitHub Actions の中では注記の形で出す。実行の一覧で目に付く。
report() {
    local level=$1 message=$2

    if [ "${GITHUB_ACTIONS:-}" = true ]; then
        echo "::$level::$message"
    else
        echo "$message" >&2
    fi
}

if ! url=$(pulumi -C "$here" config get alertWebhookUrl --stack "$stack"); then
    report error "スタック $stack の alertWebhookUrl を読めなかった"
    exit 2
fi

# 以降の出力に URL が混ざっても、ログでは伏せられる。
if [ "${GITHUB_ACTIONS:-}" = true ]; then
    echo "::add-mask::$url"
fi

# curl 自身のエラー表示は捨てる。文面に URL が入ることがある。
# つながらなかったときは 000 が返り、終了コードも 0 でなくなる。
code=$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --max-time "$timeout_seconds" -- "$url" 2> /dev/null) || true

case "$code" in
    2??)
        echo "スタック $stack の失敗通知の送信先は受け取れる（HTTP $code）"
        ;;
    401 | 403 | 404)
        report error "スタック $stack の失敗通知の送信先が無い（HTTP $code）。refresh が落ちても通知は届かない。送信先を作り直し、alertWebhookUrl を入れ直す（status-server/infra/README.md の「送信先が消えたとき」）"
        exit 1
        ;;
    *)
        # 送信先の一時的な不調や、GET を受け付けない送信先（Discord 以外）では決められない。
        # ここで落とすと、通知と関係の無い理由でデプロイが失敗に見える。
        report warning "スタック $stack の失敗通知の送信先を確かめられなかった（HTTP ${code:-000}）"
        ;;
esac
