<#
.SYNOPSIS
  雲海指数（四国カルスト姫鶴平から見下ろす雲海の期待度）。
  lowcloud_common.ps1 の末尾から dot-source される。

.DESCRIPTION
  設計は「谷に霧ができるか(F)」と「姫鶴平が雲の上に出るか(V)」を分けて掛ける。
    指数_dir = round(100 * F_dir * V_dir),  V_dir = min(V_top_dir, V_vis_S)
  山上の湿度・低層雲だけで判定すると、姫鶴平自体が霧に包まれる日も高得点になるため、
  展望地点(S)と見下ろす谷5地点を別々に取得して組み合わせる。
  係数・しきい値はすべて試作値であり、現地実績で検証された式ではない。
#>

# ---- 地点定義 ----

# 「見晴らす場所」の高度。API返却標高(要求座標のDEM由来で、モデルの地形標高ではない)とは
# 別物なので定数で持つ。姫鶴荘は約1300mだが、判定基準は展望地点の1400m。
$UnkaiSummitElev = 1400.0

$UnkaiViewpoint = [ordered]@{ id = "S"; name = "姫鶴平"; dir = "-"; lat = 33.4666147; lon = 132.9610114 }

# 谷4地点。いずれも姫鶴平から見える谷であることを現地確認済み。
# 中津(33.66/132.98)は美川と同一の格子セルに落ち、雲量・降水・気圧面がすべて同値に
# なったため除外した（返却標高だけは要求座標のDEM由来で異なるが、中身は同じ）。
$UnkaiValleys = @(
    [ordered]@{ id = "N_C"; name = "美川";   dir = "北"; lat = 33.63;  lon = 133.00 }
    [ordered]@{ id = "N_E"; name = "面河";   dir = "北"; lat = 33.60;  lon = 133.13 }
    [ordered]@{ id = "S_A"; name = "梼原";   dir = "南"; lat = 33.395; lon = 132.93 }
    [ordered]@{ id = "S_B"; name = "津野町"; dir = "南"; lat = 33.40;  lon = 133.06 }
)

# 気圧面(hPa)。best_match は全面を返すが、ECMWF IFS は 1000/925/850 のみで
# 他は null になる。null は「その面が無い」として扱う。
#
# 1000〜825hPa の8段に絞っている。谷でおよそ 地表〜1720m にあたり、判定に必要な範囲を覆う。
#   V_top_fog … 霧層の上端を展望地点1400mと比べるので 1700m 程度まであれば足りる
#   V_summit  … 山上(格子約1296m)の直上の面。通常850hPa(約1412m)、高いときで825hPa
# 800hPa以上（約1980m〜）は判定に使っていないため落とした。取得量が減るぶん、
# 上端まで湿っている日の状態が saturated_to_top になりやすくなるが、その場合は
# V_top_fog を適用しない扱いで、判断は V_summit が受け持つ。
$UnkaiLevels = @(1000, 975, 950, 925, 900, 875, 850, 825)

# 指数がこの値以上の谷を「雲海あり」と数え、4地点中いくつかを併記する（広がりの目安）。
$UnkaiSpreadThreshold = 50

# ---- 小道具 ----

function Get-Clamp01 {
    param([double]$v)
    if ($v -lt 0.0) { return 0.0 }
    if ($v -gt 1.0) { return 1.0 }
    return $v
}

# "yyyy-MM-ddTHH:00" 形式のキーで hourly 配列を引くための索引を作る。
function New-UnkaiTimeIndex {
    param($times)
    $map = @{}
    for ($i = 0; $i -lt $times.Count; $i++) { $map[[string]$times[$i]] = $i }
    return $map
}

# 任意時刻の値を前後の正時から線形補間する（日没時刻の気温などに使う）。
function Get-UnkaiInterp {
    param($idxMap, $values, [datetime]$at)
    if ($null -eq $values) { return $null }
    $k0 = $at.ToString("yyyy-MM-ddTHH:00")
    if (-not $idxMap.ContainsKey($k0)) { return $null }
    $v0 = $values[$idxMap[$k0]]
    if ($null -eq $v0) { return $null }
    $k1 = $at.AddHours(1).ToString("yyyy-MM-ddTHH:00")
    if (-not $idxMap.ContainsKey($k1)) { return [double]$v0 }
    $v1 = $values[$idxMap[$k1]]
    if ($null -eq $v1) { return [double]$v0 }
    return [double]$v0 + ([double]$v1 - [double]$v0) * ($at.Minute / 60.0)
}

# $from〜$to の正時の平均。値が1つも無ければ $null。
function Get-UnkaiMean {
    param($idxMap, $values, [datetime]$from, [datetime]$to)
    if ($null -eq $values) { return $null }
    $sum = 0.0; $n = 0
    $t = [datetime]::new($from.Year, $from.Month, $from.Day, $from.Hour, 0, 0)
    if ($t -lt $from) { $t = $t.AddHours(1) }
    while ($t -le $to) {
        $k = $t.ToString("yyyy-MM-ddTHH:00")
        if ($idxMap.ContainsKey($k)) {
            $v = $values[$idxMap[$k]]
            if ($null -ne $v) { $sum += [double]$v; $n++ }
        }
        $t = $t.AddHours(1)
    }
    if ($n -eq 0) { return $null }
    return $sum / $n
}

function Get-UnkaiValueAt {
    param($idxMap, $values, [datetime]$at)
    if ($null -eq $values) { return $null }
    $k = $at.ToString("yyyy-MM-ddTHH:00")
    if (-not $idxMap.ContainsKey($k)) { return $null }
    return $values[$idxMap[$k]]
}

