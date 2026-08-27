# KxNotifyUtils を 1 ファイルの exe としてビルドする。
#
# 手元でも CI でもこのスクリプトを使う（issue #20）。
# 複合アクション（.github/actions/build-windows）が持つのは、MSVC と Crystal を用意すること、
# このスクリプトを呼ぶこと、出来た exe を検査することだけである。
# 手順を 2 か所に書くと、片方だけ直したときに配布物と手元ビルドが食い違う。
#
# 前提:
#   - Visual Studio 2022 以降の C++ ビルドツール（cmake と rc.exe に PATH が通っていること）
#   - Crystal の Windows 版（MSVC ツールチェーン）
#
# 使い方:
#   pwsh scripts/build.ps1                リリースビルド
#   pwsh scripts/build.ps1 -DebugBuild    デバッグビルド
#   pwsh scripts/build.ps1 -Version 1.2.3 バージョンを埋めてビルドする
#
# PowerShell の共通パラメータに -Debug があるため、独自のスイッチは -DebugBuild とする。
[CmdletBinding()]
param(
  [switch]$DebugBuild,
  [string]$Output = "KxNotifyUtils.exe",
  # 実行ファイルへ埋めるバージョン。
  # 空にすると src/main.cr と res/kxnotifyutils.rc の既定値のままビルドする。
  [string]$Version = "",
  # shards install をやり直す回数。
  [int]$ShardsAttempts = 3
)

$ErrorActionPreference = "Stop"

# ネイティブコマンドの非ゼロ終了は $ErrorActionPreference では止まらない設定がある。
# 呼ぶたびに終了コードを自分で確かめる。
function Assert-LastExitCode([string]$What) {
  if ($LASTEXITCODE -ne 0) {
    throw "$What が終了コード $LASTEXITCODE で失敗した"
  }
}
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$configuration = if ($DebugBuild) { "Debug" } else { "Release" }

Write-Host "==> 依存 shard を取得する"
# uing の postinstall は libui-ng の静的ライブラリを GitHub から取得する。
# この取得は落ちることがあり、shards は理由を出さずに終わる。
# 取り直せば通るため、間隔を空けて試し直す。
#
# lib を消すのは 2 回目以降に限る。
# 途中で失敗した postinstall が壊れた lib を残すため、やり直す前には消す必要があるが、
# 1 回目の前にも消すと、手元ではビルドのたびに shard を取り直すことになる。
for ($attempt = 1; $attempt -le $ShardsAttempts; $attempt++) {
  if ($attempt -gt 1 -and (Test-Path lib)) { Remove-Item -Recurse -Force lib }
  shards install
  if ($LASTEXITCODE -eq 0) { break }
  if ($attempt -eq $ShardsAttempts) {
    throw "shards install が $ShardsAttempts 回とも失敗した"
  }
  Write-Host "shards install に失敗した ($attempt 回目, 終了コード $LASTEXITCODE)"
  Start-Sleep -Seconds ($attempt * 10)
}

Write-Host "==> NotifListenerShim をビルドする ($configuration)"
cmake -S shim -B shim/build -A x64
Assert-LastExitCode "cmake の構成"
cmake --build shim/build --config $configuration
Assert-LastExitCode "シムのビルド"

# バージョンを埋めてからリソースをコンパイルする。
#
# 本体側のバージョンは KXNOTIFYUTILS_VERSION から読むが、exe のプロパティに出る
# バージョン情報はリソースが持つため、こちらは書き換えて渡す。
#
# 書き換えるのは追跡対象のファイルであり、済んだら必ず元へ戻す。
# 戻さないと、次に -Version 無しでビルドしたときに Crystal 側は 0.1.0-dev なのに
# exe のバージョン情報だけ前回の値が残り、引数の約束に反する。
# 別の場所に一時ファイルを作る手は使えない。この .rc はアイコンを相対パスで参照している。
#
# タグが版の source of truth であり、リポジトリ側の値は手元ビルドの既定値である。
$resourceScript = "res/kxnotifyutils.rc"
$resourceBackup = $null

