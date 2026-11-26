#!/usr/bin/env bash
# 集約サーバーのバイナリを作り、Lambda へ渡す zip に詰める（仕様書 5.1）。
#
# 出力は backend/bootstrap.zip で、中身は実行権限の付いた bootstrap ひとつ。
# provided ランタイムが実行するのは zip 直下の bootstrap である。
#
# zip を自分で作るのは、Pulumi の AssetArchive が実行権限を保たないためである。
# 出来上がった zip をそのまま渡せば、モードは zip の中の記録が使われる。
#
# 使い方:
#   backend/build.sh

set -euo pipefail

# Crystal の版は status-server-backend-ci.yml と揃えて固定する。
# latest のままだと、CI が検証したのと違うコンパイラで本番の成果物が作られる。
CRYSTAL_VERSION="${CRYSTAL_VERSION:-1.21.0}"

here=$(cd "$(dirname "$0")" && pwd)
cd "$here"

for command in docker zip; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "$command が要る" >&2
        exit 1
    fi
done

# Lambda は provided.al2023 の arm64 で動かす（仕様書 5.1）。
#
# ベースイメージは musl の Alpine を使う。glibc を静的リンクしたバイナリは
# provided.al2023 上で外部 HTTPS が失敗する。これは参考リポジトリ
# （limit7412/github_notifications_slack）で実証済みの構成である。
#
# 完全静的リンクには OpenSSL/zlib/libevent の静的ライブラリ(.a)が要る。
# 現行イメージには同梱されているが、将来外れてもリンクエラーにならないよう
# apk add で明示的に入れておく。
#
# libxml2 と xz はそこに足したものである。awscr-s3 が S3 の応答を読むのに
# Crystal の XML を使い、それが libxml2 を引く。alpine の libxml2 は
# lzma 付きで作られているので、静的リンクには liblzma.a も要る。
#
# その liblzma を --whole-archive で丸ごと取り込ませている。
# --link-flags に置いたものは cc の引数で -lxml2 より前へ並ぶが、alpine の
# GNU ld は一度読み終えたアーカイブへ戻らない。-llzma をそのまま渡しても、
# あとから来る libxml2.a の xzlib.o が lzma_code を見つけられずに終わる。
# 丸ごと取り込ませれば、順番によらず解決する。
#
# chmod と chown はコンテナ内(root)で実行する。
# Linux ではコンテナが root として bind mount 上へ書くため、生成物が root 所有に
# なる。所有者でなければ chmod も touch -t も通らず、この先で止まってしまう。
# 実行したユーザーへ所有を戻しておく。
echo "bootstrap を静的ビルドする（crystal $CRYSTAL_VERSION / linux/arm64）"
docker run --rm --platform linux/arm64 \
    -v "$here":/work -w /work \
    "crystallang/crystal:$CRYSTAL_VERSION-alpine" \
    sh -c "apk add --no-cache openssl-libs-static zlib-static libevent-static \
        libxml2-static xz-static \
        && shards install --production \
        && crystal build --release \
            --link-flags '-static -Wl,--whole-archive -llzma -Wl,--no-whole-archive' \
            -o bootstrap src/main.cr \
        && chmod +x bootstrap \
        && chown $(id -u):$(id -g) bootstrap"

# 中身が同じなら同じ zip になるよう時刻を固定する。
# デプロイのたびに中身の変わらない版を作らないため。
touch -t 200001010000 bootstrap

rm -f bootstrap.zip
zip -q -X bootstrap.zip bootstrap

echo "できあがり: $here/bootstrap.zip"
if command -v unzip >/dev/null 2>&1; then
    unzip -l bootstrap.zip
fi
