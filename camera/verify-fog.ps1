#Requires -Version 5.1
<#
.SYNOPSIS
  カメラの霧ラベルと Open-Meteo の低層雲%を突き合わせ、版ごとの識別力を出す。

.DESCRIPTION
  mezuru_contrast.csv の label 列（濃霧/薄霧/靄/霧なし）を正解として、
  規定版(best_match) / EC版(ecmwf_ifs025) / 平均版 の低層雲%を評価する。

  2値の切り方: 展望あり = 靄+霧なし、展望なし = 濃霧+薄霧。
  ⚠ 靄を「展望なし」側に入れると正例ばかりになり空振りが測れなくなる。
  2026-09-10 の初回検証では、この線引きの違いで結論が変わった。

  ⚠ 結果を読むときは必ずベースライン（常に「霧」と予報した場合の正解率）と
  比べること。霧の多い期間ほどベースラインが高くなり、勝つのが難しくなる。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\camera\verify-fog.ps1
  powershell -ExecutionPolicy Bypass -File .\camera\verify-fog.ps1 -PastDays 30
#>

[CmdletBinding()]
param(
    [string]$OutDir   = "",
    [int]   $PastDays = 7,      # Open-Meteo の遡り日数（最大92）
    [double]$Lat      = 33.4666147,
    [double]$Lon      = 132.9610114,
    [switch]$Detail             # 全時刻を一覧表示する
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = $PSScriptRoot }
$csvPath = Join-Path $OutDir "mezuru_contrast.csv"
if (-not (Test-Path -LiteralPath $csvPath)) { throw "CSVが見つかりません: $csvPath" }

function Avg2 { param($a, $b)
    if ($null -eq $a -and $null -eq $b) { return $null }
    if ($null -eq $a) { return [double]$b }
    if ($null -eq $b) { return [double]$a }
    return ([double]$a + [double]$b) / 2.0 }

# V_summit 用。1400mより上で最も低い有効面を毎回選ぶため、複数面の高度も取る。
$Levels = 925,900,875,850,800
$H_S    = 1400.0   # 展望地点の判定高度（7-2節と同じ）

function Get-Hourly {
    param([string]$Model)
    $v = @("cloud_cover_low","cloud_cover","relative_humidity_2m","wind_speed_10m","visibility")
    foreach ($p in $Levels) { $v += "relative_humidity_${p}hPa"; $v += "geopotential_height_${p}hPa" }
    $u = "https://api.open-meteo.com/v1/forecast?latitude=$Lat&longitude=$Lon&hourly=$($v -join ',')" +
         "&past_days=$PastDays&forecast_days=1&timezone=Asia%2FTokyo"
    if ($Model) { $u += "&models=$Model" }
    return (Invoke-RestMethod -Uri $u -TimeoutSec 60).hourly
}

# 展望地点を挟む上下のRHを返す。上側は H_S より上で最も低い面。
function Get-SummitRh {
    param($h, [int]$i)
    foreach ($p in $Levels) {
        $z  = $h."geopotential_height_${p}hPa"[$i]
        $rh = $h."relative_humidity_${p}hPa"[$i]
        if ($null -ne $z -and $null -ne $rh -and [double]$z -gt $H_S) {
            $below = $h.relative_humidity_2m[$i]
            if ($null -eq $below) { return $null }
            return @{ below = [double]$below; above = [double]$rh; p = $p }
        }
    }
    return $null
}

Write-Host "Open-Meteo から取得中（過去 $PastDays 日）..."
$bm = Get-Hourly ""                # 既定 = best_match
$ec = Get-Hourly "ecmwf_ifs025"
$ib = @{}; for ($i=0; $i -lt $bm.time.Count; $i++) { $ib[$bm.time[$i]] = $i }
$ie = @{}; for ($i=0; $i -lt $ec.time.Count; $i++) { $ie[$ec.time[$i]] = $i }

