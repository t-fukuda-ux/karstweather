<#
.SYNOPSIS
  Open-Meteo から指定地点の毎時・雲量（低層を中心に）を取得して表示し、CSV に保存する。

.DESCRIPTION
  - API キー不要・無料
  - 既定の地点は四国カルスト 姫鶴荘
  - 取得項目: 低層雲 / 中層雲 / 高層雲 / 全雲量（いずれも %）
  - 毎時テーブル: 実行時刻から 72 時間分を表示
  - Python 不要。Windows 標準の PowerShell だけで動作します。
  - モデル切替: -Models でOpen-Meteoのモデル系統を指定（既定 best_match）。
    lowcloud_ec.ps1 はこの本体を -Models ecmwf_ifs025 で呼び出すラッパー。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\lowcloud.ps1

.EXAMPLE
  .\lowcloud.ps1 -Latitude 35.681 -Longitude 139.767 -ForecastDays 3

.EXAMPLE
  .\lowcloud.ps1 -Models ecmwf_ifs025 -OutName lowcloud_ec -ModelLabel "[ECMWF]"
#>

[CmdletBinding()]
param(
    [double]$Latitude    = 33.4666147,    # 四国カルスト 姫鶴荘
    [double]$Longitude   = 132.9610114,
    [Nullable[double]]$Elevation = 1380,   # 標高(m)。$null ならAPIが自動採用（この地点は約1296m）
    [int]   $ForecastDays = 4,            # 72h確保のため4日取得（内部用）
    [int]   $WeeklyDays  = 7,             # 週間予報の日数（最大16）
    [string]$Timezone    = "Asia/Tokyo",
    [string]$CsvPath     = "",
    [string]$Models      = "best_match",  # Open-Meteoのモデル系統（best_match/ecmwf_ifs025 等）
    [string]$OutName     = "lowcloud",    # 出力ファイル名のベース（拡張子なし）
    [string]$ModelLabel  = ""             # HTML見出しに付記するモデル表記（例 "[ECMWF]"）
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lowcloud_common.ps1")

$HourlyVars = "weather_code,temperature_2m,wind_speed_10m,precipitation_probability,precipitation,cloud_cover_low,cloud_cover_mid,cloud_cover_high,cloud_cover"

# 気象警報・注意報の対象区域（区域コード＝全国地方公共団体コード(5桁)×100）
$AlertAreas = @(
    @{ name = "久万高原町"; code = "3838600"; pref = "380000" },
    @{ name = "梼原町";     code = "3940500"; pref = "390000" }
)

# ---- データ取得 ----

function Get-WeatherData {
    $query = @{
        latitude      = $Latitude
        longitude     = $Longitude
        hourly        = $HourlyVars
        timezone      = $Timezone
        forecast_days = $ForecastDays
        wind_speed_unit = "ms"
    }
    if ($null -ne $Elevation) { $query["elevation"] = $Elevation }
    if (-not [string]::IsNullOrWhiteSpace($Models)) { $query["models"] = $Models }
    $pairs = $query.GetEnumerator() | ForEach-Object {
        "{0}={1}" -f $_.Key, [uri]::EscapeDataString([string]$_.Value)
    }
    $url = "https://api.open-meteo.com/v1/forecast?" + ($pairs -join "&")
    return Invoke-RestMethod -Uri $url -TimeoutSec 30
}

function Get-DailyRows {
    $query = @{
        latitude      = $Latitude
        longitude     = $Longitude
        daily         = "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,precipitation_sum,sunrise,sunset"
        timezone      = $Timezone
        forecast_days = $WeeklyDays
    }
    if ($null -ne $Elevation) { $query["elevation"] = $Elevation }
    if (-not [string]::IsNullOrWhiteSpace($Models)) { $query["models"] = $Models }
    $pairs = $query.GetEnumerator() | ForEach-Object { "{0}={1}" -f $_.Key, [uri]::EscapeDataString([string]$_.Value) }
    $url = "https://api.open-meteo.com/v1/forecast?" + ($pairs -join "&")
    $d = (Invoke-RestMethod -Uri $url -TimeoutSec 30).daily

    $rows = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $d.time.Count; $i++) {
        $dt = [datetime]$d.time[$i]
        $moonRS = Get-MoonRiseSet -localDate $dt -lat $Latitude -lon $Longitude
        $moonPI = Get-MoonPhaseInfo -localDate $dt
        # sunrise/sunset から HH:MM だけ抽出（"2026-06-25T04:59" → "04:59"）
        $srTime = if ($d.sunrise[$i]) { ($d.sunrise[$i] -replace '^.+T', '') } else { "--" }
        $ssTime = if ($d.sunset[$i])  { ($d.sunset[$i]  -replace '^.+T', '') } else { "--" }
        $rows.Add([pscustomobject]@{
            date       = $dt
            wcode      = $d.weather_code[$i]
            weather    = (Get-WeatherText $d.weather_code[$i])
            tmax       = $d.temperature_2m_max[$i]
            tmin       = $d.temperature_2m_min[$i]
            pop        = $d.precipitation_probability_max[$i]
            precip     = $d.precipitation_sum[$i]
            sunrise    = $srTime
            sunset     = $ssTime
            moonRise   = if ($moonRS.rise) { $moonRS.rise } else { "--" }
            moonSet    = if ($moonRS.set)  { $moonRS.set  } else { "--" }
            moonEmoji  = $moonPI.emoji
            moonName   = $moonPI.name
            moonAge    = [math]::Round($moonPI.age, 1)
        })
    }
    return $rows
}

