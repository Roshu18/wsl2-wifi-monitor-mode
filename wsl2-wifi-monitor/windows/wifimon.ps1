#Requires -Version 5.1
param(
    [Parameter(Position = 0)]
    [ValidateSet('attach', 'detach', 'list', 'status', 'install', 'doctor', 'watch', 'up', 'help')]
    [string]$Command = 'attach',

    [string]$VidPid = '',
    [string]$BusId = '',
    [string]$Distro = '',
    [string]$Channel = '',
    [switch]$All,
    [switch]$Force,
    [switch]$Up,
    [switch]$Quiet,
    [switch]$NoElevate,
    [int]$PollSeconds = 5
)

$ErrorActionPreference = 'Stop'
$script:ExitCode = 0
$script:UsbipdVersion = $null

function Write-Step { param([string]$m) if (-not $Quiet) { Write-Host "`n==> $m" -ForegroundColor Cyan } }
function Write-Info { param([string]$m) if (-not $Quiet) { Write-Host "[*] $m" -ForegroundColor Cyan } }
function Write-Ok   { param([string]$m) if (-not $Quiet) { Write-Host "[+] $m" -ForegroundColor Green } }
function Write-Warn { param([string]$m) Write-Host "[~] $m" -ForegroundColor Yellow }
function Write-Err  { param([string]$m) Write-Host "[!] $m" -ForegroundColor Red }
function Write-Hint {
    param([string[]]$lines)
    if ($Quiet) { return }
    foreach ($l in $lines) { Write-Host "    $l" -ForegroundColor DarkGray }
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-SelfElevated {
    if ($NoElevate) {
        Write-Err 'this needs Administrator rights and -NoElevate was given'
        exit 5
    }
    Write-Info 'elevating to Administrator'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", $Command)
    if ($VidPid)  { $argList += @('-VidPid', $VidPid) }
    if ($BusId)   { $argList += @('-BusId', $BusId) }
    if ($Distro)  { $argList += @('-Distro', $Distro) }
    if ($Channel) { $argList += @('-Channel', $Channel) }
    if ($All)     { $argList += '-All' }
    if ($Force)   { $argList += '-Force' }
    if ($Up)      { $argList += '-Up' }
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs -Wait -PassThru
    exit $p.ExitCode
}

function Sync-Path {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machine;$user"
}

function Get-UsbipdVersion {
    if ($script:UsbipdVersion) { return $script:UsbipdVersion }
    if (-not (Get-Command usbipd -ErrorAction SilentlyContinue)) { return $null }
    try {
        $raw = (& usbipd --version 2>&1 | Out-String).Trim()
        $m = [regex]::Match($raw, '(\d+)\.(\d+)\.(\d+)')
        if ($m.Success) {
            $script:UsbipdVersion = [version]("{0}.{1}.{2}" -f $m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value)
            return $script:UsbipdVersion
        }
    } catch { }
    $script:UsbipdVersion = [version]'0.0.0'
    return $script:UsbipdVersion
}

function Install-Usbipd {
    Sync-Path
    $v = Get-UsbipdVersion
    if ($v -and $v -ge [version]'4.0.0') {
        Write-Ok "usbipd-win $v is installed"
        return $true
    }
    if ($v) {
        Write-Warn "usbipd-win $v is old; 4.0 or newer is recommended"
    }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Err 'winget is not available, so usbipd-win cannot be installed automatically'
        Write-Hint @(
            'Install it by hand from: https://github.com/dorssel/usbipd-win/releases',
            'then run this script again.'
        )
        return $false
    }
    Write-Info 'installing usbipd-win via winget'
    & winget install --id dorssel.usbipd-win --exact --accept-source-agreements --accept-package-agreements --disable-interactivity
    Sync-Path
    $script:UsbipdVersion = $null
    $v = Get-UsbipdVersion
    if (-not $v) {
        Write-Err 'usbipd is still not on PATH'
        Write-Hint @('A new terminal (or a reboot) is sometimes needed after installation.')
        return $false
    }
    Write-Ok "usbipd-win $v installed"
    return $true
}

