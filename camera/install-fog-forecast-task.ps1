#Requires -Version 5.1
<#
.SYNOPSIS
  霧予報の履歴を保存するタスク（KarstFogForecast）をこのPCに登録する。

.DESCRIPTION
  save-fog-forecast.ps1 を1日2回実行し、姫鶴平の毎時予報を発表時刻つきで残す。
  朝と夕の2回にするのは、リード時間の長短を両方そろえるため。

    06:25 発表 → 当日の日中（リード 0〜13時間）と翌日
    18:25 発表 → 翌日の日中（リード 11〜25時間）

  分を25分にしているのは、予報の更新(11/41分)・トリガー(20分)・
  カメラ記録(50分)と重ならないようにするため。

  WakeToRun 付き。取り逃がすと同じ発表時刻の予報は二度と取れない。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\camera\install-fog-forecast-task.ps1
  powershell -ExecutionPolicy Bypass -File .\camera\install-fog-forecast-task.ps1 -Remove
#>

[CmdletBinding()]
param(
    [string]  $TaskName = "KarstFogForecast",
    [string[]]$AtTimes  = @("06:25", "18:25"),
    [switch]  $Remove
)

$ErrorActionPreference = "Stop"
$script = Join-Path $PSScriptRoot "save-fog-forecast.ps1"

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

$triggers = foreach ($t in $AtTimes) { New-ScheduledTaskTrigger -Daily -At $t }

# StartWhenAvailable: 取り逃がした回を復帰後に実行する
# WakeToRun: スリープからも復帰する（発表時刻の予報は後から取得できない）
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -WakeToRun -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -Priority 7

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Set-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers -Settings $settings | Out-Null
    Write-Host ("タスク {0} を更新しました。" -f $TaskName)
} else {
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers -Settings $settings `
        -Description "姫鶴平の毎時予報を発表時刻つきで保存する（霧予報の事前検証用）" | Out-Null
    Write-Host ("タスク {0} を登録しました。" -f $TaskName)
}

Write-Host ("実行時刻: {0}（毎日）" -f ($AtTimes -join " と "))
Write-Host ""
Write-Host "状態確認:"
Write-Host ("  Get-ScheduledTaskInfo -TaskName `"{0}`" | Select-Object LastRunTime,LastTaskResult,NextRunTime" -f $TaskName)
Write-Host ("  Import-Csv `"{0}`" | Group-Object issued_at | Select-Object Name,Count" -f (Join-Path $PSScriptRoot "fog_forecast.csv"))
