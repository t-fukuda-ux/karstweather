#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'lowcloud_common.ps1')
. (Join-Path $root 'forecast_history.ps1')
function Assert($condition,$message) { if (-not $condition) { throw $message } }
function Load-Functions($path) {
    $errors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$null,[ref]$errors)
    if ($errors) { throw ($errors | Out-String) }
    $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false) | ForEach-Object {
        # 対象スクリプトのメイン（通信・保存）は実行せず、関数だけ同じスコープへ読み込む。
        . ([scriptblock]::Create($_.Extent.Text.Replace(('function '+$_.Name+' '),('function script:'+$_.Name+' '))))
    }
}
Load-Functions (Join-Path $root 'lowcloud.ps1')
Load-Functions (Join-Path $root 'lowcloud_avg.ps1')
$Latitude=33.4666147; $Longitude=132.9610114; $WeeklyDays=7
# 温度のみを検証するため天文計算は固定値にする。
function Get-JD { param($utc) 0 }
function Get-StarIndex { param($jd,$lat,$lon,$totalCloud,$precip) 0 }
function Get-MoonAlt { param($jd,$lat,$lon) 0 }
function Get-MoonBrightness { param($jd,$lat,$lon) 0 }
function Get-MoonPhase { param($jd) 0 }
function Get-MoonRiseSet { param($localDate,$lat,$lon) @{rise='--';set='--'} }
function Get-MoonPhaseInfo { param($localDate) @{emoji='';name='';age=0} }
$h=@{}
foreach ($key in @('time','temperature_2m','weather_code','wind_speed_10m','precipitation_probability','precipitation','snowfall','cloud_cover','cloud_cover_low','cloud_cover_mid','cloud_cover_high')) { $h[$key]=@() }
for ($i=0;$i -lt 168;$i++) {
    $dt=([datetime]'2026-09-07').AddHours($i)
    $h.time += $dt.ToString('yyyy-MM-ddTHH:mm')
    $h.temperature_2m += $(if ($i -ge 144) { $null } elseif ($dt.Hour -eq 12) { 20.2 } elseif ($dt.Hour -eq 4) { 9.1 } else { 15.0 })
    foreach ($k in @('weather_code','wind_speed_10m','precipitation_probability','precipitation','snowfall','cloud_cover','cloud_cover_low','cloud_cover_mid','cloud_cover_high')) { $h[$k] += 0 }
}
$d=@{time=@();weather_code=@();temperature_2m_max=@();temperature_2m_min=@();precipitation_probability_max=@();precipitation_sum=@();sunrise=@();sunset=@()}
for($i=0;$i -lt 7;$i++) {
    $day=([datetime]'2026-09-07').AddDays($i).ToString('yyyy-MM-dd'); $d.time += $day; $d.sunrise += ($day+'T06:00'); $d.sunset += ($day+'T18:00')
    foreach($k in @('weather_code','temperature_2m_max','temperature_2m_min','precipitation_probability_max','precipitation_sum')) { $d[$k]+=0 }
}
$rows=Build-Rows -data @{hourly=$h} -AllHours
$daily=Get-DailyRows -d $d -allRows $rows
Assert ($rows.Count -eq 168 -and $daily.Count -eq 7) '週間用に7日分が必要です'
Assert ($daily[0].tmax -eq 23.2 -and $daily[0].tmin -eq 9.1) '規定/ECの補正後最高・最低が不一致'
Assert ((Format-DisplayTemperature $daily[0].tmax) -eq '24') '夏の晴天補正と切り上げ'
Assert ($daily[5].tmax -eq 23.2) '毎時表示範囲外の6日目も集計が必要'
Assert ($null -eq $daily[6].tmax -and (Format-DisplayTemperature $daily[6].tmin) -eq '--') '全欠測を0℃にしない'
$avgRows=Build-AvgRows -hA $h -hB $h
$avgDaily=Build-AvgDaily -allRows $avgRows -sunMap @{} -days 7
Assert ($avgDaily[0].tmax -eq 23.2 -and $avgDaily[0].tmin -eq 9.1) '平均版の補正後集計'
Assert ($null -eq $avgDaily[6].tmax) '平均版の欠測'
Assert ((Get-UnkaiLabel -F 0.8 -V 1 -TopStatus 'capped' -SummitStatus 'summit_dry' -GateF $true -GateV $true) -eq '雲海期待・視界良好') '短い予測ラベル'
# 更新日時はJSTからUTCへ変換し、3時間ちょうどから異常。
$temp=Join-Path ([IO.Path]::GetTempPath()) ('weather-test-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
$page=Join-Path $temp 'index.html'
[IO.File]::WriteAllText($page,'取得: 2026-09-07 09:00 JST')
& (Join-Path $root 'check_forecast.ps1') -Path $page -Now ([datetimeoffset]'2026-09-07T02:59:00Z')
$caught=$false
try { & (Join-Path $root 'check_forecast.ps1') -Path $page -Now ([datetimeoffset]'2026-09-07T03:00:00Z') } catch { $caught=$true }
Assert $caught '3時間経過した平均版は異常にする'
[IO.File]::WriteAllText($page,'取得日時なし')
$caught=$false
try { & (Join-Path $root 'check_forecast.ps1') -Path $page } catch { $caught=$true }
Assert $caught '取得日時欠落は異常にする'
# 詳細行は本テストでは最小化。履歴の時刻・欠測・上書き防止の振る舞いを検証。
function Get-UnkaiDetailLines { param($Hours,$Model) @($Hours | ForEach-Object { $_.time+','+$_.idx }) }
function Get-UnkaiLevelLines { param($Hours,$Model) @() }
$hours=@(@{date='2026-09-08';time='2026-09-08 06:00';idx=80})
Save-ForecastHistory -ByModel @{best_match=$hours} -Dir $temp -IssuedAt ([datetime]'2026-09-07 17:59') -SourceRevision 'test' -AverageMode ''
Assert (-not (Test-Path (Join-Path $temp 'forecast-history/2026-09-07'))) '18時前を夕方代表にしない'
Save-ForecastHistory -ByModel @{best_match=$hours} -Dir $temp -IssuedAt ([datetime]'2026-09-07 18:11') -SourceRevision 'test' -AverageMode ''
$history=(Get-ChildItem (Join-Path $temp 'forecast-history/2026-09-07') -Filter 'best_match-*.json').FullName
$original=[IO.File]::ReadAllText($history)
Save-ForecastHistory -ByModel @{best_match=$hours} -Dir $temp -IssuedAt ([datetime]'2026-09-07 19:11') -SourceRevision 'later' -AverageMode ''
Assert ($original -eq [IO.File]::ReadAllText($history)) '最初の予報を後続実行で上書きしない'
Assert (($original | ConvertFrom-Json).issued_at -eq '2026-09-07T18:11:00+09:00') '発表日時とJSTを保存'
$hours[0].idx=$null
Save-ForecastHistory -ByModel @{ecmwf_ifs025=$hours} -Dir $temp -IssuedAt ([datetime]'2026-09-07 18:11') -SourceRevision 'test' -AverageMode ''
Assert (@(Get-ChildItem (Join-Path $temp 'forecast-history/2026-09-07') -Filter 'ecmwf_ifs025-*.json').Count -eq 0) '全欠測の夕方代表を保存しない'
Write-Host 'PASS: 週間7日・気温補正・欠測・ラベル・鮮度境界・予報履歴'