function Get-UsbDevices {
    $v = Get-UsbipdVersion
    if (-not $v) { return @() }

    if ($v -ge [version]'4.0.0') {
        try {
            $json = (& usbipd state 2>$null | Out-String)
            if ($json.Trim()) {
                $parsed = $json | ConvertFrom-Json
                $out = @()
                foreach ($d in $parsed.Devices) {
                    $vid = ''
                    $pid = ''
                    $m = [regex]::Match([string]$d.InstanceId, 'VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})')
                    if ($m.Success) {
                        $vid = $m.Groups[1].Value.ToLower()
                        $pid = $m.Groups[2].Value.ToLower()
                    }
                    $state = 'Not shared'
                    if ($d.ClientIPAddress) { $state = 'Attached' }
                    elseif ($d.PersistedGuid) { $state = 'Shared' }
                    elseif ($d.StubInstanceId) { $state = 'Shared' }
                    $out += [pscustomobject]@{
                        BusId       = [string]$d.BusId
                        VidPid      = "$vid`:$pid"
                        Description = [string]$d.Description
                        State       = $state
                        Client      = [string]$d.ClientIPAddress
                    }
                }
                if ($out.Count -gt 0) { return $out }
            }
        } catch {
            Write-Verbose "usbipd state failed: $_"
        }
    }

    $listCmd = @('wsl', 'list')
    if ($v -ge [version]'4.0.0') { $listCmd = @('list') }
    $text = (& usbipd @listCmd 2>$null | Out-String) -split "`r?`n"
    $out = @()
    foreach ($line in $text) {
        $m = [regex]::Match($line, '^\s*(?<bus>\d+-\d+)\s+(?<vid>[0-9a-fA-F]{4}):(?<pid>[0-9a-fA-F]{4})\s+(?<desc>.+?)\s\s+(?<state>\S.*?)\s*$')
        if (-not $m.Success) { continue }
        $out += [pscustomobject]@{
            BusId       = $m.Groups['bus'].Value
            VidPid      = ($m.Groups['vid'].Value + ':' + $m.Groups['pid'].Value).ToLower()
            Description = $m.Groups['desc'].Value.Trim()
            State       = $m.Groups['state'].Value.Trim()
            Client      = ''
        }
    }
    return $out
}

function Get-AdapterDb {
    $db = @{}
    $file = Join-Path (Split-Path -Parent $PSScriptRoot) 'data\adapters.tsv'
    if (-not (Test-Path $file)) { return $db }
    foreach ($line in Get-Content -LiteralPath $file) {
        if (-not $line -or $line.StartsWith('#')) { continue }
        $f = $line -split "`t"
        if ($f.Count -lt 5) { continue }
        $key = ($f[0] + ':' + $f[1]).ToLower()
        $db[$key] = [pscustomobject]@{ Chipset = $f[2]; Driver = $f[3]; Name = $f[4] }
    }
    return $db
}

function Select-Targets {
    param([object[]]$Devices)

    if ($BusId) {
        $hit = @($Devices | Where-Object { $_.BusId -eq $BusId })
        if ($hit.Count -eq 0) { Write-Err "no device on bus $BusId"; return @() }
        return $hit
    }
    if ($VidPid) {
        $want = $VidPid.ToLower().Replace('0x', '')
        $hit = @($Devices | Where-Object { $_.VidPid -eq $want })
        if ($hit.Count -eq 0) { Write-Err "no device with id $VidPid"; return @() }
        return $hit
    }

    $db = Get-AdapterDb
    $known = @($Devices | Where-Object { $db.ContainsKey($_.VidPid) })
    if ($known.Count -gt 0) {
        foreach ($d in $known) {
            $info = $db[$d.VidPid]
            Write-Info "found $($info.Name) [$($d.VidPid)] on bus $($d.BusId) -> driver '$($info.Driver)'"
        }
        if ($All) { return $known }
        if ($known.Count -gt 1) {
            Write-Warn "$($known.Count) known adapters attached; using bus $($known[0].BusId). Pass -All or -BusId to choose."
        }
        return @($known[0])
    }

    $guess = @($Devices | Where-Object {
        $_.Description -match '(?i)wi-?fi|wlan|wireless|802\.11|network adapter'
    })
    if ($guess.Count -gt 0) {
        Write-Warn 'no adapter from the database is attached; these look like Wi-Fi devices:'
        foreach ($d in $guess) { Write-Hint @("$($d.BusId)  $($d.VidPid)  $($d.Description)") }
        Write-Hint @('Attach one explicitly:', "  .\wifimon.ps1 attach -BusId $($guess[0].BusId)")
        return @()
    }

    Write-Err 'no USB Wi-Fi adapter found'
    Write-Hint @(
        'Plug the adapter in, then list what Windows sees:',
        '  .\wifimon.ps1 list'
    )
    return @()
}

