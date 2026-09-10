#Requires -Version 5.1
<#
.SYNOPSIS
  姫鶴平ライブカメラの画像を取得し、帯ごとのコントラストと霧の判定を記録する。

.DESCRIPTION
  用途は雲海ではなく霧。カメラの視線がほぼ水平で谷が画角に入らないため、
  判定できるのは「現地がガスの中か」であり、これが霧そのものにあたる。

  指標は局所コントラスト（帯内の隣接画素の輝度差の絶対値の平均）。
  標準偏差(sd)は「明暗の広がり」を測るためなめらかな輝度勾配に嵩上げされ、
  霧の日に真っ白でも高い値を返してしまう。局所コントラストは細部の量だけを
  測るのでこの欠陥がない。sd と far_over_near は互換のため記録だけ続ける。

  ⚠ far_over_near は判定に使わないこと。実測で霧のとき上がる（設計と逆）。
  詳細は SYSTEM.md「ライブカメラによる霧の記録」節を参照。

  判定（2026-09-10 に画像を目視して暫定決定・昼間29枚）:
    濃霧 near_lc < 1.0      建物がかろうじて        展望なし
    薄霧 near_lc 1.0〜2.2   手前は明瞭、奥が消失    展望なし
    靄   near_lc 2.2〜3.7   霞むが景色は見える      展望あり
    霧なし near_lc >= 3.7   奥まで抜けている        展望あり

  ⚠ 判定は昼間のみ有効。夜間はセンサーノイズで near_lc が 3.80〜3.92 になり、
  霧なしの閾値とほぼ重なる。平均輝度 $DarkThreshold 未満は label を空にする。

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
    [int]   $Step     = 3,      # sd/平均の画素間引き。局所コントラストは常に全画素
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
# ⚠ 遠景帯が写しているのは1km先の尾根ではなく、道路の向かい側の斜面（200〜400m）。
$Zones = @(
    [ordered]@{ key = "far";  name = "遠景";  x0 = 270; x1 = 700; y0 =  45; y1 = 105 }
    [ordered]@{ key = "mid";  name = "中景";  x0 =  20; x1 = 940; y0 = 110; y1 = 240 }
    [ordered]@{ key = "near"; name = "近景";  x0 =  20; x1 = 700; y0 = 300; y1 = 470 }
)
$ExpectedWidth  = 960
$ExpectedHeight = 540

# 平均輝度がこれ未満なら夜間・薄暮とみなし、dark=1 を立てて画像を保存せず判定もしない。
# 旧値40では薄暮（平均輝度40〜75）を通してしまい、無意味な測定値を記録していた。
# 実測: 夜間の平均輝度は約28、薄暮は38〜75、昼間は121〜163。100で確実に切れる。
$DarkThreshold = 100.0

# 判定の境界（near_lc）。実測に空白がある位置に置いてある: 1.83|2.65 と 3.51|3.82
$LabelDenseMax = 1.0    # これ未満が濃霧
$LabelThinMax  = 2.2    # これ未満が薄霧
$LabelHazeMax  = 3.7    # これ未満が靄、以上が霧なし

