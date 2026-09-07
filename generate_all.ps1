#Requires -Version 5.1
<#
.SYNOPSIS
  3版（規定/EC/平均）を1回のデータ取得から生成し、index.html（平均版）まで更新する。

.DESCRIPTION
  - Open-Meteo を best_match / ecmwf_ifs025 の各1回（hourly+daily統合・7日分）、
    気象庁警報JSONを県ごとに1回だけ取得し、3版すべて同じデータから生成する。
    （従来は3スクリプトが個別に取得しており、1回の更新でOpen-Meteo計7回・気象庁計6回だった）
  - 1版の生成に失敗しても他の版は継続する。平均版が成功した時だけ index.html を更新する。
  - 全版失敗は終了コード1、履歴保存失敗は2。公開後に平均版の鮮度も別途確認する。
  - git操作は行わない。commit/pushは GitHub Actions(update.yml) または publish.ps1 が担当。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\generate_all.ps1
#>

[CmdletBinding()]
param(
    [double]$Latitude    = 33.4666147,    # 四国カルスト 姫鶴荘
    [double]$Longitude   = 132.9610114,
    [Nullable[double]]$Elevation = 1380,
    [string]$Timezone    = "Asia/Tokyo",
    [switch]$ForceUnkaiLab                # 雲海の検証ページを間隔に関係なく生成する
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lowcloud_common.ps1")

# 気象警報・注意報の対象区域（区域コード＝全国地方公共団体コード(5桁)×100）
$AlertAreas = @(
    @{ name = "久万高原町"; code = "3838600"; pref = "380000" },
    @{ name = "梼原町";     code = "3940500"; pref = "390000" }
)

# ---- データ取得（モデルごとに1回・リトライ付き） ----

$bundleA = $null
$bundleB = $null
try {
    $bundleA = Get-ForecastBundle -Latitude $Latitude -Longitude $Longitude -Elevation $Elevation `
                 -Model "best_match" -ForecastDays 7 -Timezone $Timezone
} catch {
    Write-Warning ("best_match の取得に失敗しました: {0}" -f $_.Exception.Message)
}
try {
    $bundleB = Get-ForecastBundle -Latitude $Latitude -Longitude $Longitude -Elevation $Elevation `
                 -Model "ecmwf_ifs025" -ForecastDays 7 -Timezone $Timezone
} catch {
    Write-Warning ("ecmwf_ifs025 の取得に失敗しました: {0}" -f $_.Exception.Message)
}
$alerts = $null
try {
    $alerts = Get-Alerts -areas $AlertAreas
} catch {
    Write-Warning ("警報・注意報の取得に失敗しました: {0}" -f $_.Exception.Message)
}

# ---- 雲海指数 ----
# 展望地点(姫鶴平)＋見下ろす谷4地点をモデルごとに1回ずつ取得する（天気予報本体とは別リクエスト）。
# 失敗しても天気予報3版は生成できるよう、警告のうえ null のまま進める。
$unkaiA = $null   # best_match
$unkaiB = $null   # ecmwf_ifs025
$unkaiM = $null   # 平均版（F は両モデル平均・V は best_match 由来）
$unkaiBundleA = $null   # 検証用ページの地点一覧で使うので保持しておく
try {
    $unkaiBundleA = Get-UnkaiBundle -Model "best_match" -ForecastDays 7 -Timezone $Timezone
    $unkaiA = Get-UnkaiTable -Bundle $unkaiBundleA
} catch {
    Write-Warning ("雲海指数(best_match)の算出に失敗しました: {0}" -f $_.Exception.Message)
}
try {
    $unkaiB = Get-UnkaiTable -Bundle (Get-UnkaiBundle -Model "ecmwf_ifs025" -ForecastDays 7 -Timezone $Timezone)
} catch {
    Write-Warning ("雲海指数(ECMWF)の算出に失敗しました: {0}" -f $_.Exception.Message)
}
if ($null -ne $unkaiA -and $null -ne $unkaiB) {
    try {
        $unkaiM = Get-UnkaiTableAverage -TableA $unkaiA -TableB $unkaiB
    } catch {
        Write-Warning ("雲海指数(平均)の算出に失敗しました: {0}" -f $_.Exception.Message)
    }
} elseif ($null -ne $unkaiA) {
    $unkaiM = $unkaiA   # ECMWFが欠けたときは best_match をそのまま使う
}

# ---- 3版の生成（1版の失敗で他を止めない） ----

$results = [ordered]@{ "規定版" = $false; "EC版" = $false; "平均版" = $false }

if ($null -ne $bundleA) {
    try {
        & (Join-Path $PSScriptRoot "lowcloud.ps1") -Latitude $Latitude -Longitude $Longitude -Elevation $Elevation `
            -Timezone $Timezone -Bundle $bundleA -PrefetchedAlerts $alerts -UnkaiHours $unkaiA
        $results["規定版"] = $true
    } catch {
        Write-Warning ("規定版の生成に失敗しました: {0}" -f $_.Exception.Message)
    }
} else {
    Write-Warning "規定版はデータ未取得のためスキップします。"
}

if ($null -ne $bundleB) {
    try {
        & (Join-Path $PSScriptRoot "lowcloud.ps1") -Latitude $Latitude -Longitude $Longitude -Elevation $Elevation `
            -Timezone $Timezone -Models "ecmwf_ifs025" -OutName "lowcloud_ec" -ModelLabel "[ECMWF]" `
            -Bundle $bundleB -PrefetchedAlerts $alerts -UnkaiHours $unkaiB
        $results["EC版"] = $true
    } catch {
        Write-Warning ("EC版の生成に失敗しました: {0}" -f $_.Exception.Message)
    }
} else {
    Write-Warning "EC版はデータ未取得のためスキップします。"
}

if ($null -ne $bundleA -and $null -ne $bundleB) {
    try {
        & (Join-Path $PSScriptRoot "lowcloud_avg.ps1") -Latitude $Latitude -Longitude $Longitude -Elevation $Elevation `
            -Timezone $Timezone -BundleA $bundleA -BundleB $bundleB -PrefetchedAlerts $alerts -UnkaiHours $unkaiM
        $results["平均版"] = $true
    } catch {
        Write-Warning ("平均版の生成に失敗しました: {0}" -f $_.Exception.Message)
    }
} else {
    Write-Warning "平均版は両モデルのデータが揃わないためスキップします。"
}

# ---- 雲海の検証用ページ（リンクなし・noindexで公開） ----
# 失敗しても3版の生成結果には影響させない。
if ($null -ne $unkaiA -and $null -ne $unkaiBundleA -and (Test-UnkaiLabDue -Dir $PSScriptRoot -Force:$ForceUnkaiLab)) {
    try {
        $byModel = [ordered]@{}
        $byModel["規定(best_match)"] = $unkaiA
        if ($null -ne $unkaiB) { $byModel["ECMWF"] = $unkaiB }
        if ($null -ne $unkaiM) { $byModel["平均"]  = $unkaiM }
        $lab = Save-UnkaiLab -ByModel $byModel -Bundle $unkaiBundleA `
                 -Dir $PSScriptRoot -Generated ((Get-JstNow).ToString("yyyy-MM-dd HH:mm"))
        Write-Host ("雲海の検証用ページを更新しました: {0}" -f $lab.lab)
    } catch {
        Write-Warning ("雲海の検証用ページの生成に失敗しました: {0}" -f $_.Exception.Message)
    }
}

# ---- index.html（WEB公開のルート）は平均版が成功した時だけ更新 ----

if ($results["平均版"]) {
    Copy-Item (Join-Path $PSScriptRoot "lowcloud_avg.html") (Join-Path $PSScriptRoot "index.html") -Force
    Write-Host "index.html を更新しました（平均版を反映）。"
} else {
    Write-Warning "平均版が生成できなかったため index.html は前回のまま維持します。"
}

# ---- 発表時刻付きの雲海予報履歴（検証ページの3時間間隔とは独立） ----
$historyFailed = $false
try {
    . (Join-Path $PSScriptRoot 'forecast_history.ps1')
    $historyModels = [ordered]@{}
    if ($null -ne $unkaiA) { $historyModels['best_match'] = $unkaiA }
    if ($null -ne $unkaiB) { $historyModels['ecmwf_ifs025'] = $unkaiB }
    if ($null -ne $unkaiM) { $historyModels['average'] = $unkaiM }
    $averageMode = if ($null -ne $unkaiB) { 'F=mean; V=best_match' } else { 'best_match fallback' }
    $revision = (git -C $PSScriptRoot rev-parse HEAD)
    if ($LASTEXITCODE -ne 0) { throw '履歴に記録するソースのリビジョンを取得できません。' }
    if (git -C $PSScriptRoot diff --name-only -- '*.ps1') { $revision += '+working-tree' }
    Save-ForecastHistory -ByModel $historyModels -Dir $PSScriptRoot -IssuedAt (Get-JstNow) -SourceRevision $revision -AverageMode $averageMode
} catch {
    Write-Warning ('予報履歴の保存に失敗しました: {0}' -f $_.Exception.Message)
    $historyFailed = $true
}

# ---- 結果まとめ ----

$okCount = @($results.Values | Where-Object { $_ }).Count
$summary = ($results.GetEnumerator() | ForEach-Object { "{0}={1}" -f $_.Key, $(if ($_.Value) { "OK" } else { "失敗" }) }) -join " / "
Write-Host ("生成結果: {0}" -f $summary)
if ($historyFailed -and $okCount -gt 0) { exit 2 }
if ($okCount -eq 0) {
    Write-Warning "全版の生成に失敗しました。"
    exit 1
}
