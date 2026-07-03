#Requires -Version 5.1
<#
.SYNOPSIS
  3版（規定/EC/平均）を生成し、GitHub Pages に push する（ローカルタスクスケジューラ用）。

.DESCRIPTION
  GitHub Actionsのscheduled cronが発火しないことがあるため(2026-07-01/02発覚)、
  ローカルタスクスケジューラでも二重に実行しバックアップとする。
  - 実行前に origin/main へ追従する（Actions側のコミットが挟まっても push が失敗し続けない）
  - 生成は generate_all.ps1 に集約（1版失敗でも他は継続、index.htmlは平均版成功時のみ更新）
  - push はrebase＋最大3回再試行
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

# gitはLF/CRLF等の警告をstderrに出す。$EAP=Stop だと警告が例外化しうるため、
# git操作ブロックだけ Continue にし、終了コード($LASTEXITCODE)で成否判定する。
function Invoke-GitBlock {
    param([scriptblock]$block)
    Push-Location $dir
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try { & $block } finally {
        $ErrorActionPreference = $prevEAP
        Pop-Location
    }
}

try {
    # Step 0: origin/main へ追従。
    # Actions側の自動commitが挟まったままだと以後のpushが永久に失敗するため、
    # 生成前に必ずリモートへ追従する。生成物のローカル変更は直後に再生成するので破棄してよい。
    Invoke-GitBlock {
        git fetch origin 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Log "git fetch に失敗（オフライン？）。追従せず生成のみ実施します。"
            return
        }
        git checkout -- lowcloud.html lowcloud_ec.html lowcloud_avg.html index.html 2>$null
        git pull --rebase -X theirs origin main 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            git rebase --abort 2>$null
            Write-Log "origin/main への追従に失敗しました。生成のみ実施します。"
        }
    }

    # Step 1: 3版生成（generate_all.ps1 が index.html の更新まで担当）
    Write-Log "generate_all.ps1 を実行中..."
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir "generate_all.ps1")
    if ($LASTEXITCODE -ne 0) {
        Write-Log "全版の生成に失敗しました（終了コード $LASTEXITCODE）。pushをスキップします。"
        exit 1
    }
    Write-Log "生成が完了しました。"

    # Step 2: git commit & push（競合時はrebaseして最大3回再試行）
    Invoke-GitBlock {
        git add index.html lowcloud.html lowcloud_ec.html lowcloud_avg.html 2>$null
        git diff --cached --quiet 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Log "変更なし。スキップします。"
            return
        }
        $ts = Get-Date -Format "yyyy-MM-dd HH:mm"
        git commit -m "update: $ts" 2>$null | Out-Null
        $pushed = $false
        for ($i = 1; $i -le 3; $i++) {
            # rebase中の -X theirs は「再適用する自分のコミット側」＝今生成した最新HTMLを優先する
            git pull --rebase -X theirs origin main 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) { git rebase --abort 2>$null }
            git push origin main 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { $pushed = $true; break }
            Write-Log "push 失敗（$i 回目）。10秒後に再試行します。"
            Start-Sleep -Seconds 10
        }
        if ($pushed) {
            Write-Log "GitHub Pages にアップロードしました。"
        } else {
            Write-Log "push に3回失敗しました。資格情報・ネットワークを確認してください。"
        }
    }

} catch {
    Write-Log ("エラー: {0}" -f $_.Exception.Message)
    exit 1
}