function Get-WslDistros {
    $prev = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::Unicode
        $raw = (& wsl.exe --list --verbose 2>$null | Out-String) -split "`r?`n"
    } catch {
        return @()
    } finally {
        [Console]::OutputEncoding = $prev
    }
    $out = @()
    foreach ($line in $raw) {
        $clean = $line -replace "`0", ''
        $m = [regex]::Match($clean, '^\s*(?<def>\*?)\s*(?<name>\S+)\s+(?<state>Running|Stopped|Installing)\s+(?<ver>[12])\s*$')
        if (-not $m.Success) { continue }
        $out += [pscustomobject]@{
            Name      = $m.Groups['name'].Value
            State     = $m.Groups['state'].Value
            Version   = [int]$m.Groups['ver'].Value
            IsDefault = ($m.Groups['def'].Value -eq '*')
        }
    }
    return $out
}

function Resolve-Distro {
    $distros = Get-WslDistros
    if ($distros.Count -eq 0) {
        if ($Distro) { return $Distro }
        Write-Warn 'could not read the WSL distro list; carrying on with the default distro'
        return ''
    }

    if ($Distro) {
        $hit = @($distros | Where-Object { $_.Name -eq $Distro })
        if ($hit.Count -eq 0) {
            Write-Err "distro '$Distro' is not installed. Available: $(($distros | ForEach-Object { $_.Name }) -join ', ')"
            return $null
        }
        if ($hit[0].Version -ne 2) {
            Write-Err "'$Distro' runs on WSL1, which cannot use USB passthrough"
            Write-Hint @("Convert it:  wsl --set-version $Distro 2")
            return $null
        }
        return $Distro
    }

    $v2 = @($distros | Where-Object { $_.Version -eq 2 })
    if ($v2.Count -eq 0) {
        Write-Err 'no WSL2 distro is installed'
        Write-Hint @('wsl --install -d kali-linux', 'wsl --set-default-version 2')
        return $null
    }
    $preferred = @($v2 | Where-Object { $_.Name -match '(?i)kali' })
    if ($preferred.Count -gt 0) { return $preferred[0].Name }
    $def = @($v2 | Where-Object { $_.IsDefault })
    if ($def.Count -gt 0) { return $def[0].Name }
    return $v2[0].Name
}

function Start-Distro {
    param([string]$Name)
    $startArgs = @()
    if ($Name) { $startArgs += @('-d', $Name) }
    $startArgs += @('-u', 'root', '--', 'true')
    & wsl.exe @startArgs 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Invoke-Bind {
    param([object]$Device)
    if ($Device.State -ne 'Not shared') { return $true }
    if (-not (Test-Admin)) { Invoke-SelfElevated }
    Write-Info "binding bus $($Device.BusId)"
    $bindArgs = @('bind', '--busid', $Device.BusId)
    if ($Force) { $bindArgs += '--force' }
    & usbipd @bindArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Err "could not bind bus $($Device.BusId)"
        Write-Hint @(
            'Some devices are claimed by a Windows driver and need:',
            "  .\wifimon.ps1 attach -BusId $($Device.BusId) -Force",
            'Note that -Force takes the adapter away from Windows until you detach it.'
        )
        return $false
    }
    return $true
}

function Invoke-AttachDevice {
    param([object]$Device, [string]$DistroName)
    $v = Get-UsbipdVersion
    if ($v -ge [version]'4.0.0') {
        $attachArgs = @('attach', '--wsl', '--busid', $Device.BusId)
        if ($DistroName) { $attachArgs = @('attach', "--wsl=$DistroName", '--busid', $Device.BusId) }
    } else {
        $attachArgs = @('wsl', 'attach', '--busid', $Device.BusId)
        if ($DistroName) { $attachArgs += @('--distribution', $DistroName) }
    }
    & usbipd @attachArgs
    return ($LASTEXITCODE -eq 0)
}