function Build-Rows {
    param($data)
    $h = $data.hourly
    $rows = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $h.time.Count; $i++) {
        $dt  = [datetime]($h.time[$i] -replace 'T', ' ')
        $jd  = Get-JD -utc $dt.AddHours(-9)   # JST -> UTC
        # 晴れた昼間は実気温より低く出がちなため時間帯ごとに気温を補正（表示用）
        $hh = $dt.Hour
        $tAdj = if ($hh -ge 8 -and $hh -le 10) { 1 } elseif ($hh -ge 11 -and $hh -le 15) { 2 } elseif ($hh -ge 16 -and $hh -le 17) { 1 } else { 0 }
        $star = Get-StarIndex -jd $jd -lat $Latitude -lon $Longitude -totalCloud $h.cloud_cover[$i] -precip $h.precipitation[$i]
        $mAlt = Get-MoonAlt -jd $jd -lat $Latitude -lon $Longitude
        $mBri = Get-MoonBrightness -jd $jd -lat $Latitude -lon $Longitude
        $mPhase = Get-MoonPhase -jd $jd
        $mEmoji = @("🌑","🌒","🌓","🌔","🌕","🌖","🌗","🌘")[[int][math]::Round($mPhase*8)%8]
        $rows.Add([pscustomobject]@{
            time    = ($h.time[$i] -replace 'T', ' ')
            wcode   = $h.weather_code[$i]
            weather = (Get-WeatherText $h.weather_code[$i])
            temp    = $h.temperature_2m[$i]
            tempAdj = if ($null -eq $h.temperature_2m[$i]) { $null } else { [double]$h.temperature_2m[$i] + $tAdj }
            wind    = $h.wind_speed_10m[$i]
            pop     = $h.precipitation_probability[$i]
            precip  = $h.precipitation[$i]
            low     = $h.cloud_cover_low[$i]
            mid     = $h.cloud_cover_mid[$i]
            high    = $h.cloud_cover_high[$i]
            total   = $h.cloud_cover[$i]
            star    = $star
            moonAlt    = $mAlt
            moonBright = $mBri
            moonAge    = [int][math]::Round($mPhase * 29.53)
            moonEmoji  = $mEmoji
            isPast     = $false
            isNow      = $false
        })
    }
    # 当日0時以降をすべて返す（過去分はHTMLで薄く表示するため残す。4日分の末尾まで）
    $jstNow = Get-JstNow
    $nowHour = $jstNow.Date.AddHours($jstNow.Hour)
    $todayMidnight = $jstNow.Date
    $kept = @($rows | Where-Object { [datetime]$_.time -ge $todayMidnight })
    foreach ($r in $kept) {
        $r.isPast = ([datetime]$r.time -lt $nowHour)
        $r.isNow  = ([datetime]$r.time -eq $nowHour)
    }
    return $kept
}

