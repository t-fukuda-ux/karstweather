#Requires -Version 5.1
<#
.SYNOPSIS
  このPCに天気予報の自動更新タスク（LowCloudForecast）を登録する。別PCへの移設用。

.DESCRIPTION
  リポジトリを git clone したフォルダ内で実行すると、そのフォルダの publish.ps1 を
  1時間ごとに実行するタスクスケジューラのタスクを登録する。
  - 実行分は既定で毎時20分（GitHub Actionsの11分・41分とずらしてある。-StartMinuteで変更可）
  - タスクはログオン中のユーザーで実行される（PCが起動していてログオンしている間だけ動く。
    GitHub Actionsが主担当なので、これはあくまで二重化バックアップ）
  - 前提: git がインストール済みで、GitHubへのpush認証が通ること
    （初回pushの際にGit Credential Managerがブラウザで認証を求めてくる）

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\setup-localtask.ps1
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\setup-localtask.ps1 -StartMinute 35
#>

[CmdletBinding()]
param(
    [int]$StartMinute = 20,               # 毎時の実行分（Actionsの11分・41分を避ける）
    [string]$TaskName = "LowCloudForecast"
)

$ErrorActionPreference = "Stop"

# ---- 前提チェック ----
try { $null = git --version } catch {
    throw "git が見つかりません。https://git-scm.com/ からインストールしてから再実行してください。"
}
Push-Location $PSScriptRoot
try {
    git rev-parse --is-inside-work-tree *> $null
    if ($LASTEXITCODE -ne 0) { throw "このフォルダはgitリポジトリではありません。git clone したフォルダ内で実行してください。" }
} finally { Pop-Location }

$publish = Join-Path $PSScriptRoot "publish.ps1"
if (-not (Test-Path $publish)) { throw "publish.ps1 が見つかりません: $publish" }

# ---- タスク登録 ----
# 次の「毎時$StartMinute分」を初回実行時刻にする
$now = Get-Date
$start = $now.Date.AddHours($now.Hour).AddMinutes($StartMinute)
if ($start -le $now) { $start = $start.AddHours(1) }

$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$publish`""
# [TimeSpan]::MaxValue を渡すとXMLエラーになるため、実用上十分な長期間(3650日)を指定（引き継ぎ書7章）
$trigger = New-ScheduledTaskTrigger -Once -At $start `
    -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration (New-TimeSpan -Days 3650)
# 起動していなかった時刻の分は次に可能になった時点で実行。バッテリー駆動でも実行。30分でタイムアウト
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Set-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings | Out-Null
    Write-Host "既存タスク '$TaskName' を更新しました。"
} else {
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
        -Description "四国カルスト天気予報の生成とGitHub Pages公開（1時間ごと、GitHub Actionsのバックアップ）" | Out-Null
    Write-Host "タスク '$TaskName' を登録しました。"
}
Write-Host ("初回実行: {0:yyyy-MM-dd HH:mm} から1時間ごと（毎時{1}分）" -f $start, $StartMinute)
Write-Host ""
Write-Host "次の手順で動作確認してください:"
Write-Host "  1) 手動で1回実行（初回はブラウザでGitHubの認証を求められます）:"
Write-Host "     powershell -ExecutionPolicy Bypass -File `"$publish`""
Write-Host "  2) publish.log に「GitHub Pages にアップロードしました。」が出ていればOK"
Write-Host "  3) タスクの実行履歴の確認:"
Write-Host "     Get-ScheduledTaskInfo -TaskName $TaskName | Select-Object LastRunTime, LastTaskResult"