# ---- 各因子 ----

# M: 谷の空気が飽和に近いか。
# 本番は RH ベース(C案)。RH80%で0.5、RH90%で1.0。福田さんの経験則
# 「麓の予報湿度が80%以上だと出やすい」に合わせた試作値。
function Get-UnkaiM_Rh {
    param($rh)
    if ($null -eq $rh) { return $null }
    return Get-Clamp01 -v ((([double]$rh) - 70.0) / 20.0)
}

# 露点差ベース(当初案)。並記記録用。実績が溜まったら RH 版と比較する。
function Get-UnkaiM_Dpd {
    param($t, $td)
    if ($null -eq $t -or $null -eq $td) { return $null }
    return Get-Clamp01 -v ((4.0 - ([double]$t - [double]$td)) / 3.5)
}

# W: 谷の風の弱さ。完全な無風は霧層が薄くなりやすいため 0.8 に留める。
function Get-UnkaiW {
    param($wind)
    if ($null -eq $wind) { return $null }
    $w = [double]$wind
    if ($w -le 0.0)  { return 0.8 }
    if ($w -lt 0.5)  { return 0.8 + ($w / 0.5) * 0.2 }
    if ($w -le 2.0)  { return 1.0 }
    if ($w -lt 5.0)  { return (5.0 - $w) / 3.0 }
    return 0.0
}

# C: 上空の雲による冷却の妨げが少ない度合い。放射冷却そのものではない。
# 低層雲は「これから霧になるのを妨げる雲」と「発生した雲海」をAPI上区別できないため
# 初版では外し、中・高層雲だけで作る（高層雲は妨げる力が弱いので重み0.5）。
function Get-UnkaiC {
    param($mid, $high)
    if ($null -eq $mid -and $null -eq $high) { return $null }
    $m = if ($null -eq $mid)  { 0.0 } else { [double]$mid }
    $h = if ($null -eq $high) { 0.0 } else { [double]$high }
    return 1.0 - (Get-Clamp01 -v ($m / 100.0 + 0.5 * $h / 100.0))
}

# C0: 当初案の C（全雲量・日没〜深夜の平均）。F0 の再現にのみ使う。
function Get-UnkaiC0 {
    param($total)
    if ($null -eq $total) { return $null }
    return 1.0 - (Get-Clamp01 -v ([double]$total / 100.0))
}

# R: 夜間の冷え込み。日没時から対象時刻までの気温低下。
# 霧が発生すると冷却が鈍る一方、霧頂では冷却が続くため、実際の冷え込みとの対応は単純ではない。
# C との情報の重複もあり、検証で見直す候補。
function Get-UnkaiR_Drop {
    param($tSunset, $tNow)
    if ($null -eq $tSunset -or $null -eq $tNow) { return $null }
    return Get-Clamp01 -v ((([double]$tSunset) - ([double]$tNow)) / 5.0)
}

# 日較差版（前日の最高気温 − 当日の最低気温）。福田さんの経験則に近い形。並記記録用。
function Get-UnkaiR_Range {
    param($tMaxPrev, $tMinToday)
    if ($null -eq $tMaxPrev -or $null -eq $tMinToday) { return $null }
    return Get-Clamp01 -v (((([double]$tMaxPrev) - ([double]$tMinToday)) - 7.0) / 8.0)
}

# ---- 雲頂推定 ----

# 推定雲頂高度 $h に対する展望条件。H_S-150m 以下なら 1.0、H_S+100m 以上なら 0。
function Get-UnkaiVTop {
    param([double]$h, [double]$SummitElev)
    $lo = $SummitElev - 150.0
    $hi = $SummitElev + 100.0
    if ($h -le $lo) { return 1.0 }
    if ($h -ge $hi) { return 0.0 }
    return ($hi - $h) / ($hi - $lo)
}

# ---- 展望地点が雲の中にないか（V_summit）----
#
# 地上から離れた層雲は「谷の霧層の上端」ロジックでは捉えられないため、展望地点の高度 H_S を
# 挟む上下の湿り具合を別に見る。挟む面は 875/850hPa などに固定せず、その時刻の
# geopotential_height から毎回選ぶ。
#
# 展望地点(S)は格子標高が約1296m、直上の有効面が850hPa(約1412m)で、H_S=1400m をちょうど
# 挟める。谷側のプロファイル(875hPa≒1215m)より展望地点に近いので、こちらを主に使う。
#   下側 = 展望地点の地上湿度 RH_2m（高度 = 返却標高）
#   上側 = 展望地点の有効面のうち H_S より上で最も低いもの
#
# 0/0.4/0.7/1.0 はいずれも仮の係数。0 は「確実に霧」ではなく、濃い霧の可能性を重く見た
# 暫定的な強い減点。上下の湿度だけでは 0.4 と 0.7 の差を物理的に確定できない。
# 上下どちらかが欠ける場合は 1.0 にせず null（補正を適用しない）とし、良好と区別して記録する。
function Get-UnkaiVSummit {
    param($RhBelow, $ElevBelow, $Levels, [double]$SummitElev)
    $res = [ordered]@{
        v = $null; status = "insufficient"
        rh_below = $RhBelow; z_below = $ElevBelow
        rh_above = $null; z_above = $null; p_above = $null
    }
    # 下側は展望地点の地上値。地上が H_S より上にある設定では挟めない。
    if ($null -eq $RhBelow -or $null -eq $ElevBelow -or [double]$ElevBelow -ge $SummitElev) { return $res }

    # 上側は H_S より上で最も低い有効面（毎時の実高度で選ぶ）
    $above = $null
    foreach ($l in $Levels) {
        if (-not $l.valid) { continue }
        if ([double]$l.z -le $SummitElev) { continue }
        if ($null -eq $above -or [double]$l.z -lt [double]$above.z) { $above = $l }
    }
    if ($null -eq $above) { return $res }
    $res.rh_above = $above.rh; $res.z_above = $above.z; $res.p_above = $above.p

    $wetBelow = ([double]$RhBelow    -ge 90.0)
    $wetAbove = ([double]$above.rh -ge 90.0)
    if     ($wetBelow -and $wetAbove) { $res.v = 0.00; $res.status = "summit_in_layer" }
    elseif ($wetBelow)                { $res.v = 0.40; $res.status = "below_wet" }
    elseif ($wetAbove)                { $res.v = 0.70; $res.status = "above_wet" }
    else                              { $res.v = 1.00; $res.status = "summit_dry" }
    return $res
}

