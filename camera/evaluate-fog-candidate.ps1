#Requires -Version 5.1
<#
.SYNOPSIS
  保存済み数値に暫定基準v1を適用する。既存CSV・本番ラベルは変更しない。
.EXAMPLE
  .\camera\evaluate-fog-candidate.ps1 -Date 2026-09-12 | Format-Table -AutoSize
#>
param(
    [string]$Date = (Get-Date).ToString('yyyy-MM-dd'),
    [string]$CsvPath = (Join-Path $PSScriptRoot 'mezuru_contrast.csv')
)
$ErrorActionPreference = 'Stop'
$c = Get-Content (Join-Path $PSScriptRoot 'fog-criteria-v1.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$culture = [Globalization.CultureInfo]::InvariantCulture
foreach ($r in (Import-Csv -LiteralPath $CsvPath -Encoding UTF8)) {
    if (-not $r.captured_at_jst.StartsWith($Date)) { continue }
    $reason = New-Object 'System.Collections.Generic.List[string]'
    $code = ''; $near = $null; $mid = $null; $far = $null
    if ($r.dark -ne '0' -or -not $r.mean_all -or [double]::Parse($r.mean_all,$culture) -lt $c.dark_min) {
        $reason.Add('暗い・輝度欠測')
    } elseif ($r.note -like '*size_changed*') {
        $reason.Add('画角確認が必要')
    } elseif (-not $r.near_lc -or -not $r.mid_lc -or -not $r.far_lc) {
        $reason.Add('指標欠測')
    } else {
        $near = [double]::Parse($r.near_lc,$culture)
        $mid = [double]::Parse($r.mid_lc,$culture)
        $far = [double]::Parse($r.far_lc,$culture)
        if ($near -lt $c.near_dense_max -and $far -lt $c.far_hidden_max) { $code = 'D' }
        elseif ($far -lt $c.far_hidden_max) { $code = 'B' }
        elseif ($far -lt $c.far_clear_min) { $code = 'H' }
        else { $code = 'C' }
        if ([math]::Abs($near - $c.near_dense_max) -le $c.review_near_margin) { $reason.Add('近景の境界付近') }
        if ([math]::Abs($far - $c.far_hidden_max) -le $c.review_far_hidden_margin) { $reason.Add('遠景の消失境界付近') }
        if ([math]::Abs($far - $c.far_clear_min) -le $c.review_far_clear_margin) { $reason.Add('遠景の明瞭境界付近') }
        if ($near -lt $c.near_dense_max -and $far -ge $c.far_hidden_max) { $reason.Add('近景と遠景が不整合') }
        if ($code -eq 'C' -and $mid -lt $c.review_clear_mid_min) { $reason.Add('遠景と中景が不整合') }
    }
    [pscustomobject]@{
        time = $r.captured_at_jst; version = $c.version
        near = $near; mid = $mid; far = $far
        old_label = $r.label; code = $code
        candidate = $(if ($code) { $c.labels.$code } else { '判定対象外' })
        review = ($reason.Count -gt 0); reason = ($reason -join ' / ')
    }
}
