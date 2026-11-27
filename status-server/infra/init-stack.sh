#!/usr/bin/env bash
# スタックを作り、仕様書 11.7 の値を入れる。
#
# CI から流すには Pulumi.<スタック名>.yaml が要る（#12）。まっさらなランナーには
# このファイルが無く、無いまま pulumi up を叩くと最初の config.require で止まる。
# Pulumi の設定は state ではなくこのファイルに入るためである。
#
# 二度目以降に流すと、いま入っている値を既定として見せる。Enter で通せば
# そのまま残る。空で答えても消えないので、消すときは pulumi config rm を使う。
#
# 使い方:
#   infra/init-stack.sh dev
#
# 値は一つずつ聞く。省略できるものは空のまま Enter で飛ばせる。
# 秘密の値は標準入力から渡すので、コマンドラインにも履歴にも残らない。
#
# 出来上がった Pulumi.<スタック名>.yaml は commit する。--secret で入れた値は
# 暗号文として記録されるため平文では残らない。復号には PULUMI_CONFIG_PASSPHRASE が要る。

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)

stack="${1:-}"
case "$stack" in
    "" | -h | --help)
        awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
        [ -n "$stack" ] && exit 0
        exit 2
        ;;
esac

# 名前の規則は infra/src/settings.ts に合わせる。
# ここで弾かないと、スタックと十四の設定を作ったあと pulumi up が
# 名前の検証で必ず止まる。使えないスタックだけが残る。
MAX_STACK_NAME=16

if ! printf '%s' "$stack" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'; then
    echo "スタック名 \"$stack\" は物理名に使えない。小文字、数字、ハイフンだけで、先頭と末尾は小文字か数字にする" >&2
    exit 2
fi

if [ "${#stack}" -gt "$MAX_STACK_NAME" ]; then
    echo "スタック名 \"$stack\" が長い（${#stack} 文字）。${MAX_STACK_NAME} 文字までにする" >&2
    exit 2
fi

if ! command -v pulumi > /dev/null 2>&1; then
    echo "pulumi が無い。https://www.pulumi.com/docs/install/ から入れる" >&2
    exit 1
fi

# パスフレーズは state と設定ファイルの中の secret を復号する鍵である。
# 失うと読めなくなるので、控えを残してもらう（仕様書 9.1）。
#
# 長さの下限を置くのは、設定ファイルを commit する先が public だからである（#24）。
# 暗号文が公開される以上、総当たりは誰でも好きなだけ試せる。Pulumi の鍵導出は
# PBKDF2-SHA256 を 100 万回まわすので一回の試行は重いが、人が思いついて
# 覚えられる範囲の文字列は、それでも辞書と規則の射程に入る。
#
# 文字種では見ない。規則を足すほど、生成した値が落ちて人が考えた値が通る、
# という逆転が起きる。ここで欲しいのは覚えずに生成させることなので、
# 覚えられない長さを下限にするだけでよい。
#
# 数えるのは文字である。
# バイトで数えると、マルチバイトの値でこの下限が実質的に下がる。
# 同じ絵文字を 8 個並べただけの値も 32 バイトあり、それは覚えられる長さである。
#
# ${#phrase} は使わない。
# 単位がロケールで変わり、C ロケールではバイト数を返す（#35）。
# 同じ値がロケール次第で通ったり弾かれたりするのは、下限として使えない。
#
# 代わりに UTF-8 の継続バイト（10xxxxxx）を落としてから数える。
# 残るのは各文字の先頭バイトだけなので、その数が文字数になる。
# tr へ渡すときに C ロケールを敷くので、外側のロケールには依らない。
MIN_PASSPHRASE=32