try {
  if ($Version -ne "") {
    Write-Host "==> バージョンをリソースへ埋める"

    # FILEVERSION と PRODUCTVERSION は数値 4 つしか置けない。
    # -testN のようなプレリリース識別子は入らないため、X.Y.Z だけを使う。
    if ($Version -notmatch '^(\d+)\.(\d+)\.(\d+)') {
      throw "バージョン '$Version' から X.Y.Z を読み取れなかった"
    }
    $numeric = "$($Matches[1]), $($Matches[2]), $($Matches[3]), 0"

    # 書き換える前に控えを取る。
    # 戻しはコピーで行う。読み書きを往復させると、改行や符号化の扱いで元と 1 バイト違いうる。
    $resourceBackup = Join-Path ([System.IO.Path]::GetTempPath()) "kxnotifyutils.rc.original"
    Copy-Item $resourceScript $resourceBackup -Force

    $rc = Get-Content $resourceScript -Raw
    $rc = $rc -replace '(?m)^FILEVERSION .*$', "FILEVERSION $numeric"
    $rc = $rc -replace '(?m)^PRODUCTVERSION .*$', "PRODUCTVERSION $numeric"
    # 文字列側は識別子を含む完全なバージョンを載せる。末尾の \0 はリソースの記法。
    $rc = $rc -replace '(?m)^([ \t]*VALUE "FileVersion", ").*$', ('${1}' + $Version + '\0"')
    $rc = $rc -replace '(?m)^([ \t]*VALUE "ProductVersion", ").*$', ('${1}' + $Version + '\0"')

    # BOM を付けずに書き戻す。Set-Content の既定は PowerShell の版で変わる。
    [System.IO.File]::WriteAllText(
      (Join-Path $PWD $resourceScript), $rc, (New-Object System.Text.UTF8Encoding $false))

    Write-Host "リソースへ埋めたバージョン: $Version (数値は $numeric)"
    $env:KXNOTIFYUTILS_VERSION = $Version
  }

  Write-Host "==> リソースをコンパイルする"
  rc.exe /nologo /fo res\kxnotifyutils.res res\kxnotifyutils.rc
  Assert-LastExitCode "リソースのコンパイル"
} finally {
  # 途中で落ちても戻す。書き換えたまま抜けると、次のビルドが古い版を載せる。
  if ($null -ne $resourceBackup) {
    Copy-Item $resourceBackup $resourceScript -Force
    Remove-Item $resourceBackup -Force
  }
}

Write-Host "==> 本体をビルドする"
$shimDirectory = Join-Path $root "shim\build\$configuration"
$resource = Join-Path $root "res\kxnotifyutils.res"

# /SUBSYSTEM:WINDOWS を付けないとコンソールの exe になり、起動のたびに
# コンソールウィンドウが残る（issue #19）。トレイ常駐であり、標準出力へは何も書かない。
#
# 普通ならここでエントリポイントも変える必要がある。
# /SUBSYSTEM:WINDOWS はリンカの既定エントリを wWinMainCRTStartup にするためである。
# Crystal が /ENTRY:wmainCRTStartup を明示しているので、そちらは起きない。
#
# 置き場所に空白が入っていても壊れないよう、パスは引用符で囲む。
$linkFlags = "/SUBSYSTEM:WINDOWS /LIBPATH:`"$shimDirectory`" `"$resource`""
Write-Host "link flags: $linkFlags"

# --no-debug を外すと uing が libui-ng の debug 版を選ぶ。
# uing はデバッグ情報の有無で libui-ng の release と debug を選び分けており、
# Crystal はデバッグ情報を既定で出すため、--release だけでは debug 版が使われる。
# --static は配布物を exe 1 ファイルにするために要る。
# 付けないと Crystal が同梱する DLL のインポートライブラリが選ばれ、
# zlib1.dll などを要求する exe になる。
$arguments = @("build", "src/main.cr", "-o", $Output, "--static", "--link-flags", $linkFlags)
if (-not $DebugBuild) { $arguments += @("--release", "--no-debug") }
crystal @arguments
Assert-LastExitCode "本体のビルド"

Write-Host "==> 完成: $Output"
