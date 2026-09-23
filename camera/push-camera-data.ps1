#Requires -Version 5.1
<#
.SYNOPSIS
  カメラ記録と霧予報の履歴（camera/*.csv の2ファイル）だけを commit・push する。

.DESCRIPTION
  2つのCSVはこのPCでしか作られず、後から取り直せない。PCの故障で失われないよう、
  KarstFogForecast タスクの2つ目の動作として 1日2回（予報保存の直後）GitHub へ送る。

  - commit するのは下の2ファイルだけ。作業中の他の変更は commit せず、pull 中は一時退避する（--autostash）
  - 2ファイルはこのPCだけが書くので、rebase で競合しない前提。競合したら中断して終了コード1
  - 認証は Git Credential Manager の保存済み資格情報。対話が必要なら待たずに失敗させる
  - main 以外のブランチにいる時、camera 以外の未送信 commit がある時は送らない（終了コード1）
  - 副作用として作業リポジトリも origin/main に追従する

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\camera\push-camera-data.ps1
#>

[CmdletBinding()]
param([int]$MaxTries = 3)

$ErrorActionPreference = "Stop"
$repo  = Split-Path $PSScriptRoot -Parent
$files = @("camera/fog_forecast.csv", "camera/mezuru_contrast.csv")
$log   = Join-Path $PSScriptRoot "push.log"
$env:GIT_TERMINAL_PROMPT = "0"
$env:GCM_INTERACTIVE     = "never"

function Write-PushLog([string]$msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    Write-Host $line
    try { Add-Content -LiteralPath $log -Value $line -Encoding UTF8 } catch { }
}

# git の標準エラーは進捗表示でも出るので、終了コードで成否を判定する
function Invoke-Git {
    # PowerShell 5.1 は 2>&1 で受けた標準エラーを例外にするため、この関数内だけ止めない
    $ErrorActionPreference = "Continue"
    $out = & git -C $repo @args 2>&1 | ForEach-Object { "$_" }
    return @{ ok = ($LASTEXITCODE -eq 0); out = ($out -join " / ") }
}

try {
    $branch = Invoke-Git rev-parse --abbrev-ref HEAD
    if ($branch.out -ne "main") { throw ("main 以外のブランチ（{0}）で作業中のため送りません" -f $branch.out) }

    $changed = Invoke-Git status --porcelain -- @files
    if (-not $changed.ok) { throw ("git status 失敗: " + $changed.out) }
    if ($changed.out) {
        $stamp = Get-Date -Format "yyyy-MM-dd HH:mm"
        $r = Invoke-Git commit -q -m ("data: camera records {0} JST" -f $stamp) -- @files
        if (-not $r.ok) { throw ("commit 失敗: " + $r.out) }
        Write-PushLog ("commit しました（{0} JST）" -f $stamp)
    }

    # 送るものが無くても、前回 push に失敗した commit が残っていれば送る
    for ($i = 1; $i -le $MaxTries; $i++) {
        $r = Invoke-Git pull --rebase --autostash -q origin main
        if (-not $r.ok) {
            [void](Invoke-Git rebase --abort)
            throw ("pull --rebase 失敗: " + $r.out)
        }
        $ahead = Invoke-Git rev-list --count origin/main..HEAD
        if ($ahead.ok -and $ahead.out -eq "0") { Write-PushLog "送信済み（未送信の commit なし）"; exit 0 }
        # 手作業の未送信 commit（コード変更など）を勝手に公開しない
        $names = @(& git -C $repo diff --name-only origin/main HEAD 2>$null)
        $others = @($names | Where-Object { $_ -and ($files -notcontains $_) })
        if ($others.Count -gt 0) {
            throw ("camera 以外の未送信 commit があるため送りません（手動で push してください）: " + ($others -join ", "))
        }
        $r = Invoke-Git push -q origin HEAD:main
        if ($r.ok) { Write-PushLog "push しました"; exit 0 }
        Write-PushLog ("push 失敗（{0}/{1}回目）: {2}" -f $i, $MaxTries, $r.out)
        Start-Sleep -Seconds (15 * $i)
    }
    throw "push を $MaxTries 回試みて失敗しました"
} catch {
    Write-PushLog ("失敗: " + $_.Exception.Message)
    exit 1
}