# ---- コンソール表示 ----

function Show-Table {
    param($rows, $ApiElevation, $alerts)
    $elevLabel = if ($null -ne $Elevation) { "{0}m(指定)" -f $Elevation } else { "{0}m(自動)" -f $ApiElevation }
    $labelSuffix = if ($ModelLabel) { "  $ModelLabel" } else { "" }
    Write-Host ("地点: 緯度 {0} / 経度 {1} / 標高 {2}  (タイムゾーン: {3}){4}" -f $Latitude, $Longitude, $elevLabel, $Timezone, $labelSuffix)
    Write-Host ("取得時刻: {0:yyyy-MM-dd HH:mm} JST   気温=°C / 風速=m/s" -f (Get-JstNow))
    foreach ($line in (Render-AlertConsole $alerts)) { Write-Host $line }
    Write-Host ""
    $header = (Pad "日時" 18 -Left) + (Pad "天気" 10 -Left) + (Pad "気温" 7) + (Pad "風速" 7) +
              (Pad "雨量" 8) +
              (Pad "低層" 6) + (Pad "中層" 6) + (Pad "高層" 6) + (Pad "全雲量" 7) + (Pad "星空" 6)
    Write-Host $header
    Write-Host ("-" * (Get-DisplayWidth $header))
    foreach ($r in $rows) {
        $starTxt = if ($null -eq $r.star) { "--" } else { [string]$r.star }
        $line = (Pad $r.time 18 -Left) +
                (Pad $r.weather 10 -Left) +
                (Pad (Format-Temp $r.tempAdj) 7) +
                (Pad (Format-Wind $r.wind) 7) +
                (Pad (Format-Precip $r.precip) 8) +
                (Pad (Format-Pct $r.low) 6) +
                (Pad (Format-Pct $r.mid) 6) +
                (Pad (Format-Pct $r.high) 6) +
                (Pad (Format-Pct $r.total) 7) +
                (Pad $starTxt 6)
        Write-Host $line
    }
}

# ---- CSV ----

