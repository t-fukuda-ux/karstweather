#Requires -Version 5.1
<#
.SYNOPSIS
  lowcloud_avg.html（平均版）を生成し、WEB公開用 index.html として GitHub Pages に push する。

.DESCRIPTION
  タスクスケジューラから呼び出す用（現在はGitHub Actionsが主担当。ローカル手動実行用に残置）。
  初回セットアップは setup-github.ps1 を先に実行すること。
  規定版(lowcloud.ps1)・EC版(lowcloud_ec.ps1)は比較用に手元で個別実行すること
  （WEB公開のindex.htmlには反映されない）。

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
    # Step 1: 天気予報HTML生成（平均版＝WEB公開のメイン）
    Write-Log "lowcloud_avg.ps1 を実行中..."
    & powershell -ExecutionPolicy Bypass -File (Join-Path $dir "lowcloud_avg.ps1")

    # Step 2: index.html としてコピー（GitHub Pages のルートファイル）
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
        git add index.html lowcloud_avg.html 2>$null
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
