<#
.SYNOPSIS
  lowcloud.ps1 / lowcloud_ec.ps1 / lowcloud_avg.ps1 で共有する関数・データ定義。
  各スクリプトの先頭で ". (Join-Path $PSScriptRoot 'lowcloud_common.ps1')" として読み込む。
#>

# ---- 天気コード→文言／アイコン ----

$WeatherText = @{
    0 = "快晴"; 1 = "晴れ"; 2 = "薄曇"; 3 = "曇り"
    45 = "霧"; 48 = "霧氷"
    51 = "弱霧雨"; 53 = "霧雨"; 55 = "強霧雨"; 56 = "着氷霧雨"; 57 = "着氷霧雨"
    61 = "弱い雨"; 63 = "雨"; 65 = "強い雨"; 66 = "着氷雨"; 67 = "着氷雨"
    71 = "弱い雪"; 73 = "雪"; 75 = "強い雪"; 77 = "霧雪"
    80 = "弱雨"; 81 = "にわか雨"; 82 = "激しい雨"
    85 = "弱雪"; 86 = "にわか雪"
    95 = "雷雨"; 96 = "雹雷雨"; 99 = "雹雷雨"
}

function Get-WeatherText {
    param($code)
    if ($null -eq $code) { return "--" }
    if ($WeatherText.ContainsKey([int]$code)) { return $WeatherText[[int]$code] }
    return "?($code)"
}

