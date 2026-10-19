#Requires -Version 5.1
<#
.SYNOPSIS
  カメラ記録と霧予報の履歴（camera/*.csv の2ファイル）だけを commit・push する。

.DESCRIPTION
  2つのCSVはこのPCでしか作られず、後から取り直せない。PCの故障で失われないよう、
  KarstFogForecast タスクの2つ目の動作として 1日2回（予報保存の直後）GitHub へ送る。

  - commit するのは下の2ファイルだけ。作業中の他の変更は commit せず、付け替え中は一時退避する（--autostash）
  - 2ファイルはこのPCだけが書くので、付け替えで競合しない前提。競合したら中断して終了コード1
  - 認証は Git Credential Manager の保存済み資格情報。対話が必要なら待たずに失敗させる
  - main 以外のブランチにいる時、camera 以外の未送信 commit がある時は送らない（終了コード1）
  - 副作用として作業リポジトリも origin/main に追従する

  2026-10-19 の障害を受けた再発防止（10/18 06:25 の実行が同期の途中で止まり、その後の解除で
  10/18 06:50〜17:50 のカメラ記録12回分が消え、残ったファイルが邪魔をして2日間送れなかった）:
  - 通信（fetch）と付け替え（rebase）を分ける。通信中に止まっても付け替えの途中状態は残らない。
    通信が 1000バイト/秒未満で60秒続いたら打ち切る
  - 開始時に付け替えの途中状態が残っていたら解除する。解除・中断の前に2つのCSVを控え、
    解除で消えた行を書き戻す（控えは camera/push-backup/ にも残す）
  - 付け替えの邪魔になる管理外ファイルは、GitHub 上と中身が完全に同じものだけ
    camera/push-backup/ へ退避する。中身が違えば退避せず中断する

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\camera\push-camera-data.ps1
#>

[CmdletBinding()]
param([int]$MaxTries = 3)

$ErrorActionPreference = "Stop"
$repo   = Split-Path $PSScriptRoot -Parent
$files  = @("camera/fog_forecast.csv", "camera/mezuru_contrast.csv")
$log    = Join-Path $PSScriptRoot "push.log"
$backup = Join-Path $PSScriptRoot "push-backup"
$stamp  = Get-Date -Format "yyyyMMdd-HHmmss"
$env:GIT_TERMINAL_PROMPT      = "0"
$env:GCM_INTERACTIVE          = "never"
$env:GIT_HTTP_LOW_SPEED_LIMIT = "1000"
$env:GIT_HTTP_LOW_SPEED_TIME  = "60"

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

function Test-RebaseInProgress {
    return ((Test-Path -LiteralPath (Join-Path $repo ".git/rebase-merge")) -or
            (Test-Path -LiteralPath (Join-Path $repo ".git/rebase-apply")))
}

# 2つのCSVの現在の行を控える。$Keep を付けると camera/push-backup/ にもコピーを残す
function Get-DataSnapshot([switch]$Keep) {
    $snap = @{}
    foreach ($f in $files) {
        $p = Join-Path $repo $f
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $snap[$f] = [IO.File]::ReadAllLines($p, [Text.UTF8Encoding]::new($false))
        if ($Keep) {
            [void][IO.Directory]::CreateDirectory($backup)
            Copy-Item -LiteralPath $p -Destination (Join-Path $backup ("{0}.{1}" -f (Split-Path $f -Leaf), $stamp)) -Force
        }
    }
    return $snap
}

# 控えにあって今のファイルに無い行を、控えでの順番のまま末尾へ書き戻す（UTF-8 BOM付き・CRLF）
function Restore-DataRows($snap) {
    foreach ($f in $snap.Keys) {
        $p = Join-Path $repo $f
        $old = @($snap[$f])
        if ($old.Count -le 1) { continue }
        $cur = if (Test-Path -LiteralPath $p) { @([IO.File]::ReadAllLines($p, [Text.UTF8Encoding]::new($false))) } else { @() }
        $have = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($l in $cur) { [void]$have.Add($l) }
        $missing = @($old | Select-Object -Skip 1 | Where-Object { $_ -and -not $have.Contains($_) })
        if ($missing.Count -eq 0) { continue }
        $lines = if ($cur.Count -gt 0) { @($cur | Where-Object { $_ }) } else { @($old[0]) }
        [IO.File]::WriteAllText($p, ((@($lines) + $missing) -join "`r`n") + "`r`n", [Text.UTF8Encoding]::new($true))
        Write-PushLog ("{0} に消えていた {1} 行を書き戻しました" -f $f, $missing.Count)
    }
}

# 付け替えの途中状態を、記録を失わずに解除する
function Invoke-SafeAbort([string]$why) {
    $snap = Get-DataSnapshot -Keep
    $r = Invoke-Git rebase --abort
    if (-not $r.ok) { throw ("付け替えの解除に失敗（{0}）: {1}" -f $why, $r.out) }
    Write-PushLog ("付け替えの途中状態を解除しました（{0}）" -f $why)
    Restore-DataRows $snap
}

# 付け替えで GitHub 側から入ってくるファイルと同名の管理外ファイルを退避する。
# 中身が GitHub 上と完全に同じものだけ動かす。違うものがあれば中断する。
function Move-CollidingUntracked {
    # PowerShell 5.1 は git の標準エラーを例外にするため、git の呼び出しでは止めない
    $ErrorActionPreference = "Continue"
    $untracked = @(& git -C $repo ls-files --others --exclude-standard 2>$null | Where-Object { $_ })
    if ($untracked.Count -eq 0) { return }
    $incoming = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($n in @(& git -C $repo diff --name-only --diff-filter=A HEAD origin/main 2>$null)) { if ($n) { [void]$incoming.Add($n) } }
    $hits = @($untracked | Where-Object { $incoming.Contains($_) })
    if ($hits.Count -eq 0) { return }
    $diff = @()
    foreach ($n in $hits) {
        $local  = (& git -C $repo hash-object -- $n 2>$null)
        $remote = (& git -C $repo rev-parse ("origin/main:" + $n) 2>$null)
        if ($local -ne $remote) { $diff += $n }
    }
    if ($diff.Count -gt 0) {
        throw ("GitHub 上と中身の違う管理外ファイルがあるため送りません（手で確認してください）: " + ($diff -join ", "))
    }
    $dest = Join-Path $backup ("untracked-" + $stamp)
    foreach ($n in $hits) {
        $to = Join-Path $dest $n
        [void][IO.Directory]::CreateDirectory((Split-Path $to -Parent))
        Move-Item -LiteralPath (Join-Path $repo $n) -Destination $to -Force -ErrorAction Stop
    }
    Write-PushLog ("GitHub 上と同じ管理外ファイル {0} 個を退避しました: {1}" -f $hits.Count, $dest)
}

try {
    # 前回が付け替えの途中で止まっていたら、記録を守りながら解除する
    if (Test-RebaseInProgress) { Invoke-SafeAbort "前回の途中状態" }

    $branch = Invoke-Git rev-parse --abbrev-ref HEAD
    if ($branch.out -ne "main") { throw ("main 以外のブランチ（{0}）で作業中のため送りません" -f $branch.out) }

    $changed = Invoke-Git status --porcelain -- @files
    if (-not $changed.ok) { throw ("git status 失敗: " + $changed.out) }
    if ($changed.out) {
        $label = Get-Date -Format "yyyy-MM-dd HH:mm"
        $r = Invoke-Git commit -q -m ("data: camera records {0} JST" -f $label) -- @files
        if (-not $r.ok) { throw ("commit 失敗: " + $r.out) }
        Write-PushLog ("commit しました（{0} JST）" -f $label)
    }

    # 送るものが無くても、前回 push に失敗した commit が残っていれば送る
    for ($i = 1; $i -le $MaxTries; $i++) {
        # 通信はここだけ。止まっても作業リポジトリは変わらない
        $r = Invoke-Git fetch -q origin main
        if (-not $r.ok) {
            Write-PushLog ("fetch 失敗（{0}/{1}回目）: {2}" -f $i, $MaxTries, $r.out)
            Start-Sleep -Seconds (15 * $i)
            continue
        }
        Move-CollidingUntracked
        # 付け替えは手元だけで完結する
        $r = Invoke-Git rebase --autostash -q origin/main
        if (-not $r.ok) {
            if (Test-RebaseInProgress) { Invoke-SafeAbort "付け替えの失敗" }
            throw ("rebase 失敗: " + $r.out)
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
