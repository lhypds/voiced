# voiced on Windows: builds, starts, stops and restarts the voiced service, the only part of Voiced
# that runs on Windows. The same commands as voiced on macOS, for the service alone. Run through
# voiced.cmd; install.bat installs it as the command voiced.
#
#   voiced                          show the help
#   voiced service [action]         action: build, start, stop, restart, status; leave it out to
#                                   pick it with the arrow keys
#   voiced <action> [service|all]   the same; on Windows the service is all there is
#   voiced status
#
# The service is built in service\target\release and runs as a copy in %LOCALAPPDATA%\voiced, so
# a build never has to replace the file of the running service. It starts at login from the
# voiced value under HKCU\Software\Microsoft\Windows\CurrentVersion\Run.

param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)

$ErrorActionPreference = 'Stop'

$Root = $PSScriptRoot
$ServiceFolder = Join-Path $Root 'service'
$Built = Join-Path $ServiceFolder 'target\release\voiced.exe'
$InstallFolder = Join-Path $env:LOCALAPPDATA 'voiced'
$Installed = Join-Path $InstallFolder 'voiced.exe'
$CommandFolder = Join-Path $InstallFolder 'bin'
$Log = Join-Path $InstallFolder 'voiced.log'
$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

function Show-Help {
    Write-Host @'
voiced builds and runs the voiced service, which types what Voiced on the iPhone hears at the
computer's cursor, or runs it with Claude Code. On Windows the service is the only part of Voiced
there is; the Mac and iOS apps and core need macOS.

  voiced service [build|start|stop|restart|status]
                               leave out what to do to pick it with the arrow keys
                               build: build it without touching the running service
                               start: start it, and at every login
                               stop: stop it; it no longer starts at login
                               restart: build it, then restart it
  voiced build|start|stop|restart [service]
                               the same, named the other way round
  voiced status                show whether the service runs
  voiced help                  show this

What happens to each sentence (typed at the cursor, typed and followed by Return, or run
by Claude Code) is the "Send to Mac" mode chosen on the iPhone, as is the folder Claude Code
runs in. The log is %LOCALAPPDATA%\voiced\voiced.log.
'@
}

function Show-Usage {
    Write-Host 'Usage: voiced service [build|start|stop|restart|status]'
    Write-Host '       voiced build|start|stop|restart [service]'
    Write-Host '       voiced status'
    Write-Host '       voiced help'
    exit 2
}

# Lets the user pick an option with the arrow keys (or j and k, or its number) and Enter. Returns
# it, or $null when q or Escape cancels.
function Select-Option([string]$Title, [string[]]$Options) {
    if ([Console]::IsInputRedirected) {
        Write-Host "voiced: $Title give one on the command line: $($Options -join ', ')"
        return $null
    }
    Write-Host $Title
    $index = 0
    $width = [Math]::Max(1, [Console]::WindowWidth - 1)
    $drawn = $false
    while ($true) {
        if ($drawn) {
            # Back to the first option. A terminal that does not report the cursor (CursorTop
            # stays 0) is moved up with an escape sequence instead.
            $top = [Console]::CursorTop - $Options.Count
            if ($top -ge 0) {
                [Console]::SetCursorPosition(0, $top)
            } else {
                [Console]::Write("$([char]27)[$($Options.Count)A")
            }
        }
        for ($i = 0; $i -lt $Options.Count; $i++) {
            if ($i -eq $index) {
                Write-Host ('> ' + $Options[$i]).PadRight($width) -ForegroundColor Cyan
            } else {
                Write-Host ('  ' + $Options[$i]).PadRight($width)
            }
        }
        $drawn = $true
        $key = [Console]::ReadKey($true)
        $char = [string]$key.KeyChar
        if ($key.Key -eq 'UpArrow' -or $char -eq 'k') {
            $index = ($index - 1 + $Options.Count) % $Options.Count
        } elseif ($key.Key -eq 'DownArrow' -or $char -eq 'j') {
            $index = ($index + 1) % $Options.Count
        } elseif ($key.Key -eq 'Enter') {
            return $Options[$index]
        } elseif ($key.Key -eq 'Escape' -or $char -eq 'q') {
            return $null
        } elseif ($char -match '^[1-9]$' -and [int]$char -le $Options.Count) {
            return $Options[[int]$char - 1]
        }
    }
}

# MARK: Service

# The running service: voiced.exe from the install folder, not a run's window (--claude-follow).
function Get-ServiceProcess {
    @(Get-CimInstance Win32_Process -Filter "Name = 'voiced.exe'" | Where-Object {
        $_.ExecutablePath -eq $Installed -and $_.CommandLine -notmatch '--claude-follow'
    })
}

function Find-Cargo {
    $cargo = Get-Command cargo -ErrorAction SilentlyContinue
    if ($cargo) { return $cargo.Source }
    # Not on PATH yet in a window opened before Rust was installed.
    $cargo = Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe'
    if (Test-Path $cargo) { return $cargo }
    throw 'Rust is not installed. Run setup.bat first.'
}

function Build-Service {
    $cargo = Find-Cargo
    Write-Host 'Building the voiced service...'
    Push-Location $ServiceFolder
    try {
        & $cargo build --release
        if ($LASTEXITCODE -ne 0) { throw 'The build failed.' }
    } finally {
        Pop-Location
    }
    Write-Host "Built $Built"
}

# Copies the build to the install folder, where the service runs from.
function Copy-Build {
    New-Item -ItemType Directory -Force -Path $InstallFolder | Out-Null
    Copy-Item $Built $Installed -Force
}

