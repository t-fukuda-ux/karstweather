<#
.SYNOPSIS
  Open-Meteo から指定地点の毎時・雲量（低層を中心に）を取得して表示し、CSV に保存する。

.DESCRIPTION
  - API キー不要・無料
  - 既定の地点は四国カルスト 姫鶴荘
  - 取得項目: 低層雲 / 中層雲 / 高層雲 / 全雲量（いずれも %）
  - 毎時テーブル: 実行時刻から 72 時間分を表示
  - Python 不要。Windows 標準の PowerShell だけで動作します。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\lowcloud.ps1

.EXAMPLE
  .\lowcloud.ps1 -Latitude 35.681 -Longitude 139.767 -ForecastDays 3
#>

[CmdletBinding()]
param(
    [double]$Latitude    = 33.4666147,    # 四国カルスト 姫鶴荘
    [double]$Longitude   = 132.9610114,
    [Nullable[double]]$Elevation = $null,  # 標高(m)。$null ならAPIが自動採用（この地点は約1296m）
    [int]   $ForecastDays = 4,            # 72h確保のため4日取得（内部用）
    [int]   $WeeklyDays  = 7,             # 週間予報の日数（最大16）
    [string]$Timezone    = "Asia/Tokyo",
    [string]$CsvPath     = ""
)

$ErrorActionPreference = "Stop"
$HourlyVars = "weather_code,temperature_2m,wind_speed_10m,precipitation_probability,precipitation,cloud_cover_low,cloud_cover_mid,cloud_cover_high,cloud_cover"

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

# 指定ローカル日の月の出・入り時刻を計算（10分刻みの線形補間）
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
        })
    }
    # 現在時刻の時以降をすべて返す（4日分の末尾まで）
    $nowHour = (Get-Date).Date.AddHours((Get-Date).Hour)
    return ($rows | Where-Object { [datetime]$_.time -ge $nowHour })
}

# ---- フォーマット ----

function Format-Pct    { param($v); if ($null -eq $v) { "--" } else { "$v%" } }
function Format-Precip { param($v); if ($null -eq $v) { "--" } else { ("{0:0.0}mm" -f [double]$v) } }
function Format-Temp   { param($v); if ($null -eq $v) { "--" } else { ("{0}°" -f $v) } }
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

# ---- コンソール表示 ----

function Show-Table {
    param($rows, $ApiElevation)
    $elevLabel = if ($null -ne $Elevation) { "{0}m(指定)" -f $Elevation } else { "{0}m(自動)" -f $ApiElevation }
    Write-Host ("地点: 緯度 {0} / 経度 {1} / 標高 {2}  (タイムゾーン: {3})" -f $Latitude, $Longitude, $elevLabel, $Timezone)
    Write-Host ("取得時刻: {0:yyyy-MM-dd HH:mm}   気温=°C / 風速=m/s" -f (Get-Date))
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
                (Pad (Format-Temp $r.temp) 7) +
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

# ---- HTML ----

function Save-Html {
    param($rows, $daily, [string]$path, $ApiElevation)

    $elevLabel  = if ($null -ne $Elevation) { "{0}m(指定)" -f $Elevation } else { "{0}m(自動)" -f $ApiElevation }
    $generated  = "{0:yyyy-MM-dd HH:mm}" -f (Get-Date)
    $startTime  = if ($rows.Count -gt 0) { $rows[0].time } else { "--" }
    $endTime    = if ($rows.Count -gt 0) { $rows[-1].time } else { "--" }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!DOCTYPE html><html lang="ja"><head><meta charset="utf-8">')
    [void]$sb.AppendLine('<meta name="viewport" content="width=device-width,initial-scale=1">')
    [void]$sb.AppendLine('<title>1時間天気予報 - 四国カルスト姫鶴荘</title>')
    [void]$sb.AppendLine(@'
<style>
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
</style>
'@)
    [void]$sb.AppendLine('</head><body><div class="wrap">')
    [void]$sb.AppendLine('<h1>1時間天気予報 — 四国カルスト 姫鶴荘</h1>')
    [void]$sb.AppendLine(("<p class=""meta"">緯度 {0} / 経度 {1} / 標高 {2}　|　取得: {3}　|　{4} ～ {5}　|　出典: Open-Meteo</p>" -f $Latitude, $Longitude, $elevLabel, $generated, $startTime, $endTime))
    [void]$sb.AppendLine('<div class="scroll"><table>')

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

    # 時刻行
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

    Row "天気"     { param($r) "<td class=""ico"">{0}<div class=""wt"">{1}</div></td>" -f (Get-WeatherSvg $r.wcode), $r.weather }
    Row "低層雲%"  { param($r) "<td class=""low"" style=""{0}"">{1}</td>" -f (Cloud-Bg $r.low), $r.low }
    Row "気温℃"   { param($r) "<td class=""temp"">{0}</td>" -f $r.temp }
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
        [void]$sb.Append(("<td class=""moonband""{0}>{1}</td>" -f $style, $label))
    }
    [void]$sb.AppendLine('</tr>')

    Row "星空指数" { param($r)
        if ($null -eq $r.star) { '<td class="starcell">--</td>' }
        else { "<td class=""starcell"">{0}</td>" -f $r.star }
    }

    [void]$sb.AppendLine('</table></div>')
    [void]$sb.AppendLine('<p class="legend">セルの色: 雲量・雨量は濃いほど多い（雨量は20mmで最濃、30mm以上は橙）。低層雲が当プロジェクトの主目的の指標です。<br>月の欄: 月が出ている時間帯を薄黄で表示（濃いほど明るい）。出／南中／入りの時刻と月齢を記載。<br>星空指数(0〜100, 5単位): 夜間のみ算出。大きいほど星空観測に好条件。雲量・月明かり(月齢・高度)・薄明・降水量から計算。</p>')

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
            [void]$sb.Append(("<div><span class=""tmax"">{0}°</span> <span class=""tmin"">{1}°</span></div>" -f $r.tmax, $r.tmin))
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
Show-Table -rows $rows -ApiElevation $data.elevation

try {
    $daily = Get-DailyRows
} catch {
    Write-Warning ("週間予報の取得に失敗しました: {0}" -f $_.Exception.Message)
    $daily = $null
}

if ([string]::IsNullOrWhiteSpace($CsvPath)) {
    $CsvPath = Join-Path $PSScriptRoot "lowcloud.csv"
}
try {
    Save-Csv -rows $rows -path $CsvPath
} catch {
    Write-Warning ("CSV を保存できませんでした（Excel等で開いていませんか？）: {0}" -f $_.Exception.Message)
}
try {
    Save-Html -rows $rows -daily $daily -path (Join-Path $PSScriptRoot "lowcloud.html") -ApiElevation $data.elevation
} catch {
    Write-Warning ("HTML を保存できませんでした: {0}" -f $_.Exception.Message)
}
