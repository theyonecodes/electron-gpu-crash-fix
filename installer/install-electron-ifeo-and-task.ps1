#requires -Version 5.1
<#
.SYNOPSIS
  One-shot installer for the Electron GPU crash fix.

.DESCRIPTION
  1. Registers IFEO Debugger entries for common Electron-derived apps.
  2. (Optionally) Installs a SYSTEM-level scheduled task running every 30 min
     that auto-detects newly-installed Electron apps and registers IFEO entries.

  Run elevated ONE TIME:
    powershell -NoProfile -ExecutionPolicy Bypass -File install-electron-ifeo-and-task.ps1

.PARAMETER ShimPath
  Full path to the compiled ElectronShim.exe. Defaults to "%USERPROFILE%\Desktop\ElectronShim.exe".

.PARAMETER SkipTask
  Skip installing the scheduled task. IFEO entries still get written.

.PARAMETER Apps
  Additional IFEO basenames to register on top of the defaults.

.EXAMPLE
  .\install-electron-ifeo-and-task.ps1
.EXAMPLE
  .\install-electron-ifeo-and-task.ps1 -ShimPath "C:\Tools\ElectronShim.exe" -SkipTask
.EXAMPLE
  .\install-electron-ifeo-and-task.ps1 -Apps "Spotify.exe","Slack.exe"
#>

[CmdletBinding()]
param(
    [string]$ShimPath = (Join-Path $env:USERPROFILE 'Desktop\ElectronShim.exe'),
    [switch]$SkipTask,
    [string[]]$Apps = @()
)

$ErrorActionPreference = 'Stop'

# Self-elevation guard
$id  = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr  = New-Object Security.Principal.WindowsPrincipal($id)
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Re-launching self as Administrator..."
    $argList = @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File', "`"$PSCommandPath`""
        '-ShimPath', "`"$ShimPath`""
    )
    if ($SkipTask) { $argList += '-SkipTask' }
    if ($Apps.Count -gt 0) { $argList += '-Apps'; $argList += ($Apps | ForEach-Object { "`"$_`"" }) }
    Start-Process powershell.exe -ArgumentList $argList -Verb RunAs -WindowStyle Normal
    exit
}

Write-Host "Running elevated. Started: $((Get-Date).ToString('u'))"

# --- 1. Validate shim ---
if (-not (Test-Path -LiteralPath $ShimPath)) {
    Write-Host "ERROR: shim not found at $ShimPath"
    Write-Host "Build it first: dotnet publish src\ElectronShim.csproj -c Release -r win-x64 -p:PublishSingleFile=true -o publish"
    exit 1
}
Write-Host "Shim: $ShimPath"

# --- 2. Default IFEO basenames ---
$defaults = @(
    'Obsidian.exe'
    'Code.exe'
    'Notion.exe'
    'Discord.exe'
    'electron.exe'
    'Resolve.exe'
)

$allApps = @($defaults + $Apps) | Sort-Object -Unique

Write-Host ""
Write-Host "Registering IFEO Debugger entries (basenames):"
foreach ($name in $allApps) {
    $key = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$name"
    if (-not (Test-Path -LiteralPath $key)) {
        New-Item -Path $key -Force | Out-Null
    }
    Set-ItemProperty -Path $key -Name 'Debugger' -Value $ShimPath
    Write-Host "  + $name"
}

# --- 3. Scheduled task (optional) ---
if (-not $SkipTask) {
    Write-Host ""
    Write-Host "Installing SYSTEM scheduled task..."

    $scriptPath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'ElectronAutoRegister.ps1')).Path

    # Use schtasks.exe + raw XML to avoid PowerShell cmdlet quirks:
    #   -Daily -RepetitionInterval is parameter-set conflict.
    #   -Once + -RepetitionDuration ([TimeSpan]::MaxValue) produces invalid Duration XML.
    # Manual XML with finite 5-year Duration works and is effectively perpetual.
    $startBoundary = (Get-Date).Date.AddDays(1).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Auto-detect newly-installed Electron apps and add IFEO Debugger entries to ensure they start with the proven Chromium flags. Idempotent. Runs as SYSTEM every 30 min.</Description>
    <URI>\ElectronAutoRegister</URI>
  </RegistrationInfo>
  <Triggers>
    <BootTrigger><Enabled>true</Enabled></BootTrigger>
    <CalendarTrigger>
      <StartBoundary>$startBoundary</StartBoundary>
      <Enabled>true</Enabled>
      <Repetition>
        <Interval>PT30M</Interval>
        <Duration>P1825D</Duration>
        <StopAtDurationEnd>true</StopAtDurationEnd>
      </Repetition>
    </CalendarTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <AllowStartIfOnBatteries>true</AllowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -File "$scriptPath"</Arguments>
    </Exec>
  </Actions>
</Task>
"@

    $xmlPath = Join-Path $env:TEMP "ElectronAutoRegister-task.xml"
    [System.IO.File]::WriteAllText($xmlPath, $taskXml, [System.Text.Encoding]::Unicode)

    schtasks.exe /Delete /TN ElectronAutoRegister /F 2>&1 | Out-Null
    $reg = schtasks.exe /Create /XML $xmlPath /TN ElectronAutoRegister /F 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  + \ElectronAutoRegister (SYSTEM, every 30 min + at startup)"
    } else {
        Write-Host "  ! task install failed: $reg"
    }
    Remove-Item -LiteralPath $xmlPath -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "Done. Restart any affected app."
