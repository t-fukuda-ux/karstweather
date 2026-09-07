#Requires -Version 5.1
<#
.SYNOPSIS
  雲海の検証用ページ（unkai_lab.html）と検証用CSVを、その場で最新化する。

.DESCRIPTION
  見たいときに実行する用のスクリプト。天気予報3版の生成とは独立していて、
  公開ページ（index.html・3版のHTML）には一切触れない。
  生成物は .gitignore に入れてあるので公開されない。

  通常は generate_all.ps1 が3時間おきに作り直し、GitHub Pages にも置かれる。
  このスクリプトは、間隔を待たずに今すぐ最新化したいときに使う（公開ページには触れない）。

  所要はおよそ15秒（Open-Meteoへの取得2回）。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\unkai_lab.ps1
#>

[CmdletBinding()]
param(
    [int]   $ForecastDays = 7,
    [string]$Timezone     = "Asia/Tokyo"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lowcloud_common.ps1")

$sw = [System.Diagnostics.Stopwatch]::StartNew()
Write-Host "雲海データを取得しています（2モデル・展望地点＋谷4地点）..."

$bundleA = Get-UnkaiBundle -Model "best_match"   -ForecastDays $ForecastDays -Timezone $Timezone
$tableA  = Get-UnkaiTable  -Bundle $bundleA

$tableB = $null
try {
    $tableB = Get-UnkaiTable -Bundle (Get-UnkaiBundle -Model "ecmwf_ifs025" -ForecastDays $ForecastDays -Timezone $Timezone)
} catch {
    Write-Warning ("ECMWF の取得に失敗しました（規定版のみで作成します）: {0}" -f $_.Exception.Message)
}

$byModel = [ordered]@{}
$byModel["規定(best_match)"] = $tableA
if ($null -ne $tableB) {
    $byModel["ECMWF"] = $tableB
    try { $byModel["平均"] = Get-UnkaiTableAverage -TableA $tableA -TableB $tableB }
    catch { Write-Warning ("平均の算出に失敗しました: {0}" -f $_.Exception.Message) }
}

$res = Save-UnkaiLab -ByModel $byModel -Bundle $bundleA -Dir $PSScriptRoot `
         -Generated ((Get-JstNow).ToString("yyyy-MM-dd HH:mm"))

Write-Host ""
Write-Host ("検証用ページを更新しました（{0:N0}秒）" -f $sw.Elapsed.TotalSeconds)
foreach ($f in @("unkai_lab.html", "unkai_detail.csv", "unkai_levels.csv")) {
    $p = Join-Path $PSScriptRoot $f
    if (Test-Path -LiteralPath $p) {
        Write-Host ("  {0,-20} {1,7:N0} KB" -f $f, ((Get-Item -LiteralPath $p).Length / 1KB))
    }
}
if ($res.log_created) {
    Write-Host ("  {0,-20} 新規作成しました（実績の記入用）" -f "unkai_log.csv")
}
Write-Host ""
Write-Host ("ブラウザで開く: {0}" -f (Join-Path $PSScriptRoot "unkai_lab.html"))