$WeatherSvg = @{
    clear   = '<svg viewBox="0 0 24 24" width="30" height="30"><circle cx="12" cy="12" r="5" fill="#EF9F27"/><g stroke="#EF9F27" stroke-width="1.7" stroke-linecap="round"><line x1="12" y1="1.5" x2="12" y2="4"/><line x1="12" y1="20" x2="12" y2="22.5"/><line x1="1.5" y1="12" x2="4" y2="12"/><line x1="20" y1="12" x2="22.5" y2="12"/><line x1="4.3" y1="4.3" x2="6.2" y2="6.2"/><line x1="17.8" y1="17.8" x2="19.7" y2="19.7"/><line x1="4.3" y1="19.7" x2="6.2" y2="17.8"/><line x1="17.8" y1="6.2" x2="19.7" y2="4.3"/></g></svg>'
    mclear  = '<svg viewBox="0 0 24 24" width="30" height="30"><circle cx="12" cy="12" r="5" fill="#EF9F27"/><g stroke="#EF9F27" stroke-width="1.7" stroke-linecap="round"><line x1="12" y1="2.5" x2="12" y2="4.5"/><line x1="2.5" y1="12" x2="4.5" y2="12"/><line x1="19.5" y1="12" x2="21.5" y2="12"/><line x1="12" y1="19.5" x2="12" y2="21.5"/></g></svg>'
    pcloudy = '<svg viewBox="0 0 24 24" width="30" height="30"><circle cx="16.5" cy="7.5" r="3.5" fill="#EF9F27"/><g stroke="#EF9F27" stroke-width="1.4" stroke-linecap="round"><line x1="16.5" y1="1.5" x2="16.5" y2="3"/><line x1="21.5" y1="7.5" x2="23" y2="7.5"/><line x1="20.4" y1="3.6" x2="21.5" y2="2.5"/></g><g fill="#d4d9dd"><circle cx="8" cy="14" r="3.6"/><circle cx="14.5" cy="14.5" r="4"/><circle cx="11" cy="11.5" r="4.4"/><rect x="8" y="13" width="7" height="5.5" rx="2"/></g></svg>'
    cloudy  = '<svg viewBox="0 0 24 24" width="30" height="30"><g fill="#d4d9dd"><circle cx="7.5" cy="14" r="4"/><circle cx="16" cy="14" r="4.3"/><circle cx="11.5" cy="10" r="5"/><rect x="7.5" y="12.5" width="8.5" height="6" rx="2.5"/></g></svg>'
    fog     = '<svg viewBox="0 0 24 24" width="30" height="30"><g fill="#9aa0a6"><circle cx="8" cy="9.5" r="3.4"/><circle cx="15" cy="9.5" r="3.7"/><circle cx="11.5" cy="6.5" r="4.3"/><rect x="8" y="8" width="7" height="5" rx="2"/></g><g stroke="#9aa0a6" stroke-width="1.7" stroke-linecap="round"><line x1="5.5" y1="16.5" x2="18.5" y2="16.5"/><line x1="7" y1="20" x2="17" y2="20"/></g></svg>'
    drizzle = '<svg viewBox="0 0 24 24" width="30" height="30"><g fill="#a7adb3"><circle cx="8" cy="9" r="3.3"/><circle cx="15" cy="9" r="3.6"/><circle cx="11.5" cy="6" r="4.2"/><rect x="8" y="7.5" width="7" height="5" rx="2"/></g><line x1="6.5" y1="15.5" x2="17.5" y2="15.5" stroke="#9aa0a6" stroke-width="1.4" stroke-linecap="round"/><g stroke="#8aa4c0" stroke-width="1.4" stroke-linecap="round"><line x1="8" y1="18" x2="7.4" y2="20"/><line x1="11.5" y1="18.3" x2="10.9" y2="20.3"/><line x1="15" y1="18" x2="14.4" y2="20"/></g></svg>'
    lrain   = '<svg viewBox="0 0 24 24" width="30" height="30"><g fill="#7d8590"><circle cx="8" cy="10" r="3.4"/><circle cx="15" cy="10" r="3.7"/><circle cx="11.5" cy="7" r="4.3"/><rect x="8" y="8.5" width="7" height="5" rx="2"/></g><g stroke="#378ADD" stroke-width="1.9" stroke-linecap="round"><line x1="10" y1="16" x2="9" y2="20.5"/><line x1="15" y1="16" x2="14" y2="20.5"/></g></svg>'
    rain    = '<svg viewBox="0 0 24 24" width="30" height="30"><g fill="#7d8590"><circle cx="8" cy="10" r="3.4"/><circle cx="15" cy="10" r="3.7"/><circle cx="11.5" cy="7" r="4.3"/><rect x="8" y="8.5" width="7" height="5" rx="2"/></g><g stroke="#1c7ed6" stroke-width="2" stroke-linecap="round"><line x1="8" y1="16" x2="7" y2="20.5"/><line x1="12" y1="16" x2="11" y2="20.5"/><line x1="16" y1="16" x2="15" y2="20.5"/></g></svg>'
    snow    = '<svg viewBox="0 0 24 24" width="30" height="30"><g fill="#7d8590"><circle cx="8" cy="10" r="3.4"/><circle cx="15" cy="10" r="3.7"/><circle cx="11.5" cy="7" r="4.3"/><rect x="8" y="8.5" width="7" height="5" rx="2"/></g><g fill="#85B7EB"><circle cx="8" cy="18" r="1.5"/><circle cx="12" cy="19.5" r="1.5"/><circle cx="16" cy="18" r="1.5"/></g></svg>'
    hsnow   = '<svg viewBox="0 0 24 24" width="30" height="30"><g stroke="#5DA0E0" stroke-width="1.7" stroke-linecap="round"><line x1="12" y1="3" x2="12" y2="21"/><line x1="4" y1="7.5" x2="20" y2="16.5"/><line x1="20" y1="7.5" x2="4" y2="16.5"/></g><g stroke="#5DA0E0" stroke-width="1.5" stroke-linecap="round"><line x1="12" y1="3" x2="9.5" y2="5"/><line x1="12" y1="3" x2="14.5" y2="5"/><line x1="12" y1="21" x2="9.5" y2="19"/><line x1="12" y1="21" x2="14.5" y2="19"/></g></svg>'
    thunder = '<svg viewBox="0 0 24 24" width="30" height="30"><g fill="#7d8590"><circle cx="8" cy="9" r="3.4"/><circle cx="15" cy="9" r="3.7"/><circle cx="11.5" cy="6" r="4.3"/><rect x="8" y="7.5" width="7" height="5" rx="2"/></g><polygon points="13,13 8.5,19 11.5,19 10,23.5 15.5,17 12,17" fill="#EF9F27"/></svg>'
}

function Get-WeatherSvg {
    param($code)
    if ($null -eq $code) { return "" }
    $c = [int]$code
    $key = switch ($c) {
        0           { "clear" }
        1           { "mclear" }
        2           { "pcloudy" }
        3           { "cloudy" }
        { $_ -in 45,48 }                 { "fog" }
        { $_ -in 51,53,55,56,57 }        { "drizzle" }
        { $_ -in 61,80 }                 { "lrain" }
        { $_ -in 63,65,66,67,81 }        { "rain" }
        { $_ -in 71,73,77,85 }           { "snow" }
        { $_ -in 75,86 }                 { "hsnow" }
        { $_ -in 82,95,96,99 }           { "thunder" }
        default     { "cloudy" }
    }
    return $WeatherSvg[$key]
}

# 現在時刻をJST(UTC+9、DSTなし)で返す。
# GitHub Actions等、実行サーバーのローカルタイムゾーンがJSTでない環境でも
# 正しくJSTの「現在時刻」を得るため、Get-Dateの結果をUTC経由でJSTに変換する。
function Get-JstNow {
    return (Get-Date).ToUniversalTime().AddHours(9)
}

