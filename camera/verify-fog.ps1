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

function Get-Hourly {
    param([string]$Model)
    $vars = "cloud_cover_low,cloud_cover,relative_humidity_2m,relative_humidity_850hPa,wind_speed_10m,visibility"
    $u = "https://api.open-meteo.com/v1/forecast?latitude=$Lat&longitude=$Lon&hourly=$vars" +
         "&past_days=$PastDays&forecast_days=1&timezone=Asia%2FTokyo"
    if ($Model) { $u += "&models=$Model" }
    return (Invoke-RestMethod -Uri $u -TimeoutSec 60).hourly
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

if ($Detail) {
    "=== 全時刻 ==="
    $d | Sort-Object time | Format-Table time,label,展望,near_lc,規定版,EC版,平均版,RH850,風 -AutoSize
}