function Invoke-LinuxUp {
    param([string]$DistroName)
    $root = Split-Path -Parent $PSScriptRoot
    $wslArgs = @()
    if ($DistroName) { $wslArgs += @('-d', $DistroName) }
    $wslArgs += @('-u', 'root', '--', 'wslpath', '-a', $root)
    $target = (& wsl.exe @wslArgs 2>$null | Out-String).Trim() -replace "`0", ''
    if (-not $target) {
        Write-Warn 'could not translate the script path for WSL; run the Linux side by hand'
        return $false
    }
    $cmd = "'$target/wifimon' up"
    if ($Channel) { $cmd += " --channel $Channel" }
    Write-Step "running inside ${DistroName}: wifimon up"
    $runArgs = @()
    if ($DistroName) { $runArgs += @('-d', $DistroName) }
    $runArgs += @('-u', 'root', '--', 'bash', '-c', $cmd)
    & wsl.exe @runArgs
    return ($LASTEXITCODE -eq 0)
}

function Invoke-Attach {
    if (-not (Install-Usbipd)) { return 3 }
    $distroName = Resolve-Distro
    if ($null -eq $distroName) { return 4 }

    $devices = Get-UsbDevices
    if ($devices.Count -eq 0) {
        Write-Err 'usbipd reported no USB devices at all'
        Write-Hint @('Check the service is running:  Get-Service usbipd')
        return 3
    }

    $targets = Select-Targets -Devices $devices
    if ($targets.Count -eq 0) { return 2 }

    Write-Info "starting WSL distro '$distroName'"
    if (-not (Start-Distro -Name $distroName)) {
        Write-Warn 'the distro did not start cleanly; attaching anyway'
    }

    $attached = 0
    foreach ($d in $targets) {
        if ($d.State -eq 'Attached') {
            Write-Ok "$($d.VidPid) on bus $($d.BusId) is already attached"
            $attached++
            continue
        }
        if (-not (Invoke-Bind -Device $d)) { continue }
        Write-Step "attaching bus $($d.BusId) ($($d.Description)) to $distroName"
        if (Invoke-AttachDevice -Device $d -DistroName $distroName) {
            $attached++
        } else {
            Write-Err "attach failed for bus $($d.BusId)"
            Write-Hint @(
                'Common causes:',
                '  - the WSL kernel is too old: run  wsl --update  then  wsl --shutdown',
                '  - a firewall is blocking the usbipd service',
                '  - the device was unplugged between listing and attaching'
            )
        }
    }

    if ($attached -eq 0) { return 1 }

    Start-Sleep -Seconds 2
    $after = Get-UsbDevices
    foreach ($d in $targets) {
        $now = @($after | Where-Object { $_.BusId -eq $d.BusId })
        if ($now.Count -gt 0 -and $now[0].State -eq 'Attached') {
            Write-Ok "bus $($d.BusId) is attached to $distroName"
        } else {
            Write-Warn "bus $($d.BusId) does not report as attached; check: usbipd list"
        }
    }

    if ($Up) {
        if (-not (Invoke-LinuxUp -DistroName $distroName)) { return 1 }
        return 0
    }

    Write-Host ''
    Write-Hint @(
        'Now, inside WSL (as root):',
        '  sudo ./wifimon setup     first time only, builds the driver',
        '  sudo ./wifimon up        enable monitor mode',
        'Or do both from here next time:',
        '  .\wifimon.ps1 attach -Up'
    )
    return 0
}