# ---- API取得（リトライ付き） ----

# URLをGETしJSONとして返す。一時的な失敗（タイムアウト・5xx等）に備え最大$MaxTriesまでリトライする。
# 2026-07-02にOpen-Meteoの30秒タイムアウトでActionsが2回失敗したため導入（タイムアウトも60秒に延長）。
function Invoke-JsonWithRetry {
    param(
        [string]$Uri,
        [int]$MaxTries = 3,
        [int]$TimeoutSec = 60,
        [int[]]$DelaysSec = @(5, 15)
    )
    for ($try = 1; $try -le $MaxTries; $try++) {
        try {
            return Invoke-RestMethod -Uri $Uri -TimeoutSec $TimeoutSec
        } catch {
            if ($try -ge $MaxTries) { throw }
            $delay = if ($try -le $DelaysSec.Count) { $DelaysSec[$try - 1] } else { $DelaysSec[-1] }
            Write-Warning ("API取得失敗（{0}/{1}回目）: {2} — {3}秒後に再試行" -f $try, $MaxTries, $_.Exception.Message, $delay)
            Start-Sleep -Seconds $delay
        }
    }
}

# Open-Meteo forecast API を hourly+daily まとめて1回で取得する。
# 3版（規定/EC/平均）が必要とする変数の和集合を常に取得し、各版は必要な列だけ使う。
$OpenMeteoHourlyVars = "weather_code,temperature_2m,wind_speed_10m,precipitation_probability,precipitation,snowfall,cloud_cover_low,cloud_cover_mid,cloud_cover_high,cloud_cover"
$OpenMeteoDailyVars  = "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,precipitation_sum,sunrise,sunset"

function Get-ForecastBundle {
    param(
        [double]$Latitude,
        [double]$Longitude,
        [Nullable[double]]$Elevation,
        [string]$Model,
        [int]$ForecastDays = 7,
        [string]$Timezone = "Asia/Tokyo"
    )
    $query = @{
        latitude        = $Latitude
        longitude       = $Longitude
        hourly          = $OpenMeteoHourlyVars
        daily           = $OpenMeteoDailyVars
        timezone        = $Timezone
        forecast_days   = $ForecastDays
        wind_speed_unit = "ms"
    }
    if ($null -ne $Elevation) { $query["elevation"] = $Elevation }
    if (-not [string]::IsNullOrWhiteSpace($Model)) { $query["models"] = $Model }
    $pairs = $query.GetEnumerator() | ForEach-Object { "{0}={1}" -f $_.Key, [uri]::EscapeDataString([string]$_.Value) }
    $url = "https://api.open-meteo.com/v1/forecast?" + ($pairs -join "&")
    return Invoke-JsonWithRetry -Uri $url
}

# ---- 天文計算（月の出入り・月相） ----

# ユリウス日（UTC datetime から）
function Get-JD {
    param([datetime]$utc)
    $y = $utc.Year; $m = $utc.Month; $d = $utc.Day
    $h = $utc.Hour + $utc.Minute / 60.0
    if ($m -le 2) { $y--; $m += 12 }
    $A = [math]::Floor($y / 100.0)
    $B = 2 - $A + [math]::Floor($A / 4.0)
    return [math]::Floor(365.25 * ($y + 4716)) + [math]::Floor(30.6001 * ($m + 1)) + $d + $B - 1524.5 + $h / 24.0
}

# 時間数（小数）→ "HH:MM" 文字列
function Format-HourToHHMM {
    param([double]$h)
    $hh = [int][math]::Floor($h)
    $mm = [int][math]::Round(($h % 1) * 60)
    if ($mm -eq 60) { $hh++; $mm = 0 }
    if ($hh -ge 24) { $hh -= 24 }
    return "{0:D2}:{1:D2}" -f $hh, $mm
}

