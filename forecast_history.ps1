#Requires -Version 5.1
# 計算結果の履歴。現地実績（unkai_log.csv）は一切読み書きしない。
# 週間予報（7日分）の履歴。1日1回（18時以降の最初の実行）、版ごとに weekly-history/発表日/版-時刻.csv へ保存し上書きしない。
# 何日先まで当たるかを後で実測と比べるため（2026-09-25〜）。気温は表示用の補正後と、補正前のモデル値の両方を残す。
$WeeklyHistoryHeader = 'issued_at,model,target_date,lead_days,weather,wcode,tmax_disp,tmin_disp,tmax_raw,tmin_raw,pop_max,precip_sum,snow_sum,source_revision'

function Save-WeeklyForecast {
    param($Daily, $AllRows, [string]$Model, [string]$Dir, [datetime]$IssuedAt, [string]$SourceRevision)
    if ($IssuedAt.Hour -lt 18 -or $null -eq $Daily) { return }
    $days = @($Daily | Where-Object { $null -ne $_ })
    # 気温が1日も無い（中身の無い応答）なら保存せず、その日の後続の実行で再試行する
    if (@($days | Where-Object { $null -ne $_.tmax }).Count -eq 0) { return }
    $histDir = Join-Path $Dir ('weekly-history/' + $IssuedAt.ToString('yyyy-MM-dd'))
    [void][IO.Directory]::CreateDirectory($histDir)
    if (@(Get-ChildItem -LiteralPath $histDir -Filter ($Model + '-*.csv') -File).Count -gt 0) { return }

    $fmt = { param($v, $f) if ($null -eq $v) { '' } else { ([double]$v).ToString($f, [Globalization.CultureInfo]::InvariantCulture) } }
    $stamp = $IssuedAt.ToString('yyyy-MM-ddTHH:mm:ss') + '+09:00'
    $lines = @($WeeklyHistoryHeader)
    foreach ($d in $days) {
        $date = ([datetime]$d.date).Date
        $dayRows = @($AllRows | Where-Object { ([datetime]$_.time).Date -eq $date })
        $raw = @($dayRows | ForEach-Object { $_.temp } | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
        $snowVals = @($dayRows | Where-Object { $_.PSObject.Properties['snow'] -and $null -ne $_.snow } | ForEach-Object { [double]$_.snow })
        $wcode = if ($d.PSObject.Properties['wcode']) { $d.wcode } else { $null }
        $lines += (@(
            $stamp, $Model, $date.ToString('yyyy-MM-dd'), [int]($date - $IssuedAt.Date).TotalDays,
            ('"' + ([string]$d.weather -replace '"', '') + '"'), $(if ($null -eq $wcode) { '' } else { [string]$wcode }),
            (& $fmt $d.tmax '0.0'), (& $fmt $d.tmin '0.0'),
            $(if ($raw.Count) { (& $fmt ($raw | Measure-Object -Maximum).Maximum '0.0') } else { '' }),
            $(if ($raw.Count) { (& $fmt ($raw | Measure-Object -Minimum).Minimum '0.0') } else { '' }),
            (& $fmt $d.pop '0'), (& $fmt $d.precip '0.0'),
            $(if ($snowVals.Count) { (& $fmt ($snowVals | Measure-Object -Sum).Sum '0.00') } else { '' }),
            $SourceRevision
        ) -join ',')
    }
    $path = Join-Path $histDir ($Model + '-' + $IssuedAt.ToString('HHmmss') + '.csv')
    [IO.File]::WriteAllLines($path, $lines, [Text.UTF8Encoding]::new($true))
}

function Save-ForecastHistory {
    param($ByModel, [string]$Dir, [datetime]$IssuedAt, [string]$SourceRevision, [string]$AverageMode)
    $stamp = $IssuedAt.ToString("yyyy-MM-ddTHH:mm:ss") + '+09:00'
    foreach ($model in $ByModel.Keys) {
        $hours = @($ByModel[$model] | Where-Object { ([datetime]$_.time) -gt $IssuedAt })
        if ($hours.Count -eq 0) { continue }
        $record = [ordered]@{
            schema_version = 1
            issued_at = $stamp
            issued_at_meaning = '取得・計算完了時刻（モデル初期時刻ではない）'
            source_revision = $SourceRevision
            model = $model
            average_mode = $(if ($model -eq 'average') { $AverageMode } else { $null })
            detail_header = $UnkaiDetailHeader
            detail_rows = @(Get-UnkaiDetailLines -Hours $hours -Model $model)
            level_header = $UnkaiLevelHeader
            level_rows = @(Get-UnkaiLevelLines -Hours $hours -Model $model)
        }
        $json = ConvertTo-Json -InputObject $record -Depth 8 -Compress
        # 毎回の履歴はローカル用（CIではその実行中のみ）。自動削除しない。
        $runDir = Join-Path $Dir 'forecast-runs'
        [void][IO.Directory]::CreateDirectory($runDir)
        $runFile = Join-Path $runDir ($IssuedAt.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N') + '-' + $model + '.json')
        [IO.File]::WriteAllText($runFile,$json,[Text.UTF8Encoding]::new($false))
        # 18時以降に最初に得た各モデルの翌朝予報を長期保存。欠測なら後続の実行で再試行する。
        $tomorrow = $IssuedAt.Date.AddDays(1).ToString('yyyy-MM-dd')
        $usable = @($hours | Where-Object { $_.date -eq $tomorrow -and $null -ne $_.idx }).Count -gt 0
        if ($IssuedAt.Hour -ge 18 -and $usable) {
            $historyDir = Join-Path $Dir ('forecast-history/' + $IssuedAt.ToString('yyyy-MM-dd'))
            [void][IO.Directory]::CreateDirectory($historyDir)
            $path = Join-Path $historyDir ($model + '-' + $IssuedAt.ToString('HHmmss') + '-' + [guid]::NewGuid().ToString('N') + '.json')
            # 同じ日・版を後の予報で上書きしない。再実行にも対応。
            if (@(Get-ChildItem -LiteralPath $historyDir -Filter ($model + '-*.json') -File).Count -eq 0) {
                [IO.File]::WriteAllText($path,$json,[Text.UTF8Encoding]::new($false))
            }
        }
    }
}
