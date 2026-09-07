#Requires -Version 5.1
# 計算結果の履歴。現地実績（unkai_log.csv）は一切読み書きしない。
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