# 月の赤経・赤緯を Meeus 多項補正モデルで計算（Table 47.A/B 上位20/10項）
# ネスト配列を避け、列ごとのフラット配列＋forループで実装（PS5.1対応）
function Get-MoonRADec {
    param([double]$jd)
    $T  = ($jd - 2451545.0) / 36525.0
    $r  = [math]::PI / 180
    $Lp = ((218.3164477 + 481267.88123421*$T - 0.0015786*$T*$T + $T*$T*$T/538841.0   - $T*$T*$T*$T/65194000.0 ) % 360 + 360) % 360
    $D  = ((297.8501921 + 445267.1114034 *$T - 0.0018819*$T*$T + $T*$T*$T/545868.0   - $T*$T*$T*$T/113065000.0) % 360 + 360) % 360
    $M  = ((357.5291092 + 35999.0502909  *$T - 0.0001536*$T*$T + $T*$T*$T/24490000.0                           ) % 360 + 360) % 360
    $Mp = ((134.9633964 + 477198.8675055 *$T + 0.0087414*$T*$T + $T*$T*$T/69699.0    - $T*$T*$T*$T/14712000.0 ) % 360 + 360) % 360
    $F  = ((93.2720950  + 483202.0175233 *$T - 0.0036539*$T*$T - $T*$T*$T/3526000.0  + $T*$T*$T*$T/863310000.0) % 360 + 360) % 360
    $E  = 1.0 - 0.002516*$T - 0.0000074*$T*$T

    $Drad=[double]($D*$r); $Mrad=[double]($M*$r); $Mprad=[double]($Mp*$r); $Frad=[double]($F*$r)

    # Table 47.A 上位20項: D / M / M' / F / Σl係数(×10⁻⁶°)
    [int[]]$lD  = 0, 2, 2, 0,  0,  0, 2,  2, 2,  2,  0, 1,  0, 2,  0,  0, 4, 0, 4,  2
    [int[]]$lM  = 0, 0, 0, 0,  1,  0, 0, -1, 0, -1,  1, 0,  1, 0,  0,  0, 0, 0, 0,  1
    [int[]]$lMp = 1,-1, 0, 2,  0,  0,-2, -1, 1,  0, -1, 0,  1, 0,  1, -1,-1, 3,-2, -1
    [int[]]$lF  = 0, 0, 0, 0,  0,  2, 0,  0, 0,  0,  0, 0,  0,-2,  2, -2, 0, 0, 0,  0
    [double[]]$lC = 6288774,1274027,658314,213618,-185116,-114332,58793,57066,53322,45758,-40923,-34720,-30383,15327,-12528,10980,10675,10034,8548,-7888

    # Table 47.B 上位10項: D / M / M' / F / Σb係数(×10⁻⁶°)
    [int[]]$bD  = 0, 0, 0, 2,  2,  2, 2, 0, 2,  0
    [int[]]$bM  = 0, 0, 0, 0,  0,  0, 0, 0, 0,  0
    [int[]]$bMp = 0, 1, 1, 0, -1, -1, 0, 2, 1,  2
    [int[]]$bF  = 1, 1,-1,-1,  1, -1, 1, 1,-1, -1
    [double[]]$bC = 5128122,280602,277693,173237,55413,46271,32573,17198,9266,8822

    $sumL = 0.0
    for ($i = 0; $i -lt 20; $i++) {
        $c = $lC[$i]
        $am = [math]::Abs($lM[$i])
        if ($am -eq 1) { $c *= $E } elseif ($am -eq 2) { $c *= $E * $E }
        $sumL += $c * [math]::Sin([double]$lD[$i]*$Drad + [double]$lM[$i]*$Mrad + [double]$lMp[$i]*$Mprad + [double]$lF[$i]*$Frad)
    }
    $sumB = 0.0
    for ($i = 0; $i -lt 10; $i++) {
        $c = $bC[$i]
        $am = [math]::Abs($bM[$i])
        if ($am -eq 1) { $c *= $E } elseif ($am -eq 2) { $c *= $E * $E }
        $sumB += $c * [math]::Sin([double]$bD[$i]*$Drad + [double]$bM[$i]*$Mrad + [double]$bMp[$i]*$Mprad + [double]$bF[$i]*$Frad)
    }

    $lonMoon = ($Lp + $sumL / 1000000.0 + 360) % 360
    $latMoon = $sumB / 1000000.0
    $obl = 23.4393 - 0.013004 * $T

    $sinDec = [math]::Sin($latMoon*$r)*[math]::Cos($obl*$r) +
              [math]::Cos($latMoon*$r)*[math]::Sin($obl*$r)*[math]::Sin($lonMoon*$r)
    $dec = [math]::Asin([math]::Max(-1.0, [math]::Min(1.0, $sinDec))) / $r
    $ra  = ([math]::Atan2(
                [math]::Sin($lonMoon*$r)*[math]::Cos($obl*$r) - [math]::Tan($latMoon*$r)*[math]::Sin($obl*$r),
                [math]::Cos($lonMoon*$r)) / $r + 360) % 360
    return @{ ra = $ra; dec = $dec; lon = $lonMoon }
}

