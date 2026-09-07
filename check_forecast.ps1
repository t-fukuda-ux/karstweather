#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Path = (Join-Path $PSScriptRoot 'index.html'),
    [ValidateRange(1,168)][double]$MaxAgeHours = 3,
    [datetimeoffset]$Now = [datetimeoffset]::UtcNow
)
$ErrorActionPreference = 'Stop'
# チェックアウトの更新日時ではなく、実際に公開するページに記録された取得時刻を使う。
$html = [IO.File]::ReadAllText($Path)
$m = [regex]::Match($html, '取得:\s*(\d{4}-\d{2}-\d{2} \d{2}:\d{2}) JST')
if (-not $m.Success) { throw '平均版の取得時刻を確認できません。index.html を確認してください。' }
$issued = [datetimeoffset]::ParseExact(($m.Groups[1].Value + ' +09:00'), 'yyyy-MM-dd HH:mm zzz', [cultureinfo]::InvariantCulture)
$age = ($Now - $issued).TotalHours
if ($age -lt -0.25) { throw '平均版の取得時刻が未来になっています。時刻設定を確認してください。' }
if ($age -ge $MaxAgeHours) {
    throw ('平均版の更新停止: 最終取得 {0} JST（{1:F1}時間経過、基準{2}時間）。他の版が成功していても要確認です。' -f $m.Groups[1].Value,$age,$MaxAgeHours)
}
Write-Host ('平均版の鮮度: 正常（最終取得 {0} JST）' -f $m.Groups[1].Value)