# パスフレーズを入れたファイルの上限。
#
# trim_go_space は端の空白を一文字ずつ落とすので、空白だけのファイルでは時間が長さの二乗で伸びる。
# 弾かずに通すと、短すぎるという答えを出すまでに CPU を使い切ることになる。
#
# この上限での最悪は 0.22 秒だった（空白 512 バイトのファイル、bash 5.2、C.UTF-8）。
# README が勧める openssl rand -base64 32 は 44 バイトなので、実用の十倍を超える余裕がある。
MAX_PASSPHRASE_BYTES=512

# Go の strings.TrimSpace と同じ範囲で前後の空白を落とす。
#
# [[:space:]] には頼らない。
# 当たる文字がロケールで変わるためである。
# glibc の C ロケールでは ASCII の六文字だけだが、C.UTF-8 では U+1680 や U+3000 も空白に分類される（この環境で両方を測った）。
# 一方 Pulumi が落とすのは unicode.IsSpace の範囲で、こちらはロケールで変わらない。
#
# 落とし残すと長さの下限をすり抜けられる。
# 一文字の後ろに NBSP を 31 個並べたファイルは、落とし残せば下限を越えて通り、Pulumi は一文字のパスフレーズで暗号化する。
# 端に一個置いた場合の一文字ずれでは済まない。
#
# 符号位置は 8 進で書く。
# $'\uXXXX' は Bash 4.2 以降で、このリポジトリは macOS 標準の 3.2 で動くことを前提にしている。
# 8 進エスケープなら 3.2 でも通り、UTF-8 のバイト列をそのまま書ける。
#
# 端の空白は一文字ずつ落とす。
# まとめて落とす書き方（extglob の +(...)）も試したが、bash の最長一致が総当たりになり、空白 1000 文字で 30 秒を超えた。
# 一文字ずつでも時間は長さの二乗で伸びるため、入力の大きさを MAX_PASSPHRASE_BYTES で抑えてある。
#
# 突き合わせは Go の strings.TrimSpace そのものと行った。
# 空白候補と通常の文字を混ぜた 3000 本を C と C.UTF-8 の両方で流し、結果は全て一致した（#24）。
GO_SPACES=(
    $'\011' $'\012' $'\013' $'\014' $'\015' $'\040'
    $'\302\205' $'\302\240' $'\341\232\200'
    $'\342\200\200' $'\342\200\201' $'\342\200\202' $'\342\200\203'
    $'\342\200\204' $'\342\200\205' $'\342\200\206' $'\342\200\207'
    $'\342\200\210' $'\342\200\211' $'\342\200\212'
    $'\342\200\250' $'\342\200\251' $'\342\200\257'
    $'\342\201\237' $'\343\200\200'
)

trim_go_space() {
    local s="$1" before sp

    # 一巡では端の一個ずつしか落ちない。
    # 変わらなくなるまで回す。
    while :; do
        before="$s"
        for sp in "${GO_SPACES[@]}"; do
            s="${s#"$sp"}"
            s="${s%"$sp"}"
        done
        [ "$s" = "$before" ] && break
    done

    printf '%s' "$s"
}

# 鍵の材料になる文字列を、Pulumi と同じ形で取り出す。
#
# 環境変数はそのまま使われる（pkg/secrets/passphrase/manager.go の readPassphrase）。
# ファイルのほうは strings.TrimSpace を通してから使われる。$(cat) が落とすのは
# 末尾の改行だけなので、CRLF のファイルだと CR が残り、ここでの長さが Pulumi の
# 見る長さより一文字多くなる。下限をすり抜けられるので、前後の空白を自分で落とす。
phrase=""
if [ -n "${PULUMI_CONFIG_PASSPHRASE+set}" ]; then
    # 空で export されていても Pulumi はこちらを採る。os.LookupEnv は値ではなく
    # 設定の有無を見るためで、そのとき鍵は空文字から導かれる。値の有無で分けると、
    # ここではファイルを見て通し、Pulumi は空文字で暗号化する、という食い違いになる。
    # 空なら下の長さの検査が 0 文字として弾く。
    phrase="$PULUMI_CONFIG_PASSPHRASE"
