#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Owner = 't-fukuda-ux',
    [string]$Repository = 'karstweather',
    [string]$Workflow = 'update.yml',
    [string]$Branch = 'main',
    [string]$PublicUrl = 'https://t-fukuda-ux.github.io/karstweather/',
    [int]$RunTimeoutMinutes = 12,
    [int]$PageTimeoutMinutes = 3,
    [int]$MaxPublishedAgeMinutes = 50,
    [string]$LogPath = ''
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path $PSScriptRoot 'weather-trigger.log'
}
$script:ApiHeaders = $null
$script:Mutex = $null

function Write-TriggerLog {
    param([string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Output $line
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

function Limit-LogSize {
    if (-not (Test-Path -LiteralPath $LogPath)) { return }
    $file = Get-Item -LiteralPath $LogPath
    if ($file.Length -le 1MB) { return }
    $lines = @(Get-Content -LiteralPath $LogPath -Tail 2000)
    Set-Content -LiteralPath $LogPath -Value $lines -Encoding UTF8
}

function Get-GitHubCredential {
    $output = @('protocol=https', 'host=github.com', '') | git credential fill 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'GitHubの保存済み認証を取得できません。' }
    $values = @{}
    foreach ($line in $output) {
        $pair = $line -split '=', 2
        if ($pair.Count -eq 2) { $values[$pair[0]] = $pair[1] }
    }
    if ([string]::IsNullOrWhiteSpace($values.password)) { throw 'GitHub認証が保存されていません。' }
    return $values
}

function Invoke-GitHubApi {
    param([string]$Uri, [string]$Method = 'GET', [string]$Body = '')
    $args = @{
        Uri = $Uri
        Method = $Method
        Headers = $script:ApiHeaders
        TimeoutSec = 15
        UseBasicParsing = $true
    }
    if ($Body) {
        $args.Body = $Body
        $args.ContentType = 'application/json'
    }
    return Invoke-RestMethod @args
}

function Get-PublishedAt {
    param([string]$Url)
    $separator = if ($Url.Contains('?')) { '&' } else { '?' }
    $response = Invoke-WebRequest -Uri ($Url + $separator + 'verify=' + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) `
        -UseBasicParsing -TimeoutSec 15 -Headers @{ 'Cache-Control' = 'no-cache' }
    $match = [regex]::Match($response.Content, '取得:\s*(\d{4}-\d{2}-\d{2} \d{2}:\d{2}) JST')
    if (-not $match.Success) { throw '公開ページから取得日時を読み取れません。' }
    return [DateTimeOffset]::ParseExact(
        ($match.Groups[1].Value + ' +09:00'),
        'yyyy-MM-dd HH:mm zzz',
        [Globalization.CultureInfo]::InvariantCulture
    )
}

try {
    Limit-LogSize
    $createdNew = $false
    $script:Mutex = New-Object Threading.Mutex($true, 'Local\KarstWeatherWorkflowTrigger', [ref]$createdNew)
    if (-not $createdNew) {
        Write-TriggerLog '前回の処理が実行中のため、今回は何もせず終了します。'
        exit 0
    }

    # 宿泊管理処理を優先する。以降は短いHTTPS通信と待機だけを行う。
    [Diagnostics.Process]::GetCurrentProcess().PriorityClass = [Diagnostics.ProcessPriorityClass]::BelowNormal
    $start = [DateTimeOffset]::UtcNow
    $baseline = $null
    try { $baseline = Get-PublishedAt -Url $PublicUrl } catch { Write-TriggerLog ('更新前ページの確認に失敗: ' + $_.Exception.Message) }
    if ($null -ne $baseline) {
        $baselineAge = ($start - $baseline.ToUniversalTime()).TotalMinutes
        if ($baselineAge -ge -5 -and $baselineAge -lt $MaxPublishedAgeMinutes) {
            Write-TriggerLog ('公開ページは{0:F0}分前に更新済みのため、GitHub起動を省略します。' -f $baselineAge)
            exit 0
        }
    }

    $credential = Get-GitHubCredential
    $script:ApiHeaders = @{
        Authorization = 'Bearer ' + $credential.password
        Accept = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent' = 'karstweather-local-trigger'
    }
    $credential.Clear()

    $apiRoot = 'https://api.github.com/repos/{0}/{1}' -f $Owner, $Repository
    $dispatchBody = @{ ref = $Branch } | ConvertTo-Json -Compress
    Invoke-GitHubApi -Uri ($apiRoot + '/actions/workflows/' + $Workflow + '/dispatches') -Method POST -Body $dispatchBody | Out-Null
    Write-TriggerLog 'GitHub Actionsへ更新開始を依頼しました。'

    $run = $null
    $findLimit = [DateTimeOffset]::UtcNow.AddMinutes(2)
    while ([DateTimeOffset]::UtcNow -lt $findLimit -and $null -eq $run) {
        Start-Sleep -Seconds 10
        $runs = Invoke-GitHubApi -Uri ($apiRoot + '/actions/workflows/' + $Workflow + '/runs?event=workflow_dispatch&per_page=10')
        $run = @($runs.workflow_runs | Where-Object {
            [DateTimeOffset]$_.created_at -ge $start.AddSeconds(-5) -and $_.head_branch -eq $Branch
        } | Sort-Object created_at -Descending | Select-Object -First 1)
        if ($run.Count -gt 0) { $run = $run[0] } else { $run = $null }
    }
    if ($null -eq $run) { throw '起動したGitHub Actionsを2分以内に確認できませんでした。' }
    Write-TriggerLog ('実行を確認: ' + $run.html_url)

    $runLimit = [DateTimeOffset]::UtcNow.AddMinutes($RunTimeoutMinutes)
    while ([DateTimeOffset]::UtcNow -lt $runLimit -and $run.status -ne 'completed') {
        Start-Sleep -Seconds 15
        $run = Invoke-GitHubApi -Uri ($apiRoot + '/actions/runs/' + $run.id)
    }
    if ($run.status -ne 'completed') { throw ('GitHub Actionsが{0}分以内に完了しませんでした。' -f $RunTimeoutMinutes) }
    if ($run.conclusion -ne 'success') { throw ('GitHub Actionsが失敗しました: {0}' -f $run.html_url) }

    $pageLimit = [DateTimeOffset]::UtcNow.AddMinutes($PageTimeoutMinutes)
    $published = $null
    while ([DateTimeOffset]::UtcNow -lt $pageLimit) {
        try {
            $published = Get-PublishedAt -Url $PublicUrl
            # 秒を表示しないページなので、起動した分の開始時刻を分単位で比較する。
            $startMinute = [DateTimeOffset]::new($start.Year, $start.Month, $start.Day, $start.Hour, $start.Minute, 0, [TimeSpan]::Zero)
            if ($published.ToUniversalTime() -ge $startMinute) { break }
        } catch {
            Write-TriggerLog ('公開確認を再試行: ' + $_.Exception.Message)
        }
        Start-Sleep -Seconds 15
    }
    if ($null -eq $published -or $published.ToUniversalTime() -lt $startMinute) {
        $before = if ($null -eq $baseline) { '不明' } else { $baseline.ToString('yyyy-MM-dd HH:mm zzz') }
        throw ('Actionsは成功しましたが、公開ページの更新を確認できません（更新前: {0}）。' -f $before)
    }
    Write-TriggerLog ('公開反映を確認しました: 取得 {0} JST' -f $published.ToOffset([TimeSpan]::FromHours(9)).ToString('yyyy-MM-dd HH:mm'))
    exit 0
} catch {
    Write-TriggerLog ('失敗: ' + $_.Exception.Message)
    exit 1
} finally {
    $script:ApiHeaders = $null
    if ($null -ne $script:Mutex) {
        try { $script:Mutex.ReleaseMutex() } catch {}
        $script:Mutex.Dispose()
    }
}
