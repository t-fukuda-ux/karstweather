#Requires -Version 5.1
<#
.SYNOPSIS
  lowcloud.html を生成して GitHub Pages に push する。

.DESCRIPTION
  タスクスケジューラから呼び出す用。
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
    # Step 1: 天気予報HTML生成
    Write-Log "lowcloud.ps1 を実行中..."
    & powershell -ExecutionPolicy Bypass -File (Join-Path $dir "lowcloud.ps1")

    # Step 2: index.html としてコピー（GitHub Pages のルートファイル）
    $src  = Join-Path $dir "lowcloud.html"
    $dest = Join-Path $dir "index.html"
    Copy-Item -Path $src -Destination $dest -Force
    Write-Log "index.html を更新しました。"

    # Step 3: git commit & push
    Push-Location $dir
    try {
        git add index.html lowcloud.html 2>&1 | Out-Null
        $changed = git status --porcelain
        if ($changed) {
            $ts = Get-Date -Format "yyyy-MM-dd HH:mm"
            git commit -m "update: $ts" 2>&1 | Out-Null
            git push origin main 2>&1 | Out-Null
            Write-Log "GitHub Pages にアップロードしました。"
        } else {
            Write-Log "変更なし。スキップします。"
        }
    } finally {
        Pop-Location
    }

} catch {
    Write-Log ("エラー: {0}" -f $_.Exception.Message)
    exit 1
}