function Invoke-Detach {
    if (-not (Get-UsbipdVersion)) { Write-Err 'usbipd is not installed'; return 3 }
    $devices = Get-UsbDevices
    $targets = @()
    if ($BusId -or $VidPid) {
        $targets = Select-Targets -Devices $devices
    } else {
        $targets = @($devices | Where-Object { $_.State -eq 'Attached' })
        if ($targets.Count -eq 0) { Write-Info 'nothing is attached'; return 0 }
    }
    if ($targets.Count -eq 0) { return 2 }

    $v = Get-UsbipdVersion
    foreach ($d in $targets) {
        Write-Info "detaching bus $($d.BusId)"
        if ($v -ge [version]'4.0.0') {
            & usbipd detach --busid $d.BusId
        } else {
            & usbipd wsl detach --busid $d.BusId
        }
        if ($LASTEXITCODE -eq 0) { Write-Ok "bus $($d.BusId) detached" } else { Write-Warn "detach failed for bus $($d.BusId)" }
    }
    return 0
}

function Show-List {
    if (-not (Get-UsbipdVersion)) { Write-Err 'usbipd is not installed (run: .\wifimon.ps1 install)'; return 3 }
    $db = Get-AdapterDb
    $devices = Get-UsbDevices
    if ($devices.Count -eq 0) { Write-Warn 'no USB devices reported'; return 1 }
    $rows = foreach ($d in $devices) {
        $known = ''
        $driver = ''
        if ($db.ContainsKey($d.VidPid)) {
            $known = $db[$d.VidPid].Name
            $driver = $db[$d.VidPid].Driver
        }
        $label = $d.Description
        if ($known) { $label = $known }
        [pscustomobject]@{
            BusId  = $d.BusId
            VidPid = $d.VidPid
            State  = $d.State
            Driver = $driver
            Device = $label
        }
    }
    $rows | Format-Table -AutoSize
    return 0
}

function Show-Status {
    $v = Get-UsbipdVersion
    if ($v) { Write-Ok "usbipd-win $v" } else { Write-Warn 'usbipd-win is not installed' }

    try {
        $wslVer = (& wsl.exe --version 2>$null | Out-String) -replace "`0", ''
        if ($wslVer.Trim()) {
            foreach ($line in ($wslVer -split "`r?`n")) {
                if ($line.Trim()) { Write-Hint @($line.Trim()) }
            }
        } else {
            Write-Warn 'this is the inbox version of WSL (no --version); an update is recommended'
            Write-Hint @('wsl --update')
        }
    } catch {
        Write-Warn 'wsl.exe did not respond to --version'
    }

    $distros = Get-WslDistros
    foreach ($d in $distros) {
        $tag = ''
        if ($d.IsDefault) { $tag = ' (default)' }
        if ($d.Version -eq 2) {
            Write-Ok "$($d.Name): WSL2, $($d.State)$tag"
        } else {
            Write-Warn "$($d.Name): WSL1, $($d.State)$tag - convert with: wsl --set-version $($d.Name) 2"
        }
    }

    $attached = @(Get-UsbDevices | Where-Object { $_.State -eq 'Attached' })
    if ($attached.Count -gt 0) {
        foreach ($d in $attached) { Write-Ok "attached: $($d.VidPid) on bus $($d.BusId) -> $($d.Client)" }
    } else {
        Write-Warn 'no USB device is attached to WSL'
    }
    return 0
}

function Invoke-Doctor {
    Write-Step 'Windows side'
    $osv = [Environment]::OSVersion.Version
    if ($osv.Build -ge 19044) {
        Write-Ok "Windows build $($osv.Build) supports USB passthrough"
    } else {
        Write-Warn "Windows build $($osv.Build) is older than 19044; usbipd needs Windows 10 21H2 or newer"
    }
    if (Test-Admin) { Write-Ok 'running as Administrator' } else { Write-Warn 'not Administrator (binding a device needs elevation)' }

    $svc = Get-Service -Name usbipd -ErrorAction SilentlyContinue
    if ($svc) {
        if ($svc.Status -eq 'Running') { Write-Ok 'usbipd service is running' }
        else { Write-Warn "usbipd service is $($svc.Status); start it with: Start-Service usbipd" }
    } else {
        Write-Warn 'usbipd service is not installed'
    }

    Show-Status | Out-Null

    Write-Step 'WSL side'
    $distroName = Resolve-Distro
    if ($null -eq $distroName) { return 4 }
    $root = Split-Path -Parent $PSScriptRoot
    $wslArgs = @()
    if ($distroName) { $wslArgs += @('-d', $distroName) }
    $wslArgs += @('-u', 'root', '--', 'wslpath', '-a', $root)
    $target = (& wsl.exe @wslArgs 2>$null | Out-String).Trim() -replace "`0", ''
    if (-not $target) {
        Write-Warn 'could not reach the WSL side; run "wifimon doctor" inside the distro'
        return 1
    }
    $runArgs = @()
    if ($distroName) { $runArgs += @('-d', $distroName) }
    $runArgs += @('-u', 'root', '--', 'bash', '-c', "'$target/wifimon' doctor")
    & wsl.exe @runArgs
    return $LASTEXITCODE
}

