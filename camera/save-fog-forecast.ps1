#Requires -Version 5.1
<#
.SYNOPSIS
  霧予報の検証用に、姫鶴平（展望地点）の毎時予報を発表時刻つきで保存する。

.DESCRIPTION
  雲海用の forecast-history とは別立て。理由は3つ。

  1. forecast-history に保存される cloud_low は「谷4地点」の値で、
     姫鶴平の低層雲%はどの版のファイルにも入っていない（雲海指数が
     展望地点の低層雲を使わない設計のため、計算テーブルに乗っていない）
  2. forecast-history は 05:00〜08:00 の4時刻しか残さない。霧は日中も出る
  3. 雲海と霧では必要な変数も時間帯も違う。履歴を分けたほうが両方きれいになる

  ⚠ これがないと「予報として当たったか」は検証できない。verify-fog.ps1 が
  やっているのは診断（過去時刻に対する現在の解析値との突き合わせ）であって、
  事前に発表された予報の検証ではない。

  カメラは日中しか判定できないので、対象時刻は既定で 05:00〜19:00 JST に絞る。
  同じ発表時（時単位）の行が既にあれば何もしない（重複実行の保護）。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\camera\save-fog-forecast.ps1
  powershell -ExecutionPolicy Bypass -File .\camera\save-fog-forecast.ps1 -HorizonHours 60
#>

[CmdletBinding()]
param(
    [string]$OutDir       = "",
    [double]$Lat          = 33.4666147,
    [double]$Lon          = 132.9610114,
    [int]   $HorizonHours = 42,   # 何時間先まで保存するか
    [int]   $FirstHour    = 5,    # 対象に含める時刻の下限（JST）
    [int]   $LastHour     = 19,   # 同上の上限
    [switch]$Force                # 同じ発表時の行があっても追記する
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = $PSScriptRoot }
$csv = Join-Path $OutDir "fog_forecast.csv"
$log = Join-Path $OutDir "capture.log"

$Levels = 925,900,875,850,800
$H_S    = 1400.0   # 展望地点の判定高度（SYSTEM.md 7-2 と同じ）

function Write-FogLog {
    param([string]$msg)
    $line = "[{0:yyyy-MM-dd HH:mm:ss}] fog-forecast: {1}" -f (Get-Date), $msg
    Write-Host $line
    try { Add-Content -LiteralPath $log -Value $line -Encoding UTF8 } catch { }
}

function Avg2 { param($a, $b)
    if ($null -eq $a -and $null -eq $b) { return $null }
    if ($null -eq $a) { return [double]$b }
    if ($null -eq $b) { return [double]$a }
    return ([double]$a + [double]$b) / 2.0 }

function Fmt { param($v, [int]$d = 1)
    if ($null -eq $v) { return "" }
    return ("{0:F$d}" -f [double]$v) }

function Get-Hourly {
    param([string]$Model, [int]$Days)
    $v = @("cloud_cover_low","cloud_cover","relative_humidity_2m","wind_speed_10m","visibility","precipitation")
    foreach ($p in $Levels) { $v += "relative_humidity_${p}hPa"; $v += "geopotential_height_${p}hPa" }
    $u = "https://api.open-meteo.com/v1/forecast?latitude=$Lat&longitude=$Lon&hourly=$($v -join ',')" +
         "&forecast_days=$Days&timezone=Asia%2FTokyo"
    if ($Model) { $u += "&models=$Model" }
    return (Invoke-RestMethod -Uri $u -TimeoutSec 60).hourly
}

# 展望地点を挟む上下のRHと V_summit（7-2節の式）
function Get-Summit {
    param($h, [int]$i)
    foreach ($p in $Levels) {
        $z  = $h."geopotential_height_${p}hPa"[$i]
        $rh = $h."relative_humidity_${p}hPa"[$i]
        if ($null -ne $z -and $null -ne $rh -and [double]$z -gt $H_S) {
            $below = $h.relative_humidity_2m[$i]
            if ($null -eq $below) { return $null }
            $bw = ([double]$below -ge 90); $aw = ([double]$rh -ge 90)
            $v = if ($bw -and $aw) { 0.00 } elseif ($aw) { 0.15 } elseif ($bw) { 0.50 } else { 1.00 }
            return @{ below = [double]$below; above = [double]$rh; p = $p; v = $v }
        }
    }
    return $null
}

# ---- 発表時刻。重複実行の保護 ----