# 太陽の黄経（度）
function Get-SunLon {
    param([double]$jd)
    $r = [math]::PI / 180
    $n = $jd - 2451545.0
    $L = ((280.460 + 0.9856474 * $n) % 360 + 360) % 360
    $g = ((357.528 + 0.9856003 * $n) % 360 + 360) % 360
    return (($L + 1.915 * [math]::Sin($g*$r) + 0.020 * [math]::Sin(2*$g*$r)) % 360 + 360) % 360
}

# 月相 phase（0=新月, 0.5=満月）。月と太陽の黄経差（離角）から算出＝朔基準で正確
function Get-MoonPhase {
    param([double]$jd)
    $lm = (Get-MoonRADec -jd $jd).lon
    $ls = Get-SunLon -jd $jd
    $D  = (($lm - $ls) % 360 + 360) % 360
    return $D / 360.0
}

# 指定JD（UTC）における月の高度（度）
function Get-MoonAlt {
    param([double]$jd, [double]$lat, [double]$lon)
    $pos = Get-MoonRADec -jd $jd
    $T   = ($jd - 2451545.0) / 36525.0
    $r   = [math]::PI / 180
    $gmst = ((280.46061837 + 360.98564736629*($jd-2451545.0) + 0.000387933*$T*$T) % 360 + 360) % 360
    $lha  = ($gmst + $lon - $pos.ra + 360) % 360
    $sinAlt = [math]::Sin($lat*$r)*[math]::Sin($pos.dec*$r) +
              [math]::Cos($lat*$r)*[math]::Cos($pos.dec*$r)*[math]::Cos($lha*$r)
    return [math]::Asin([math]::Max(-1.0,[math]::Min(1.0,$sinAlt))) / $r
}

# 指定ローカル日の月の出・入り時刻を計算（2分刻みの線形補間）
function Get-MoonRiseSet {
    param([datetime]$localDate, [double]$lat, [double]$lon, [int]$tz = 9)
    $jd0 = Get-JD -utc $localDate.Date.AddHours(-$tz)   # ローカル深夜0時 = UTC
    $stepH = 2.0 / 60.0                                    # 2分 = 0.0333h
    $stepJD = $stepH / 24.0
    $prev = Get-MoonAlt -jd $jd0 -lat $lat -lon $lon
    $rise = $null; $set = $null
    $horizon = 0.35     # 月の出入りの基準高度（視差0.95°補正込み：0.7275×π-0.34°）
    for ($i = 1; $i -le 720; $i++) {                      # 24h = 720ステップ
        $jd  = $jd0 + $i * $stepJD
        $cur = Get-MoonAlt -jd $jd -lat $lat -lon $lon
        $lhPrev = ($i - 1) * $stepH
        $lhCur  = $i * $stepH
        if ($null -eq $rise -and $prev -lt $horizon -and $cur -ge $horizon) {
            $frac = ($horizon - $prev) / ($cur - $prev)
            $rise = Format-HourToHHMM -h ($lhPrev + $frac * ($lhCur - $lhPrev))
        }
        if ($null -eq $set -and $prev -ge $horizon -and $cur -lt $horizon) {
            $frac = ($horizon - $prev) / ($cur - $prev)
            $set  = Format-HourToHHMM -h ($lhPrev + $frac * ($lhCur - $lhPrev))
        }
        if ($null -ne $rise -and $null -ne $set) { break }
        $prev = $cur
    }
    return @{ rise = $rise; set = $set }
}

# 月相（0=新月, 0.25=上弦, 0.5=満月, 0.75=下弦）と月齢（日）を返す
function Get-MoonPhaseInfo {
    param([datetime]$localDate, [int]$tz = 9)
    $jd = Get-JD -utc $localDate.Date.AddHours(12 - $tz)   # 正午 JST
    $phase = Get-MoonPhase -jd $jd
    $age = $phase * 29.53
    $idx = [int][math]::Round($phase * 8) % 8
    $emojis = @("🌑","🌒","🌓","🌔","🌕","🌖","🌗","🌘")
    $names  = @("新月","三日月","上弦","十三夜","満月","十六夜","下弦","有明月")
    return @{ phase = $phase; age = $age; emoji = $emojis[$idx]; name = $names[$idx] }
}

# ---- 星空指数 ----
# 設計: 月齢→明るさ K&S(1991) / 高度減光 Kasten-Young(1989) / 薄明→空輝度SQM / 雲量と合成
# すべて「満月の南中=明るさ100」スケールに統一する。

# Kasten & Young (1989) のエアマス（高度 h 度、h>0 を想定）
function Get-AirMass {
    param([double]$h)
    if ($h -le 0) { return 40.0 }
    $r = [math]::PI / 180
    return 1.0 / ([math]::Sin($h*$r) + 0.50572 * [math]::Pow($h + 6.07995, -1.6364))
}

