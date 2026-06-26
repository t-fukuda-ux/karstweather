#Requires -Version 5.1
<#
.SYNOPSIS
  GitHub Pages 公開の初回セットアップ（1回だけ実行する）

.DESCRIPTION
  実行前に以下を準備すること:
    1. GitHub でリポジトリを新規作成（Public、README なし）
       例: https://github.com/あなたのID/himezuraso-weather
    2. GitHub で Personal Access Token (PAT) を発行
       Settings → Developer settings → Personal access tokens → Fine-grained tokens
       権限: Contents (Read and Write)
    3. 下の $RepoUrl と $UserName を書き換えてから実行

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File ".\setup-github.ps1"
#>

# ======================================================
# ★ここを書き換えてから実行する★
$RepoUrl  = "https://github.com/t-fukuda-ux/karstweather.git"
$UserName = "t-fukuda-ux"
$UserMail = "t-fukuda@kumax.co.jp"
# ======================================================

$ErrorActionPreference = "Stop"
$dir = $PSScriptRoot

Write-Host "=== GitHub Pages セットアップ ===" -ForegroundColor Cyan

# git の初期化
Push-Location $dir
try {
    if (-not (Test-Path (Join-Path $dir ".git"))) {
        git init -b main
        Write-Host "git init 完了" -ForegroundColor Green
    } else {
        Write-Host "git リポジトリは既に存在します。" -ForegroundColor Yellow
    }

    # ユーザー設定
    git config user.name  $UserName
    git config user.email $UserMail

    # リモート設定
    $existing = git remote get-url origin 2>$null
    if ($existing) {
        git remote set-url origin $RepoUrl
        Write-Host "リモート URL を更新しました: $RepoUrl" -ForegroundColor Green
    } else {
        git remote add origin $RepoUrl
        Write-Host "リモートを追加しました: $RepoUrl" -ForegroundColor Green
    }

    # 初回HTML生成
    Write-Host "lowcloud.ps1 を実行中..." -ForegroundColor Cyan
    & powershell -ExecutionPolicy Bypass -File (Join-Path $dir "lowcloud.ps1")
    Copy-Item (Join-Path $dir "lowcloud.html") (Join-Path $dir "index.html") -Force

    # 初回 commit & push
    git add .
    git commit -m "initial commit"
    Write-Host ""
    Write-Host "★ 次にGitHubのパスワード入力欄が出たら:" -ForegroundColor Yellow
    Write-Host "  ユーザー名: $UserName" -ForegroundColor Yellow
    Write-Host "  パスワード: 発行した PAT を貼り付ける（画面には表示されない）" -ForegroundColor Yellow
    Write-Host ""
    git push -u origin main

    Write-Host ""
    Write-Host "=== 完了 ===" -ForegroundColor Green
    Write-Host "GitHub リポジトリの Settings → Pages で以下を設定してください:" -ForegroundColor Cyan
    Write-Host "  Source: Deploy from a branch" -ForegroundColor Cyan
    Write-Host "  Branch: main / (root)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "公開URLは数分後に以下になります:" -ForegroundColor Cyan
    $user = $RepoUrl -replace 'https://github.com/(.+?)/.+', '$1'
    $repo = $RepoUrl -replace 'https://github.com/.+?/(.+?)\.git', '$1'
    Write-Host ("  https://{0}.github.io/{1}/" -f $user, $repo) -ForegroundColor Green

} finally {
    Pop-Location
}
