<#
.SYNOPSIS
  Windy(Point Forecast API) と Open-Meteo の「低層雲(%)」を同地点・同時刻で並べて比較する。

.DESCRIPTION
  - Windy は API キーが必須（無料: https://api.windy.com/keys で発行）
  - 公平な比較のため両方とも GFS モデルに揃える
  - 時刻は UTC で突き合わせ、表示は JST

.EXAMPLE
  .\windy_compare.ps1 -WindyKey "あなたのキー"

.EXAMPLE
  $env:WINDY_KEY="..." ; .\windy_compare.ps1
#>

[CmdletBinding()]
param(
    [string]$WindyKey  = $env:WINDY_KEY,
    [double]$Latitude  = 33.4666147,
    [double]$Longitude = 132.9610114,
    [string]$Model     = "gfs",         # Windy 無料APIは gfs
    [string]$OmModel   = "best_match"   # Open-Meteo 側のモデル。既定は HTML と同じ best_match
                                        # （gfs はこの地点で低層雲が100%に張り付く異常があるため非推奨）
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($WindyKey)) {
    Write-Error "Windy API キーが必要です。-WindyKey か 環境変数 WINDY_KEY で渡してください（https://api.windy.com/keys）。"
    exit 1
}

# ---- Windy: 低層雲を取得 ----
$body = @{
    lat        = $Latitude
    lon        = $Longitude
    model      = $Model
    parameters = @("lclouds")
    levels     = @("surface")
    key        = $WindyKey
} | ConvertTo-Json

try {
    $windy = Invoke-RestMethod -Uri "https://api.windy.com/api/point-forecast/v2" -Method Post -ContentType "application/json" -Body $body -TimeoutSec 30
} catch {
    Write-Error ("Windy 取得に失敗: {0}" -f $_.Exception.Message)
    exit 1
}

$wTs  = $windy.ts                 # UTC ミリ秒の配列
$wLow = $windy.'lclouds-surface'  # %（プロパティ名にハイフンがあるので '' で囲む）

# Windy の時刻(UTC) -> 低層雲 の対応表
$wMap = @{}
for ($i = 0; $i -lt $wTs.Count; $i++) {
    $utc = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$wTs[$i]).UtcDateTime
    $key = $utc.ToString("yyyy-MM-ddTHH:mm")
    $wMap[$key] = [math]::Round([double]$wLow[$i])
}

# ---- Open-Meteo: 低層雲を取得（UTC基準・モデルは $OmModel）----
$omUrl = "https://api.open-meteo.com/v1/forecast?latitude=$Latitude&longitude=$Longitude" +
         "&hourly=cloud_cover_low&models=$OmModel&timezone=GMT&forecast_days=3"
try {
    $om = Invoke-RestMethod -Uri $omUrl -TimeoutSec 30
} catch {
    Write-Error ("Open-Meteo 取得に失敗: {0}" -f $_.Exception.Message)
    exit 1
}
$omMap = @{}
for ($i = 0; $i -lt $om.hourly.time.Count; $i++) {
    $omMap[$om.hourly.time[$i]] = $om.hourly.cloud_cover_low[$i]
}

# ---- 突き合わせて表示 ----
Write-Host ("地点: 緯度 {0} / 経度 {1}   Windy={2} / Open-Meteo={3}" -f $Latitude, $Longitude, $Model, $OmModel)
Write-Host ("低層雲(%) 比較   Windy ts={0}件 / Open-Meteo ts={1}件" -f $wTs.Count, $om.hourly.time.Count)
Write-Host ""
Write-Host ("{0,-18}{1,8}{2,12}{3,8}" -f "日時(JST)", "Windy", "Open-Meteo", "差")
Write-Host ("-" * 46)

$diffs = New-Object System.Collections.Generic.List[double]
foreach ($key in ($wMap.Keys | Sort-Object)) {
    if (-not $omMap.ContainsKey($key)) { continue }   # 双方に存在する時刻だけ比較
    $w = $wMap[$key]
    $o = $omMap[$key]
    $jst = ([datetime]::ParseExact($key, "yyyy-MM-ddTHH:mm", $null)).AddHours(9)
    if ($null -eq $o) {
        Write-Host ("{0,-18}{1,7}%{2,11}{3,8}" -f $jst.ToString("MM-dd HH:mm"), $w, "--", "--")
        continue
    }
    $d = $w - $o
    $diffs.Add([math]::Abs($d))
    Write-Host ("{0,-18}{1,7}%{2,10}%{3,7}" -f $jst.ToString("MM-dd HH:mm"), $w, $o, ("{0:+0;-0;0}" -f $d))
}

if ($diffs.Count -gt 0) {
    $mae = ($diffs | Measure-Object -Average).Average
    Write-Host ("-" * 46)
    Write-Host ("平均絶対差(MAE): {0:0.0} ポイント（{1}時刻で比較）" -f $mae, $diffs.Count)
}