function Start-VoicedService {
    if ((Get-ServiceProcess).Count -gt 0) {
        Write-Host 'voiced is already running.'
        return
    }
    if (-not (Test-Path $Built) -and -not (Test-Path $Installed)) { Build-Service }
    # A newer build is what starts.
    if ((Test-Path $Built) -and (-not (Test-Path $Installed) -or
            (Get-Item $Built).LastWriteTime -gt (Get-Item $Installed).LastWriteTime)) {
        Copy-Build
    }
    Set-ItemProperty -Path $RunKey -Name voiced -Value "`"$Installed`""
    Start-Process -FilePath $Installed
    for ($i = 0; $i -lt 20 -and (Get-ServiceProcess).Count -eq 0; $i++) { Start-Sleep -Milliseconds 250 }
    if ((Get-ServiceProcess).Count -eq 0) { throw "voiced did not start; see $Log" }
    Write-Host 'Started voiced.'
}

function Stop-VoicedService {
    # Removing the value keeps the service from starting again at the next login.
    Remove-ItemProperty -Path $RunKey -Name voiced -ErrorAction SilentlyContinue
    $processes = Get-ServiceProcess
    if ($processes.Count -eq 0) {
        Write-Host 'voiced is not running.'
        return
    }
    $processes | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    for ($i = 0; $i -lt 50 -and (Get-ServiceProcess).Count -gt 0; $i++) { Start-Sleep -Milliseconds 100 }
    if ((Get-ServiceProcess).Count -gt 0) { throw 'voiced did not stop.' }
    Write-Host 'Stopped voiced.'
}

function Restart-VoicedService {
    Build-Service
    Stop-VoicedService
    Copy-Build
    Start-VoicedService
}

function Show-Status {
    $processes = Get-ServiceProcess
    if ($processes.Count -gt 0) {
        Write-Host "voiced:       running (pid $($processes[0].ProcessId))"
    } else {
        Write-Host 'voiced:       stopped'
    }
    $atLogin = (Get-ItemProperty -Path $RunKey -Name voiced -ErrorAction SilentlyContinue) -ne $null
    Write-Host ("at login:     " + $(if ($atLogin) { 'starts' } else { 'does not start' }))
}

function Invoke-Service([string]$Action) {
    switch ($Action) {
        'build' { Build-Service }
        'start' { Start-VoicedService }
        'stop' { Stop-VoicedService }
        'restart' { Restart-VoicedService }
        'status' { Show-Status }
        default { Write-Host "voiced: the service has no $Action."; Show-Usage }
    }
}

function Assert-Service([string]$Part) {
    if ($Part -eq 'service' -or $Part -eq 'all') { return }
    if (@('macos', 'ios', 'core') -contains $Part) {
        Write-Host "voiced: $Part needs macOS; on Windows the service is the only part there is."
        exit 2
    }
    Show-Usage
}

# MARK: The command, as install.bat and uninstall.bat set it up

# voiced on PATH: a voiced.cmd in a folder of its own, since %LOCALAPPDATA%\voiced holds
# voiced.exe, which cmd would run in its place.
function Install-Command {
    New-Item -ItemType Directory -Force -Path $CommandFolder | Out-Null
    Set-Content -Path (Join-Path $CommandFolder 'voiced.cmd') -Encoding Ascii -Value @(
        '@echo off',
        "call `"$(Join-Path $Root 'voiced.cmd')`" %*"
    )
    $path = [string][Environment]::GetEnvironmentVariable('Path', 'User')
    if (($path -split ';') -notcontains $CommandFolder) {
        [Environment]::SetEnvironmentVariable('Path', (($path.TrimEnd(';'), $CommandFolder) -join ';').TrimStart(';'), 'User')
        Write-Host "Installed the voiced command in $CommandFolder; open a new window to use it."
    } else {
        Write-Host "Installed the voiced command in $CommandFolder."
    }
    Restart-VoicedService
    Write-Host 'The first time, allow voiced through Windows Firewall on private networks so the iPhone can reach it.'
}

function Uninstall-Command {
    Stop-VoicedService
    Remove-Item -Force -ErrorAction SilentlyContinue $Installed
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $CommandFolder
    $path = [string][Environment]::GetEnvironmentVariable('Path', 'User')
    $kept = ($path -split ';' | Where-Object { $_ -and $_ -ne $CommandFolder }) -join ';'
    if ($kept -ne $path) { [Environment]::SetEnvironmentVariable('Path', $kept, 'User') }
    Write-Host "Removed voiced and the voiced command. The log is kept in $InstallFolder."
}

# MARK: Commands

$arguments = @($Arguments | Where-Object { $_ -ne $null })
$first = if ($arguments.Count -gt 0) { $arguments[0] } else { '' }

try {
    switch -Regex ($first) {
        '^(|help|-h|--help)$' { Show-Help }
        '^status$' {
            if ($arguments.Count -ne 1) { Show-Usage }
            Show-Status
        }
        '^service$' {
            if ($arguments.Count -gt 2) { Show-Usage }
            $action = if ($arguments.Count -eq 2) { $arguments[1] } else {
                Select-Option 'service:' @('build', 'start', 'stop', 'restart', 'status')
            }
            if (-not $action) { exit 1 }
            Invoke-Service $action
        }
        '^(build|start|stop|restart)$' {
            if ($arguments.Count -gt 2) { Show-Usage }
            if ($arguments.Count -eq 2) { Assert-Service $arguments[1] }
            Invoke-Service $first
        }
        '^(macos|ios|core)$' { Assert-Service $first }
        '^--install$' { Install-Command }
        '^--uninstall$' { Uninstall-Command }
        default { Show-Usage }
    }
} catch {
    Write-Host "voiced: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