# 谷上空の展望高度帯に湿潤層があるかどうか（補助・記録のみ）。
# 山上側で挟めた場合は V に掛けないが、山上と食い違うときの手がかりとして残す。
function Get-UnkaiValleyBandWet {
    param($Levels, [double]$SummitElev)
    foreach ($l in $Levels) {
        if (-not $l.valid) { continue }
        if ($null -eq $l.rh) { continue }
        if ([double]$l.rh -lt 90.0) { continue }
        if ([double]$l.z -ge ($SummitElev - 200.0) -and [double]$l.z -le ($SummitElev + 250.0)) { return $true }
    }
    return $false
}

# 適用できた補正だけの最小値をとる。すべて適用できなければ null。
# 補正を適用しないことと「良好(1.0)」は区別する。
function Get-UnkaiVCombine {
    param($Values)
    $vals = @($Values | Where-Object { $null -ne $_ })
    if ($vals.Count -eq 0) { return $null }
    $m = [double]$vals[0]
    foreach ($v in $vals) { if ([double]$v -lt $m) { $m = [double]$v } }
    return $m
}

# 谷地点の気圧面プロファイルから雲頂を推定する。
# 単一値ではなく下側・上側の高度と状態を返す。粗い高度間隔による不確かさを潰さないため。
#   capped           : 湿潤層の上に乾いた面がある（雲頂を挟めた）
#   straddles_summit : capped だが推定範囲が展望地点の高度を跨ぐ（判定が曖昧）
#   no_moist_layer   : 地上から連続する湿潤層を検出できない。V_top=null（補正を適用しない）
#   saturated_to_top : 取得範囲の最上まで RH>=90%。雲頂を確認できないため V_top=null
#   insufficient_levels : 地中を除いた有効面が2面未満。判定不能で V_top=null
# no_moist_layer に 1.0 を与えないのは、「湿潤層を検出できなかった」ことを「展望良好」と
# 同じ扱いにしないため。地上から離れた層雲はここでは捉えられず、それは V_summit が受け持つ。
function Get-UnkaiCloudTop {
    param($Rh, $Gph, $SurfacePressure, [double]$SummitElev)
    $res = [ordered]@{
        top_status = "insufficient_levels"
        h_lower = $null; h_upper = $null; h_mid = $null
        v_top = $null; v_top_low = $null; v_top_high = $null
        straddles = $false; levels_used = 0
    }
    if ($null -eq $SurfacePressure) { return $res }
    $sp = [double]$SurfacePressure

    # 地中の面を除く。surface_pressure も返却標高への補正を受けている可能性があるため、
    # 判別の妥当性を後から検証できるよう値そのものを記録側に残す。
    $valid = @()
    foreach ($p in ($UnkaiLevels | Sort-Object -Descending)) {
        if ($p -ge ($sp - 5.0)) { continue }
        if ($null -eq $Rh[$p] -or $null -eq $Gph[$p]) { continue }
        $valid += , ([ordered]@{ p = $p; rh = [double]$Rh[$p]; z = [double]$Gph[$p] })
    }
    $res.levels_used = $valid.Count
    if ($valid.Count -lt 2) { return $res }

    # 最下有効面が乾いていれば、地上から連続する湿潤層は検出できない。
    # 地上〜最下面の間だけの浅い霧も、地上から離れた層雲も、ここでは判別できないため
    # 「良好」とはせず補正を適用しない（null）。
    if ($valid[0].rh -lt 90.0) {
        $res.top_status = "no_moist_layer"
        return $res
    }

    $i = 0
    while ($i + 1 -lt $valid.Count -and $valid[$i + 1].rh -ge 90.0) { $i++ }
    if ($i -eq $valid.Count - 1) {
        $res.top_status = "saturated_to_top"
        $res.h_lower = $valid[$i].z
        return $res
    }

    $res.top_status = "capped"
    $res.h_lower = $valid[$i].z
    $res.h_upper = $valid[$i + 1].z
    $res.h_mid   = ($res.h_lower + $res.h_upper) / 2.0
    $res.v_top      = Get-UnkaiVTop -h $res.h_mid   -SummitElev $SummitElev
    $res.v_top_low  = Get-UnkaiVTop -h $res.h_lower -SummitElev $SummitElev
    $res.v_top_high = Get-UnkaiVTop -h $res.h_upper -SummitElev $SummitElev
    if ($res.h_lower -lt $SummitElev -and $res.h_upper -gt $SummitElev) {
        $res.straddles = $true
        $res.top_status = "straddles_summit"
    }
    return $res
}

