param(
    [string]$VidPid = '',
    [string]$Distro = '',
    [string]$BusId = '',
    [switch]$Up,
    [switch]$Force
)

Write-Host 'attach.ps1 now forwards to windows\wifimon.ps1 attach - see README.md' -ForegroundColor DarkGray

$target = Join-Path $PSScriptRoot 'windows\wifimon.ps1'
if (-not (Test-Path $target)) {
    Write-Host "[!] missing $target" -ForegroundColor Red
    exit 1
}

$forward = @('attach')
if ($VidPid) { $forward += @('-VidPid', $VidPid) }
if ($Distro) { $forward += @('-Distro', $Distro) }
if ($BusId)  { $forward += @('-BusId', $BusId) }
if ($Up)     { $forward += '-Up' }
if ($Force)  { $forward += '-Force' }

& $target @forward
exit $LASTEXITCODE
