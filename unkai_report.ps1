<#
.SYNOPSIS
  雲海指数の出力（検証用CSV・検証用ページ・実績記録の雛形）。
  lowcloud_common.ps1 の末尾から dot-source される。

.DESCRIPTION
  ここで作るファイルは一般公開しない。publish.ps1 と GitHub Actions はいずれも
  git add の対象を index.html と3版のHTMLに明示限定しているため、
  .gitignore への追加とあわせて二重に公開を防いでいる。
#>

function Format-UnkaiNum {
    param($v, [int]$Digits = 2)
    if ($null -eq $v) { return "" }
    return ("{0:F$Digits}" -f [double]$v)
}

function Format-UnkaiCell {
    param($v, [int]$Digits = 2)
    if ($null -eq $v) { return "--" }
    return ("{0:F$Digits}" -f [double]$v)
}

function Format-UnkaiInt {
    param($v)
    if ($null -eq $v) { return "--" }
    return [string][int]$v
}

function Format-UnkaiBool {
    param($v)
    if ($null -eq $v) { return "" }
    if ($v) { return "1" } else { return "0" }
}

$UnkaiTopStatusText = @{
    "capped"              = "雲頂を挟めた"
    "straddles_summit"    = "展望地点の高度を跨ぐ"
    "no_moist_layer"      = "湿潤層を検出できず"
    "saturated_to_top"    = "取得範囲の上まで湿潤"
    "insufficient_levels" = "有効面が2面未満"
}

# ---- 検証用CSV ----

$UnkaiDetailHeader = @(
    "date","time","model","point_id","point_name","dir","api_elev",
    "T","Td","dpd","RH","wind","cloud_low","cloud_low_at_sunset","cloud_mid","cloud_high","cloud_total",
    "precip","surface_pressure","day_range",
    "M_rh","M_dpd_lin","M_dpd_pow","W","C","C0","R_drop","R_range",
    "F_add","F_b","F_c","F_c_mlin","F_c_mpow","F_c_rrange","F0","simple",
    "top_status","levels_used","H_top_lower","H_top_upper","H_top_mid","V_top_fog","V_top_low","V_top_high",
    "summit_status","V_summit","summit_rh_below","summit_z_below","summit_p_above","summit_rh_above","summit_z_above","valley_band_wet",
    "vis","vis_status","V_vis","V_sfc","V","gate_f","gate_v",
    "idx","idx_add","idx_b","idx_c_mlin","idx_c_mpow","idx_c_rrange","idx_f0","label"
) -join ","