# ---- 結合 ----
$d = foreach ($r in (Import-Csv -LiteralPath $csvPath)) {
    if (-not $r.label) { continue }                      # 夜間・薄暮は判定なし
    $t = [datetime]::ParseExact($r.captured_at_jst, "yyyy-MM-dd HH:mm", $null)
    $key = $t.AddMinutes(10).ToString("yyyy-MM-ddTHH:00")   # HH:50 → 直近の正時
    if (-not $ib.ContainsKey($key)) { continue }
    $i = $ib[$key]
    $j = if ($ie.ContainsKey($key)) { $ie[$key] } else { $null }
    [pscustomobject]@{
        time = $r.captured_at_jst; label = $r.label; near_lc = [double]$r.near_lc
        展望 = if ($r.label -eq "靄" -or $r.label -eq "霧なし") { "あり" } else { "なし" }
        規定版 = $bm.cloud_cover_low[$i]
        EC版   = if ($null -ne $j) { $ec.cloud_cover_low[$j] } else { $null }
        平均版 = Avg2 $bm.cloud_cover_low[$i] $(if ($null -ne $j) { $ec.cloud_cover_low[$j] } else { $null })
        RH850 = $bm.relative_humidity_850hPa[$i]
        風    = $bm.wind_speed_10m[$i]
        # V_summit（7-2節の式）。規定版とEC版の両方で計算する
        V規定 = $(if ($s1 = Get-SummitRh $bm $i) {
                    if ($s1.below -ge 90 -and $s1.above -ge 90) { 0.00 }
                    elseif ($s1.above -ge 90) { 0.15 }
                    elseif ($s1.below -ge 90) { 0.50 } else { 1.00 } } else { $null })
        VEC   = $(if ($null -ne $j -and ($s2 = Get-SummitRh $ec $j)) {
                    if ($s2.below -ge 90 -and $s2.above -ge 90) { 0.00 }
                    elseif ($s2.above -ge 90) { 0.15 }
                    elseif ($s2.below -ge 90) { 0.50 } else { 1.00 } } else { $null })
        最小RH規定 = $(if ($s1) { [math]::Min($s1.below, $s1.above) } else { $null })
        最小RHEC   = $(if ($s2) { [math]::Min($s2.below, $s2.above) } else { $null })
    }
}
$d = @($d)
if ($d.Count -eq 0) { throw "突合できる時刻がありません。-PastDays を増やしてください" }

"=== 4区分の内訳（突合できた $($d.Count) 時刻）==="
foreach ($k in "濃霧","薄霧","靄","霧なし") {
    $g = @($d | Where-Object { $_.label -eq $k })
    if ($g.Count) { "  {0,-6} {1,3}時刻   near_lc {2:F2}〜{3:F2}" -f $k, $g.Count,
        (($g|ForEach-Object{$_.near_lc}|Measure-Object -Minimum).Minimum),
        (($g|ForEach-Object{$_.near_lc}|Measure-Object -Maximum).Maximum) }
}
""
$no  = @($d | Where-Object { $_.展望 -eq "なし" })   # 霧
$yes = @($d | Where-Object { $_.展望 -eq "あり" })
"=== 2値: 展望なし(濃霧+薄霧) $($no.Count)  vs  展望あり(靄+霧なし) $($yes.Count) ==="
$base = $no.Count / $d.Count
"  ベースライン（常に「霧」と予報）の正解率: {0:P0}  ← これに勝てない閾値は無意味" -f $base
""

function Auc { param($a, $b, $v)
    $x = @($a | ForEach-Object { [double]$_.$v }); $y = @($b | ForEach-Object { [double]$_.$v })
    if ($x.Count -eq 0 -or $y.Count -eq 0) { return [double]::NaN }
    $w = 0.0
    foreach ($i in $x) { foreach ($j in $y) { if ($i -gt $j) { $w += 1 } elseif ($i -eq $j) { $w += 0.5 } } }
    return $w / ($x.Count * $y.Count) }