# 太陽高度（度）。低精度式（薄明判定には十分な±0.01°級）
function Get-SunAlt {
    param([double]$jd, [double]$lat, [double]$lon)
    $r = [math]::PI / 180
    $n = $jd - 2451545.0
    $L = ((280.460 + 0.9856474 * $n) % 360 + 360) % 360
    $g = ((357.528 + 0.9856003 * $n) % 360 + 360) % 360
    $lambda = $L + 1.915 * [math]::Sin($g*$r) + 0.020 * [math]::Sin(2*$g*$r)
    $eps = 23.439 - 0.0000004 * $n
    $ra  = ([math]::Atan2([math]::Cos($eps*$r)*[math]::Sin($lambda*$r), [math]::Cos($lambda*$r)) / $r + 360) % 360
    $dec = [math]::Asin([math]::Sin($eps*$r)*[math]::Sin($lambda*$r)) / $r
    $gmst = ((280.46061837 + 360.98564736629 * $n) % 360 + 360) % 360
    $lha  = ($gmst + $lon - $ra + 360) % 360
    $sinAlt = [math]::Sin($lat*$r)*[math]::Sin($dec*$r) + [math]::Cos($lat*$r)*[math]::Cos($dec*$r)*[math]::Cos($lha*$r)
    return [math]::Asin([math]::Max(-1.0,[math]::Min(1.0,$sinAlt))) / $r
}

# 薄明による空の明るさ（満月南中=100）。太陽高度 s 度。SQM式: hnsky.org のフィット
function Get-TwilightBrightness {
    param([double]$s)
    if ($s -ge 0)   { return 100.0 }   # 日没前は星見えない
    if ($s -le -18) { return 0.0 }     # 天文薄明終了＝暗夜
    if ($s -gt -12) { $sqm = -1.057 * $s + 6.749 }
    else            { $sqm = -0.0744 * $s * $s - 2.577 * $s - 0.585 }
    # 暗夜 SQM≈21.8 を 0、満月南中 SQM≈18 を 100 に正規化（係数3.0）
    $excess = [math]::Pow(10, 0.4 * (21.8 - $sqm))
    $ind = 3.0 * ($excess - 1)
    if ($ind -lt 0)   { return 0.0 }
    if ($ind -gt 100) { return 100.0 }
    return $ind
}

# 月明かりによる空の明るさ（満月南中=100）
function Get-MoonBrightness {
    param([double]$jd, [double]$lat, [double]$lon, [double]$kext = 0.15)
    $r = [math]::PI / 180
    $pos = Get-MoonRADec -jd $jd
    $T = ($jd - 2451545.0) / 36525.0
    $gmst = ((280.46061837 + 360.98564736629*($jd-2451545.0) + 0.000387933*$T*$T) % 360 + 360) % 360
    $lha  = ($gmst + $lon - $pos.ra + 360) % 360
    $sinAlt = [math]::Sin($lat*$r)*[math]::Sin($pos.dec*$r) + [math]::Cos($lat*$r)*[math]::Cos($pos.dec*$r)*[math]::Cos($lha*$r)
    $h = [math]::Asin([math]::Max(-1.0,[math]::Min(1.0,$sinAlt))) / $r
    if ($h -le 0) { return 0.0 }   # 月が地平線下なら月明かりなし
    # 月相→位相角α（度）: phase 0=新月, 0.5=満月
    $phase = Get-MoonPhase -jd $jd
    $alpha = [math]::Abs(180 - $phase * 360)
    # K&S(1991) 位相項。満月(α=0)で1
    $phaseCoef = [math]::Pow(10, -0.4 * (0.026 * $alpha + 4e-9 * [math]::Pow($alpha, 4)))
    # 高度による大気減光（その夜の南中高度を基準=1）
    $hTransit = 90 - [math]::Abs($lat - $pos.dec)
    $X  = Get-AirMass -h $h
    $Xt = Get-AirMass -h $hTransit
    $altCoef = [math]::Pow(10, -0.4 * $kext * ($X - $Xt))
    return 100.0 * $phaseCoef * $altCoef
}

