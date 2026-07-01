<#
.SYNOPSIS
  Open-Meteo の best_match と ECMWF(ecmwf_ifs025) を平均した「平均版」天気予報を出力する。

.DESCRIPTION
  - 数値（気温/風速/降水確率/降水量/各雲量）は best_match と ECMWF の単純平均。
  - 天気コードは平均できないため、平均した降水量・降雪量・雲量から毎時の天気を再判定する
    （Derive-HourlyWeather）。雷雨は両モデルいずれかが雷雨コードなら最優先。
  - 週間予報は日別APIを使わず、平均した毎時7日分から複合表現（のち/時々/一時）を組み立てる
    （Build-CompoundWeekly / Weekly-IconCode）。ただし日の出・日の入りはモデル差がないため
    best_match の日別APIから取得する。
  - 詳細はプロジェクトの引き継ぎ書 7-2 節を参照。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\lowcloud_avg.ps1
#>

[CmdletBinding()]
param(
    [double]$Latitude    = 33.4666147,
    [double]$Longitude   = 132.9610114,
    [Nullable[double]]$Elevation = 1380,
    [int]   $ForecastDays = 7,    # 平均版は毎時7日分を取得し、週間もそこから算出する
    [int]   $WeeklyDays  = 7,
    [string]$Timezone    = "Asia/Tokyo",
    [string]$CsvPath     = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lowcloud_common.ps1")

$ModelLabel = "[平均(best_match+ECMWF)]"
$OutName    = "lowcloud_avg"

# 気象警報・注意報の対象区域（区域コード＝全国地方公共団体コード(5桁)×100）
$AlertAreas = @(
    @{ name = "久万高原町"; code = "3838600"; pref = "380000" },
    @{ name = "梼原町";     code = "3940500"; pref = "390000" }
)

# ---- 数値ヘルパー ----

function Or0  { param($v); if ($null -eq $v) { 0.0 } else { [double]$v } }
function Avg2 {
    param($a, $b)
    if ($null -eq $a -and $null -eq $b) { return $null }
    if ($null -eq $a) { return [double]$b }
    if ($null -eq $b) { return [double]$a }
    return ([double]$a + [double]$b) / 2.0
}

# ---- データ取得 ----

$AvgHourlyVars = "weather_code,temperature_2m,wind_speed_10m,precipitation_probability,precipitation,snowfall,cloud_cover_low,cloud_cover_mid,cloud_cover_high,cloud_cover"

function Get-ModelHourly {
    param([string]$model)
    $query = @{
        latitude = $Latitude; longitude = $Longitude; hourly = $AvgHourlyVars
        timezone = $Timezone; forecast_days = $ForecastDays; wind_speed_unit = "ms"; models = $model
    }
    if ($null -ne $Elevation) { $query["elevation"] = $Elevation }
    $pairs = $query.GetEnumerator() | ForEach-Object { "{0}={1}" -f $_.Key, [uri]::EscapeDataString([string]$_.Value) }
    $url = "https://api.open-meteo.com/v1/forecast?" + ($pairs -join "&")
    return (Invoke-RestMethod -Uri $url -TimeoutSec 30).hourly
}

# 日の出・日の入りだけは best_match の日別API から取得する（モデル間差がほぼ無いため）
function Get-SunTimes {
    $query = @{ latitude = $Latitude; longitude = $Longitude; daily = "sunrise,sunset"; timezone = $Timezone; forecast_days = $WeeklyDays }
    if ($null -ne $Elevation) { $query["elevation"] = $Elevation }
    $pairs = $query.GetEnumerator() | ForEach-Object { "{0}={1}" -f $_.Key, [uri]::EscapeDataString([string]$_.Value) }
    $url = "https://api.open-meteo.com/v1/forecast?" + ($pairs -join "&")
    $d = (Invoke-RestMethod -Uri $url -TimeoutSec 30).daily
    $map = @{}
    for ($i = 0; $i -lt $d.time.Count; $i++) {
        $sr = if ($d.sunrise[$i]) { ($d.sunrise[$i] -replace '^.+T', '') } else { "--" }
        $ss = if ($d.sunset[$i])  { ($d.sunset[$i]  -replace '^.+T', '') } else { "--" }
        $map[$d.time[$i]] = @{ sunrise = $sr; sunset = $ss }
    }
    return $map
}

# ---- 平均版だけの天気判定（数値から毎時の天気を導出） ----

# 毎時の天気（判定順 ⓪雷雨 → ①雪・みぞれ → ②雨 → ③晴れ/曇り）
function Derive-HourlyWeather {
    param($codeA, $codeB, [double]$precip, [double]$snow, [double]$total)
    $thunderCodes = @(95, 96, 99)
    if (($null -ne $codeA -and $thunderCodes -contains [int]$codeA) -or
        ($null -ne $codeB -and $thunderCodes -contains [int]$codeB)) {
        return @{ key = "thunder"; label = "雷雨" }
    }
    if ($snow -gt 0) {
        if ($precip -gt 0.1) { return @{ key = "sleet"; label = "みぞれ" } }
        if ($snow -lt 0.5)   { return @{ key = "snow_weak"; label = "弱い雪" } }
        if ($snow -lt 2)     { return @{ key = "snow"; label = "雪" } }
        return @{ key = "snow_heavy"; label = "大雪" }
    }
    if ($precip -ge 0.1) {
        if ($precip -lt 1)  { return @{ key = "drizzle"; label = "霧雨" } }
        if ($precip -lt 3)  { return @{ key = "rain_weak"; label = "弱い雨" } }
        if ($precip -lt 10) { return @{ key = "rain"; label = "雨" } }
        if ($precip -lt 20) { return @{ key = "rain_mod"; label = "やや強い雨" } }
        if ($precip -lt 30) { return @{ key = "rain_strong"; label = "強い雨" } }
        if ($precip -lt 50) { return @{ key = "rain_heavy"; label = "激しい雨" } }
        if ($precip -lt 80) { return @{ key = "rain_veryheavy"; label = "非常に激しい雨" } }
        return @{ key = "rain_violent"; label = "猛烈な雨" }
    }
    if ($total -le 15) { return @{ key = "clear";   label = "快晴" } }
    if ($total -le 50) { return @{ key = "mclear";  label = "晴れ" } }
    if ($total -le 80) { return @{ key = "pcloudy"; label = "薄曇" } }
    return @{ key = "cloudy"; label = "曇り" }
}

# 内部天気キー → 既存SVGアイコンキー
function Get-AvgIconKey {
    param([string]$key)
    switch ($key) {
        "thunder"        { return "thunder" }
        "sleet"          { return "snow" }
        "snow_weak"      { return "snow" }
        "snow"           { return "snow" }
        "snow_heavy"     { return "hsnow" }
        "drizzle"        { return "drizzle" }
        "rain_weak"      { return "lrain" }
        "clear"          { return "clear" }
        "mclear"         { return "mclear" }
        "pcloudy"        { return "pcloudy" }
        "cloudy"         { return "cloudy" }
        default          { return "rain" }   # rain/rain_mod/rain_strong/rain_heavy/rain_veryheavy/rain_violent
    }
}

# 内部天気キー → 粗い区分（晴/曇/雨/雪/雷）。複合文言の元になる。
function Class-Of {
    param([string]$key)
    switch ($key) {
        "clear"  { return "晴" }
        "mclear" { return "晴" }
        "pcloudy"{ return "曇" }
        "cloudy" { return "曇" }
        "thunder"{ return "雷" }
        default {
            if ($key -eq "drizzle" -or $key -like "rain*") { return "雨" }
            if ($key -eq "sleet"   -or $key -like "snow*") { return "雪" }
            return "曇"
        }
    }
}

function Class-Label {
    param([string]$cls)
    switch ($cls) {
        "晴" { return "晴れ" }
        "曇" { return "曇り" }
        "雨" { return "雨" }
        "雪" { return "雪" }
        "雷" { return "雨" }   # 雷は文言上は雨に折り込み、アイコンだけ別途最優先で雷にする
        default { return $cls }
    }
}

# 1日の日中(6-18時)の粗区分配列から複合表現を組み立てる
function Compound-Text {
    param([string[]]$classes)
    $n = $classes.Count
    if ($n -eq 0) { return @{ text = "--"; pattern = "none"; primary = $null; secondary = $null } }

    $counts = @{}
    foreach ($c in $classes) {
        if (-not $counts.ContainsKey($c)) { $counts[$c] = 0 }
        $counts[$c] = $counts[$c] + 1
    }
    $primary = ($counts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key

    $half = [int][math]::Ceiling($n / 2.0)
    $firstHalf  = $classes[0..($half - 1)]
    $secondHalf = if ($n -gt $half) { $classes[$half..($n - 1)] } else { @() }

    $cf = @{}; foreach ($c in $firstHalf)  { if (-not $cf.ContainsKey($c)) { $cf[$c] = 0 }; $cf[$c]++ }
    $cs = @{}; foreach ($c in $secondHalf) { if (-not $cs.ContainsKey($c)) { $cs[$c] = 0 }; $cs[$c]++ }
    $domFirst  = if ($cf.Count -gt 0) { ($cf.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key } else { $null }
    $domSecond = if ($cs.Count -gt 0) { ($cs.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key } else { $null }
    $domFirstShare  = if ($domFirst  -and $firstHalf.Count  -gt 0) { $cf[$domFirst]  / [double]$firstHalf.Count }  else { 0 }
    $domSecondShare = if ($domSecond -and $secondHalf.Count -gt 0) { $cs[$domSecond] / [double]$secondHalf.Count } else { 0 }

    if ($domFirst -and $domSecond -and $domFirst -ne $domSecond -and $domFirstShare -ge 0.6 -and $domSecondShare -ge 0.6) {
        $text = "{0}のち{1}" -f (Class-Label $domFirst), (Class-Label $domSecond)
        return @{ text = $text; pattern = "のち"; primary = $domFirst; secondary = $domSecond }
    }

    # 副次クラス（主以外で最多のもの）
    $secKey = $null; $secCount = 0
    foreach ($kv in $counts.GetEnumerator()) {
        if ($kv.Key -ne $primary -and $kv.Value -gt $secCount) { $secKey = $kv.Key; $secCount = $kv.Value }
    }
    if (-not $secKey) {
        return @{ text = (Class-Label $primary); pattern = "single"; primary = $primary; secondary = $null }
    }

    # 副次クラスの連続区間(run)数
    $runs = 0; $prevIsSec = $false
    foreach ($c in $classes) {
        $isSec = ($c -eq $secKey)
        if ($isSec -and -not $prevIsSec) { $runs++ }
        $prevIsSec = $isSec
    }

    if ($secCount -le 3 -and $runs -le 1) {
        return @{ text = ("{0}一時{1}" -f (Class-Label $primary), (Class-Label $secKey)); pattern = "一時"; primary = $primary; secondary = $secKey }
    }
    if ($secCount -lt ($n / 2.0)) {
        return @{ text = ("{0}時々{1}" -f (Class-Label $primary), (Class-Label $secKey)); pattern = "時々"; primary = $primary; secondary = $secKey }
    }
    return @{ text = ("{0}のち{1}" -f (Class-Label $primary), (Class-Label $secKey)); pattern = "のち"; primary = $primary; secondary = $secKey }
}

# 1日分の毎時行(averaged)から複合表現・雷有無・日雨量/雪量を組み立てる
function Build-CompoundWeekly {
    param($dayRowsAll)
    $daytime = @($dayRowsAll | Where-Object { $h = ([datetime]$_.time).Hour; $h -ge 6 -and $h -le 18 })
    $classes = @()
    foreach ($r in $daytime) {
        $c = Class-Of $r.wkey
        if ($c -eq "雷") { $c = "雨" }   # 雷は文言上「雨」に折り込む（アイコンはhasThunderで別途最優先）
        $classes += $c
    }
    $ct = Compound-Text -classes $classes

    $hasThunder = $false
    $rainSum = 0.0; $snowSum = 0.0
    foreach ($r in $dayRowsAll) {
        if ($r.wkey -eq "thunder") { $hasThunder = $true }
        $rainSum += (Or0 $r.precip)
        $snowSum += (Or0 $r.snow)
    }
    return @{ text = $ct.text; pattern = $ct.pattern; primary = $ct.primary; secondary = $ct.secondary; hasThunder = $hasThunder; rainSum = $rainSum; snowSum = $snowSum }
}

# 複合表現から週間カードのアイコンキーを決める
function Weekly-IconCode {
    param($cw)
    $text = $cw.text
    $icon = "cloudy"
    if ($text -match "晴" -and $text -match "曇") {
        $icon = "pcloudy"
    } elseif ($cw.primary -eq "晴" -and $cw.secondary -eq "雨" -and ($cw.pattern -eq "一時" -or $cw.pattern -eq "時々")) {
        $icon = "pcloudy"
    } elseif ($cw.pattern -eq "一時") {
        $icon = switch ($cw.primary) {
            "晴" { "clear" }
            "曇" { "cloudy" }
            "雨" { if ($cw.rainSum -lt 10) { "drizzle" } elseif ($cw.rainSum -lt 40) { "lrain" } else { "rain" } }
            "雪" { "snow" }
            default { "cloudy" }
        }
    } elseif ($cw.pattern -eq "single" -and $cw.primary -eq "晴") {
        $icon = "clear"
    } else {
        $icon = switch ($cw.primary) {
            "晴" { "clear" }
            "曇" { "cloudy" }
            "雨" { if ($cw.rainSum -lt 10) { "drizzle" } elseif ($cw.rainSum -lt 40) { "lrain" } else { "rain" } }
            "雪" { "snow" }
            default { "cloudy" }
        }
    }
    if ($cw.hasThunder) { $icon = "thunder" }
    return $icon
}

# ---- 毎時行の構築（2モデル平均＋天気導出） ----

function Build-AvgRows {
    param($hA, $hB)
    $bIndex = @{}
    for ($j = 0; $j -lt $hB.time.Count; $j++) { $bIndex[$hB.time[$j]] = $j }

    $rows = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $hA.time.Count; $i++) {
        $t = $hA.time[$i]
        $j = if ($bIndex.ContainsKey($t)) { $bIndex[$t] } else { $null }

        $bTemp = $null; $bWind = $null; $bPop = $null; $bPrec = $null; $bSnow = $null
        $bLow  = $null; $bMid  = $null; $bHigh = $null; $bTot  = $null; $codeB = $null
        if ($null -ne $j) {
            $bTemp = $hB.temperature_2m[$j]
            $bWind = $hB.wind_speed_10m[$j]
            $bPop  = $hB.precipitation_probability[$j]
            $bPrec = $hB.precipitation[$j]
            $bSnow = $hB.snowfall[$j]
            $bLow  = $hB.cloud_cover_low[$j]
            $bMid  = $hB.cloud_cover_mid[$j]
            $bHigh = $hB.cloud_cover_high[$j]
            $bTot  = $hB.cloud_cover[$j]
            $codeB = $hB.weather_code[$j]
        }
        $tempAvg = Avg2 $hA.temperature_2m[$i] $bTemp
        $windAvg = Avg2 $hA.wind_speed_10m[$i] $bWind
        $popAvg  = Avg2 $hA.precipitation_probability[$i] $bPop
        $precAvg = Avg2 $hA.precipitation[$i] $bPrec
        $snowAvg = Avg2 $hA.snowfall[$i] $bSnow
        $lowAvg  = Avg2 $hA.cloud_cover_low[$i] $bLow
        $midAvg  = Avg2 $hA.cloud_cover_mid[$i] $bMid
        $highAvg = Avg2 $hA.cloud_cover_high[$i] $bHigh
        $totAvg  = Avg2 $hA.cloud_cover[$i] $bTot
        $codeA   = $hA.weather_code[$i]

        $derived = Derive-HourlyWeather -codeA $codeA -codeB $codeB -precip (Or0 $precAvg) -snow (Or0 $snowAvg) -total (Or0 $totAvg)

        $dt  = [datetime]($t -replace 'T', ' ')
        $jd  = Get-JD -utc $dt.AddHours(-9)
        $hh  = $dt.Hour
        $tAdj = if ($hh -ge 8 -and $hh -le 10) { 1 } elseif ($hh -ge 11 -and $hh -le 15) { 2 } elseif ($hh -ge 16 -and $hh -le 17) { 1 } else { 0 }
        $star = Get-StarIndex -jd $jd -lat $Latitude -lon $Longitude -totalCloud $totAvg -precip $precAvg
        $mAlt = Get-MoonAlt -jd $jd -lat $Latitude -lon $Longitude
        $mBri = Get-MoonBrightness -jd $jd -lat $Latitude -lon $Longitude
        $mPhase = Get-MoonPhase -jd $jd
        $mEmoji = @("🌑","🌒","🌓","🌔","🌕","🌖","🌗","🌘")[[int][math]::Round($mPhase * 8) % 8]

        $rows.Add([pscustomobject]@{
            time    = ($t -replace 'T', ' ')
            wkey    = $derived.key
            weather = $derived.label
            temp    = $tempAvg
            tempAdj = if ($null -eq $tempAvg) { $null } else { $tempAvg + $tAdj }
            wind    = $windAvg
            pop     = $popAvg
            precip  = (Or0 $precAvg)
            snow    = (Or0 $snowAvg)
            low     = $lowAvg
            mid     = $midAvg
            high    = $highAvg
            total   = $totAvg
            star    = $star
            moonAlt    = $mAlt
            moonBright = $mBri
            moonAge    = [int][math]::Round($mPhase * 29.53)
            moonEmoji  = $mEmoji
        })
    }
    return $rows
}

# ---- 週間カードの構築（毎時から集計、日の出入りのみ別途取得） ----

function Build-AvgDaily {
    param($allRows, $sunMap, [int]$days)
    $grouped = $allRows | Group-Object { ([datetime]$_.time).Date } | Sort-Object Name
    $daily = New-Object System.Collections.Generic.List[object]
    $count = 0
    foreach ($g in $grouped) {
        if ($count -ge $days) { break }
        $date = [datetime]$g.Name
        $dayRows = @($g.Group)

        $cw = Build-CompoundWeekly -dayRowsAll $dayRows
        $icon = Weekly-IconCode -cw $cw

        $rawTemps = @($dayRows | ForEach-Object { $_.temp } | Where-Object { $null -ne $_ })
        $tmaxRaw = if ($rawTemps.Count -gt 0) { ($rawTemps | Measure-Object -Maximum).Maximum } else { $null }
        $tminRaw = if ($rawTemps.Count -gt 0) { ($rawTemps | Measure-Object -Minimum).Minimum } else { $null }

        $pops = @($dayRows | ForEach-Object { $_.pop } | Where-Object { $null -ne $_ })
        $popMax = if ($pops.Count -gt 0) { ($pops | Measure-Object -Maximum).Maximum } else { $null }

        $moonRS = Get-MoonRiseSet -localDate $date -lat $Latitude -lon $Longitude
        $moonPI = Get-MoonPhaseInfo -localDate $date
        $dkey = "{0:yyyy-MM-dd}" -f $date
        $sun = if ($sunMap.ContainsKey($dkey)) { $sunMap[$dkey] } else { @{ sunrise = "--"; sunset = "--" } }

        $daily.Add([pscustomobject]@{
            date      = $date
            icon      = $icon
            weather   = $cw.text
            tmax      = $tmaxRaw
            tmin      = $tminRaw
            pop       = $popMax
            precip    = $cw.rainSum
            sunrise   = $sun.sunrise
            sunset    = $sun.sunset
            moonRise  = if ($moonRS.rise) { $moonRS.rise } else { "--" }
            moonSet   = if ($moonRS.set)  { $moonRS.set  } else { "--" }
            moonEmoji = $moonPI.emoji
            moonAge   = [math]::Round($moonPI.age, 1)
        })
        $count++
    }
    return $daily
}

# ---- コンソール表示 ----

function Show-AvgTable {
    param($rows, $alerts)
    Write-Host ("地点: 緯度 {0} / 経度 {1} / 標高 {2}m(指定)  (タイムゾーン: {3})  {4}" -f $Latitude, $Longitude, $Elevation, $Timezone, $ModelLabel)
    Write-Host ("取得時刻: {0:yyyy-MM-dd HH:mm}   気温=°C / 風速=m/s" -f (Get-Date))
    foreach ($line in (Render-AlertConsole $alerts)) { Write-Host $line }
    Write-Host ""
    $header = (Pad "日時" 18 -Left) + (Pad "天気" 12 -Left) + (Pad "気温" 7) + (Pad "風速" 7) +
              (Pad "降水" 6) + (Pad "雨量" 8) +
              (Pad "低層" 6) + (Pad "中層" 6) + (Pad "高層" 6) + (Pad "全雲量" 7) + (Pad "星空" 6)
    Write-Host $header
    Write-Host ("-" * (Get-DisplayWidth $header))
    foreach ($r in $rows) {
        $starTxt = if ($null -eq $r.star) { "--" } else { [string]$r.star }
        $line = (Pad $r.time 18 -Left) +
                (Pad $r.weather 12 -Left) +
                (Pad (Format-Temp $r.tempAdj) 7) +
                (Pad (Format-Wind $r.wind) 7) +
                (Pad (Format-Pct $r.pop) 6) +
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

function Save-AvgCsv {
    param($rows, [string]$path)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("日時,天気,気温℃,風速m/s,降水確率%,雨量mm,低層雲%,中層雲%,高層雲%,全雲量%,星空指数")
    foreach ($r in $rows) {
        $starCsv = if ($null -eq $r.star) { "" } else { [string]$r.star }
        [void]$sb.AppendLine(("{0},{1},{2:0.0},{3:0.0},{4},{5:0.0},{6:0},{7:0},{8:0},{9:0},{10}" -f `
            $r.time, $r.weather, $r.temp, $r.wind, $r.pop, $r.precip, $r.low, $r.mid, $r.high, $r.total, $starCsv))
    }
    $enc = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($path, $sb.ToString(), $enc)
    Write-Host ""
    Write-Host ("CSV を保存しました: {0}" -f $path)
}

# ---- HTML ----

function Save-AvgHtml {
    param($rows, $daily, [string]$path, $alerts)

    $generated = "{0:yyyy-MM-dd HH:mm}" -f (Get-Date)
    $startTime = if ($rows.Count -gt 0) { $rows[0].time } else { "--" }
    $endTime   = if ($rows.Count -gt 0) { $rows[-1].time } else { "--" }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!DOCTYPE html><html lang="ja"><head><meta charset="utf-8">')
    [void]$sb.AppendLine('<meta name="viewport" content="width=device-width,initial-scale=1">')
    [void]$sb.AppendLine(("<title>1時間天気予報 - 四国カルスト姫鶴荘 {0}</title>" -f $ModelLabel))
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
.card{background:#fff;border:1px solid #e3e7ec;border-radius:10px;padding:10px 8px;min-width:112px;text-align:center;flex:0 0 auto;}
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
tr.date th.dcell{text-align:left;background:#f0f3f7;border-bottom:none;padding:3px 0;}
tr.date th.dcell>span{position:sticky;left:64px;padding:0 8px;display:inline-block;font-weight:600;color:#333;}
tr.date th.dcell.datesat>span{color:#1c7ed6;}
tr.date th.dcell.datesun>span{color:#d6336c;}
td.moonband{border-left:none;border-right:none;font-size:10px;padding:2px 1px;color:#7a5c00;line-height:1.3;white-space:nowrap;}
b.arUp{color:#e8590c;font-size:13px;font-weight:900;}
b.arDn{color:#1565c0;font-size:13px;font-weight:900;}
td.starcell{font-weight:700;color:#3a3f7a;}
th.rl .lcl{font-size:9px;font-weight:600;}
'@)
    [void]$sb.AppendLine($AlertCss)
    [void]$sb.AppendLine('</style>')
    [void]$sb.AppendLine('</head><body><div class="wrap">')
    [void]$sb.AppendLine(("<h1>1時間天気予報 — 四国カルスト 姫鶴荘 {0}</h1>" -f $ModelLabel))
    [void]$sb.AppendLine(("<p class=""meta"">緯度 {0} / 経度 {1} / 標高 {2}m(指定)　|　取得: {3}　|　{4} ～ {5}　|　出典: Open-Meteo(best_match+ECMWF平均)</p>" -f $Latitude, $Longitude, $Elevation, $generated, $startTime, $endTime))
    [void]$sb.AppendLine((Render-AlertHtml $alerts))
    [void]$sb.AppendLine('<div class="scroll"><table>')

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

    [void]$sb.Append('<tr class="hour"><th class="rl">時刻</th>')
    foreach ($r in $rows) {
        $dt = [datetime]$r.time
        [void]$sb.Append(("<th>{0}</th>" -f $dt.Hour))
    }
    [void]$sb.AppendLine('</tr>')

    function Row {
        param([string]$label, [scriptblock]$cell)
        [void]$sb.Append(("<tr><th class=""rl"">{0}</th>" -f $label))
        foreach ($r in $rows) { [void]$sb.Append((& $cell $r)) }
        [void]$sb.AppendLine('</tr>')
    }

    Row "天気" { param($r) "<td class=""ico"">{0}<div class=""wt"">{1}</div></td>" -f $WeatherSvg[(Get-AvgIconKey $r.wkey)], $r.weather }
    Row '<span class="lcl">低層雲</span> 霧' { param($r) "<td class=""low"" style=""{0}"">{1:0}</td>" -f (Cloud-Bg $r.low), $r.low }
    Row "気温℃" { param($r) "<td class=""temp"">{0}</td>" -f [int][math]::Ceiling([double]$r.tempAdj) }
    Row "風速m/s" { param($r)
        $wbg = if ($r.wind -ge 6) { ' style="background:#ffe0b2"' } elseif ($r.wind -ge 3) { ' style="background:#fff9c4"' } else { '' }
        "<td{0}>{1:0.0}</td>" -f $wbg, $r.wind
    }
    Row "降水確率" { param($r)
        if ($null -eq $r.pop) { '<td>--</td>' } else { "<td style=""{0}"">{1:0}%</td>" -f (Pop-Bg $r.pop), $r.pop }
    }
    Row "雨量mm" { param($r) "<td style=""{0}"">{1:0.0}</td>" -f (Rain-Bg $r.precip), $r.precip }
    Row "全雲量%" { param($r) "<td style=""{0}"">{1:0}</td>" -f (Cloud-Bg $r.total), $r.total }

    $moonRise = @{}; $moonSet = @{}; $moonTransit = @{}; $ageAt = @{}
    for ($k = 0; $k -lt $rows.Count; $k++) {
        $a  = [double]$rows[$k].moonAlt
        $t  = [datetime]$rows[$k].time
        $pa = if ($k -gt 0)             { [double]$rows[$k-1].moonAlt } else { $null }
        $na = if ($k -lt $rows.Count-1) { [double]$rows[$k+1].moonAlt } else { $null }
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
            $L = 100 - [math]::Round([double]$r.moonBright * 0.35)
            $style = " style=""background:hsl(50,90%,{0}%)""" -f $L
        }
        [void]$sb.Append(("<td class=""moonband""{0}>{1}</td>" -f $style, $label))
    }
    [void]$sb.AppendLine('</tr>')

    Row "星空指数" { param($r)
        if ($null -eq $r.star) { '<td class="starcell">--</td>' }
        else { "<td class=""starcell"">{0}</td>" -f $r.star }
    }

    [void]$sb.AppendLine('</table></div>')
    [void]$sb.AppendLine('<p class="legend">※本ページは best_match と ECMWF(ecmwf_ifs025) の平均値です。天気・週間の文言は数値から機械的に推定した近似表現で、気象庁の予報文とは一致しません。<br>※低層雲の数値が大きい程、霧が出やすく、濃い傾向があります。<br>※気温は晴れた昼間の気温が実際よりも低く出がちです。<br>※山の上は風速が標示よりも強くなります。３ｍ以上は風が強い。<br>※星空指数は、大きいほど星空観測に好条件。主に雲量・月明かりから計算。</p>')

    if ($daily -and $daily.Count -gt 0) {
        [void]$sb.AppendLine('<h2>週間天気予報</h2>')
        [void]$sb.AppendLine('<div class="days">')
        foreach ($r in $daily) {
            $wd  = $JpWeek[[int]$r.date.DayOfWeek]
            $cls = if ($r.date.DayOfWeek -eq 'Saturday') { 'card sat' } elseif ($r.date.DayOfWeek -eq 'Sunday') { 'card sun' } else { 'card' }
            $popTxt   = if ($null -eq $r.pop) { "--" } else { "{0:0}%" -f $r.pop }
            $popColor = if ($null -eq $r.pop) { "#999" } elseif ($r.pop -ge 70) { "#1c7ed6" } elseif ($r.pop -ge 40) { "#378ADD" } else { "#8aa4c0" }
            $mmTxt    = if ($null -eq $r.precip) { "" } elseif ([double]$r.precip -ge 100) { (" {0:0}mm" -f $r.precip) } else { (" {0:0.#}mm" -f $r.precip) }

            [void]$sb.Append(("<div class=""{0}""><div class=""dow"">{1}</div><div class=""dt"">{2}/{3}</div>" -f $cls, $wd, $r.date.Month, $r.date.Day))
            [void]$sb.Append($WeatherSvg[$r.icon])
            [void]$sb.Append(("<div class=""wt"">{0}</div>" -f $r.weather))
            $tmaxTxt = if ($null -eq $r.tmax) { "--" } else { "{0}°" -f [int][math]::Ceiling([double]$r.tmax + 2.0) }
            $tminTxt = if ($null -eq $r.tmin) { "--" } else { "{0}°" -f [int][math]::Ceiling([double]$r.tmin) }
            [void]$sb.Append(("<div><span class=""tmax"">{0}</span> <span class=""tmin"">{1}</span></div>" -f $tmaxTxt, $tminTxt))
            [void]$sb.Append(("<div class=""pop""><span style=""font-size:11px;color:#888"">降水</span> <span style=""color:{0}"">{1}</span><span style=""color:#1c7ed6;font-size:11px"">{2}</span></div>" -f $popColor, $popTxt, $mmTxt))
            [void]$sb.Append(("<div class=""sunrow"">🌅{0}　🌇{1}</div>" -f $r.sunrise, $r.sunset))
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
  setTimeout(postHeight, 300);
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
    $hA = Get-ModelHourly -model "best_match"
    $hB = Get-ModelHourly -model "ecmwf_ifs025"
} catch {
    Write-Error ("取得に失敗しました: {0}" -f $_.Exception.Message)
    exit 1
}
$allRows = Build-AvgRows -hA $hA -hB $hB
$nowHour = (Get-Date).Date.AddHours((Get-Date).Hour)
$rows = @($allRows | Where-Object { [datetime]$_.time -ge $nowHour })

try {
    $alerts = Get-Alerts -areas $AlertAreas
} catch {
    Write-Warning ("警報・注意報の取得に失敗しました: {0}" -f $_.Exception.Message)
    $alerts = $null
}

Show-AvgTable -rows $rows -alerts $alerts

try {
    $sunMap = Get-SunTimes
    $daily = Build-AvgDaily -allRows $allRows -sunMap $sunMap -days $WeeklyDays
} catch {
    Write-Warning ("週間予報の算出に失敗しました: {0}" -f $_.Exception.Message)
    $daily = $null
}

if ([string]::IsNullOrWhiteSpace($CsvPath)) {
    $CsvPath = Join-Path $PSScriptRoot "$OutName.csv"
}
try {
    Save-AvgCsv -rows $rows -path $CsvPath
} catch {
    Write-Warning ("CSV を保存できませんでした（Excel等で開いていませんか？）: {0}" -f $_.Exception.Message)
}
try {
    Save-AvgHtml -rows $rows -daily $daily -path (Join-Path $PSScriptRoot "$OutName.html") -alerts $alerts
} catch {
    Write-Warning ("HTML を保存できませんでした: {0}" -f $_.Exception.Message)
}