foreach ($m in "規定版","EC版","平均版") {
    if (@($d | Where-Object { $null -ne $_.$m }).Count -eq 0) { continue }
    $a = ($no  | ForEach-Object { [double]$_.$m } | Measure-Object -Average)
    $b = ($yes | ForEach-Object { [double]$_.$m } | Measure-Object -Average)
    "=== $m ==="
    "  展望なし(霧) 平均 {0,5:F1}%   展望あり 平均 {1,5:F1}%   AUC {2:F2}" -f $a.Average, $b.Average, (Auc $no $yes $m)
    "  閾値   捕捉      見逃し  空振り     正解率   ベースライン差"
    foreach ($th in 20,30,40,50,60) {
        $tp = @($no  | Where-Object { [double]$_.$m -ge $th }).Count
        $fp = @($yes | Where-Object { [double]$_.$m -ge $th }).Count
        $acc = ($tp + ($yes.Count - $fp)) / $d.Count
        $delta = "{0:+0.0%;-0.0%;0.0%}" -f ($acc - $base)   # 符号つきで表示する
        "   {0,3}%  {1,3}/{2,-3}    {3,3}   {4,3}/{5,-3}   {6,6:P0}   {7,8}" -f `
          $th, $tp, $no.Count, ($no.Count-$tp), $fp, $yes.Count, $acc, $delta
    }
    ""
}

# ---- V_summit（7-2節の式）----
# ⚠ 2026-09-10 の検証では、規定版の湿度では展望ありの全時刻が V=0.00 に落ちた
#    （空振り100%）。式ではなく best_match の湿度が乾燥を表現できないことが原因。
"=== V_summit（0=雲の中 / 0.15=上のみ湿潤 / 0.5=下のみ / 1.0=乾燥）==="
foreach ($vc in @(@{v="V規定"; rh="最小RH規定"; n="規定版の湿度"}, @{v="VEC"; rh="最小RHEC"; n="EC版の湿度"})) {
    $g = @($d | Where-Object { $null -ne $_.($vc.v) })
    if ($g.Count -eq 0) { continue }
    $gn = @($g | Where-Object { $_.展望 -eq "なし" }); $gy = @($g | Where-Object { $_.展望 -eq "あり" })
    if ($gn.Count -eq 0 -or $gy.Count -eq 0) { continue }
    $gb = $gn.Count / $g.Count
    "  --- $($vc.n)  n=$($g.Count) ---"
    foreach ($th in 0.00, 0.15, 0.50) {
        $tp = @($gn | Where-Object { $_.($vc.v) -le $th }).Count
        $fp = @($gy | Where-Object { $_.($vc.v) -le $th }).Count
        $acc = ($tp + ($gy.Count - $fp)) / $g.Count
        $dl = "{0:+0.0%;-0.0%;0.0%}" -f ($acc - $gb)
        "    V<={0:F2} を霧   捕捉 {1,3}/{2,-3}  見逃し {3,3}  空振り {4,3}/{5,-3}  正解率 {6,6:P0}  {7,8}" -f `
          $th, $tp, $gn.Count, ($gn.Count-$tp), $fp, $gy.Count, $acc, $dl
    }
    # 素の最小RHでも見る（V_summit の90%という切り方が妥当かの確認）
    $a = ($gn | ForEach-Object { $_.($vc.rh) } | Measure-Object -Average -Minimum -Maximum)
    $b = ($gy | ForEach-Object { $_.($vc.rh) } | Measure-Object -Average -Minimum -Maximum)
    "    最小RH  霧 {0:F1}% ({1:F0}-{2:F0})   展望あり {3:F1}% ({4:F0}-{5:F0})" -f `
      $a.Average,$a.Minimum,$a.Maximum,$b.Average,$b.Minimum,$b.Maximum
    "    ※ 展望ありの下限が90%を割らない版は、RH>=90 で切る V_summit では原理的に区別できない"
}
""

if ($Detail) {
    "=== 全時刻 ==="
    $d | Sort-Object time | Format-Table time,label,展望,near_lc,規定版,EC版,平均版,V規定,VEC,風 -AutoSize
}