# 星空指数（0-100, 5単位）。昼間（太陽高度>=0）は $null を返す
function Get-StarIndex {
    param([double]$jd, [double]$lat, [double]$lon, $totalCloud, $precip)
    $s = Get-SunAlt -jd $jd -lat $lat -lon $lon
    if ($s -ge 0) { return $null }
    $bMoon = Get-MoonBrightness -jd $jd -lat $lat -lon $lon
    $bTwi  = Get-TwilightBrightness -s $s
    $B = $bMoon + $bTwi
    if ($B -gt 100) { $B = 100 }
    $c = if ($null -eq $totalCloud) { 0.0 } else { [double]$totalCloud }
    $idx = (100 - $c) * (1 - $B / 100)
    # 降水量で減衰（1mm未満の雨は×0.7、1mm以上は×0.4。降水確率はMSMで非提供のため不使用）
    $pr = if ($null -eq $precip) { 0.0 } else { [double]$precip }
    if     ($pr -ge 1.0) { $idx *= 0.4 }
    elseif ($pr -gt 0.0) { $idx *= 0.7 }
    if ($idx -lt 0) { $idx = 0 }
    return [int]([math]::Round($idx / 5.0) * 5)   # 5単位に丸め
}

# ---- フォーマット ----

function Format-Pct    { param($v); if ($null -eq $v) { "--" } else { "$v%" } }
function Format-Precip { param($v); if ($null -eq $v) { "--" } else { ("{0:0.0}mm" -f [double]$v) } }
function Format-Temp   { param($v); if ($null -eq $v) { "--" } else { ("{0}°" -f [int][math]::Ceiling([double]$v)) } }   # 0捨1入(切り上げ)
function Format-Wind   { param($v); if ($null -eq $v) { "--" } else { ("{0:0.0}" -f [double]$v) } }

function Get-DisplayWidth {
    param([string]$s)
    $w = 0
    foreach ($ch in $s.ToCharArray()) { if ([int]$ch -gt 255) { $w += 2 } else { $w += 1 } }
    return $w
}

function Pad {
    param([string]$s, [int]$width, [switch]$Left)
    $space = $width - (Get-DisplayWidth $s)
    if ($space -lt 0) { $space = 0 }
    if ($Left) { return $s + (" " * $space) } else { return (" " * $space) + $s }
}

# ---- 色ユーティリティ ----

function Cloud-Bg {
    param($v)
    if ($null -eq $v) { return "background:#fff" }
    $vv = [double]$v
    $l = [math]::Round(100 - (0.3 * $vv + 0.003 * $vv * $vv))
    $fg = if ($l -lt 55) { "#fff" } else { "#111" }
    return ("background:hsl(210,16%,{0}%);color:{1}" -f $l, $fg)
}

function Pop-Bg {
    param($v)
    if ($null -eq $v) { return "background:#fff" }
    $l = 100 - ([double]$v * 0.40)
    return ("background:hsl(205,80%,{0}%)" -f ([math]::Round($l)))
}

# 雨量セル: 多いほど濃い青（20mmで最濃）。1mm未満は1mm相当、30mm以上は薄橙の単色
function Rain-Bg {
    param($v)
    if ($null -eq $v) { return "" }
    $vv = [double]$v
    if ($vv -le 0)   { return "" }                   # 雨なしは無色
    if ($vv -ge 30)  { return "background:#ffd9a0" } # 30mm以上は薄橙(単色)
    $eff = [math]::Max(1.0, $vv)                      # 1mm未満は1mm扱い
    $l = 100 - [math]::Min($eff, 20) / 20 * 55        # 1mm→97%、20mm→45%
    $fg = if ($l -lt 55) { ";color:#fff" } else { "" }
    return ("background:hsl(210,85%,{0}%){1}" -f [math]::Round($l), $fg)
}

$JpWeek = @("日", "月", "火", "水", "木", "金", "土")

# ---- 気象警報・注意報（気象庁 防災情報XML互換JSON） ----

# 警報・注意報コード→名称（気象庁「警報等情報要素コード」に基づく。網羅的ではないベストエフォート）
$WarnNames = @{
    "02" = "暴風雪警報";   "03" = "大雨警報";     "04" = "洪水警報";     "05" = "暴風警報"
    "06" = "大雪警報";     "07" = "波浪警報";     "08" = "高潮警報";     "09" = "土砂災害警報"
    "10" = "大雨注意報";   "11" = "洪水注意報";   "12" = "大雪注意報";   "13" = "風雪注意報"
    "14" = "雷注意報";     "15" = "強風注意報";   "16" = "波浪注意報";   "17" = "融雪注意報"
    "18" = "高潮注意報";   "20" = "濃霧注意報";   "21" = "乾燥注意報";   "22" = "なだれ注意報"
    "23" = "低温注意報";   "24" = "霜注意報";     "25" = "着氷注意報";   "26" = "着雪注意報"
    "32" = "暴風雪特別警報"; "33" = "大雨特別警報"; "35" = "暴風特別警報"
    "36" = "大雪特別警報";   "37" = "波浪特別警報"; "38" = "高潮特別警報"; "39" = "土砂災害特別警報"
}

