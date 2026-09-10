#Requires -Version 5.1
<#
.SYNOPSIS
  姫鶴平ライブカメラの記録タスク（KarstCameraCapture）をこのPCに登録する。

.DESCRIPTION
  毎時 capture-mezuru.ps1 を実行し、画像とコントラストを記録する。
  第1段階（記録のみ）なので、判定も通知も行わない。数秒で終わる軽い処理。

  ログオン中のユーザー権限で動く。PCがスリープ・電源断の間は動かないが、
  記録が目的なので欠測があっても支障はない。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\camera\install-camera-task.ps1
  powershell -ExecutionPolicy Bypass -File .\camera\install-camera-task.ps1 -StartMinute 50
#>

[CmdletBinding()]
param(
    [string]$TaskName    = "KarstCameraCapture",
    [int]   $StartMinute = 50,   # 毎時の実行分。予報の更新(11/41分)やトリガー(20分)と重ならないよう既定50分
    [switch]$Remove
)

$ErrorActionPreference = "Stop"
$script = Join-Path $PSScriptRoot "capture-mezuru.ps1"

if ($Remove) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host ("タスク {0} を削除しました。" -f $TaskName)
    } else {
        Write-Host ("タスク {0} は登録されていません。" -f $TaskName)
    }
    return
}

if (-not (Test-Path -LiteralPath $script)) { throw ("スクリプトが見つかりません: {0}" -f $script) }

$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument ("-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"{0}`"" -f $script)

# 次の「毎時$StartMinute分」から1時間ごと
$now   = Get-Date
$start = $now.Date.AddHours($now.Hour).AddMinutes($StartMinute)
if ($start -le $now) { $start = $start.AddHours(1) }
$trigger = New-ScheduledTaskTrigger -Once -At $start `
    -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration (New-TimeSpan -Days 3650)

# 低優先度・多重起動なし・10分で打ち切り（通常は数秒で終わる）
# -WakeToRun: スリープ中でも復帰して実行する。2026-09-09 22:50〜09-10 10:50 に
# 12時間の欠測が発生し、朝5〜9時という霧の最重要時間帯が丸ごと落ちたため追加した。
# 欠測した時間帯だけは後から復元できないので、記録の穴を空けないことを優先する。
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -WakeToRun -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -Priority 7

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Set-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings | Out-Null
    Write-Host ("タスク {0} を更新しました。" -f $TaskName)
} else {
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
        -Description "姫鶴平ライブカメラのコントラストを毎時記録する（霧の検証用・判定はしない）" | Out-Null
    Write-Host ("タスク {0} を登録しました。" -f $TaskName)
}

Write-Host ("初回実行: {0:yyyy-MM-dd HH:mm} から1時間ごと（毎時{1}分）" -f $start, $StartMinute)
Write-Host ""
Write-Host "状態確認:"
Write-Host ("  Get-ScheduledTaskInfo -TaskName `"{0}`" | Select-Object LastRunTime,LastTaskResult,NextRunTime" -f $TaskName)
Write-Host ("  Get-Content `"{0}`" -Tail 10" -f (Join-Path $PSScriptRoot "capture.log"))
