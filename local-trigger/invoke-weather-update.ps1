#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Owner = 't-fukuda-ux',
    [string]$Repository = 'karstweather',
    [string]$Workflow = 'update.yml',
    [string]$Branch = 'main',
    [string]$PublicUrl = 'https://t-fukuda-ux.github.io/karstweather/',
    [int]$RunTimeoutMinutes = 12,
    [int]$PageTimeoutMinutes = 8,
    # 毎時20分の実行で、直前の cron(11/41分) が遅れて前時の40〜50分台に走っていても今回起動する
    # （50分だと省略され、更新が約100分空いていた）。
    [int]$MaxPublishedAgeMinutes = 25,
    # タスクスケジューラの再実行はスクリプトの終了コード1では働かないため、スクリプト内で再試行する。
    [int]$MaxAttempts = 3,
    [int]$RetryWaitMinutes = 10,
    # この回数だけ続けて失敗したら GitHub に Issue を作る（GitHub からメールが届く）。復旧したら閉じる。
    [int]$AlertAfterFailures = 3,
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
    # 非表示タスクでは認証ダイアログに応答できず、打ち切りまで固まるため対話を禁止する。
    $env:GCM_INTERACTIVE = 'never'
    $env:GIT_TERMINAL_PROMPT = '0'
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
    $request = @{
        Uri = $Uri
        Method = $Method
        Headers = $script:ApiHeaders
        TimeoutSec = 15
        UseBasicParsing = $true
    }
    if ($Body) {
        $request.Body = $Body
        $request.ContentType = 'application/json'
    }
    return Invoke-RestMethod @request
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

$script:StatePath = Join-Path $PSScriptRoot 'trigger-state.json'
$script:ApiRoot = 'https://api.github.com/repos/{0}/{1}' -f $Owner, $Repository

function Connect-GitHub {
    if ($null -ne $script:ApiHeaders) { return }
    $credential = Get-GitHubCredential
    $script:ApiHeaders = @{
        Authorization = 'Bearer ' + $credential.password
        Accept = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent' = 'karstweather-local-trigger'
    }
    $credential.Clear()
}

# 連続失敗の回数と、通知用に作った Issue の番号を覚えておく
function Read-TriggerState {
    try {
        $s = [IO.File]::ReadAllText($script:StatePath) | ConvertFrom-Json
        return @{ failures = [int]$s.failures; issue = $s.issue }
    } catch { return @{ failures = 0; issue = $null } }
}
function Save-TriggerState($state) {
    try { [IO.File]::WriteAllText($script:StatePath, ($state | ConvertTo-Json -Compress)) } catch { Write-TriggerLog ('状態の保存に失敗: ' + $_.Exception.Message) }
}

# 失敗が続いたら Issue を作る。公開リポジトリなので本文は時刻とエラー文だけにする。
# 通知の失敗で本来の終了コードを変えないよう、ここでの例外はログに残すだけ。
function Register-TriggerFailure([string]$message) {
    $state = Read-TriggerState
    $state.failures++
    if ($state.failures -ge $AlertAfterFailures -and -not $state.issue) {
        try {
            Connect-GitHub
            $body = @{
                title = '天気予報の自動更新が止まっています'
                body  = ("サーバーPCのトリガーが {0} 回続けて更新に失敗しました（最終 {1} JST）。`n`n最後のエラー: {2}`n`n公開ページ: {3}`n`n復旧するとこの Issue は自動で閉じます。" -f `
                    $state.failures, (Get-Date -Format 'yyyy-MM-dd HH:mm'), $message, $PublicUrl)
            } | ConvertTo-Json -Compress
            $issue = Invoke-GitHubApi -Uri ($script:ApiRoot + '/issues') -Method POST -Body $body
            $state.issue = $issue.number
            Write-TriggerLog ('更新停止の Issue を作成しました: ' + $issue.html_url)
        } catch {
            Write-TriggerLog ('Issue を作成できませんでした（PAT に Issues の書き込み権限が必要）: ' + $_.Exception.Message)
        }
    }
    Save-TriggerState $state
}

function Register-TriggerSuccess {
    $state = Read-TriggerState
    if ($state.failures -eq 0 -and -not $state.issue) { return }
    if ($state.issue) {
        try {
            Connect-GitHub
            $comment = @{ body = ('復旧しました（{0} JST に公開ページの更新を確認）。' -f (Get-Date -Format 'yyyy-MM-dd HH:mm')) } | ConvertTo-Json -Compress
            Invoke-GitHubApi -Uri ($script:ApiRoot + '/issues/' + $state.issue + '/comments') -Method POST -Body $comment | Out-Null
            Invoke-GitHubApi -Uri ($script:ApiRoot + '/issues/' + $state.issue) -Method PATCH -Body '{"state":"closed"}' | Out-Null
            Write-TriggerLog ('復旧したため Issue #{0} を閉じました。' -f $state.issue)
        } catch {
            # 閉じられなければ次回また試す
            Write-TriggerLog ('Issue を閉じられませんでした: ' + $_.Exception.Message)
            Save-TriggerState @{ failures = 0; issue = $state.issue }
            return
        }
    }
    Save-TriggerState @{ failures = 0; issue = $null }
}

function Invoke-UpdateOnce {
    param([DateTimeOffset]$Start, $Baseline)
    $start = $Start
    $baseline = $Baseline
    Connect-GitHub
    # 秒を表示しないページなので、起動した分の開始時刻を分単位で比較する。
    $startMinute = [DateTimeOffset]::new($start.Year, $start.Month, $start.Day, $start.Hour, $start.Minute, 0, [TimeSpan]::Zero)

    $apiRoot = $script:ApiRoot
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
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $start = [DateTimeOffset]::UtcNow
        $baseline = $null
        try { $baseline = Get-PublishedAt -Url $PublicUrl } catch { Write-TriggerLog ('更新前ページの確認に失敗: ' + $_.Exception.Message) }
        if ($null -ne $baseline) {
            $baselineAge = ($start - $baseline.ToUniversalTime()).TotalMinutes
            if ($baselineAge -ge -5 -and $baselineAge -lt $MaxPublishedAgeMinutes) {
                Write-TriggerLog ('公開ページは{0:F0}分前に更新済みのため、GitHub起動を省略します。' -f $baselineAge)
                Register-TriggerSuccess
                exit 0
            }
        }
        try {
            Invoke-UpdateOnce -Start $start -Baseline $baseline
            Register-TriggerSuccess
            exit 0
        } catch {
            Write-TriggerLog ('失敗（{0}/{1}回目）: {2}' -f $attempt, $MaxAttempts, $_.Exception.Message)
            if ($attempt -ge $MaxAttempts) { Register-TriggerFailure $_.Exception.Message; exit 1 }
            Start-Sleep -Seconds ($RetryWaitMinutes * 60)
        }
    }
} catch {
    Write-TriggerLog ('失敗: ' + $_.Exception.Message)
    Register-TriggerFailure $_.Exception.Message
    exit 1
} finally {
    $script:ApiHeaders = $null
    if ($null -ne $script:Mutex) {
        try { $script:Mutex.ReleaseMutex() } catch {}
        $script:Mutex.Dispose()
    }
}
