#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$TaskName = 'KarstWeatherWorkflowTrigger',
    [int]$StartMinute = 20,
    [string]$InstallDir = (Join-Path $env:ProgramData 'KarstWeatherTrigger')
)

$ErrorActionPreference = 'Stop'
if ($StartMinute -lt 0 -or $StartMinute -gt 59) { throw 'StartMinuteは0～59で指定してください。' }

$installDirExisted = Test-Path -LiteralPath $InstallDir
[void][IO.Directory]::CreateDirectory($InstallDir)
if (-not $installDirExisted) {
# 定期実行コードを他ユーザーが変更できないよう、専用フォルダの継承を切る。
$currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
$acl = New-Object Security.AccessControl.DirectorySecurity
$acl.SetOwner($currentSid)
$acl.SetAccessRuleProtection($true, $false)
$inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
$propagate = [Security.AccessControl.PropagationFlags]::None
$allow = [Security.AccessControl.AccessControlType]::Allow
foreach ($entry in @(
    @{ Sid = $currentSid; Rights = [Security.AccessControl.FileSystemRights]::FullControl },
    @{ Sid = New-Object Security.Principal.SecurityIdentifier('S-1-5-18'); Rights = [Security.AccessControl.FileSystemRights]::FullControl },
    @{ Sid = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544'); Rights = [Security.AccessControl.FileSystemRights]::FullControl }
)) {
    $rule = New-Object Security.AccessControl.FileSystemAccessRule($entry.Sid, $entry.Rights, $inherit, $propagate, $allow)
    [void]$acl.AddAccessRule($rule)
}
Set-Acl -LiteralPath $InstallDir -AclObject $acl
}
$source = Join-Path $PSScriptRoot 'invoke-weather-update.ps1'
$installed = Join-Path $InstallDir 'invoke-weather-update.ps1'
Copy-Item -LiteralPath $source -Destination $installed -Force

$powershell = Join-Path $PSHOME 'powershell.exe'
if (-not (Test-Path -LiteralPath $powershell)) { $powershell = 'powershell.exe' }
$action = New-ScheduledTaskAction -Execute $powershell `
    -Argument ('-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $installed)

$now = Get-Date
$start = $now.Date.AddHours($now.Hour).AddMinutes($StartMinute)
if ($start -le $now) { $start = $start.AddHours(1) }
$trigger = New-ScheduledTaskTrigger -Once -At $start `
    -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration (New-TimeSpan -Days 3650)

# Priority 7はWindowsタスクスケジューラの低優先度。重複起動は無視する。
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 20) `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew
$settings.Priority = 7

$identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
$task = New-ScheduledTask -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
    -Description '毎時20分にGitHub Actionsへ姫鶴荘天気予報の更新を依頼し、公開反映を確認する軽量バックアップ。'
Register-ScheduledTask -TaskName $TaskName -InputObject $task -Force | Out-Null

Write-Output ('タスクを登録しました: {0}' -f $TaskName)
Write-Output ('次回実行: {0:yyyy-MM-dd HH:mm}' -f $start)
Write-Output ('実体: {0}' -f $installed)
