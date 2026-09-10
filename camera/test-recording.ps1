#Requires -Version 5.1
# オフライン回帰確認。本番CSV・タスク・ネットワークには触れない。
param([string]$Case, [string]$TestDir)
$ErrorActionPreference = 'Stop'

if ($Case) {
    function Invoke-WebRequest { throw 'TEST: network unavailable' }
    function Invoke-RestMethod { throw 'TEST: network unavailable' }
    switch ($Case) {
        'camera-header' { & "$PSScriptRoot/capture-mezuru.ps1" -OutDir $TestDir }
        'forecast-header' { & "$PSScriptRoot/save-fog-forecast.ps1" -OutDir $TestDir -Force }
        'camera-network' { & "$PSScriptRoot/capture-mezuru.ps1" -OutDir $TestDir -NoImage }
        'forecast-network' { & "$PSScriptRoot/save-fog-forecast.ps1" -OutDir $TestDir }
        'forecast-duplicate' { & "$PSScriptRoot/save-fog-forecast.ps1" -OutDir $TestDir }
    }
    exit $LASTEXITCODE
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('fog-recording-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
foreach ($name in 'camera-header','forecast-header','camera-network','forecast-network','forecast-duplicate') {
    $dir = Join-Path $testRoot $name
    New-Item -ItemType Directory -Path $dir | Out-Null
    $csvName = if ($name -like 'camera-*') { 'mezuru_contrast.csv' } else { 'fog_forecast.csv' }
    $csv = Join-Path $dir $csvName
    if ($name -like '*-header') { Set-Content -LiteralPath $csv -Value "old,header`r`nkeep,this" -Encoding UTF8 }
    if ($name -eq 'forecast-duplicate') {
        $header = 'issued_at,target_time,lead_h,cl_bm,cl_ec,cl_avg,rh2m_bm,rh2m_ec,rh_above_bm,rh_above_ec,p_above_bm,p_above_ec,v_bm,v_ec,wind_bm,vis_bm,precip_bm'
        $issued = (Get-Date).ToUniversalTime().AddHours(9).ToString('yyyy-MM-dd HH:mm')
        Set-Content -LiteralPath $csv -Value @($header, ($issued + ',2099-01-01 12:00,1,0,0,0,0,0,0,0,925,925,1,1,0,0,0')) -Encoding UTF8
    }
    $before = if (Test-Path -LiteralPath $csv) { (Get-FileHash -LiteralPath $csv).Hash } else { $null }
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Case $name -TestDir $dir 2>&1
    $actual = $LASTEXITCODE
    $expected = if ($name -eq 'forecast-duplicate') { 0 } else { 1 }
    if ($actual -ne $expected) { throw "$name exit=$actual expected=$expected : $output" }
    if ($before -and (Get-FileHash -LiteralPath $csv).Hash -ne $before) { throw "$name changed existing CSV" }
    if ($name -like '*-header' -and "$output" -match 'network unavailable') { throw "$name reached network" }
    if ($name -like '*-network' -and "$output" -notmatch 'network unavailable') { throw "$name did not exercise network failure" }
    Write-Host "PASS $name"
}
Write-Host "Test artifacts: $testRoot"
