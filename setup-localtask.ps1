#Requires -Version 5.1
<#
.SYNOPSIS
  毎時20分にGitHub Actionsを補助起動する軽量タスクをこのPCへ登録する。
.DESCRIPTION
  管理者として開いたWindows PowerShellで実行する。
  PC上では予報生成やgit操作を行わず、公開ページが50分以上更新されていない時だけ
  workflow_dispatchを送り、GitHub側の完了と公開ページへの反映を確認する。
#>
[CmdletBinding()]
param(
    [int]$StartMinute = 20,
    [string]$TaskName = 'KarstWeatherWorkflowTrigger'
)
$ErrorActionPreference = 'Stop'
$installer = Join-Path $PSScriptRoot 'local-trigger\install-weather-trigger.ps1'
if (-not (Test-Path -LiteralPath $installer)) { throw "インストーラーが見つかりません: $installer" }
& $installer -StartMinute $StartMinute -TaskName $TaskName
exit $LASTEXITCODE