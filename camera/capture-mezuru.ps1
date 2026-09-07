#Requires -Version 5.1
<#
.SYNOPSIS
  姫鶴平ライブカメラの画像を取得し、距離帯ごとのコントラストを記録する。

.DESCRIPTION
  第1段階（記録のみ）。霧かどうかの判定は行わない。
  晴天時・霧天時のデータが溜まってから、現地の目視記録と突き合わせて基準値を決める。

  原理: 霧が出ると遠景のコントラスト（輝度の標準偏差）が落ちる。
  近景は霧の影響を受けにくいので、遠景/近景の比を見ると明るさの変化を打ち消せる。

  2026-09-07 17:50 の実測（霧。数百m先は見えるが1km先は見えない）では
    遠景 19.8 / 中景 29.5 / 近景 40.0、比 0.50

  カメラは姫鶴荘（karst.co.jp）自身のもの。画像は 960x540 固定で、
  時刻・日付・ロゴが焼き込まれているため、その領域は測定から除外している。
  ⚠ カメラの向きや画角が変わったら $Zones を引き直すこと。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\camera\capture-mezuru.ps1
#>

[CmdletBinding()]
param(
    [string]$Url      = "https://www.karst.co.jp/cam/mezuru01.jpg",
    [string]$OutDir   = "",     # 既定: このスクリプトと同じ場所
    [int]   $KeepDays = 90,     # 画像の保存日数。CSVは消さない
    [int]   $Step     = 3,      # 画素の間引き。小さいほど精密で遅い
    [switch]$NoImage            # 画像を保存せず数値だけ記録する
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = $PSScriptRoot }
$imgDir = Join-Path $OutDir "images"
$csv    = Join-Path $OutDir "mezuru_contrast.csv"
$log    = Join-Path $OutDir "capture.log"

function Write-CamLog {
    param([string]$msg)
    $line = "[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $msg
    Write-Host $line
    try { Add-Content -LiteralPath $log -Value $line -Encoding UTF8 } catch { }
}

# 測定する帯。画像 960x540 前提。OSD（時刻・日付・ロゴ）と右手前の樹木は除外する。
$Zones = @(
    [ordered]@{ key = "far";  name = "遠景";  x0 = 270; x1 = 700; y0 =  45; y1 = 105 }
    [ordered]@{ key = "mid";  name = "中景";  x0 =  20; x1 = 940; y0 = 110; y1 = 240 }
    [ordered]@{ key = "near"; name = "近景";  x0 =  20; x1 = 700; y0 = 300; y1 = 470 }
)
$ExpectedWidth  = 960
$ExpectedHeight = 540

# 平均輝度がこれ未満なら夜間・暗すぎとみなし、コントラストは記録するが dark=1 を立てる
$DarkThreshold = 40.0

function Get-ZoneStats {
    param($Bitmap, $Zone, [int]$Step)
    $sum = 0.0; $sum2 = 0.0; $n = 0
    $x1 = [math]::Min($Zone.x1, $Bitmap.Width)
    $y1 = [math]::Min($Zone.y1, $Bitmap.Height)
    for ($y = $Zone.y0; $y -lt $y1; $y += $Step) {
        for ($x = $Zone.x0; $x -lt $x1; $x += $Step) {
            $c = $Bitmap.GetPixel($x, $y)
            $l = 0.299 * $c.R + 0.587 * $c.G + 0.114 * $c.B
            $sum += $l; $sum2 += $l * $l; $n++
        }
    }
    if ($n -eq 0) { return [ordered]@{ mean = $null; sd = $null; n = 0 } }
    $mean = $sum / $n
    $var  = $sum2 / $n - $mean * $mean
    if ($var -lt 0) { $var = 0 }
    return [ordered]@{ mean = $mean; sd = [math]::Sqrt($var); n = $n }
}

function Format-CamNum {
    param($v, [int]$d = 1)
    if ($null -eq $v) { return "" }
    return ("{0:F$d}" -f [double]$v)
}

# ---- 取得 ----

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
if (-not $NoImage) { New-Item -ItemType Directory -Force -Path $imgDir | Out-Null }

$nowJst = (Get-Date).ToUniversalTime().AddHours(9)   # サーバーのTZに依存させない
$stamp  = $nowJst.ToString("yyyyMMdd_HHmm")
$tmp    = Join-Path $env:TEMP ("mezuru_{0}.jpg" -f $stamp)