# V_vis: 展望地点の予報視程。best_match のみ提供され、ECMWF では全 null。
# null は「視界良好」ではなく「視程補正なし」。呼び出し側で vis_status を必ず記録する。
function Get-UnkaiVVis {
    param($vis)
    if ($null -eq $vis) { return $null }
    return Get-Clamp01 -v ((([double]$vis) - 1000.0) / 9000.0)
}

# V_sfc: 山上の低層雲量・RH。記録のみで V には掛けない。
# 山上グリッドの低層雲は「現地の霧」と「眼下の雲海がセルに含まれているだけ」を区別できず、
# min に入れると雲海の出ている日を機械的に減点してしまうため。
function Get-UnkaiVSfc {
    param($low, $rh)
    $a = if ($null -eq $low) { $null } else { 1.0 - (Get-Clamp01 -v ((([double]$low) - 40.0) / 50.0)) }
    $b = if ($null -eq $rh)  { $null } else { Get-Clamp01 -v ((98.0 - ([double]$rh)) / 10.0) }
    if ($null -eq $a) { return $b }
    if ($null -eq $b) { return $a }
    return [math]::Min($a, $b)
}

# ---- API取得 ----

$UnkaiSurfaceVars = "temperature_2m,dew_point_2m,relative_humidity_2m,wind_speed_10m,cloud_cover,cloud_cover_low,cloud_cover_mid,cloud_cover_high,precipitation,surface_pressure,visibility"
$UnkaiDailyVars   = "temperature_2m_max,temperature_2m_min,sunrise,sunset"

# 展望地点1 + 谷5 をカンマ区切りで1リクエストにまとめて取得する。
# past_days=1 は、予報初日の「前日の日没・前日の最高気温」を得るために必要。
function Get-UnkaiBundle {
    param([string]$Model, [int]$ForecastDays = 7, [string]$Timezone = "Asia/Tokyo")
    $pts = @($UnkaiViewpoint) + $UnkaiValleys
    $lv = @()
    foreach ($p in $UnkaiLevels) {
        $lv += ("relative_humidity_{0}hPa" -f $p)
        $lv += ("geopotential_height_{0}hPa" -f $p)
    }
    $query = [ordered]@{
        latitude        = (($pts | ForEach-Object { $_.lat }) -join ",")
        longitude       = (($pts | ForEach-Object { $_.lon }) -join ",")
        hourly          = ($UnkaiSurfaceVars + "," + ($lv -join ","))
        daily           = $UnkaiDailyVars
        timezone        = $Timezone
        forecast_days   = $ForecastDays
        past_days       = 1
        wind_speed_unit = "ms"
    }
    if (-not [string]::IsNullOrWhiteSpace($Model)) { $query["models"] = $Model }
    $pairs = $query.GetEnumerator() | ForEach-Object { "{0}={1}" -f $_.Key, [uri]::EscapeDataString([string]$_.Value) }
    $url = "https://api.open-meteo.com/v1/forecast?" + ($pairs -join "&")
    $res = Invoke-JsonWithRetry -Uri $url

    # 複数地点指定時は配列で返る。地点定義と同じ順序で対応付ける。
    $arr = @($res)
    if ($arr.Count -ne $pts.Count) {
        throw ("雲海: 地点数が一致しません（要求 {0} / 応答 {1}）" -f $pts.Count, $arr.Count)
    }
    $out = [ordered]@{}
    for ($i = 0; $i -lt $pts.Count; $i++) {
        $d = $arr[$i]
        $out[[string]$pts[$i].id] = [ordered]@{
            meta   = $pts[$i]
            data   = $d
            idxMap = (New-UnkaiTimeIndex -times $d.hourly.time)
            elev   = $d.elevation
        }
    }
    return $out
}

# ---- 1地点・1時刻の計算 ----

