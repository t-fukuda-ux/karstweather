#Requires -Version 5.1
<#
.SYNOPSIS
  mezuru_contrast.csv を新形式（局所コントラスト列と判定列つき）へ移行する。

.DESCRIPTION
  2026-09-10 の列追加にともなう一度きりの移行。保存済み画像から
  far_lc / mid_lc / near_lc を計算し、label を付ける。

  既存の far_sd 等は再計算せずそのまま残す（当時の記録として保存する）。
  dark だけは閾値を 40→100 に変えた影響で意味が変わるため、mean_all から
  全行を新しい閾値で計算し直す。画像が残っていない行は *_lc と label が空になる。

  実行前に mezuru_contrast.csv.bak へバックアップを取る。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\camera\migrate-csv.ps1
  powershell -ExecutionPolicy Bypass -File .\camera\migrate-csv.ps1 -WhatIf
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$OutDir = ""
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = $PSScriptRoot }
$csv    = Join-Path $OutDir "mezuru_contrast.csv"
$imgDir = Join-Path $OutDir "images"
$bak    = "$csv.bak"

if (-not (Test-Path -LiteralPath $csv)) { throw "CSVが見つかりません: $csv" }

$NewHeader = "captured_at_jst,http_last_modified,bytes,sha1_8,mean_all,dark,far_mean,far_sd,mid_mean,mid_sd,near_mean,near_sd,far_over_near,far_lc,mid_lc,near_lc,label,note"
$OldCols = "captured_at_jst","http_last_modified","bytes","sha1_8","mean_all","dark",
           "far_mean","far_sd","mid_mean","mid_sd","near_mean","near_sd","far_over_near","note"

$Zones = @(
    [ordered]@{ key = "far";  x0 = 270; x1 = 700; y0 =  45; y1 = 105 }
    [ordered]@{ key = "mid";  x0 =  20; x1 = 940; y0 = 110; y1 = 240 }
    [ordered]@{ key = "near"; x0 =  20; x1 = 700; y0 = 300; y1 = 470 }
)
$DarkThreshold = 100.0
$LabelDenseMax = 1.0
$LabelThinMax  = 2.2
$LabelHazeMax  = 3.7

Add-Type -AssemblyName System.Drawing

function Get-ZoneLc {
    param($Bmp, $Zones)
    $rect = [System.Drawing.Rectangle]::new(0, 0, $Bmp.Width, $Bmp.Height)
    $data = $Bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                          [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    try {
        $stride = $data.Stride
        $buf = New-Object byte[] ($stride * $Bmp.Height)
        [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $buf, 0, $buf.Length)
    } finally { $Bmp.UnlockBits($data) }
    $out = [ordered]@{}
    foreach ($z in $Zones) {
        $xEnd = [math]::Min($z.x1, $Bmp.Width - 1)
        $yEnd = [math]::Min($z.y1, $Bmp.Height)
        $dsum = 0.0; $dn = 0
        for ($y = $z.y0; $y -lt $yEnd; $y++) {
            $row = $y * $stride
            for ($x = $z.x0; $x -lt $xEnd; $x++) {
                $i = $row + $x * 3
                $a = 0.114*$buf[$i]   + 0.587*$buf[$i+1] + 0.299*$buf[$i+2]
                $b = 0.114*$buf[$i+3] + 0.587*$buf[$i+4] + 0.299*$buf[$i+5]
                $dsum += [math]::Abs($a - $b); $dn++
            }
        }
        $out[$z.key] = if ($dn -gt 0) { $dsum / $dn } else { $null }
    }
    return $out
}

function Fmt { param($v, [int]$d = 2)
    if ($null -eq $v -or $v -eq "") { return "" }
    return ("{0:F$d}" -f [double]$v) }

$rows = Import-Csv -LiteralPath $csv
$first = ([string](Get-Content -LiteralPath $csv -TotalCount 1)).TrimStart([char]0xFEFF)
if ($first.Trim() -eq $NewHeader) { "既に新形式です。何もしません。"; return }

$out = New-Object System.Collections.Generic.List[string]
$out.Add($NewHeader)
$filled = 0; $missing = 0; $darkChanged = 0
$counts = @{}

foreach ($r in $rows) {
    $ts = $r.($OldCols[0])
    if (-not $ts) { $ts = $r.PSObject.Properties.Name[0] | ForEach-Object { $r.$_ } }
    $img = Join-Path $imgDir ("mezuru_{0}.jpg" -f ([datetime]::ParseExact($ts, "yyyy-MM-dd HH:mm", $null).ToString("yyyyMMdd_HHmm")))

    $lc = [ordered]@{ far = $null; mid = $null; near = $null }
    if (Test-Path -LiteralPath $img) {
        $bmp = [System.Drawing.Bitmap]::FromFile($img)
        try { $lc = Get-ZoneLc -Bmp $bmp -Zones $Zones } finally { $bmp.Dispose() }
        $filled++
    } else { $missing++ }

    # dark は新しい閾値で計算し直す
    $meanAll = if ($r.mean_all) { [double]$r.mean_all } else { $null }
    $newDark = if ($null -ne $meanAll -and $meanAll -lt $DarkThreshold) { 1 } else { 0 }
    if ("$newDark" -ne "$($r.dark)") { $darkChanged++ }

    $label = ""
    if ($newDark -eq 0 -and $null -ne $lc.near) {
        $label = if     ($lc.near -lt $LabelDenseMax) { "濃霧" }
                 elseif ($lc.near -lt $LabelThinMax)  { "薄霧" }
                 elseif ($lc.near -lt $LabelHazeMax)  { "靄" }
                 else                                 { "霧なし" }
        if (-not $counts.ContainsKey($label)) { $counts[$label] = 0 }
        $counts[$label]++
    }

    $out.Add((@(
        $ts,
        ('"' + ($r.http_last_modified -replace '"', "'") + '"'),
        $r.bytes, $r.sha1_8, $r.mean_all, $newDark,
        $r.far_mean, $r.far_sd, $r.mid_mean, $r.mid_sd, $r.near_mean, $r.near_sd,
        $r.far_over_near,
        (Fmt $lc.far), (Fmt $lc.mid), (Fmt $lc.near),
        $label, $r.note
    ) -join ","))
}

if ($PSCmdlet.ShouldProcess($csv, "新形式へ書き換え（バックアップ: $bak）")) {
    Copy-Item -LiteralPath $csv -Destination $bak -Force
    Set-Content -LiteralPath $csv -Value $out -Encoding UTF8
    "移行しました。バックアップ: $bak"
} else {
    "（-WhatIf のため書き込みません）"
}
"  対象 {0}行 / 画像あり {1} / 画像なし {2} / dark が変わった行 {3}" -f $rows.Count, $filled, $missing, $darkChanged
foreach ($k in "濃霧","薄霧","靄","霧なし") { if ($counts.ContainsKey($k)) { "  {0,-6} {1,2}行" -f $k, $counts[$k] } }
