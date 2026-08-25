# KxNotifyUtils を 1 ファイルの exe としてビルドする。
#
# 前提:
#   - Visual Studio 2022 以降の C++ ビルドツール（cmake と rc.exe に PATH が通っていること）
#   - Crystal の Windows 版（MSVC ツールチェーン）
#
# 使い方:
#   pwsh scripts/build.ps1              リリースビルド
#   pwsh scripts/build.ps1 -DebugBuild  デバッグビルド
#
# PowerShell の共通パラメータに -Debug があるため、独自のスイッチは -DebugBuild とする。
[CmdletBinding()]
param(
  [switch]$DebugBuild,
  [string]$Output = "KxNotifyUtils.exe"
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

Write-Host "==> NotifListenerShim をビルドする ($configuration)"
cmake -S shim -B shim/build -A x64
Assert-LastExitCode "cmake の構成"
cmake --build shim/build --config $configuration
Assert-LastExitCode "シムのビルド"

Write-Host "==> リソースをコンパイルする"
rc.exe /nologo /fo res\kxnotifyutils.res res\kxnotifyutils.rc
Assert-LastExitCode "リソースのコンパイル"

Write-Host "==> 依存 shard を取得する"
shards install
Assert-LastExitCode "shards install"

Write-Host "==> 本体をビルドする"
$shimDirectory = Join-Path $root "shim\build\$configuration"
$resource = Join-Path $root "res\kxnotifyutils.res"
$linkFlags = "/LIBPATH:$shimDirectory `"$resource`""

# --no-debug を外すと uing が libui-ng の debug 版を選ぶ。
# uing はデバッグ情報の有無で libui-ng の release と debug を選び分けており、
# Crystal はデバッグ情報を既定で出すため、--release だけでは debug 版が使われる。
$arguments = @("build", "src/main.cr", "-o", $Output, "--link-flags", $linkFlags)
if (-not $DebugBuild) { $arguments += @("--release", "--no-debug") }
crystal @arguments
Assert-LastExitCode "本体のビルド"

Write-Host "==> 完成: $Output"