function Get-WarnLevel {
    param([string]$code)
    if ($code -in @("32","33","35","36","37","38","39")) { return "特別警報" }
    if ($code -match '^0[2-9]$') { return "警報" }
    return "注意報"
}

# 対象区域の発表中警報・注意報を取得する。
# $areas: @(@{name="久万高原町"; code="3838600"; pref="380000"}, ...)
# 戻り値: @(@{ name="久万高原町"; items=@(@{code="10"; name="大雨注意報"; level="注意報"}, ...) }, ...) （発表なしの町は items=@()）
function Get-Alerts {
    param($areas)
    $result = New-Object System.Collections.Generic.List[object]
    $prefCache = @{}
    foreach ($a in $areas) {
        $items = New-Object System.Collections.Generic.List[object]
        try {
            if (-not $prefCache.ContainsKey($a.pref)) {
                $prefCache[$a.pref] = Invoke-JsonWithRetry -Uri "https://www.jma.go.jp/bosai/warning/data/warning/$($a.pref).json" -MaxTries 2 -TimeoutSec 30
            }
            $doc = $prefCache[$a.pref]
            $area = $null
            foreach ($at in $doc.areaTypes) {
                $hit = $at.areas | Where-Object { $_.code -eq $a.code }
                if ($hit) { $area = $hit; break }
            }
            if ($area) {
                foreach ($w in $area.warnings) {
                    if ($w.code -and $w.status -ne "解除") {
                        $name = if ($WarnNames.ContainsKey($w.code)) { $WarnNames[$w.code] } else { "警報等($($w.code))" }
                        $items.Add(@{ code = $w.code; name = $name; level = (Get-WarnLevel $w.code) })
                    }
                }
            }
        } catch {
            # 取得失敗しても処理は継続（警報表示なしとして扱う）
        }
        $result.Add(@{ name = $a.name; items = $items })
    }
    return $result
}

# 警報一覧 → HTMLバナー文字列（発表中があれば色分け表示、無ければ小さく「発表なし」）
function Render-AlertHtml {
    param($alerts)
    if (-not $alerts -or $alerts.Count -eq 0) { return "" }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<div class="alertwrap">')
    foreach ($a in $alerts) {
        if ($a.items.Count -eq 0) {
            [void]$sb.Append(("<span class=""alertnone"">{0}: 発表なし</span>" -f $a.name))
        } else {
            $maxLevel = if ($a.items | Where-Object { $_.level -eq "特別警報" }) { "特別警報" }
                        elseif ($a.items | Where-Object { $_.level -eq "警報" })   { "警報" }
                        else { "注意報" }
            $cls = switch ($maxLevel) { "特別警報" { "alertspecial" }; "警報" { "alertwarn" }; default { "alertcaution" } }
            $names = ($a.items | ForEach-Object { $_.name }) -join "・"
            [void]$sb.Append(("<span class=""alertbanner {0}"">⚠ {1}: {2}</span>" -f $cls, $a.name, $names))
        }
    }
    [void]$sb.Append('</div>')
    return $sb.ToString()
}

# 警報一覧 → コンソール表示用テキスト行
function Render-AlertConsole {
    param($alerts)
    $lines = New-Object System.Collections.Generic.List[string]
    if (-not $alerts -or $alerts.Count -eq 0) { return $lines }
    foreach ($a in $alerts) {
        if ($a.items.Count -eq 0) {
            $lines.Add("警報等: $($a.name) 発表なし")
        } else {
            $names = ($a.items | ForEach-Object { $_.name }) -join "・"
            $lines.Add("⚠ 警報等: $($a.name) $names")
        }
    }
    return $lines
}

# 警報バナー用CSS（HTML側で埋め込む）
$AlertCss = @'
.alertwrap{margin:8px 16px 4px;display:flex;flex-wrap:nowrap;align-items:center;gap:8px;overflow-x:auto;}
.alertbanner{display:inline-block;flex:0 0 auto;white-space:nowrap;border-radius:6px;padding:6px 10px;font-size:13px;font-weight:600;}
.alertbanner.alertcaution{background:#fff3bf;color:#7a5c00;}
.alertbanner.alertwarn{background:#ffe3e3;color:#a61e1e;}
.alertbanner.alertspecial{background:#8b0000;color:#fff;}
.alertnone{display:inline-block;flex:0 0 auto;white-space:nowrap;font-size:11px;color:#aaa;}
'@