$nowJst = (Get-Date).ToUniversalTime().AddHours(9)
$issued = $nowJst.ToString("yyyy-MM-dd HH:mm")
$issuedHour = $nowJst.ToString("yyyy-MM-dd HH")

$header = "issued_at,target_time,lead_h,cl_bm,cl_ec,cl_avg,rh2m_bm,rh2m_ec,rh_above_bm,rh_above_ec,p_above_bm,p_above_ec,v_bm,v_ec,wind_bm,vis_bm,precip_bm"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
if (Test-Path -LiteralPath $csv) {
    $first = ([string](Get-Content -LiteralPath $csv -TotalCount 1)).TrimStart([char]0xFEFF)
    if ($first.Trim() -ne $header) {
        Write-FogLog "CSVのヘッダが現在の形式と異なります。追記を中止しました"
        exit 1
    }
    if (-not $Force) {
        $dup = @(Import-Csv -LiteralPath $csv | Where-Object { $_.issued_at -like "$issuedHour*" }).Count
        if ($dup -gt 0) { Write-FogLog ("同じ発表時({0}時)の行が {1} 件あるため何もしません" -f $issuedHour, $dup); exit 0 }
    }
} else {
    Set-Content -LiteralPath $csv -Value $header -Encoding UTF8
}

# ---- 取得 ----

$days = [math]::Min(7, [math]::Max(2, [int][math]::Ceiling(($nowJst.Hour + $HorizonHours) / 24.0)))
try {
    $bm = Get-Hourly ""              $days
    $ec = Get-Hourly "ecmwf_ifs025"  $days
} catch {
    Write-FogLog ("取得失敗: {0}" -f $_.Exception.Message)
    exit 1    # タスクの実行結果から欠測を検知できるようにする
}

$ie = @{}; for ($i = 0; $i -lt $ec.time.Count; $i++) { $ie[$ec.time[$i]] = $i }

$limit = $nowJst.AddHours($HorizonHours)
$rows = New-Object System.Collections.Generic.List[string]
for ($i = 0; $i -lt $bm.time.Count; $i++) {
    $t = [datetime]::ParseExact($bm.time[$i], "yyyy-MM-dd'T'HH:mm", $null)
    if ($t -le $nowJst -or $t -gt $limit) { continue }          # 未来だけ・地平線まで
    if ($t.Hour -lt $FirstHour -or $t.Hour -gt $LastHour) { continue }  # カメラが判定できる時間帯だけ

    $j  = $(if ($ie.ContainsKey($bm.time[$i])) { $ie[$bm.time[$i]] } else { $null })
    $s1 = Get-Summit $bm $i
    $s2 = $(if ($null -ne $j) { Get-Summit $ec $j } else { $null })
    $clB = $bm.cloud_cover_low[$i]
    $clE = $(if ($null -ne $j) { $ec.cloud_cover_low[$j] } else { $null })

    $rows.Add((@(
        $issued, $t.ToString("yyyy-MM-dd HH:mm"), [int]($t - $nowJst).TotalHours,
        (Fmt $clB 0), (Fmt $clE 0), (Fmt (Avg2 $clB $clE) 1),
        (Fmt $bm.relative_humidity_2m[$i] 0),
        (Fmt $(if ($null -ne $j) { $ec.relative_humidity_2m[$j] } else { $null }) 0),
        (Fmt $(if ($s1) { $s1.above } else { $null }) 0),
        (Fmt $(if ($s2) { $s2.above } else { $null }) 0),
        $(if ($s1) { $s1.p } else { "" }),
        $(if ($s2) { $s2.p } else { "" }),
        (Fmt $(if ($s1) { $s1.v } else { $null }) 2),
        (Fmt $(if ($s2) { $s2.v } else { $null }) 2),
        (Fmt $bm.wind_speed_10m[$i] 1),
        (Fmt $bm.visibility[$i] 0),
        (Fmt $bm.precipitation[$i] 2)
    ) -join ","))
}

if ($rows.Count -eq 0) { Write-FogLog "保存対象の時刻がありませんでした"; exit 0 }
Add-Content -LiteralPath $csv -Value $rows -Encoding UTF8
Write-FogLog ("発表 {0} / {1}行を保存（リード {2}〜{3}時間）" -f $issued, $rows.Count,
    ([int](($rows[0] -split ',')[2])), ([int](($rows[$rows.Count-1] -split ',')[2])))