function Get-UnkaiValleyRow {
    param(
        $Point, [datetime]$At, [datetime]$SunsetPrev, [datetime]$MidnightPrev,
        $TMaxPrev, $TMinToday, [double]$SummitElev
    )
    $h = $Point.data.hourly
    $ix = $Point.idxMap

    $t     = Get-UnkaiValueAt -idxMap $ix -values $h.temperature_2m       -at $At
    $td    = Get-UnkaiValueAt -idxMap $ix -values $h.dew_point_2m         -at $At
    $rh    = Get-UnkaiValueAt -idxMap $ix -values $h.relative_humidity_2m -at $At
    $wind  = Get-UnkaiValueAt -idxMap $ix -values $h.wind_speed_10m       -at $At
    $low   = Get-UnkaiValueAt -idxMap $ix -values $h.cloud_cover_low      -at $At
    $tot   = Get-UnkaiValueAt -idxMap $ix -values $h.cloud_cover          -at $At
    $prec  = Get-UnkaiValueAt -idxMap $ix -values $h.precipitation        -at $At
    $sp    = Get-UnkaiValueAt -idxMap $ix -values $h.surface_pressure     -at $At
    $lowAtSunset = Get-UnkaiInterp -idxMap $ix -values $h.cloud_cover_low -at $SunsetPrev

    # C は日没〜対象時刻の中・高層雲の平均
    $midM  = Get-UnkaiMean -idxMap $ix -values $h.cloud_cover_mid  -from $SunsetPrev -to $At
    $highM = Get-UnkaiMean -idxMap $ix -values $h.cloud_cover_high -from $SunsetPrev -to $At
    # C0 は当初案の定義（全雲量・日没〜深夜）
    $totM  = Get-UnkaiMean -idxMap $ix -values $h.cloud_cover -from $SunsetPrev -to $MidnightPrev
    $tSunset = Get-UnkaiInterp -idxMap $ix -values $h.temperature_2m -at $SunsetPrev

    $mRh  = Get-UnkaiM_Rh  -rh $rh
    $mLin = Get-UnkaiM_Dpd -t $t -td $td
    $mPow = if ($null -eq $mLin) { $null } else { [math]::Pow($mLin, 0.7) }
    $W    = Get-UnkaiW -wind $wind
    $C    = Get-UnkaiC  -mid $midM -high $highM
    $C0   = Get-UnkaiC0 -total $totM
    $rDrop  = Get-UnkaiR_Drop  -tSunset $tSunset -tNow $t
    $rRange = Get-UnkaiR_Range -tMaxPrev $TMaxPrev -tMinToday $TMinToday

    # --- 式バリアント ---
    # 構造の比較（M・R は本番設定で固定）
    #   F_add : 加算式。M 以外を足し合わせるため「湿って弱風」だけで0.60が確定してしまう。
    #   F_b   : W も掛け算に。
    #   F_c   : C も掛け算に（本番）。M・W・C の3つを必要条件として掛け、R だけ加点に残す。
    #           経験則の「晴れ かつ 弱風 かつ 気温差大 かつ 湿度80%以上」というAND構造に最も近い。
    $Fadd = Get-UnkaiF   -M $mRh -Const 0.30 -W $W -Wc 0.30 -C $C -Cc 0.25 -R $rDrop -Rc 0.15
    $Fb   = Get-UnkaiF_B -M $mRh -W $W -C $C -R $rDrop
    $Fc   = Get-UnkaiF_C -M $mRh -W $W -C $C -R $rDrop

    # M・R の比較（構造は案cで固定）
    $FcMlin   = Get-UnkaiF_C -M $mLin -W $W -C $C -R $rDrop
    $FcMpow   = Get-UnkaiF_C -M $mPow -W $W -C $C -R $rDrop
    $FcRrange = Get-UnkaiF_C -M $mRh  -W $W -C $C -R $rRange

    # 当初案そのまま（主観を入れる前の式）。C も当初定義の C0 を使う。
    $F0 = Get-UnkaiF -M $mLin -Const 0.50 -W $W -Wc 0.25 -C $C0 -Cc 0.15 -R $rDrop -Rc 0.10

    # 経験則ベースライン: 湿度80%以上・風3m/s未満・日較差8℃以上・中高層雲40%未満
    $range = if ($null -eq $TMaxPrev -or $null -eq $TMinToday) { $null } else { [double]$TMaxPrev - [double]$TMinToday }
    $midHigh = if ($null -eq $midM -and $null -eq $highM) { $null } else {
        (&{ if ($null -eq $midM) { 0.0 } else { [double]$midM } }) + (&{ if ($null -eq $highM) { 0.0 } else { [double]$highM } })
    }
    $simple = $null
    if ($null -ne $rh -and $null -ne $wind -and $null -ne $range -and $null -ne $midHigh) {
        $simple = ([double]$rh -ge 80.0 -and [double]$wind -lt 3.0 -and $range -ge 8.0 -and $midHigh -lt 40.0)
    }

    # 雲頂
    $rhL = @{}; $gpL = @{}
    foreach ($p in $UnkaiLevels) {
        $rhL[$p] = Get-UnkaiValueAt -idxMap $ix -values $h.("relative_humidity_{0}hPa"   -f $p) -at $At
        $gpL[$p] = Get-UnkaiValueAt -idxMap $ix -values $h.("geopotential_height_{0}hPa" -f $p) -at $At
    }
    $top = Get-UnkaiCloudTop -Rh $rhL -Gph $gpL -SurfacePressure $sp -SummitElev $SummitElev

    # 気圧面プロファイルを生のまま残す（検証用ページで雲頂推定の根拠を確認するため）
    $levels = @()
    foreach ($p in ($UnkaiLevels | Sort-Object -Descending)) {
        $valid = ($null -ne $sp -and $p -lt ([double]$sp - 5.0) -and $null -ne $rhL[$p] -and $null -ne $gpL[$p])
        $levels += , ([ordered]@{ p = $p; rh = $rhL[$p]; z = $gpL[$p]; valid = $valid })
    }

    return [ordered]@{
        id = $Point.meta.id; name = $Point.meta.name; dir = $Point.meta.dir
        api_elev = $Point.elev
        t = $t; td = $td; dpd = (&{ if ($null -eq $t -or $null -eq $td) { $null } else { [double]$t - [double]$td } })
        rh = $rh; wind = $wind; low = $low; mid = $midM; high = $highM; total = $totM
        precip = $prec; surface_pressure = $sp; low_at_sunset = $lowAtSunset; day_range = $range
        m_rh = $mRh; m_dpd_lin = $mLin; m_dpd_pow = $mPow
        w = $W; c = $C; c0 = $C0; r_drop = $rDrop; r_range = $rRange
        f = $Fc; f_add = $Fadd; f_b = $Fb; f_c = $Fc
        f_c_mlin = $FcMlin; f_c_mpow = $FcMpow; f_c_rrange = $FcRrange
        f0 = $F0; simple = $simple
        top = $top; levels = $levels
    }
}