$lastMod = ""
try {
    # キャッシュを避けるため毎回異なるクエリを付ける
    $u = "{0}?t={1}" -f $Url, [int][double]::Parse((Get-Date -UFormat %s))
    $resp = Invoke-WebRequest -Uri $u -OutFile $tmp -TimeoutSec 30 -UseBasicParsing -PassThru
    if ($resp.Headers["Last-Modified"]) { $lastMod = [string]$resp.Headers["Last-Modified"] }
} catch {
    Write-CamLog ("取得失敗: {0}" -f $_.Exception.Message)
    exit 0    # 定期実行を失敗扱いにしない
}

if (-not (Test-Path -LiteralPath $tmp)) { Write-CamLog "画像が保存されませんでした"; exit 0 }
$bytes = (Get-Item -LiteralPath $tmp).Length
if ($bytes -lt 2000) { Write-CamLog ("画像が小さすぎます（{0} バイト）。中断します" -f $bytes); exit 0 }

# 同じ画像が続いていないか（カメラの停止検知）用にハッシュを残す
$sha = (Get-FileHash -LiteralPath $tmp -Algorithm SHA1).Hash.Substring(0, 8)

# ---- 測定 ----

Add-Type -AssemblyName System.Drawing
$stats = [ordered]@{}
$w = 0; $h = 0; $sizeNote = ""
try {
    $bmp = [System.Drawing.Bitmap]::FromFile($tmp)
    $w = $bmp.Width; $h = $bmp.Height
    if ($w -ne $ExpectedWidth -or $h -ne $ExpectedHeight) {
        # 画角が変わると帯の位置が合わなくなる。記録は続けるが印を残す
        $sizeNote = ("size_changed({0}x{1})" -f $w, $h)
        Write-CamLog ("⚠ 画像サイズが想定と異なります: {0}x{1}（想定 {2}x{3}）。帯の再設定が必要です" -f $w, $h, $ExpectedWidth, $ExpectedHeight)
    }
    foreach ($z in $Zones) { $stats[$z.key] = Get-ZoneStats -Bitmap $bmp -Zone $z -Step $Step }
    $bmp.Dispose()
} catch {
    Write-CamLog ("画像を解析できませんでした: {0}" -f $_.Exception.Message)
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    exit 0
}

$meanAll = 0.0; $cnt = 0
foreach ($k in $stats.Keys) { if ($null -ne $stats[$k].mean) { $meanAll += $stats[$k].mean; $cnt++ } }
if ($cnt -gt 0) { $meanAll = $meanAll / $cnt } else { $meanAll = $null }
$dark = if ($null -ne $meanAll -and $meanAll -lt $DarkThreshold) { 1 } else { 0 }

# 遠景/近景の比。全体の明るさの変化を打ち消した霧の指標
$ratio = $null
if ($null -ne $stats["far"].sd -and $null -ne $stats["near"].sd -and $stats["near"].sd -gt 0.5) {
    $ratio = $stats["far"].sd / $stats["near"].sd
}

# ---- 記録 ----

$header = "captured_at_jst,http_last_modified,bytes,sha1_8,mean_all,dark,far_mean,far_sd,mid_mean,mid_sd,near_mean,near_sd,far_over_near,note"
if (-not (Test-Path -LiteralPath $csv)) {
    Set-Content -LiteralPath $csv -Value $header -Encoding UTF8
}
$row = @(
    $nowJst.ToString("yyyy-MM-dd HH:mm"),
    ('"' + ($lastMod -replace '"', "'") + '"'),
    $bytes, $sha,
    (Format-CamNum $meanAll 1), $dark,
    (Format-CamNum $stats["far"].mean 1),  (Format-CamNum $stats["far"].sd 2),
    (Format-CamNum $stats["mid"].mean 1),  (Format-CamNum $stats["mid"].sd 2),
    (Format-CamNum $stats["near"].mean 1), (Format-CamNum $stats["near"].sd 2),
    (Format-CamNum $ratio 3),
    $sizeNote
) -join ","
Add-Content -LiteralPath $csv -Value $row -Encoding UTF8

# ---- 画像の保存と間引き ----

if ($NoImage) {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
} else {
    $dest = Join-Path $imgDir ("mezuru_{0}.jpg" -f $stamp)
    Move-Item -LiteralPath $tmp -Destination $dest -Force
    $limit = (Get-Date).AddDays(-$KeepDays)
    Get-ChildItem -LiteralPath $imgDir -Filter "mezuru_*.jpg" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $limit } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
}

Write-CamLog ("記録: 遠景 sd={0} / 中景 sd={1} / 近景 sd={2} / 比={3} / 平均輝度={4}{5}" -f `
    (Format-CamNum $stats["far"].sd 1), (Format-CamNum $stats["mid"].sd 1), (Format-CamNum $stats["near"].sd 1), `
    (Format-CamNum $ratio 2), (Format-CamNum $meanAll 0), $(if ($dark -eq 1) { " [暗い]" } else { "" }))