function Save-Csv {
    param($rows, [string]$path)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("日時,天気,気温℃,風速m/s,雨量mm,低層雲%,中層雲%,高層雲%,全雲量%,星空指数")
    foreach ($r in $rows) {
        $starCsv = if ($null -eq $r.star) { "" } else { [string]$r.star }
        [void]$sb.AppendLine(("{0},{1},{2},{3:0.0},{4:0.0},{5},{6},{7},{8},{9}" -f `
            $r.time, $r.weather, $r.temp, $r.wind, $r.precip, $r.low, $r.mid, $r.high, $r.total, $starCsv))
    }
    $enc = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($path, $sb.ToString(), $enc)
    Write-Host ""
    Write-Host ("CSV を保存しました: {0}" -f $path)
}

# ---- HTML ----

function Save-Html {
    param($rows, $daily, [string]$path, $ApiElevation, $alerts)

    $elevLabel  = if ($null -ne $Elevation) { "{0}m(指定)" -f $Elevation } else { "{0}m(自動)" -f $ApiElevation }
    $generated  = "{0:yyyy-MM-dd HH:mm} JST" -f (Get-JstNow)
    $startTime  = if ($rows.Count -gt 0) { $rows[0].time } else { "--" }
    $endTime    = if ($rows.Count -gt 0) { $rows[-1].time } else { "--" }
    $titleSuffix = if ($ModelLabel) { " $ModelLabel" } else { "" }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!DOCTYPE html><html lang="ja"><head><meta charset="utf-8">')
    [void]$sb.AppendLine('<meta name="viewport" content="width=device-width,initial-scale=1">')
    [void]$sb.AppendLine(("<title>1時間天気予報 - 四国カルスト姫鶴荘{0}</title>" -f $titleSuffix))
    [void]$sb.AppendLine('<style>')
    [void]$sb.AppendLine(@'
:root{font-family:"Segoe UI",system-ui,sans-serif;}
body{margin:0;background:#f5f7fa;color:#222;}
.wrap{max-width:100%;}
h1{font-size:18px;margin:14px 16px 2px;}
.meta{font-size:12px;color:#666;margin:0 16px 10px;}
.scroll{overflow-x:auto;border-top:1px solid #d8dde3;border-bottom:1px solid #d8dde3;background:#fff;}
table{border-collapse:collapse;white-space:nowrap;}
th,td{border:1px solid #e3e7ec;text-align:center;font-size:12px;padding:3px 4px;min-width:40px;}
th.rl{position:sticky;left:0;z-index:2;background:#eef1f5;text-align:right;min-width:62px;font-weight:600;color:#444;}
tr.date th{background:#f0f3f7;font-weight:600;color:#333;border-bottom:none;}
tr.hour th{background:#f7f9fb;color:#555;font-weight:500;}
td.ico{line-height:1;padding-top:4px;}
td.ico svg{display:block;margin:0 auto;}
td.ico .wt{font-size:11px;color:#555;margin-top:1px;font-weight:500;}
td.temp{font-weight:600;color:#c0392b;}
td.low{font-weight:700;}
.sat{color:#d6336c;}.sun{color:#1c7ed6;}
.legend{font-size:11px;color:#888;margin:8px 16px 16px;}
h2{font-size:16px;margin:18px 16px 6px;font-weight:600;}
.days{display:flex;gap:8px;overflow-x:auto;padding:0 16px 16px;}
.card{background:#fff;border:1px solid #e3e7ec;border-radius:10px;padding:10px 8px;min-width:102px;text-align:center;flex:0 0 auto;}
.card .dow{font-size:13px;font-weight:600;color:#444;}
.card .dt{font-size:11px;color:#888;margin-bottom:4px;}
.card .wt{font-size:11px;color:#555;margin:2px 0 4px;font-weight:500;}
.card .tmax{color:#c0392b;font-weight:600;font-size:14px;}
.card .tmin{color:#1c7ed6;font-size:13px;}
.card .pop{font-size:12px;margin-top:4px;}
.card .sunrow{font-size:11px;color:#c07000;margin-top:6px;letter-spacing:0.01em;}
.card .moonrow{font-size:12px;margin-top:3px;}
.card .moonrs{font-size:11px;color:#5c6bc0;margin-top:2px;}
.card.sat .dow{color:#1c7ed6;}.card.sun .dow{color:#d6336c;}
/* 日付行: 横スクロールしても日付ラベルが左に貼り付く */
tr.date th.dcell{text-align:left;background:#f0f3f7;border-bottom:none;padding:3px 0;}
tr.date th.dcell>span{position:sticky;left:64px;padding:0 8px;display:inline-block;font-weight:600;color:#333;}
tr.date th.dcell.datesat>span{color:#1c7ed6;}
tr.date th.dcell.datesun>span{color:#d6336c;}
/* 月の欄: 縦線なし。月が出ている時間帯を明るさに応じた薄黄でグラデーション */
td.moonband{border-left:none;border-right:none;font-size:10px;padding:2px 1px;color:#7a5c00;line-height:1.3;white-space:nowrap;}
b.arUp{color:#e8590c;font-size:13px;font-weight:900;}
b.arDn{color:#1565c0;font-size:13px;font-weight:900;}
td.starcell{font-weight:700;color:#3a3f7a;}
th.rl .lcl{font-size:9px;font-weight:600;}
th.nowcol{background:#fff3bf;color:#a15c00;font-weight:800;}
'@)
    [void]$sb.AppendLine($AlertCss)
    [void]$sb.AppendLine('</style>')
    [void]$sb.AppendLine('</head><body><div class="wrap">')
    [void]$sb.AppendLine(("<h1>1時間天気予報 — 四国カルスト 姫鶴荘{0}</h1>" -f $titleSuffix))
    $modelSuffix = if ($Models -and $Models -ne "best_match") { " ($Models)" } else { "" }
    [void]$sb.AppendLine(("<p class=""meta"">緯度 {0} / 経度 {1} / 標高 {2}　|　取得: {3}　|　{4} ～ {5}　|　出典: Open-Meteo{6}</p>" -f $Latitude, $Longitude, $elevLabel, $generated, $startTime, $endTime, $modelSuffix))
    [void]$sb.AppendLine((Render-AlertHtml $alerts))
    [void]$sb.AppendLine('<div class="scroll"><table>')

    # 過去の時刻のセルを薄く表示するため、td/thタグに opacity を後付けする
    function Dim-IfPast {
        param([string]$html, [bool]$isPast)
        if (-not $isPast) { return $html }
        if ($html -match '<(td|th)([^>]*)style="([^"]*)"') {
            return ($html -replace '<(td|th)([^>]*)style="([^"]*)"', '<$1$2style="opacity:.4;$3"')
        }
        return ($html -replace '<(td|th)([^>]*)>', '<$1$2 style="opacity:.4;">')
    }

    # 日付行: 各日を colspan でまとめ、ラベルを sticky にして横スクロール時も左に表示
    [void]$sb.Append('<tr class="date"><th class="rl">日付</th>')
    $idx = 0
    while ($idx -lt $rows.Count) {
        $dt = [datetime]$rows[$idx].time
        $d  = "{0:yyyy-MM-dd}" -f $dt
        $span = 0
        for ($j = $idx; $j -lt $rows.Count; $j++) {
            if (("{0:yyyy-MM-dd}" -f [datetime]$rows[$j].time) -eq $d) { $span++ } else { break }
        }
        $wd  = $JpWeek[[int]$dt.DayOfWeek]
        $cls = if ($dt.DayOfWeek -eq 'Saturday') { ' datesat' } elseif ($dt.DayOfWeek -eq 'Sunday') { ' datesun' } else { '' }
        [void]$sb.Append(("<th class=""dcell{0}"" colspan=""{1}""><span>{2}/{3}({4})</span></th>" -f $cls, $span, $dt.Month, $dt.Day, $wd))
        $idx += $span
    }
    [void]$sb.AppendLine('</tr>')

    # 時刻行（現在時刻のセルは強調し、id="nowcol"を付けて読み込み時にスクロール位置の目印にする）
    [void]$sb.Append('<tr class="hour"><th class="rl">時刻</th>')
    foreach ($r in $rows) {
        $dt = [datetime]$r.time
        $th = if ($r.isNow) { "<th id=""nowcol"" class=""nowcol"">{0}</th>" -f $dt.Hour } else { "<th>{0}</th>" -f $dt.Hour }
        [void]$sb.Append((Dim-IfPast -html $th -isPast $r.isPast))
    }
    [void]$sb.AppendLine('</tr>')

    function Row {
        param([string]$label, [scriptblock]$cell)
        [void]$sb.Append(("<tr><th class=""rl"">{0}</th>" -f $label))
        foreach ($r in $rows) { [void]$sb.Append((Dim-IfPast -html (& $cell $r) -isPast $r.isPast)) }
        [void]$sb.AppendLine('</tr>')
    }

    Row "天気"     { param($r) "<td class=""ico"">{0}<div class=""wt"">{1}</div></td>" -f (Get-WeatherSvg $r.wcode), $r.weather }
    Row '<span class="lcl">低層雲</span> 霧'  { param($r) "<td class=""low"" style=""{0}"">{1}</td>" -f (Cloud-Bg $r.low), $r.low }
    Row "気温℃"   { param($r) "<td class=""temp"">{0}</td>" -f [int][math]::Ceiling([double]$r.tempAdj) }
    Row "風速m/s"  { param($r)
        $wbg = if ($r.wind -ge 6) { ' style="background:#ffe0b2"' } elseif ($r.wind -ge 3) { ' style="background:#fff9c4"' } else { '' }
        "<td{0}>{1:0.0}</td>" -f $wbg, $r.wind
    }
    Row "雨量mm"   { param($r) "<td style=""{0}"">{1:0.0}</td>" -f (Rain-Bg $r.precip), $r.precip }
    Row "全雲量%"  { param($r) "<td style=""{0}"">{1}</td>" -f (Cloud-Bg $r.total), $r.total }

    # 月の欄: 月が出ている時間帯を明るさに応じた薄黄でグラデーション（縦線なし）
    # 出/南中/入りの正確時刻を毎時の月高度から補間し、月齢を出〜南中・南中〜入りの中間に表示
    $moonRise = @{}; $moonSet = @{}; $moonTransit = @{}; $ageAt = @{}
    for ($k = 0; $k -lt $rows.Count; $k++) {
        $a  = [double]$rows[$k].moonAlt
        $t  = [datetime]$rows[$k].time
        $pa = if ($k -gt 0)              { [double]$rows[$k-1].moonAlt } else { $null }
        $na = if ($k -lt $rows.Count-1)  { [double]$rows[$k+1].moonAlt } else { $null }
        if ($null -ne $pa -and $pa -lt 0 -and $a -ge 0) {
            $frac = (0 - $pa) / ($a - $pa)
            $moonRise[$k] = "{0:HH:mm}" -f $t.AddHours(-1).AddMinutes([int][math]::Round($frac*60))
        }
        if ($null -ne $pa -and $pa -ge 0 -and $a -lt 0) {
            $frac = $pa / ($pa - $a)
            $moonSet[$k] = "{0:HH:mm}" -f $t.AddHours(-1).AddMinutes([int][math]::Round($frac*60))
        }
        if ($null -ne $pa -and $null -ne $na -and $a -gt 0 -and $a -ge $pa -and $a -gt $na) {
            $den = $pa - 2*$a + $na
            $off = if ($den -ne 0) { 0.5 * ($pa - $na) / $den } else { 0 }
            $moonTransit[$k] = "{0:HH:mm}" -f $t.AddMinutes([int][math]::Round($off*60))
        }
    }
    foreach ($tk in $moonTransit.Keys) {
        $age = $rows[$tk].moonAge
        $em  = $rows[$tk].moonEmoji
        $rk = ($moonRise.Keys | Where-Object { $_ -le $tk } | Sort-Object -Descending | Select-Object -First 1)
        $sk = ($moonSet.Keys  | Where-Object { $_ -ge $tk } | Sort-Object | Select-Object -First 1)
        if ($null -ne $rk) { $ageAt[[int](($rk + $tk)/2)] = "$em 月齢$age" }
        if ($null -ne $sk) { $ageAt[[int](($tk + $sk)/2)] = "$em 月齢$age" }
    }
    [void]$sb.Append('<tr><th class="rl">月</th>')
    for ($k = 0; $k -lt $rows.Count; $k++) {
        $r = $rows[$k]; $a = [double]$r.moonAlt
        $label = ""
        if     ($moonRise.ContainsKey($k))    { $label = "🌙<b class=""arUp"">↑</b>" + $moonRise[$k] }
        elseif ($moonTransit.ContainsKey($k)) { $label = "南中" + $moonTransit[$k] }
        elseif ($moonSet.ContainsKey($k))     { $label = "<b class=""arDn"">↓</b>" + $moonSet[$k] + "🌙" }
        elseif ($ageAt.ContainsKey($k))       { $label = $ageAt[$k] }
        $style = ""
        if ($a -gt 0) {
            $L = 100 - [math]::Round([double]$r.moonBright * 0.35)   # 明るいほど濃い黄
            $style = " style=""background:hsl(50,90%,{0}%)""" -f $L
        }
        $td = "<td class=""moonband""{0}>{1}</td>" -f $style, $label
        [void]$sb.Append((Dim-IfPast -html $td -isPast $r.isPast))
    }
    [void]$sb.AppendLine('</tr>')

    Row "星空指数" { param($r)
        if ($null -eq $r.star) { '<td class="starcell">--</td>' }
        else { "<td class=""starcell"">{0}</td>" -f $r.star }
    }

    [void]$sb.AppendLine('</table></div>')
    [void]$sb.AppendLine('<p class="legend">※低層雲の数値が大きい程、霧が出やすく、濃い傾向があります。<br>※気温は晴れた昼間の気温が実際よりも低く出がちです。<br>※山の上は風速が標示よりも強くなります。３ｍ以上は風が強い。今後風が強まるのか弱まるのか傾向を見るのに使ってください。<br>※雨量は少し離れた場所が大雨予報の時に、(雨雲がズレるリスクを考慮して）大きく出る事が有ります。<br>※星空指数は、大きいほど星空観測に好条件。主に雲量・月明かりから計算。</p>')

    # ---- 週間予報 ----
    if ($daily -and $daily.Count -gt 0) {
        [void]$sb.AppendLine('<h2>週間天気予報</h2>')
        [void]$sb.AppendLine('<div class="days">')
        foreach ($r in $daily) {
            $wd  = $JpWeek[[int]$r.date.DayOfWeek]
            $cls = if ($r.date.DayOfWeek -eq 'Saturday') { 'card sat' } elseif ($r.date.DayOfWeek -eq 'Sunday') { 'card sun' } else { 'card' }
            $popTxt   = if ($null -eq $r.pop)    { "--" } else { "$($r.pop)%" }
            $popColor = if ($null -eq $r.pop)    { "#999" } elseif ($r.pop -ge 70) { "#1c7ed6" } elseif ($r.pop -ge 40) { "#378ADD" } else { "#8aa4c0" }
            $mmTxt    = if ($null -eq $r.precip) { "" } elseif ([double]$r.precip -ge 100) { (" {0:0}mm" -f $r.precip) } else { (" {0:0.#}mm" -f $r.precip) }

            [void]$sb.Append(("<div class=""{0}""><div class=""dow"">{1}</div><div class=""dt"">{2}/{3}</div>" -f $cls, $wd, $r.date.Month, $r.date.Day))
            [void]$sb.Append((Get-WeatherSvg $r.wcode))
            [void]$sb.Append(("<div class=""wt"">{0}</div>" -f $r.weather))
            [void]$sb.Append(("<div><span class=""tmax"">{0}°</span> <span class=""tmin"">{1}°</span></div>" -f [int][math]::Ceiling([double]$r.tmax + 2.0), [int][math]::Ceiling([double]$r.tmin)))
            [void]$sb.Append(("<div class=""pop""><span style=""font-size:11px;color:#888"">降水</span> <span style=""color:{0}"">{1}</span><span style=""color:#1c7ed6;font-size:11px"">{2}</span></div>" -f $popColor, $popTxt, $mmTxt))
            # 日の出・日の入り
            [void]$sb.Append(("<div class=""sunrow"">🌅{0}　🌇{1}</div>" -f $r.sunrise, $r.sunset))
            # 月相・月の出入り
            $ageInt = [int][math]::Round($r.moonAge)
            $moonLabel = switch ($ageInt) {
                0  { "新月" }; 3  { "三日月" }; 15 { "満月" }
                default { "月齢{0}日" -f $ageInt }
            }
            [void]$sb.Append(("<div class=""moonrow"">{0} {1}</div>" -f $r.moonEmoji, $moonLabel))
            [void]$sb.AppendLine(("<div class=""moonrs"">🌙<b class=""arUp"">↑</b>{0}　<b class=""arDn"">↓</b>{1}</div></div>" -f $r.moonRise, $r.moonSet))
        }
        [void]$sb.AppendLine('</div>')
    }

    [void]$sb.AppendLine('</div>')

    # 親ページ(WordPress等)へ自身の高さを通知し、iframeの高さを自動追従させる
    $autoHeight = @'
<script>
(function () {
  function postHeight() {
    var h = Math.max(
      document.body.scrollHeight, document.documentElement.scrollHeight,
      document.body.offsetHeight, document.documentElement.offsetHeight
    );
    if (window.parent !== window) {
      window.parent.postMessage({ type: 'karstweather-height', height: h }, '*');
    }
  }
  window.addEventListener('load', postHeight);
  window.addEventListener('resize', postHeight);
  if (window.ResizeObserver) {
    new ResizeObserver(postHeight).observe(document.body);
  }
  // フォント描画やレイアウト確定後の取りこぼし防止
  setTimeout(postHeight, 300);

  // 毎時テーブルを開いた時、現在時刻の列を左端の固定見出し列のすぐ右に来るようにスクロール
  // （左へスクロールすると当日0時までの過去分が見える）。見出し列の実幅を測ってその分だけ余分にずらす。
  function scrollToNow() {
    var nowCol = document.getElementById('nowcol');
    var scrollDiv = document.querySelector('.scroll');
    var labelCell = document.querySelector('th.rl');
    if (!nowCol || !scrollDiv) return;
    var labelWidth = labelCell ? labelCell.getBoundingClientRect().width : 0;
    var nowRect = nowCol.getBoundingClientRect();
    var scrollRect = scrollDiv.getBoundingClientRect();
    var target = (nowRect.left - scrollRect.left + scrollDiv.scrollLeft) - labelWidth;
    scrollDiv.scrollLeft = Math.max(0, target);
  }
  window.addEventListener('load', scrollToNow);
  setTimeout(scrollToNow, 300);
})();
</script>
'@
    [void]$sb.AppendLine($autoHeight)
    [void]$sb.AppendLine('</body></html>')

    $enc = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($path, $sb.ToString(), $enc)
    Write-Host ("HTML を保存しました: {0}" -f $path)
}

# ---- メイン ----
try {
    $data = Get-WeatherData
} catch {
    Write-Error ("取得に失敗しました: {0}" -f $_.Exception.Message)
    exit 1
}
$rows = Build-Rows -data $data
$futureRows = @($rows | Where-Object { -not $_.isPast })   # コンソール/CSV用（現在時刻以降のみ）

try {
    $alerts = Get-Alerts -areas $AlertAreas
} catch {
    Write-Warning ("警報・注意報の取得に失敗しました: {0}" -f $_.Exception.Message)
    $alerts = $null
}

Show-Table -rows $futureRows -ApiElevation $data.elevation -alerts $alerts

try {
    $daily = Get-DailyRows
} catch {
    Write-Warning ("週間予報の取得に失敗しました: {0}" -f $_.Exception.Message)
    $daily = $null
}

if ([string]::IsNullOrWhiteSpace($CsvPath)) {
    $CsvPath = Join-Path $PSScriptRoot "$OutName.csv"
}
try {
    Save-Csv -rows $futureRows -path $CsvPath
} catch {
    Write-Warning ("CSV を保存できませんでした（Excel等で開いていませんか？）: {0}" -f $_.Exception.Message)
}
try {
    Save-Html -rows $rows -daily $daily -path (Join-Path $PSScriptRoot "$OutName.html") -ApiElevation $data.elevation -alerts $alerts
} catch {
    Write-Warning ("HTML を保存できませんでした: {0}" -f $_.Exception.Message)
}