# F = M × (定数 + 各係数×各因子)。因子が1つでも欠ければ null（欠測を0点と混同しないため）。
function Get-UnkaiF {
    param($M, [double]$Const, $W, [double]$Wc, $C, [double]$Cc, $R, [double]$Rc)
    if ($null -eq $M -or $null -eq $W -or $null -eq $C -or $null -eq $R) { return $null }
    return [double]$M * ($Const + $Wc * [double]$W + $Cc * [double]$C + $Rc * [double]$R)
}

# 案b: 風も必要条件として掛ける。
function Get-UnkaiF_B {
    param($M, $W, $C, $R)
    if ($null -eq $M -or $null -eq $W -or $null -eq $C -or $null -eq $R) { return $null }
    return [double]$M * [double]$W * (0.35 + 0.45 * [double]$C + 0.20 * [double]$R)
}

# 案c(本番): 上空の雲も必要条件として掛ける。C は 0 でも完全には潰さず 0.3 を残す
# （中・高層雲が多くても雲海が出ることはあるため、ゲートではなく強い減点として扱う）。
function Get-UnkaiF_C {
    param($M, $W, $C, $R)
    if ($null -eq $M -or $null -eq $W -or $null -eq $C -or $null -eq $R) { return $null }
    return [double]$M * (0.3 + 0.7 * [double]$C) * (0.35 + 0.40 * [double]$W + 0.25 * [double]$R)
}

# ---- 全体の組み立て ----

# 対象時刻に降っていれば放射霧ではないし、展望も利かない。
# 前夜の雨は好条件なので、ゲートは対象時刻の降水量だけで判定する。
$UnkaiPrecipGate = 0.5

function Get-UnkaiGate {
    param($Precip)
    if ($null -eq $Precip) { return $true }
    return ([double]$Precip -le $UnkaiPrecipGate)
}

function Get-UnkaiLabel {
    param($F, $V, [string]$TopStatus, [string]$SummitStatus, [bool]$GateF = $true, [bool]$GateV = $true)
    if (-not $GateF -or -not $GateV) { return "降水あり" }
    if ($null -eq $F) { return "判定不能" }
    if ($null -eq $V) { return "判定不能" }
    if ([double]$F -lt 0.40) { return "雲海の条件なし" }
    # 「現地も霧」は断定ではなく、展望高度帯が湿っているという疑いを示す。
    if ($SummitStatus -eq "summit_in_layer") { return "雲海あり・現地も霧の疑い" }
    if ($TopStatus -eq "straddles_summit")   { return "雲海あり・雲頂不確実" }
    if ($SummitStatus -eq "insufficient")    { return "雲海あり・展望は判定材料不足" }
    if ([double]$V -ge 0.60) { return "雲海あり・展望良好" }
    if ([double]$V -ge 0.30) { return "雲海あり・展望不良" }
    return "雲海あり・現地も霧の疑い"
}

function Get-UnkaiIdx {
    param($F, $V, [bool]$GateF = $true, [bool]$GateV = $true)
    # 降水ゲートは V が求まらない場合より優先する。大雨で雲頂を確認できない日を
    # 「判定不能」ではなく 0（降水あり）と言い切るため。
    if (-not $GateF -or -not $GateV) { return 0 }
    if ($null -eq $F -or $null -eq $V) { return $null }
    $x = 100.0 * [double]$F * [double]$V
    if ($x -lt 0) { $x = 0 }
    return [int][math]::Round($x)
}

# 谷ごとの指数を方角別・全体に集約する。どこか1つの谷で出れば見えるので max をとり、
# あわせて一定以上に達した地点数（広がりの目安）を数える。
function Get-UnkaiAggregate {
    param($Valleys)
    $best = $null; $north = $null; $south = $null; $spread = 0
    foreach ($r in $Valleys) {
        if ($null -eq $r.idx) { continue }
        if ($r.idx -ge $UnkaiSpreadThreshold) { $spread++ }
        if ($null -eq $best  -or $r.idx -gt $best.idx)  { $best  = $r }
        if ($r.dir -eq "北" -and ($null -eq $north -or $r.idx -gt $north.idx)) { $north = $r }
        if ($r.dir -eq "南" -and ($null -eq $south -or $r.idx -gt $south.idx)) { $south = $r }
    }
    return [ordered]@{ best = $best; north = $north; south = $south; spread = $spread }
}

