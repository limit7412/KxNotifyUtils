#!/usr/bin/env bash
# status-server-deploy.yml を master の ref で workflow_dispatch として起こし、終わるまで待つ。
# 承認待ちに入ったら、またその後ろに並んだら、待たずに終える（下の注記）。
#
#   .github/scripts/dispatch-deploy.sh <スタック名> <識別子> [期待するコミット] [出す内容の ref]
#
# 出す内容の ref を渡すと、status-server-deploy.yml はそれを checkout して、master に含まれることを
# 確かめてから出す。渡さないと master の先端を出す。
# 期待するコミットを渡すなら、出す内容の ref も渡す。渡さないと、起こすまでのあいだに master が
# 進んだとき、起こされた側は新しい先端を checkout して、期待するコミットと食い違い、必ず止まる。
#
# 呼ぶのは status-server-deploy-dev.yml である。
# 環境変数 GH_TOKEN（actions: write と checks: read を持つ GITHUB_TOKEN）と GH_REPO が要る。
# actions: write は起こすのと、五時間たったときや親が取り消されたときに取り消すのに使う。
# CANCELLED_OK=true を渡すと、起こした実行が concurrency の群で後続に置き換えられて
# 取り消されたときは 0 で終える。dev ではそれは「後から起こした実行が代わりに出す」ことを
# 意味し、失敗ではない。同じスタックへ後から起こした実行が見つからない取り消し
# （人が Actions から止めたなど）は、後続が無く dev が更新されていないので失敗にする。
#
# workflow_call で呼ばずに起こすのは、呼ばれたワークフローが呼んだ側のコミットの定義で
# 動くためである。master の ref で起こせば、定義も内容もその時点の master の先端になる。
# GITHUB_TOKEN で起こした workflow_dispatch は実行を作る（GITHUB_TOKEN が起こすイベントの
# うち workflow_dispatch と repository_dispatch だけが例外である）。
#
# 起こした実行の ID は同期的には返らない。gh run list は起動の入力では絞れないので、
# 識別子を dispatch_id で渡し、status-server-deploy.yml がそれを実行の名前に付け、一覧の名前で探す。
# 同じコミットで直前に手で流した実行と取り違えない。
set -euo pipefail

STACK="${1:?スタック名を指定すること}"
DISPATCH_ID="${2:?識別子を指定すること}"
EXPECTED_SHA="${3:-}"
REF="${4:-}"
: "${GH_TOKEN:?GH_TOKEN が要る}"
: "${GH_REPO:?GH_REPO が要る}"

# 探す範囲の下限。時計のずれを見て一分前から
SINCE=$(date -u -d '-1 minute' +%Y-%m-%dT%H:%M:%S+00:00)

# 起こした実行を識別子で探す。見つからなければ空
find_run() {
  gh run list --workflow status-server-deploy.yml --event workflow_dispatch --branch master \
    --created ">=$SINCE" --limit 20 --json databaseId,displayTitle \
    --jq "map(select(.displayTitle | endswith(\"[$DISPATCH_ID]\"))) | .[0].databaseId // empty"
}

# 起こした実行を、こちらが先に終わるときは取り消す。
# 起こした実行は独立していて、こちらが止まっても続き、親を止めた後に prod が変わる。
# 取り消すのは、親のジョブが取り消されたとき（ランナーが INT、次いで TERM を送る）と、
# 状態を読めないなど、こちらが結果を見届けられずに落ちるときである。
# 見届けたとき（終わった、承認待ちで手を離した）は CLEANUP を none にしてから終える。
# 起こしてから実行が見つかるまでのあいだに落ちたときも、識別子で探して取り消す。
# 取り消しの後 KILL までは間があるが長くはないので、探すのは短く切り上げる
RUN_ID=""
CLEANUP=cancel
cancel_child() {
  if [ -z "$RUN_ID" ]; then
    for _ in 1 2 3; do
      RUN_ID=$(find_run || true)
      [ -n "$RUN_ID" ] && break
      sleep 2
    done
  fi
  if [ -n "$RUN_ID" ]; then
    echo "::warning::起こした deploy の実行 $RUN_ID を取り消す" >&2
    gh run cancel "$RUN_ID" || true
  else
    echo "::warning::起こした deploy の実行がまだ見つからない。Actions の deploy で [$DISPATCH_ID] を探し、手で取り消す" >&2
  fi
  CLEANUP=none
}
on_exit() {
  CODE=$?
  trap - EXIT
  if [ "$CLEANUP" = cancel ]; then
    echo "::warning::deploy の結果を見届けられずに $CODE で終わる" >&2
    cancel_child
  fi
  exit "$CODE"
}
on_cancel() {
  trap - INT TERM
  echo "::warning::親のジョブが取り消された" >&2
  cancel_child
  exit 130
}
trap on_exit EXIT
trap on_cancel INT TERM

gh workflow run status-server-deploy.yml --ref master \
  -f "stack=$STACK" -f "ref=$REF" -f "expected_sha=$EXPECTED_SHA" -f "dispatch_id=$DISPATCH_ID"
echo "status-server-deploy.yml を master の ref で起こした（stack=$STACK、ref=${REF:-なし}、expected_sha=${EXPECTED_SHA:-なし}、dispatch_id=$DISPATCH_ID）"

# 一覧を読めなかったときは空と同じに扱い、残りの回数で読み直す。
# 一度の失敗で落とすと、起こした実行が動いているのに、単発の読み取りの失敗で取り消してしまう
for _ in $(seq 1 12); do
  sleep 5
  RUN_ID=$(find_run || true)
  [ -n "$RUN_ID" ] && break
