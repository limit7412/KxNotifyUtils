# ビルド済みの KxNotifyUtils.exe を配布用の zip にまとめる。
#
# BOOTH ではファイルを 1 つ添えて頒布するため、exe とライセンス表記をまとめた zip を作る。
# GitHub Releases には exe 単体も引き続き添付する。
# 更新の確認と自動更新は exe 単体を名前で探すため（src/update/models.cr の ASSET_NAME）、
# zip は別名で並べるだけにして、exe の添付は外さない。
#
# 前提:
#   - 作業ディレクトリの直下に scripts/build.ps1 で作った exe があること
#
# 使い方:
#   pwsh scripts/package.ps1                KxNotifyUtils-dev.zip を作る
#   pwsh scripts/package.ps1 -Version 1.2.3 KxNotifyUtils-1.2.3.zip を作る
#
# GitHub Actions の中で動かした場合は、作った zip のパスを出力 path に書く。
# zip の名前をワークフロー側でも組み立てると、片方だけ直したときに添付が空振りする。
[CmdletBinding()]
param(
  # zip の名前に入れるバージョン。空なら dev とする。
  [string]$Version = "",
  [string]$Executable = "KxNotifyUtils.exe"
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

# ファイル名に使えない文字が版に入っていると、zip の作成が分かりにくい形で落ちる。
# 版は workflow_dispatch の自由入力からも流れてくるため、ここで弾く。
if ($Version -ne "" -and $Version -notmatch '^[0-9A-Za-z.\-+]+$') {
  throw "バージョン '$Version' に zip の名前へ使えない文字が含まれている"
}
$label = if ($Version -ne "") { $Version } else { "dev" }
$archive = "KxNotifyUtils-$label.zip"

# 展開先に中身が散らばらないよう、1 つのフォルダへまとめて入れる。
$folder = "KxNotifyUtils"

# 左が zip の中での名前、右がリポジトリ内のパスである。
#
# LICENSE は拡張子を付けて入れる。拡張子が無いと、Windows ではダブルクリックで開けない。
# MIT License は複製にライセンス表記を含めることを求めるため、LICENSE は必ず入れる。
# 依存するソフトウェアの表記は exe にも埋め込んであるが、展開しただけで読めるよう同梱する。
#
# README.md は入れない。docs/ への相対リンクが zip の中では切れるためである。
# 使い方は BOOTH の商品ページと GitHub の README で案内する。
$entries = [ordered]@{
  "KxNotifyUtils.exe"      = $Executable
  "LICENSE.txt"            = "LICENSE"
  "THIRD-PARTY-NOTICES.md" = "THIRD-PARTY-NOTICES.md"
}

foreach ($source in $entries.Values) {
  if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
    throw "zip に入れる $source が見つからない"
  }
}

Write-Host "==> $archive を作る"

# 前回の zip が残っていると、ZipFile.Open の Create は失敗する。
if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }

# Compress-Archive は PowerShell の版によってエントリ名の区切りに \ を使い、
# 展開ツールによってはフォルダではなく \ を含むファイル名として扱われる。
# エントリ名を自分で決められる ZipFile を使う。
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$zip = [System.IO.Compression.ZipFile]::Open(
  (Join-Path $root $archive), [System.IO.Compression.ZipArchiveMode]::Create)
try {
  foreach ($name in $entries.Keys) {
    $source = Join-Path $root $entries[$name]
    [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
      $zip, $source, "$folder/$name", [System.IO.Compression.CompressionLevel]::Optimal)
  }
} finally {
  # 閉じるまで中央ディレクトリが書かれない。途中で落ちても閉じて、壊れた zip を掴んだままにしない。
  $zip.Dispose()
}

# 読み直して、入れたつもりのものが入っているかを確かめる。
# 作成に失敗したまま添付すると、BOOTH で購入した人が壊れた zip を受け取る。
$check = [System.IO.Compression.ZipFile]::OpenRead((Join-Path $root $archive))
try {
  $actual = @($check.Entries | ForEach-Object { $_.FullName } | Sort-Object)
  $expected = @($entries.Keys | ForEach-Object { "$folder/$_" } | Sort-Object)
  Write-Host "zip の中身:"
  $check.Entries | ForEach-Object { Write-Host "  $($_.FullName) ($($_.Length) bytes)" }
  if (Compare-Object $expected $actual) {
    throw "zip の中身が想定と一致しない"
  }
} finally {
  $check.Dispose()
}

if ($env:GITHUB_OUTPUT) {
  "path=$archive" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
}

Write-Host "==> 完成: $archive"