# 平均版。F は両モデルの平均、V は best_match 側のものを使う。
# ECMWF は視程が全欠測で気圧面も粗く、V の材料が揃わないため（混成である旨は凡例に明記する）。
function Get-UnkaiTableAverage {
    param($TableA, $TableB)
    $mapB = @{}
    foreach ($h in $TableB) { $mapB[[string]$h.time] = $h }

    $out = @()
    foreach ($ha in $TableA) {
        $hb = $mapB[[string]$ha.time]
        $valleys = @()
        foreach ($ra in $ha.valleys) {
            $rb = if ($null -eq $hb) { $null } else { $hb.valleys | Where-Object { $_.id -eq $ra.id } }
            $row = [ordered]@{}
            foreach ($k in $ra.Keys) { $row[$k] = $ra[$k] }
            foreach ($k in @("f_c","f_add","f_b","f_c_mlin","f_c_mpow","f_c_rrange","f0")) {
                $row[$k] = Get-UnkaiMeanOf2 -A $ra[$k] -B (&{ if ($null -eq $rb) { $null } else { $rb[$k] } })
            }
            $row["f"] = $row["f_c"]
            # V・ゲートは A（best_match）側をそのまま使う
            $row["idx"]          = Get-UnkaiIdx -F $row.f_c        -V $ra.v -GateF $ra.gate_f -GateV $ra.gate_v
            $row["idx_add"]      = Get-UnkaiIdx -F $row.f_add      -V $ra.v -GateF $ra.gate_f -GateV $ra.gate_v
            $row["idx_b"]        = Get-UnkaiIdx -F $row.f_b        -V $ra.v -GateF $ra.gate_f -GateV $ra.gate_v
            $row["idx_c_mlin"]   = Get-UnkaiIdx -F $row.f_c_mlin   -V $ra.v -GateF $ra.gate_f -GateV $ra.gate_v
            $row["idx_c_mpow"]   = Get-UnkaiIdx -F $row.f_c_mpow   -V $ra.v -GateF $ra.gate_f -GateV $ra.gate_v
            $row["idx_c_rrange"] = Get-UnkaiIdx -F $row.f_c_rrange -V $ra.v -GateF $ra.gate_f -GateV $ra.gate_v
            $row["idx_f0"]       = Get-UnkaiIdx -F $row.f0         -V $ra.v -GateF $ra.gate_f -GateV $ra.gate_v
            $row["label"] = Get-UnkaiLabel -F $row.f_c -V $ra.v -TopStatus $ra.top.top_status `
                                -SummitStatus $ra.summit_status -GateF $ra.gate_f -GateV $ra.gate_v
            $valleys += , $row
        }
        $agg = Get-UnkaiAggregate -Valleys $valleys
        $h = [ordered]@{}
        foreach ($k in $ha.Keys) { $h[$k] = $ha[$k] }
        $h["valleys"] = $valleys
        $h["best"] = $agg.best; $h["north"] = $agg.north; $h["south"] = $agg.south
        $h["idx"]   = (&{ if ($null -eq $agg.best) { $null } else { $agg.best.idx } })
        $h["dir"]   = (&{ if ($null -eq $agg.best -or $agg.best.idx -le 0) { "--" } else { $agg.best.dir } })
        $h["label"] = (&{ if ($null -eq $agg.best) { "判定不能" } else { $agg.best.label } })
        $h["spread"] = $agg.spread
        $out += , $h
    }
    return $out
}

function Get-UnkaiMeanOf2 {
    param($A, $B)
    if ($null -eq $A -and $null -eq $B) { return $null }
    if ($null -eq $A) { return [double]$B }
    if ($null -eq $B) { return [double]$A }
    return ([double]$A + [double]$B) / 2.0
}

# 日の出前後4時刻 × 谷4地点を計算し、時刻単位に集約した表を返す。
function Get-UnkaiTable {
    param($Bundle, [double]$SummitElev = $UnkaiSummitElev)

    $vp     = $Bundle["S"]
    $vpH    = $vp.data.hourly
    $vpIx   = $vp.idxMap
    $daily  = $vp.data.daily
    $hours  = @()

    for ($j = 1; $j -lt $daily.time.Count; $j++) {
        if ([string]::IsNullOrWhiteSpace($daily.sunrise[$j]) -or [string]::IsNullOrWhiteSpace($daily.sunset[$j - 1])) { continue }
        $sunrise    = [datetime]::ParseExact([string]$daily.sunrise[$j],     "yyyy-MM-dd'T'HH:mm", $null)
        $sunsetPrev = [datetime]::ParseExact([string]$daily.sunset[$j - 1],  "yyyy-MM-dd'T'HH:mm", $null)
        $dayStart   = [datetime]::new($sunrise.Year, $sunrise.Month, $sunrise.Day, 0, 0, 0)
        $hSr        = if ($sunrise.Minute -ge 30) { $sunrise.Hour + 1 } else { $sunrise.Hour }

        foreach ($off in -1, 0, 1, 2) {
            $at = $dayStart.AddHours($hSr + $off)

            # 展望地点(S)側
            $vis    = Get-UnkaiValueAt -idxMap $vpIx -values $vpH.visibility           -at $at
            $vpLow  = Get-UnkaiValueAt -idxMap $vpIx -values $vpH.cloud_cover_low      -at $at
            $vpRh   = Get-UnkaiValueAt -idxMap $vpIx -values $vpH.relative_humidity_2m -at $at
            $vpPrec = Get-UnkaiValueAt -idxMap $vpIx -values $vpH.precipitation        -at $at
            $vVis   = Get-UnkaiVVis -vis $vis
            $vSfc   = Get-UnkaiVSfc -low $vpLow -rh $vpRh
            $visStatus = if ($null -eq $vis) { "missing" } else { "ok" }
            $gateV  = Get-UnkaiGate -Precip $vpPrec

            # 展望地点が雲の中にないか。下側は山上の地上湿度、上側は H_S より上で最も低い
            # 有効面（毎時の実高度で選ぶ）。谷側より展望地点に近い位置で挟めるため主に使う。
            $vpSp = Get-UnkaiValueAt -idxMap $vpIx -values $vpH.surface_pressure -at $at
            $vpLevels = @()
            foreach ($p in ($UnkaiLevels | Sort-Object -Descending)) {
                $lrh = Get-UnkaiValueAt -idxMap $vpIx -values $vpH.("relative_humidity_{0}hPa"   -f $p) -at $at
                $lz  = Get-UnkaiValueAt -idxMap $vpIx -values $vpH.("geopotential_height_{0}hPa" -f $p) -at $at
                $lok = ($null -ne $vpSp -and $p -lt ([double]$vpSp - 5.0) -and $null -ne $lrh -and $null -ne $lz)
                $vpLevels += , ([ordered]@{ p = $p; rh = $lrh; z = $lz; valid = $lok })
            }
            $summit = Get-UnkaiVSummit -RhBelow $vpRh -ElevBelow $vp.elev -Levels $vpLevels -SummitElev $SummitElev

            $valleys = @()
            foreach ($v in $UnkaiValleys) {
                $pt = $Bundle[[string]$v.id]
                $vd = $pt.data.daily
                $row = Get-UnkaiValleyRow -Point $pt -At $at -SunsetPrev $sunsetPrev -MidnightPrev $dayStart `
                        -TMaxPrev $vd.temperature_2m_max[$j - 1] -TMinToday $vd.temperature_2m_min[$j] `
                        -SummitElev $SummitElev

                # V_dir = min(V_top_fog_dir, V_summit, V_vis_S)
                # 適用できた補正だけの最小値をとる。すべて適用できなければ null（指数は "--"）。
                # 補正を適用しないことと「良好(1.0)」は区別して記録する。
                $vTop = $row.top.v_top
                $V = Get-UnkaiVCombine -Values @($vTop, $summit.v, $vVis)

                # 谷で降っていれば放射霧ではない。山上で降っていれば展望も利かない。
                $gateF = Get-UnkaiGate -Precip $row.precip

                $row["v_vis"] = $vVis
                $row["vis_status"] = $visStatus
                $row["v_sfc"] = $vSfc
                $row["v_top_fog"] = $vTop
                $row["v_summit"] = $summit.v
                $row["summit_status"] = $summit.status
                $row["summit_rh_below"] = $summit.rh_below
                $row["summit_z_below"]  = $summit.z_below
                $row["summit_rh_above"] = $summit.rh_above
                $row["summit_z_above"]  = $summit.z_above
                $row["summit_p_above"]  = $summit.p_above
                # 谷上空の展望高度帯が湿っているか（補助・記録のみ）。山上判定と食い違うときの手がかり。
                $row["valley_band_wet"] = Get-UnkaiValleyBandWet -Levels $row.levels -SummitElev $SummitElev
                $row["v"] = $V
                $row["gate_f"] = $gateF
                $row["gate_v"] = $gateV
                # idx が本番（案c）。他は検証用ページ向けの並記。
                $row["idx"]          = Get-UnkaiIdx -F $row.f_c        -V $V -GateF $gateF -GateV $gateV
                $row["idx_add"]      = Get-UnkaiIdx -F $row.f_add      -V $V -GateF $gateF -GateV $gateV
                $row["idx_b"]        = Get-UnkaiIdx -F $row.f_b        -V $V -GateF $gateF -GateV $gateV
                $row["idx_c_mlin"]   = Get-UnkaiIdx -F $row.f_c_mlin   -V $V -GateF $gateF -GateV $gateV
                $row["idx_c_mpow"]   = Get-UnkaiIdx -F $row.f_c_mpow   -V $V -GateF $gateF -GateV $gateV
                $row["idx_c_rrange"] = Get-UnkaiIdx -F $row.f_c_rrange -V $V -GateF $gateF -GateV $gateV
                $row["idx_f0"]       = Get-UnkaiIdx -F $row.f0         -V $V -GateF $gateF -GateV $gateV
                $row["label"]  = Get-UnkaiLabel -F $row.f_c -V $V -TopStatus $row.top.top_status `
                                    -SummitStatus $summit.status -GateF $gateF -GateV $gateV
                $valleys += , $row
            }

            $agg = Get-UnkaiAggregate -Valleys $valleys
            $best = $agg.best; $north = $agg.north; $south = $agg.south; $spread = $agg.spread

            $hours += , [ordered]@{
                date = $dayStart.ToString("yyyy-MM-dd")
                time = $at.ToString("yyyy-MM-dd HH:00")
                hh = $at.ToString("HH")
                sunrise = $sunrise.ToString("HH:mm")
                offset = $off
                valleys = $valleys
                best = $best; north = $north; south = $south
                idx = (&{ if ($null -eq $best) { $null } else { $best.idx } })
                dir = (&{ if ($null -eq $best -or $best.idx -le 0) { "--" } else { $best.dir } })
                label = (&{ if ($null -eq $best) { "判定不能" } else { $best.label } })
                spread = $spread
                spread_total = $UnkaiValleys.Count
                vp_vis = $vis; vp_low = $vpLow; vp_rh = $vpRh; vp_precip = $vpPrec
                v_vis = $vVis; v_sfc = $vSfc; vis_status = $visStatus; gate_v = $gateV
                summit = $summit; vp_levels = $vpLevels
            }
        }
    }
    return $hours
}

# 日別（その日の4時刻のうち最大の時刻をとる）
function Get-UnkaiDaily {
    param($Hours)
    $byDate = [ordered]@{}
    foreach ($h in $Hours) {
        if (-not $byDate.Contains($h.date)) { $byDate[$h.date] = @() }
        $byDate[$h.date] += , $h
    }
    $out = @()
    foreach ($d in $byDate.Keys) {
        $peak = $null
        foreach ($h in $byDate[$d]) {
            if ($null -eq $h.idx) { continue }
            if ($null -eq $peak -or $h.idx -gt $peak.idx) { $peak = $h }
        }
        if ($null -eq $peak) {
            $out += , [ordered]@{ date = $d; idx = $null; dir = "--"; label = "判定不能"; peak_time = "--"; spread = 0; spread_total = $UnkaiValleys.Count }
        } else {
            $out += , [ordered]@{
                date = $d; idx = $peak.idx; dir = $peak.dir; label = $peak.label
                peak_time = ($peak.hh + "時"); spread = $peak.spread; spread_total = $peak.spread_total
            }
        }
    }
    return $out
}