done
if [ -z "$RUN_ID" ]; then
  echo "::error::起こした deploy の実行が一分たっても見つからない（一覧を読めなかった場合も含む）。Actions の deploy で [$DISPATCH_ID] を探す" >&2
  exit 1
fi
echo "deploy の実行: https://github.com/$GH_REPO/actions/runs/$RUN_ID"

# 終わるまで待つ。gh run watch は使わず、状態を読んで待つ。
# environment prod に required reviewers があると、起こした実行は承認まで waiting で止まる。
# watch はそれも待ち続け、承認が六時間を超えると、こちらのジョブが先に実行時間の上限で落ちる。
# 起こした実行は残るので、親は失敗のまま後から承認されて出る、という食い違いになる。
# 承認待ち（wait timer も同じ状態になる）に入ったら追うのをやめ、その先の結果は
# 起こした実行で見る。dev には承認が無いので、ここへは来ない。
#
# 同じスタックの前の実行が承認待ちのあいだは、この実行は concurrency の群の空きを待ち、
# 状態は waiting ではなく queued や pending のままになる。それも同じに扱い、
# 同じスタックの前の実行に waiting のものがあれば追うのをやめる。
# どちらにも当たらずに五時間たったとき（ランナー不足で並んだまま、pulumi up が終わらない）は、
# 上限で落ちる前に起こした実行を取り消して失敗にする。承認待ちと違って、そのまま手を離すと
# 親が緑のまま後から失敗する、または親の後で出る、という食い違いになる。通常は来ない

# 実行の名前は status-server-deploy.yml の run-name のとおり「deploy <スタック名>」か
# 「deploy <スタック名> [<識別子>]」で、その二つの形だけを同じスタックと見る。
# 前方一致にすると dev2 のような名前のスタックも拾う
SAME_STACK="(.displayTitle == \"deploy $STACK\" or (.displayTitle | startswith(\"deploy $STACK [\")))"

hand_off() {
  # 承認待ちは人の手を待つ状態で、こちらが見届けるものではない。取り消さずに終える
  CLEANUP=none
  echo "::notice::deploy の実行 $RUN_ID は $1。ここでは待たず、その先の結果はその実行で見る"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    echo "deploy の実行 $RUN_ID は $1。その先の結果は https://github.com/$GH_REPO/actions/runs/$RUN_ID で見る" >> "$GITHUB_STEP_SUMMARY"
  fi
  exit 0
}

# 状態を読む。一度の失敗で落とすと、API の一時的な不調で prod のデプロイを取り消してしまう。
# 三度まで試し、それでも読めなければ落ちる（上の on_exit が起こした実行を取り消す）
run_status() {
  for K in 1 2 3; do
    if OUT=$(gh run view "$RUN_ID" --json status --jq '.status'); then
      printf '%s\n' "$OUT"
      return 0
    fi
    echo "::warning::deploy の実行 $RUN_ID の状態を読めない（$K 度目）" >&2
    sleep 10
  done
  echo "::error::deploy の実行 $RUN_ID の状態を三度読めない" >&2
  return 1
}

STARTED=$(date +%s)
while :; do
  STATUS=$(run_status)
  case "$STATUS" in
    completed)
      break
      ;;
    waiting)
      hand_off "environment の保護規則（承認か wait timer）で止まっている"
      ;;
    in_progress)
      ;;
    *)
      # queued、pending、requested。群の空きを待っている先が承認待ちなら、いつ空くか分からない
      # 一覧を読めないときは 0 と見て待ち続ける。ここで落とす理由は無い
      BLOCKED=$(gh run list --workflow status-server-deploy.yml --status waiting --limit 20 --json databaseId,displayTitle \
        --jq "map(select(.databaseId < $RUN_ID and $SAME_STACK)) | length" || echo 0)
      if [ "$BLOCKED" -gt 0 ]; then
        hand_off "同じスタックの前の実行が承認待ちで止まっていて、その後ろに並んでいる"
      fi
      ;;
  esac
  if [ $(( $(date +%s) - STARTED )) -ge $(( 5 * 60 * 60 )) ]; then
    # 取り消しは上の on_exit が行う。pulumi up の途中で取り消すと state のロックが
    # 残ることがあり、その場合は pulumi cancel で外す
    echo "::error::deploy の実行 $RUN_ID は五時間たっても終わっていない（状態 $STATUS）。取り消して失敗にする" >&2
    exit 1
  fi
  sleep 20
done
# 終わったので、この先で落ちても取り消すものは無い
CLEANUP=none
CONCLUSION=$(gh run view "$RUN_ID" --json conclusion --jq '.conclusion')
case "$CONCLUSION" in
  success)
    echo "deploy の実行 $RUN_ID は成功した"
    ;;
  cancelled)
    if [ "${CANCELLED_OK:-false}" = true ]; then
      # 同じスタックへ、この実行より後に起こされた実行があるか
      NEWER=$(gh run list --workflow status-server-deploy.yml --event workflow_dispatch --branch master \
        --limit 20 --json databaseId,displayTitle \
        --jq "map(select(.databaseId > $RUN_ID and $SAME_STACK)) | length")
      if [ "$NEWER" -gt 0 ]; then
        echo "::notice::deploy の実行 $RUN_ID は取り消された。同じスタックへ後から起こした実行が代わりに出す"
        exit 0
      fi
    fi
    echo "::error::deploy の実行 $RUN_ID は取り消され、同じスタックへ後から起こした実行も無い" >&2
    exit 1
    ;;
  *)
    echo "::error::deploy の実行 $RUN_ID は $CONCLUSION で終わった" >&2
    exit 1
    ;;
esac
