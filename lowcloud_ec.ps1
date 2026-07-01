<#
.SYNOPSIS
  lowcloud.ps1 を ECMWF(ecmwf_ifs025) モデルで実行する薄いラッパー。

.DESCRIPTION
  地点・標高等のパラメータは lowcloud.ps1 と同じものを受け取り、そのまま本体へ転送する。
  モデル・出力名・見出し表記だけを ECMWF 用に固定する。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\lowcloud_ec.ps1
#>

[CmdletBinding()]
param(
    [double]$Latitude    = 33.4666147,
    [double]$Longitude   = 132.9610114,
    [Nullable[double]]$Elevation = 1380,
    [int]   $ForecastDays = 4,
    [int]   $WeeklyDays  = 7,
    [string]$Timezone    = "Asia/Tokyo",
    [string]$CsvPath     = ""
)

& (Join-Path $PSScriptRoot "lowcloud.ps1") @PSBoundParameters `
    -Models "ecmwf_ifs025" -OutName "lowcloud_ec" -ModelLabel "[ECMWF]"
