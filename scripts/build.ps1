# KxNotifyUtils を 1 ファイルの exe としてビルドする。
#
# 前提:
#   - Visual Studio 2022 以降の C++ ビルドツール（cmake と rc.exe に PATH が通っていること）
#   - Crystal の Windows 版（MSVC ツールチェーン）
#
# 使い方:
#   pwsh scripts/build.ps1            リリースビルド
#   pwsh scripts/build.ps1 -Debug     デバッグビルド
[CmdletBinding()]
param(
  [switch]$DebugBuild,
  [string]$Output = "KxNotifyUtils.exe"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$configuration = if ($DebugBuild) { "Debug" } else { "Release" }

Write-Host "==> NotifListenerShim をビルドする ($configuration)"
cmake -S shim -B shim/build -A x64
cmake --build shim/build --config $configuration

Write-Host "==> リソースをコンパイルする"
rc.exe /nologo /fo res\kxnotifyutils.res res\kxnotifyutils.rc

Write-Host "==> 依存 shard を取得する"
shards install

Write-Host "==> 本体をビルドする"
$shimDirectory = Join-Path $root "shim\build\$configuration"
$resource = Join-Path $root "res\kxnotifyutils.res"
$linkFlags = "/LIBPATH:$shimDirectory `"$resource`""

$arguments = @("build", "src/main.cr", "-o", $Output, "--link-flags", $linkFlags)
if (-not $DebugBuild) { $arguments += "--release" }
crystal @arguments

Write-Host "==> 完成: $Output"