function Get-UnkaiDetailLines {
    param($Hours, [string]$Model)
    $lines = @()
    foreach ($h in $Hours) {
        foreach ($r in $h.valleys) {
            $lines += (@(
                $h.date, $h.time, $Model, $r.id, $r.name, $r.dir, (Format-UnkaiNum $r.api_elev 0),
                (Format-UnkaiNum $r.t 1), (Format-UnkaiNum $r.td 1), (Format-UnkaiNum $r.dpd 1),
                (Format-UnkaiNum $r.rh 0), (Format-UnkaiNum $r.wind 2),
                (Format-UnkaiNum $r.low 0), (Format-UnkaiNum $r.low_at_sunset 0),
                (Format-UnkaiNum $r.mid 0), (Format-UnkaiNum $r.high 0), (Format-UnkaiNum $r.total 0),
                (Format-UnkaiNum $r.precip 2), (Format-UnkaiNum $r.surface_pressure 1), (Format-UnkaiNum $r.day_range 1),
                (Format-UnkaiNum $r.m_rh 3), (Format-UnkaiNum $r.m_dpd_lin 3), (Format-UnkaiNum $r.m_dpd_pow 3),
                (Format-UnkaiNum $r.w 3), (Format-UnkaiNum $r.c 3), (Format-UnkaiNum $r.c0 3),
                (Format-UnkaiNum $r.r_drop 3), (Format-UnkaiNum $r.r_range 3),
                (Format-UnkaiNum $r.f_add 3), (Format-UnkaiNum $r.f_b 3), (Format-UnkaiNum $r.f_c 3),
                (Format-UnkaiNum $r.f_c_mlin 3), (Format-UnkaiNum $r.f_c_mpow 3), (Format-UnkaiNum $r.f_c_rrange 3),
                (Format-UnkaiNum $r.f0 3), (Format-UnkaiBool $r.simple),
                $r.top.top_status, $r.top.levels_used,
                (Format-UnkaiNum $r.top.h_lower 0), (Format-UnkaiNum $r.top.h_upper 0), (Format-UnkaiNum $r.top.h_mid 0),
                (Format-UnkaiNum $r.top.v_top 3), (Format-UnkaiNum $r.top.v_top_low 3), (Format-UnkaiNum $r.top.v_top_high 3),
                $r.summit_status, (Format-UnkaiNum $r.v_summit 3),
                (Format-UnkaiNum $r.summit_rh_below 0), (Format-UnkaiNum $r.summit_z_below 0),
                $r.summit_p_above, (Format-UnkaiNum $r.summit_rh_above 0), (Format-UnkaiNum $r.summit_z_above 0),
                (Format-UnkaiBool $r.valley_band_wet),
                (Format-UnkaiNum $h.vp_vis 0), $r.vis_status, (Format-UnkaiNum $r.v_vis 3), (Format-UnkaiNum $r.v_sfc 3),
                (Format-UnkaiNum $r.v 3), (Format-UnkaiBool $r.gate_f), (Format-UnkaiBool $r.gate_v),
                (Format-UnkaiInt $r.idx), (Format-UnkaiInt $r.idx_add), (Format-UnkaiInt $r.idx_b),
                (Format-UnkaiInt $r.idx_c_mlin), (Format-UnkaiInt $r.idx_c_mpow), (Format-UnkaiInt $r.idx_c_rrange),
                (Format-UnkaiInt $r.idx_f0), $r.label
            ) -join ",")
        }
    }
    return $lines
}

$UnkaiLevelHeader = "date,time,model,point_id,point_name,pressure_hPa,rh,geopotential_m,valid"

function Get-UnkaiLevelLines {
    param($Hours, [string]$Model)
    $lines = @()
    foreach ($h in $Hours) {
        foreach ($r in $h.valleys) {
            foreach ($l in $r.levels) {
                $lines += (@(
                    $h.date, $h.time, $Model, $r.id, $r.name, $l.p,
                    (Format-UnkaiNum $l.rh 0), (Format-UnkaiNum $l.z 0), (Format-UnkaiBool $l.valid)
                ) -join ",")
            }
        }
    }
    return $lines
}

# 実績記録の雛形。既存ファイルは絶対に上書きしない（記入済みの内容を失わないため）。
function Initialize-UnkaiLog {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { return $false }
    $head = @(
        "# 雲海の実績記録。谷側(F)と展望側(V)を分けて記録する。",
        "# valley_unkai : なし / 一部 / 広範囲 / 確認できない",
        "# view         : 良好 / 一部遮られる / 霧で見えない",
        "# 展望地点が霧で谷を確認できない日は valley_unkai を「確認できない」とし、",
        "# その日は F の正誤判定に使わず、視界側の検証にだけ使う。",
        "date,valley_unkai,view,direction,note"
    )
    Set-Content -LiteralPath $Path -Value $head -Encoding UTF8
    return $true
}

# ---- 検証用ページ ----