function Invoke-Watch {
    if (-not (Install-Usbipd)) { return 3 }
    $distroName = Resolve-Distro
    if ($null -eq $distroName) { return 4 }

    $devices = Get-UsbDevices
    $targets = Select-Targets -Devices $devices
    if ($targets.Count -eq 0) { return 2 }
    $d = $targets[0]
    if (-not (Invoke-Bind -Device $d)) { return 1 }

    $v = Get-UsbipdVersion
    if ($v -ge [version]'4.0.0') {
        Write-Step "watching bus $($d.BusId); it will re-attach automatically (Ctrl+C to stop)"
        & usbipd attach "--wsl=$distroName" --busid $d.BusId --auto-attach
        return $LASTEXITCODE
    }

    Write-Step "polling every ${PollSeconds}s to keep bus $($d.BusId) attached (Ctrl+C to stop)"
    while ($true) {
        $now = @(Get-UsbDevices | Where-Object { $_.BusId -eq $d.BusId })
        if ($now.Count -eq 0) {
            Write-Warn "bus $($d.BusId) disappeared; waiting for it to come back"
        } elseif ($now[0].State -ne 'Attached') {
            Write-Info "re-attaching bus $($d.BusId)"
            Invoke-AttachDevice -Device $d -DistroName $distroName | Out-Null
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

function Show-Usage {
    Write-Host @'
wifimon.ps1 - attach a USB Wi-Fi adapter to WSL2 for monitor mode

Usage: .\wifimon.ps1 <command> [options]

Commands
  attach     Bind and attach the adapter to a WSL2 distro (default)
  detach     Give the adapter back to Windows
  list       Show every USB device usbipd can see, annotated with known adapters
  status     Show usbipd, WSL and attachment state
  watch      Keep the adapter attached across unplugs and sleep
  install    Install or upgrade usbipd-win
  doctor     Check both sides and run the Linux diagnostics
  help       This text

Options
  -VidPid <vvvv:pppp>   Target a specific USB id
  -BusId <n-m>          Target a specific bus id
  -Distro <name>        WSL distro to attach to (default: a Kali WSL2 distro, else the default one)
  -All                  Attach every known adapter, not just the first
  -Force                Steal the device from its Windows driver (usbipd bind --force)
  -Up                   After attaching, run "wifimon up" inside WSL
  -Channel <n>          Channel to pass to "wifimon up"
  -Quiet                Errors only
  -NoElevate            Fail instead of prompting for Administrator

Examples
  .\wifimon.ps1 attach                       Attach whatever known adapter is plugged in
  .\wifimon.ps1 attach -Up -Channel 6        Attach, then enable monitor mode on channel 6
  .\wifimon.ps1 attach -BusId 2-4 -Force     Attach a device Windows will not release
  .\wifimon.ps1 watch                        Survive replugging and sleep
  .\wifimon.ps1 doctor                       Work out why it is not working
'@
}

switch ($Command) {
    'attach'  { $script:ExitCode = Invoke-Attach }
    'up'      { $Up = $true; $script:ExitCode = Invoke-Attach }
    'detach'  { $script:ExitCode = Invoke-Detach }
    'list'    { $script:ExitCode = Show-List }
    'status'  { $script:ExitCode = Show-Status }
    'install' { if (Install-Usbipd) { $script:ExitCode = 0 } else { $script:ExitCode = 3 } }
    'doctor'  { $script:ExitCode = Invoke-Doctor }
    'watch'   { $script:ExitCode = Invoke-Watch }
    'help'    { Show-Usage; $script:ExitCode = 0 }
}

exit $script:ExitCode