# 帯ごとの 平均輝度 / 標準偏差 / 局所コントラスト をまとめて求める。
# LockBits で画素配列を1回だけ取り出す（GetPixel は1画素ずつ呼ぶため遅い）。
function Get-ZoneMetrics {
    param($Bmp, $Zones, [int]$Step)
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
        $xEnd = [math]::Min($z.x1, $Bmp.Width - 1)   # x+1 を読むので1画素余裕を持たせる
        $yEnd = [math]::Min($z.y1, $Bmp.Height)
        $sum = 0.0; $sum2 = 0.0; $n = 0               # 平均・標準偏差（間引きあり）
        $dsum = 0.0; $dn = 0                          # 局所コントラスト（全画素）
        for ($y = $z.y0; $y -lt $yEnd; $y++) {
            $row = $y * $stride
            $sample = (($y - $z.y0) % $Step) -eq 0
            for ($x = $z.x0; $x -lt $xEnd; $x++) {
                $i = $row + $x * 3
                # BGR順。輝度 = 0.299R + 0.587G + 0.114B
                $a = 0.114*$buf[$i] + 0.587*$buf[$i+1] + 0.299*$buf[$i+2]
                $b = 0.114*$buf[$i+3] + 0.587*$buf[$i+4] + 0.299*$buf[$i+5]
                $dsum += [math]::Abs($a - $b); $dn++
                if ($sample -and ((($x - $z.x0) % $Step) -eq 0)) {
                    $sum += $a; $sum2 += $a * $a; $n++
                }
            }
        }
        if ($n -eq 0) {
            $out[$z.key] = [ordered]@{ mean = $null; sd = $null; lc = $null }
        } else {
            $mean = $sum / $n
            $var  = $sum2 / $n - $mean * $mean
            if ($var -lt 0) { $var = 0 }
            $out[$z.key] = [ordered]@{ mean = $mean; sd = [math]::Sqrt($var)
                                       lc = $(if ($dn -gt 0) { $dsum / $dn } else { $null }) }
        }
    }
    return $out
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
    $stats = Get-ZoneMetrics -Bmp $bmp -Zones $Zones -Step $Step
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

# 旧指標。判定には使わない（霧のとき上がるため）。互換のため記録だけ続ける。
$ratio = $null
if ($null -ne $stats["far"].sd -and $null -ne $stats["near"].sd -and $stats["near"].sd -gt 0.5) {
    $ratio = $stats["far"].sd / $stats["near"].sd
}

# 判定。夜間は近景の局所コントラストがノイズで霧なしの閾値に達するため空にする。
$nlc   = $stats["near"].lc
$label = ""
if ($dark -eq 0 -and $null -ne $nlc) {
    $label = if     ($nlc -lt $LabelDenseMax) { "濃霧" }
             elseif ($nlc -lt $LabelThinMax)  { "薄霧" }
             elseif ($nlc -lt $LabelHazeMax)  { "靄" }
             else                             { "霧なし" }
}

# ---- 記録 ----

$header = "captured_at_jst,http_last_modified,bytes,sha1_8,mean_all,dark,far_mean,far_sd,mid_mean,mid_sd,near_mean,near_sd,far_over_near,far_lc,mid_lc,near_lc,label,note"
if (-not (Test-Path -LiteralPath $csv)) {
    Set-Content -LiteralPath $csv -Value $header -Encoding UTF8
} else {
    # 列を追加した際に旧形式のまま追記すると列がずれる。気づけるように警告を出す。
    $first = ([string](Get-Content -LiteralPath $csv -TotalCount 1)).TrimStart([char]0xFEFF)
    if ($first.Trim() -ne $header) {
        Write-CamLog "⚠ CSVのヘッダが現在の形式と異なります。migrate-csv.ps1 で移行してください"
    }
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
    (Format-CamNum $stats["far"].lc 2), (Format-CamNum $stats["mid"].lc 2), (Format-CamNum $nlc 2),
    $label,
    $sizeNote
) -join ","
Add-Content -LiteralPath $csv -Value $row -Encoding UTF8

# ---- 画像の保存と間引き ----

# 夜間・薄暮の画像は照明がないため真っ黒＋センサーノイズで、検証に使えない。
# 数値は記録するが画像は保存しない（1日あたり約1MBのうち約半分がこれだった）。
if ($NoImage -or $dark -eq 1) {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
} else {
    $dest = Join-Path $imgDir ("mezuru_{0}.jpg" -f $stamp)
    Move-Item -LiteralPath $tmp -Destination $dest -Force
    $limit = (Get-Date).AddDays(-$KeepDays)
    Get-ChildItem -LiteralPath $imgDir -Filter "mezuru_*.jpg" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $limit } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
}

Write-CamLog ("記録: {0}  近景lc={1} / 中景lc={2} / 遠景lc={3} / 平均輝度={4}{5}" -f `
    $(if ($label) { $label } else { "判定なし" }),
    (Format-CamNum $nlc 2), (Format-CamNum $stats["mid"].lc 2), (Format-CamNum $stats["far"].lc 2),
    (Format-CamNum $meanAll 0), $(if ($dark -eq 1) { " [暗い]" } else { "" }))
