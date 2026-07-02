#Requires -Version 5.1
<#
.SYNOPSIS
  規定版・EC版・平均版を生成し、平均版を WEB公開用 index.html として GitHub Pages に push する。

.DESCRIPTION
  タスクスケジューラから呼び出す用。GitHub Actionsのscheduled cronが
  発火しないことがあるため(2026-07-02発覚)、ローカルタスクスケジューラでも
  二重に実行しバックアップとする。
  初回セットアップは setup-github.ps1 を先に実行すること。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File ".\publish.ps1"
#>

$ErrorActionPreference = "Stop"
$dir = $PSScriptRoot

function Write-Log {
    param([string]$msg)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] $msg"
    Write-Host $line
    Add-Content -Path (Join-Path $dir "publish.log") -Value $line -Encoding UTF8
}

try {
    # Step 1: 3版すべて生成（規定版・EC版・平均版）
    Write-Log "lowcloud.ps1 を実行中..."
    & powershell -ExecutionPolicy Bypass -File (Join-Path $dir "lowcloud.ps1")
    Write-Log "lowcloud_ec.ps1 を実行中..."
    & powershell -ExecutionPolicy Bypass -File (Join-Path $dir "lowcloud_ec.ps1")
    Write-Log "lowcloud_avg.ps1 を実行中..."
    & powershell -ExecutionPolicy Bypass -File (Join-Path $dir "lowcloud_avg.ps1")

    # Step 2: index.html としてコピー（GitHub Pages のルートファイル、平均版を反映）
    $src  = Join-Path $dir "lowcloud_avg.html"
    $dest = Join-Path $dir "index.html"
    Copy-Item -Path $src -Destination $dest -Force
    Write-Log "index.html を更新しました。"

    # Step 3: git commit & push
    # gitはLF/CRLF等の警告をstderrに出す。$EAP=Stop + 2>&1 だと警告が例外化して
    # commit/push に到達しないため、このブロックだけ Continue にし、終了コードで成否判定する。
    Push-Location $dir
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        git add index.html lowcloud.html lowcloud_ec.html lowcloud_avg.html 2>$null
        $changed = git status --porcelain
        if ($changed) {
            $ts = Get-Date -Format "yyyy-MM-dd HH:mm"
            git commit -m "update: $ts" 2>$null | Out-Null
            git push origin main 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Log "GitHub Pages にアップロードしました。"
            } else {
                Write-Log ("push 失敗 (exit {0})。資格情報・ネットワークを確認してください。" -f $LASTEXITCODE)
            }
        } else {
            Write-Log "変更なし。スキップします。"
        }
    } finally {
        $ErrorActionPreference = $prevEAP
        Pop-Location
    }

} catch {
    Write-Log ("エラー: {0}" -f $_.Exception.Message)
    exit 1
}