elif [ -n "${PULUMI_CONFIG_PASSPHRASE_FILE:-}" ]; then
    # 相対パスは絶対パスへ直して環境変数へ書き戻す。
    #
    # pulumi -C は「そのディレクトリで起動したかのように」振る舞うので、相対の
    # ままだと Pulumi は infra/ から解決する。ここで読むファイルと
    # 食い違い、無ければスタックの作成が落ち、別の短いファイルがあれば検査した値と
    # 違う鍵で暗号化される。Pulumi CLI 3.259.0 で、-C の先から解決することを確かめた。
    case "$PULUMI_CONFIG_PASSPHRASE_FILE" in
        /*) ;;
        *) PULUMI_CONFIG_PASSPHRASE_FILE="$PWD/$PULUMI_CONFIG_PASSPHRASE_FILE" ;;
    esac
    export PULUMI_CONFIG_PASSPHRASE_FILE

    if [ ! -r "$PULUMI_CONFIG_PASSPHRASE_FILE" ]; then
        echo "PULUMI_CONFIG_PASSPHRASE_FILE が読めない: $PULUMI_CONFIG_PASSPHRASE_FILE" >&2
        exit 1
    fi

    # 中身を読む前に大きさで弾く。
    # バイトで数えるのは、文字で数えると単位がロケールで変わるためである。
    if [ "$(( $(wc -c < "$PULUMI_CONFIG_PASSPHRASE_FILE") ))" -gt "$MAX_PASSPHRASE_BYTES" ]; then
        echo "PULUMI_CONFIG_PASSPHRASE_FILE が大きい（${MAX_PASSPHRASE_BYTES} バイトまで）: $PULUMI_CONFIG_PASSPHRASE_FILE" >&2
        echo "  パスフレーズだけが入ったファイルか確かめる" >&2
        exit 1
    fi
    # 前後の空白を落としてから測る。
    # Pulumi はファイルから読んだ値を strings.TrimSpace してから鍵の材料にする。
    # 落とさずに測ると、末尾の改行やその他の空白の分だけ長く見える。
    phrase=$(trim_go_space "$(cat "$PULUMI_CONFIG_PASSPHRASE_FILE")")
else
    echo "PULUMI_CONFIG_PASSPHRASE が要る。これを失うと secret を読めなくなるので、控えを残すこと" >&2
    exit 1
fi

# 文字数を数える。
# 継続バイトを落とした残りが文字数である（上の MIN_PASSPHRASE を参照）。
phrase_chars=$(( $(printf '%s' "$phrase" | LC_ALL=C tr -d '\200-\277' | wc -c) ))

if [ "$phrase_chars" -lt "$MIN_PASSPHRASE" ]; then
    echo "PULUMI_CONFIG_PASSPHRASE が短い（${phrase_chars} 文字）。${MIN_PASSPHRASE} 文字以上にする" >&2
    echo "  設定ファイルは commit され、このリポジトリは public である（#24）" >&2
    echo "  覚えずに済ませる。次のように作って、パスワードマネージャへ入れる" >&2
    echo "    openssl rand -base64 32" >&2
    echo >&2
    echo "  既にこのパスフレーズでスタックを作ってあるなら、先に入れ替える。" >&2
    echo "  古いほうを PULUMI_CONFIG_PASSPHRASE に入れたまま次を実行すると、" >&2
    echo "  新しいパスフレーズを聞かれ、設定と state が入れ替わったもので暗号化し直される。" >&2
    echo "    pulumi -C \"$here\" stack change-secrets-provider passphrase --stack $stack" >&2
    echo "  そのあと新しいほうを PULUMI_CONFIG_PASSPHRASE に入れて、ここへ戻る。" >&2
    echo >&2
    echo "  古い設定ファイルを commit してあるなら、入れ替えだけでは足りない。" >&2
    echo "  古い暗号文は履歴に残り、弱いパスフレーズごと総当たりの的になる。" >&2
    echo "  そこに入っていた secret は作り直す（alertWebhookUrl、設定へ入れていたなら" >&2
    echo "  Cloudflare のトークンも）。" >&2
    exit 1
fi

# 入力が尽きたら止める。省略ではなく中断だからである。
# 省略できない値を聞いている途中で Ctrl-D を押されたときに、
# 同じ警告を出し続ける無限ループにならないようにする。
# この実行で新しく作ったスタック。中断したときの案内に使う。
# 元からあったスタックを「作りかけ」として案内すると、
# 案内どおりに消したときに以前からある設定ごと消えてしまう。
created_main=no


abort_on_eof() {
    printf '\n' >&2
    echo "入力が尽きたので中断する。" >&2

    if [ "$created_main" = no ]; then
        echo "この実行で作ったスタックは無いので、消すものも無い" >&2
        exit 1
    fi

    echo "この実行で作ったスタックを消すなら、次を実行する" >&2
    echo "  pulumi -C \"$here\" stack rm $stack" >&2
    exit 1
}

# 一問だけ聞く。答えは ANSWER に入れる。既定があれば、空の答えはそれで埋める。
# EOF なら 1 を返す。呼び出し側は abort_on_eof で止める。
#
# 秘密の値は端末へ出さない。履歴に残らなくても、打っている最中の画面と
# セッションの録画には残るためである。
ask() {
    local label="$1" default="${2:-}" hidden="${3:-}"

    ANSWER=""

    if [ -n "$default" ]; then
        printf '%s [%s]: ' "$label" "$default" >&2
    else
        printf '%s: ' "$label" >&2
    fi

    if [ -n "$hidden" ]; then
        # -s は改行を出さないので、こちらで出す
        read -rs ANSWER || return 1
        printf '\n' >&2
    else
        read -r ANSWER || return 1
    fi

    [ -n "$ANSWER" ] || ANSWER="$default"
    return 0
}

# いま設定に入っている値。無ければ空を返す。
#
# 二度目以降の実行で、入っている値を既定として見せるために使う。
# 見せずに聞くと、Enter で通したときに何が残ったのか分からない。
# 空で答えても消えはしない。消したいときは pulumi config rm を使う。
current_config() {
    local dir="$1" key="$2"

    pulumi -C "$dir" config get --stack "$stack" "$key" 2> /dev/null || true
}

# 省略できない値。空で返ってきたら聞き直す。
set_required() {
    local dir="$1" key="$2" label="$3" default="${4:-}" existing=""

    existing=$(current_config "$dir" "$key")
    [ -z "$existing" ] || default="$existing"

    while :; do
        ask "$label" "$default" || abort_on_eof
        [ -n "$ANSWER" ] && break
        echo "  ここは省略できない" >&2
    done

    pulumi -C "$dir" config set --stack "$stack" "$key" "$ANSWER"
}

# 省略できる値。空なら設定へ書かない。
set_optional() {
    local dir="$1" key="$2" label="$3" default="${4:-}" existing=""

    existing=$(current_config "$dir" "$key")
    [ -z "$existing" ] || default="$existing"

    ask "$label" "$default" || abort_on_eof
    if [ -z "$ANSWER" ]; then
        return 0
    fi

    pulumi -C "$dir" config set --stack "$stack" "$key" "$ANSWER"
}

# aws を呼ぶ。出力は標準出力へ、雑音は捨てる。
#
# 資格情報は AWS_* をそのまま使う。状態が R2 にあったころは、そこに R2 の鍵が
# 入っていたので DEPLOY_AWS_* を移していた。状態が Pulumi Cloud へ移って
# バックエンドが AWS_* を見なくなったので、その切り分けは要らない（#23）。
#
# aws が無ければ 1 を返す。呼び出し側はどちらも「既定が無い」として扱う。
aws_deploy() {
    command -v aws > /dev/null 2>&1 || return 1

    aws "$@" 2> /dev/null
}

# 設定にその値が入っているか。中身は取り出さない。
#
# 秘密の値について「入っているか」だけを知りたいときに使う。
# current_config は復号した平文を返すので、こちらでは呼ばない。
has_config() {
    local dir="$1" key="$2"

    pulumi -C "$dir" config get --stack "$stack" "$key" > /dev/null 2>&1
}

# 秘密の値。打っている最中も画面に出さず、標準入力から渡して暗号文として記録する。
#
# 二度目以降は Enter で今の値のままにできる。既定として見せることはしない。
# 見せれば画面に出てしまい、隠して聞いた意味が無くなる。
set_secret() {
    local dir="$1" key="$2" label="$3" keep=""

    if has_config "$dir" "$key"; then
        keep="$label（Enter で今の値のまま）"
    fi

    while :; do
        ask "${keep:-$label}" "" hidden || abort_on_eof
        [ -n "$ANSWER" ] && break
        [ -z "$keep" ] || return 0
        echo "  ここは省略できない" >&2
    done

    printf '%s' "$ANSWER" | pulumi -C "$dir" config set --stack "$stack" --secret "$key"
}

# 以前の init-stack.sh が入れていた値を落とす。
#
# 質問から外しただけでは Pulumi.<スタック名>.yaml に残る。secret 指定の値なら
# 暗号文で残り、その設定ファイルは commit する。パスフレーズを持つ相手は
# 復号できるので、消したつもりの資格情報が commit 済みの履歴に残り続ける。
drop_config() {
    local dir="$1" key="$2" why="$3"

    has_config "$dir" "$key" || return 0

    pulumi -C "$dir" config rm --stack "$stack" "$key" > /dev/null
    echo "  $key を消した。$why"
}

# 名前を変えた設定を引き継ぐ。
#
# 新しい側がまだ空のときだけ写す。既に入っていれば、そちらが新しいので触らない。
# 写し終えたら古い側を落とす。残しておくと、読む者のいないキーが
# commit 済みの設定ファイルに溜まる。
#
# secret 指定の値には使わない。current_config は復号した平文を返すので、
# そのまま config set へ渡すと暗号文だったものが平文で書き直される。
rename_config() {
    local dir="$1" old="$2" new="$3"

    has_config "$dir" "$old" || return 0

    if ! has_config "$dir" "$new"; then
        pulumi -C "$dir" config set --stack "$stack" "$new" "$(current_config "$dir" "$old")"
        echo "  $old を $new へ引き継いだ"
    fi

    pulumi -C "$dir" config rm --stack "$stack" "$old" > /dev/null
}

# スタックを選ぶ。無ければ作る。
# 新しく作ったときだけ 0 を返す。元からあった場合は 1 を返し、
# 中断時の削除案内から外す。
create_stack() {
    local dir="$1"

    if pulumi -C "$dir" stack select "$stack" > /dev/null 2>&1; then
        return 1
    fi

    # 終了状態を自分で見る。この関数は `create_stack ... && created=yes` の形で
    # 呼ばれるため、中では errexit が効かない。任せると、置き場所へ繋がらない
    # ときや認証に失敗したときでも return 0 まで進み、作ったことにして
    # 設定を書き始めてしまう。
    if ! pulumi -C "$dir" stack select --create "$stack" --secrets-provider passphrase > /dev/null; then
        echo "スタック $stack を作れなかった（$dir）" >&2
        exit 1
    fi

    return 0
}

echo
echo "=== $stack を作る ==="
create_stack "$here" && created_main=yes

# 使わなくなった設定を落とす。
#
# 質問から外すだけでは、以前の init-stack.sh で作ったスタックに残り続ける。
# githubDispatchToken はリポジトリへの書き込み権限を持つトークンで、
# 暗号文とはいえ commit 済みの設定ファイルに入ったままになる。
drop_config "$here" githubDispatchToken "GitHub 側でこのトークンを失効させること。commit 済みの履歴からは消えない"
drop_config "$here" ytdlpLayerArn "Layer は pulumi up が作るので、ARN を設定に持たない"
drop_config "$here" cloudflare:apiToken "CLOUDFLARE_API_TOKEN で渡す。commit 済みの履歴に暗号文が残っているなら、トークンを作り直すこと"
drop_config "$here" ytdlpLayerVersion "yt-dlp の検査は取り下げた（仕様書 7）"
drop_config "$here" ytdlpVersion "yt-dlp の検査は取り下げた（仕様書 7）"

# 権限境界を ARN ではなく名前で持つように変えた（#26）。
#
# rename_config では写せない。旧い側は ARN で、新しい側は名前だからである。
# arn:<パーティション>:iam::<アカウントID>:policy/ から後ろを取る。パスを挟んだ
# ポリシーでも残りをそのまま名前として扱う。ARN でない値なら何も削らない。
if has_config "$here" workloadBoundaryArn; then
    boundary_was=$(current_config "$here" workloadBoundaryArn)
    boundary_now="${boundary_was#arn:*:iam::*:policy/}"

    if [ -n "$boundary_now" ] && [ -z "$(current_config "$here" workloadBoundaryName)" ]; then
        pulumi -C "$here" config set --stack "$stack" workloadBoundaryName "$boundary_now"
        echo "  workloadBoundaryArn を workloadBoundaryName へ移した（$boundary_now）"
    fi

    pulumi -C "$here" config rm --stack "$stack" workloadBoundaryArn > /dev/null
fi

# 二度目の実行で Enter を押したときに、既定のリージョンで上書きしない。
# 別のリージョンで作ってあると、AWS のリソースが置き換わる。
region_default=$(current_config "$here" aws:region)
[ -n "$region_default" ] || region_default="ap-northeast-1"

# 全スタックで同じにする。デプロイロールと権限境界をスタック間で共有しており、
# その ARN にはリージョンが一つしか書けない（docs/aws-oidc.md）。
ask "AWS のリージョン（仕様書 5.1。全スタックで同じにする）" "$region_default" || abort_on_eof
pulumi -C "$here" config set --stack "$stack" aws:region "$ANSWER"

echo
echo "--- Cloudflare（仕様書 6） ---"
# API トークンはここでは聞かない。CLOUDFLARE_API_TOKEN で渡す（#24）。
#
# 設定へ入れると commit されるファイルに暗号文が載る。プロバイダは環境変数からも
# 読むので、入れる意味が無い。CI は元からこの環境変数で渡している。
set_required "$here" cloudflareAccountId "アカウント ID"
set_required "$here" deliveryZoneId "配信ドメインのゾーン ID"
set_required "$here" deliveryHost "配信ホスト名（例 status.example.com）"
set_optional "$here" bucketLocation "バケットの場所" "apac"
set_optional "$here" publicBucket "配信バケット名（既定 qazx7412-vrc-service-status-panel-$stack-public）"
set_optional "$here" stateBucket "内部バケット名（既定 qazx7412-vrc-service-status-panel-$stack-state）"

echo
echo "--- 合成監視の対象（仕様書 3.3） ---"
set_required "$here" youtubeProbeVideoId "YouTube の固定動画 ID"
set_required "$here" boothProbeItemId "BOOTH の商品 ID"

echo
echo "--- 集約サーバー（仕様書 9.3、11.7） ---"
set_secret "$here" alertWebhookUrl "失敗時のアラート送信先 URL"

# CI から流すかどうかは、権限境界を入れるかどうかで決まる。
# 入れれば実行時ロールに境界が付き、デプロイロールがそのロールを作れる。
# 入れなければ手元からしか流せない。
#
# 境界は Pulumi ではなく AWS CLI で作ってある（docs/aws-oidc.md）。
# 設定に入れるのは名前だけで、ARN は roles.ts が組み立てる。ARN にはアカウント
# ID が入り、この設定ファイルは commit され、リポジトリは public だからである（#26）。
#
# 実在を確かめてからでないと既定にしない。ask は空の答えを既定で埋めるので、
# 無いものを既定に出すと、Enter で通しただけで存在しない境界を指すことになる。
# fork 先のように境界をまだ作っていないアカウントでは、そのまま流すと
# 最初の CreateRole が落ちる。無ければ既定を空にして、Enter で飛ばせるようにする。
#
# 確かめるほうには ARN が要るので、その場のアカウントから組んで問い合わせる。
# 組んだ ARN は設定へは入れない。
#
# パーティションも呼び出し元から取る。書き下すと aws-cn や GovCloud で実在する
# 境界を見つけられず、既定が空のまま Enter で通されて、CI の CreateRole が
# そこで落ちる。roles.ts が組み立てる ARN と食い違うことにもなる。
#
# 呼び出し元の ARN は arn:<パーティション>:iam::<アカウントID>:user/... の形をしており、
# アカウントも同じ一回で取れる。
#
# aws が無いときも、資格情報が通らないときも、同じく既定が空になるだけである。
# その場合は名前を手で入れる。
boundary_default=""
boundary_name=qazx7412-vrc-service-status-panel-workload-boundary
caller_arn=$(aws_deploy sts get-caller-identity --query Arn --output text || true)
if [ -n "$caller_arn" ] && [ "$caller_arn" != "None" ]; then
    IFS=: read -r _ partition _ _ account _ <<< "$caller_arn" || true

    if [ -n "${partition:-}" ] && [ -n "${account:-}" ] && aws_deploy iam get-policy \
        --policy-arn "arn:$partition:iam::$account:policy/$boundary_name" > /dev/null; then
        boundary_default="$boundary_name"
    fi
fi

echo
echo "--- GitHub Actions からの入口（仕様書 9.1） ---"
set_optional "$here" workloadBoundaryName \
    "実行時ロールの権限境界の名前（CI から流さないなら空のまま）" "$boundary_default"

# 案内は絶対パスで出す。README の手順は infra/ から実行するので、
# 相対パスを出すと、そこからは infra/infra を指してしまう。
echo
echo "=== ここまでで出来たもの ==="
echo "  $here/Pulumi.$stack.yaml"
echo
echo "次にやること"

# Cloudflare のトークンは設定に入らないので、流す前に環境変数へ入れてもらう（#24）。
deploy_line="       printf 'CLOUDFLARE_API_TOKEN: '; read -rs cloudflare_token && echo
       CLOUDFLARE_API_TOKEN=\"\$cloudflare_token\" \"$here/deploy.sh\""
deploy_label="本体を流す"

echo "  1. 出来た Pulumi.$stack.yaml を commit する（#12）"
echo "  2. $deploy_label"
echo "$deploy_line"

# 境界を入れていないスタックは手元専用である。CI 向けの案内は出さない。
#
# ここは has_config では見分けられない。workloadBoundaryName は Pulumi.yaml に
# default: "" 付きで宣言してあるので、設定へ入れていなくても config get は
# その既定を返して成功する。入っているかどうかは値の中身で見る。
if [ -n "$(current_config "$here" workloadBoundaryName)" ]; then
    echo "  3. 次の三つが GitHub の Secrets にあるか確かめる"
    echo "       AWS_DEPLOY_ROLE_ARN             デプロイロールの ARN（docs/aws-oidc.md）"
    echo "       PULUMI_CONFIG_PASSPHRASE        いま使ったもの"
    echo "       CLOUDFLARE_API_TOKEN            Cloudflare の API トークン"
    echo "     状態の置き場所への鍵は要らない。Pulumi Cloud へは OIDC で入る（#23）"
    echo "     どれが何に使われるかは README の「ワークフローでの受け取り」にある"
fi