$UnkaiLabCss = @'
body{font-family:"Segoe UI","Yu Gothic UI",sans-serif;margin:16px;background:#fafafa;color:#222;font-size:13px;}
h1{font-size:19px;margin:0 0 4px;}
h2{font-size:15px;margin:22px 0 6px;border-left:5px solid #3a3f7a;padding-left:8px;}
h3{font-size:13px;margin:14px 0 4px;color:#3a3f7a;}
p.meta{color:#666;font-size:11px;margin:0 0 12px;}
p.note{color:#555;font-size:11px;margin:4px 0 10px;line-height:1.6;}
table{border-collapse:collapse;margin:6px 0 10px;background:#fff;}
th,td{border:1px solid #d0d0d0;padding:2px 6px;text-align:right;white-space:nowrap;}
th{background:#eef0f6;font-weight:600;}
td.l,th.l{text-align:left;}
td.prod{background:#eef6ee;font-weight:700;}
th.prod{background:#dfeddf;}
td.dim{color:#999;}
td.bad{background:#fdecea;}
td.warn{background:#fff6e0;}
details{margin:6px 0;}
summary{cursor:pointer;color:#3a3f7a;font-size:12px;padding:3px 0;}
.wrap{overflow-x:auto;}
.legend{font-size:11px;color:#555;line-height:1.7;}
'@

function Get-UnkaiLabHtml {
    param($ByModel, $Bundle, [string]$Generated)

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!DOCTYPE html><html lang="ja"><head><meta charset="utf-8">')
    [void]$sb.AppendLine('<meta name="robots" content="noindex,nofollow">')
    [void]$sb.AppendLine('<title>雲海指数 検証用ページ（非公開）</title>')
    [void]$sb.AppendLine("<style>$UnkaiLabCss</style></head><body>")
    [void]$sb.AppendLine('<h1>雲海指数 検証用ページ<span style="font-size:12px;color:#a00;">（非公開・公開ページとは別）</span></h1>')
    [void]$sb.AppendLine(("<p class=""meta"">生成: {0}　|　展望地点の判定高度 H_S = {1}m　|　降水ゲート {2}mm　|　出典: Open-Meteo</p>" -f $Generated, [int]$UnkaiSummitElev, $UnkaiPrecipGate))
    [void]$sb.AppendLine('<p class="note">係数・しきい値はすべて試作値で、現地実績で検証された式ではありません。指数は「雲海期待度」であって発生確率ではありません。</p>')

    # 地点一覧
    [void]$sb.AppendLine('<h2>地点</h2>')
    [void]$sb.AppendLine('<div class="wrap"><table><tr><th class="l">ID</th><th class="l">名称</th><th class="l">方角</th><th>要求緯度</th><th>要求経度</th><th>応答緯度</th><th>応答経度</th><th>返却標高</th></tr>')
    foreach ($p in (@($UnkaiViewpoint) + $UnkaiValleys)) {
        $b = $Bundle[[string]$p.id]
        [void]$sb.AppendLine(("<tr><td class=""l"">{0}</td><td class=""l"">{1}</td><td class=""l"">{2}</td><td>{3}</td><td>{4}</td><td>{5}</td><td>{6}</td><td>{7}m</td></tr>" -f `
            $p.id, $p.name, $p.dir, $p.lat, $p.lon, $b.data.latitude, $b.data.longitude, [int]$b.elev))
    }
    [void]$sb.AppendLine('</table></div>')
    [void]$sb.AppendLine('<p class="note">返却標高は要求座標のDEM由来で、モデルの地形標高でも実測標高でもありません。応答緯度経度が同じ地点は同一の格子セルを見ています。</p>')

    foreach ($model in $ByModel.Keys) {
        $hrs = $ByModel[$model]
        [void]$sb.AppendLine(("<h2>{0}</h2>" -f $model))
        if ($null -eq $hrs -or $hrs.Count -eq 0) {
            [void]$sb.AppendLine('<p class="note">データがありません。</p>')
            continue
        }

        # --- 式バリアント比較 ---
        [void]$sb.AppendLine('<h3>式バリアント比較（各時刻の最良地点）</h3>')
        [void]$sb.AppendLine('<div class="wrap"><table><tr><th class="l">日時</th><th class="l">地点</th><th>現行(加算)</th><th>案b</th><th class="prod">案c 本番</th><th>当初案</th><th>簡易判定</th><th class="l">状態</th></tr>')
        foreach ($h in $hrs) {
            $r = $h.best
            if ($null -eq $r) {
                [void]$sb.AppendLine(("<tr><td class=""l"">{0}</td><td class=""l"" colspan=""7"">判定不能</td></tr>" -f $h.time))
                continue
            }
            $sim = if ($null -eq $r.simple) { "--" } elseif ($r.simple) { "○" } else { "×" }
            [void]$sb.AppendLine(("<tr><td class=""l"">{0}</td><td class=""l"">{1}</td><td>{2}</td><td>{3}</td><td class=""prod"">{4}</td><td>{5}</td><td>{6}</td><td class=""l"">{7}</td></tr>" -f `
                $h.time, $r.name, (Format-UnkaiInt $r.idx_add), (Format-UnkaiInt $r.idx_b), (Format-UnkaiInt $r.idx), (Format-UnkaiInt $r.idx_f0), $sim, $r.label))
        }
        [void]$sb.AppendLine('</table></div>')
        [void]$sb.AppendLine('<p class="note">現行(加算)=M×(.30+.30W+.25C+.15R)　案b=M×W×(.35+.45C+.20R)　案c=M×(.3+.7C)×(.35+.40W+.25R)　当初案=露点差ベース・定数0.50・全雲量C0。<br>簡易判定＝経験則（湿度80%以上・風3m/s未満・日較差8℃以上・中高層雲40%未満）。指数がこの判定に勝てなければ複雑な式を使う意味がありません。</p>')

        # --- M・R の比較 ---
        [void]$sb.AppendLine('<details><summary>M・R の比較（構造は案cで固定）</summary><div class="wrap"><table><tr><th class="l">日時</th><th class="l">地点</th><th class="prod">M_rh 本番</th><th>M 露点差(線形)</th><th>M 露点差(曲線)</th><th>R 日較差版</th></tr>')
        foreach ($h in $hrs) {
            $r = $h.best
            if ($null -eq $r) { continue }
            [void]$sb.AppendLine(("<tr><td class=""l"">{0}</td><td class=""l"">{1}</td><td class=""prod"">{2}</td><td>{3}</td><td>{4}</td><td>{5}</td></tr>" -f `
                $h.time, $r.name, (Format-UnkaiInt $r.idx), (Format-UnkaiInt $r.idx_c_mlin), (Format-UnkaiInt $r.idx_c_mpow), (Format-UnkaiInt $r.idx_c_rrange)))
        }
        [void]$sb.AppendLine('</table></div></details>')

        # --- 変数の生値 ---
        [void]$sb.AppendLine('<h3>変数の生値</h3>')
        foreach ($v in $UnkaiValleys) {
            $isMain = ($v.id -eq "N_C" -or $v.id -eq "S_A")
            $tbl = New-Object System.Text.StringBuilder
            [void]$tbl.AppendLine('<div class="wrap"><table><tr><th class="l">日時</th><th>気温</th><th>露点</th><th>T-Td</th><th>湿度</th><th>風</th><th>低層雲</th><th>日没時低層雲</th><th>中層雲</th><th>高層雲</th><th>全雲量</th><th>降水</th><th>地上気圧</th><th>日較差</th><th>M</th><th>W</th><th>C</th><th>C0</th><th>R</th><th class="prod">F 案c</th></tr>')
            foreach ($h in $hrs) {
                $r = $h.valleys | Where-Object { $_.id -eq $v.id }
                if ($null -eq $r) { continue }
                $cls = if (-not $r.gate_f) { ' class="bad"' } else { '' }
                [void]$tbl.AppendLine(("<tr><td class=""l"">{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td><td>{5}</td><td>{6}</td><td>{7}</td><td>{8}</td><td>{9}</td><td>{10}</td><td{11}>{12}</td><td>{13}</td><td>{14}</td><td>{15}</td><td>{16}</td><td>{17}</td><td>{18}</td><td>{19}</td><td class=""prod"">{20}</td></tr>" -f `
                    $h.time, (Format-UnkaiCell $r.t 1), (Format-UnkaiCell $r.td 1), (Format-UnkaiCell $r.dpd 1),
                    (Format-UnkaiCell $r.rh 0), (Format-UnkaiCell $r.wind 1), (Format-UnkaiCell $r.low 0), (Format-UnkaiCell $r.low_at_sunset 0),
                    (Format-UnkaiCell $r.mid 0), (Format-UnkaiCell $r.high 0), (Format-UnkaiCell $r.total 0),
                    $cls, (Format-UnkaiCell $r.precip 2), (Format-UnkaiCell $r.surface_pressure 1), (Format-UnkaiCell $r.day_range 1),
                    (Format-UnkaiCell $r.m_rh 2), (Format-UnkaiCell $r.w 2), (Format-UnkaiCell $r.c 2), (Format-UnkaiCell $r.c0 2),
                    (Format-UnkaiCell $r.r_drop 2), (Format-UnkaiCell $r.f_c 2)))
            }
            [void]$tbl.AppendLine('</table></div>')
            if ($isMain) {
                [void]$sb.AppendLine(("<h3>{0}（主軸）</h3>" -f $v.name))
                [void]$sb.AppendLine($tbl.ToString())
            } else {
                [void]$sb.AppendLine(("<details><summary>{0}（補助）</summary>{1}</details>" -f $v.name, $tbl.ToString()))
            }
        }
        [void]$sb.AppendLine('<p class="note">日没時点の低層雲は「霧の発生を妨げる先在の雲」を捉えている可能性がある一方、その時点で既に霧や層雲が出ていることもあります。断定せず記録のみに留めています。降水ゲートで0になった行は赤背景です。</p>')

        # --- 雲頂の内訳 ---
        [void]$sb.AppendLine('<h3>雲頂の内訳（気圧面プロファイル・日の出時刻のみ）</h3>')
        [void]$sb.AppendLine('<div class="wrap"><table><tr><th class="l">日時</th><th class="l">地点</th><th>地上気圧</th>')
        foreach ($p in ($UnkaiLevels | Sort-Object -Descending)) { [void]$sb.AppendLine(("<th>{0}</th>" -f $p)) }
        [void]$sb.AppendLine('<th class="l">状態</th><th>下端</th><th>上端</th><th class="prod">V_top</th></tr>')
        foreach ($h in $hrs) {
            if ($h.offset -ne 0) { continue }
            foreach ($r in $h.valleys) {
                [void]$sb.AppendLine(("<tr><td class=""l"">{0}</td><td class=""l"">{1}</td><td>{2}</td>" -f $h.time, $r.name, (Format-UnkaiCell $r.surface_pressure 0)))
                foreach ($l in $r.levels) {
                    if (-not $l.valid) {
                        [void]$sb.AppendLine('<td class="dim">地中/欠</td>')
                    } else {
                        $c = if ([double]$l.rh -ge 90.0) { ' class="warn"' } else { '' }
                        [void]$sb.AppendLine(("<td{0}>{1}%<br>{2}m</td>" -f $c, [int]$l.rh, [int]$l.z))
                    }
                }
                $st = $UnkaiTopStatusText[[string]$r.top.top_status]
                if ([string]::IsNullOrEmpty($st)) { $st = $r.top.top_status }
                [void]$sb.AppendLine(("<td class=""l"">{0}</td><td>{1}</td><td>{2}</td><td class=""prod"">{3}</td></tr>" -f `
                    $st, (Format-UnkaiCell $r.top.h_lower 0), (Format-UnkaiCell $r.top.h_upper 0), (Format-UnkaiCell $r.top.v_top 2)))
            }
        }
        [void]$sb.AppendLine('</table></div>')
        [void]$sb.AppendLine(("<p class=""note"">湿度90%以上の面を黄色で示します。地上気圧より下の面は地中として除外していますが、地上気圧自体も返却標高への補正を受けている可能性があるため、判別の妥当性を後から確認できるよう値を併記しています。<br>展望地点の判定高度 {0}m は 875hPa(約1215m)と850hPa(約1461m)の間にあり、この帯に雲頂が入る日は上下の判定ができません（状態「展望地点の高度を跨ぐ」）。ECMWF は 1000/925/850/700hPa しか返さないため、谷では実質2面しか使えず雲頂をほぼ評価できません。</p>" -f [int]$UnkaiSummitElev))

        # --- V の内訳 ---
        [void]$sb.AppendLine('<h3>V の内訳</h3>')
        [void]$sb.AppendLine('<div class="wrap"><table>')
        [void]$sb.AppendLine('<tr><th class="l" rowspan="2">日時</th><th colspan="6">V_summit（展望地点が雲の中にないか・主）</th><th colspan="3">V_vis（予報視程）</th><th colspan="3">記録のみ</th>')
        foreach ($v in $UnkaiValleys) { [void]$sb.AppendLine(("<th colspan=""2"">{0}</th>" -f $v.name)) }
        [void]$sb.AppendLine('</tr><tr><th>下側高度</th><th>下側湿度</th><th>上側面</th><th>上側高度</th><th>上側湿度</th><th class="prod">V_summit</th>')
        [void]$sb.AppendLine('<th>視程</th><th class="l">状態</th><th>V_vis</th><th>山上低層雲</th><th>V_sfc</th><th>山上降水</th>')
        foreach ($v in $UnkaiValleys) { [void]$sb.AppendLine('<th>V_top_fog</th><th>谷上空</th>') }
        [void]$sb.AppendLine('</tr>')
        foreach ($h in $hrs) {
            $gc = if (-not $h.gate_v) { ' class="bad"' } else { '' }
            $sm = $h.summit
            $sc = if ($sm.status -eq "summit_in_layer") { ' class="bad"' } elseif ($sm.status -eq "insufficient") { ' class="warn"' } else { ' class="prod"' }
            [void]$sb.AppendLine(("<tr><td class=""l"">{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td><td>{5}</td><td{6}>{7}</td>" -f `
                $h.time, (Format-UnkaiCell $sm.z_below 0), (Format-UnkaiCell $sm.rh_below 0),
                (&{ if ($null -eq $sm.p_above) { "--" } else { ("{0}hPa" -f $sm.p_above) } }),
                (Format-UnkaiCell $sm.z_above 0), (Format-UnkaiCell $sm.rh_above 0), $sc, (Format-UnkaiCell $sm.v 2)))
            [void]$sb.AppendLine(("<td>{0}</td><td class=""l"">{1}</td><td>{2}</td><td>{3}</td><td>{4}</td><td{5}>{6}</td>" -f `
                (Format-UnkaiCell $h.vp_vis 0), $h.vis_status, (Format-UnkaiCell $h.v_vis 2),
                (Format-UnkaiCell $h.vp_low 0), (Format-UnkaiCell $h.v_sfc 2), $gc, (Format-UnkaiCell $h.vp_precip 2)))
            foreach ($v in $UnkaiValleys) {
                $r = $h.valleys | Where-Object { $_.id -eq $v.id }
                $bw = if ($r.valley_band_wet) { "湿" } else { "－" }
                [void]$sb.AppendLine(("<td>{0}</td><td>{1}</td>" -f (Format-UnkaiCell $r.top.v_top 2), $bw))
            }
            [void]$sb.AppendLine('</tr>')
        }
        [void]$sb.AppendLine('</table></div>')
        [void]$sb.AppendLine(("<p class=""note""><b>V = min(V_top_fog, V_summit, V_vis)</b>。適用できた補正だけの最小値をとり、すべて適用できなければ「--」です。<b>補正を適用しないことと「良好(1.0)」は区別</b>しており、湿潤層を検出できない場合や上端が不明な場合を 1.0 にはしていません。<br>" +
            "V_summit は展望地点の高度 $([int]$UnkaiSummitElev)m を挟む上下の湿り具合です。挟む面は固定せず、その時刻の geopotential_height から毎回選びます（上側の高度が時刻ごとに動くのはそのためです）。上下どちらかが欠ける場合は「判定材料不足」とし、1.0 にはしません。<br>" +
            "0／0.4／0.7／1.0 はいずれも仮の係数です。<b>0 は「確実に霧」ではなく、濃い霧の可能性を重く見た暫定的な強い減点</b>です。上下の湿度だけでは 0.4 と 0.7 の差を物理的に確定できません（直上だけ湿っていても、層の下端が展望地点より下にある可能性があります）。<br>" +
            "「谷上空」は谷側のプロファイルで展望高度帯が湿っているかの補助記録で、V には掛けていません。山上判定と食い違うときの手がかりとして残しています。<br>" +
            "V_vis が「missing」の版は視程補正なしで、視界良好という意味ではありません。V_sfc（山上の低層雲）も記録のみです。山上格子の低層雲は「現地の霧」と「眼下の雲海が同じセルに含まれているだけ」を区別できないためです。</p>"))
    }

    # --- モデル比較 ---
    if ($ByModel.Keys.Count -ge 2) {
        [void]$sb.AppendLine('<h2>モデル比較（本番＝案c の指数）</h2>')
        [void]$sb.AppendLine('<div class="wrap"><table><tr><th class="l">日時</th>')
        foreach ($m in $ByModel.Keys) { [void]$sb.AppendLine(("<th>{0}</th>" -f $m)) }
        [void]$sb.AppendLine('</tr>')
        $baseHrs = $ByModel[@($ByModel.Keys)[0]]
        foreach ($bh in $baseHrs) {
            [void]$sb.AppendLine(("<tr><td class=""l"">{0}</td>" -f $bh.time))
            foreach ($m in $ByModel.Keys) {
                $mh = $ByModel[$m] | Where-Object { $_.time -eq $bh.time }
                $val = if ($null -eq $mh) { "--" } else { Format-UnkaiInt $mh.idx }
                [void]$sb.AppendLine(("<td>{0}</td>" -f $val))
            }
            [void]$sb.AppendLine('</tr>')
        }
        [void]$sb.AppendLine('</table></div>')
    }

    # --- 実績記録 ---
    [void]$sb.AppendLine('<h2>実績記録</h2>')
    [void]$sb.AppendLine('<p class="legend">unkai_log.csv に毎朝2軸で記入してください。既存の記入内容はスクリプト再実行でも上書きされません。<br>')
    [void]$sb.AppendLine('　<b>谷の雲海</b>： なし ／ 一部 ／ 広範囲 ／ 確認できない<br>')
    [void]$sb.AppendLine('　<b>展望地点の視界</b>： 良好 ／ 一部遮られる ／ 霧で見えない<br>')
    [void]$sb.AppendLine('展望地点が霧で谷を確認できない日は「確認できない」とし、その日は F の正誤判定に使わず、視界側の検証にだけ使います。</p>')
    [void]$sb.AppendLine('</body></html>')
    return $sb.ToString()
}

# ---- 保存 ----

function Save-UnkaiLab {
    param($ByModel, $Bundle, [string]$Dir, [string]$Generated)
    $html = Get-UnkaiLabHtml -ByModel $ByModel -Bundle $Bundle -Generated $Generated
    $labPath = Join-Path $Dir "unkai_lab.html"
    Set-Content -LiteralPath $labPath -Value $html -Encoding UTF8

    $detail = @($UnkaiDetailHeader)
    $levels = @($UnkaiLevelHeader)
    foreach ($m in $ByModel.Keys) {
        $detail += Get-UnkaiDetailLines -Hours $ByModel[$m] -Model $m
        $levels += Get-UnkaiLevelLines  -Hours $ByModel[$m] -Model $m
    }
    Set-Content -LiteralPath (Join-Path $Dir "unkai_detail.csv") -Value $detail -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $Dir "unkai_levels.csv") -Value $levels -Encoding UTF8
    $created = Initialize-UnkaiLog -Path (Join-Path $Dir "unkai_log.csv")

    return [ordered]@{ lab = $labPath; log_created = $created }
}
