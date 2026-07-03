#Requires -Version 5.1
<#
.SYNOPSIS
  3版（規定/EC/平均）を1回のデータ取得から生成し、index.html（平均版）まで更新する。

.DESCRIPTION
  - Open-Meteo を best_match / ecmwf_ifs025 の各1回（hourly+daily統合・7日分）、
    気象庁警報JSONを県ごとに1回だけ取得し、3版すべて同じデータから生成する。
    （従来は3スクリプトが個別に取得しており、1回の更新でOpen-Meteo計7回・気象庁計6回だった）
  - 1版の生成に失敗しても他の版は継続する。平均版が成功した時だけ index.html を更新する。
  - 全版失敗した場合のみ終了コード1（GitHub Actionsの失敗通知は本当の異常時だけ届く）。
  - git操作は行わない。commit/pushは GitHub Actions(update.yml) または publish.ps1 が担当。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\generate_all.ps1
#>

[CmdletBinding()]
param(
    [double]$Latitude    = 33.4666147,    # 四国カルスト 姫鶴荘
    [double]$Longitude   = 132.9610114,
    [Nullable[double]]$Elevation = 1380,
    [string]$Timezone    = "Asia/Tokyo"
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

# ---- 3版の生成（1版の失敗で他を止めない） ----

$results = [ordered]@{ "規定版" = $false; "EC版" = $false; "平均版" = $false }

if ($null -ne $bundleA) {
    try {
        & (Join-Path $PSScriptRoot "lowcloud.ps1") -Latitude $Latitude -Longitude $Longitude -Elevation $Elevation `
            -Timezone $Timezone -Bundle $bundleA -PrefetchedAlerts $alerts
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
            -Bundle $bundleB -PrefetchedAlerts $alerts
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
            -Timezone $Timezone -BundleA $bundleA -BundleB $bundleB -PrefetchedAlerts $alerts
        $results["平均版"] = $true
    } catch {
        Write-Warning ("平均版の生成に失敗しました: {0}" -f $_.Exception.Message)
    }
} else {
    Write-Warning "平均版は両モデルのデータが揃わないためスキップします。"
}

# ---- index.html（WEB公開のルート）は平均版が成功した時だけ更新 ----

if ($results["平均版"]) {
    Copy-Item (Join-Path $PSScriptRoot "lowcloud_avg.html") (Join-Path $PSScriptRoot "index.html") -Force
    Write-Host "index.html を更新しました（平均版を反映）。"
} else {
    Write-Warning "平均版が生成できなかったため index.html は前回のまま維持します。"
}

# ---- 結果まとめ ----

$okCount = @($results.Values | Where-Object { $_ }).Count
$summary = ($results.GetEnumerator() | ForEach-Object { "{0}={1}" -f $_.Key, $(if ($_.Value) { "OK" } else { "失敗" }) }) -join " / "
Write-Host ("生成結果: {0}" -f $summary)
if ($okCount -eq 0) {
    Write-Warning "全版の生成に失敗しました。"
    exit 1
}
