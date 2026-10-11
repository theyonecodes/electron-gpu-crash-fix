#requires -Version 5.1
<#
.SYNOPSIS
  One-shot installer for the Electron GPU crash fix — Enhanced with BackupEngine, DarkTheme GUI, Jev Router

.DESCRIPTION
  1. Registers IFEO Debugger entries for common Electron-derived apps.
  2. (Optionally) Installs a SYSTEM-level scheduled task running every 30 min
     that auto-detects newly-installed Electron apps and registers IFEO entries.
  3. NEW: Creates automatic registry backups before any IFEO changes.
  4. NEW: Dark theme tkinter GUI for app selection and monitoring.
  5. NEW: Jev Router triage for confidence assessment.

  Run elevated ONE TIME:
    powershell -NoProfile -ExecutionPolicy Bypass -File install-electron-ifeo-and-task.ps1

.PARAMETER ShimPath
  Full path to the compiled ElectronShim.exe. Defaults to "%USERPROFILE%\Desktop\ElectronShim.exe".

.PARAMETER SkipTask
  Skip installing the scheduled task. IFEO entries still get written.

.PARAMETER Apps
  Additional IFEO basenames to register on top of the defaults.

.PARAMETER DryRun
  Preview changes without writing. Uses Jev Router for confidence assessment.

.PARAMETER Gui
  Launch the DarkTheme tkinter GUI instead of console.

.EXAMPLE
  .\install-electron-ifeo-and-task.ps1
.EXAMPLE
  .\install-electron-ifeo-and-task.ps1 -ShimPath "C:\Tools\ElectronShim.exe" -SkipTask
.EXAMPLE
  .\install-electron-ifeo-and-task.ps1 -Apps "Spotify.exe","Slack.exe"
.EXAMPLE
  .\install-electron-ifeo-and-task.ps1 -Gui
.EXAMPLE
  .\install-electron-ifeo-and-task.ps1 -DryRun
#>

[CmdletBinding()]
param(
    [string]$ShimPath = (Join-Path $env:USERPROFILE 'Desktop\ElectronShim.exe'),
    [switch]$SkipTask,
    [string[]]$Apps = @(),
    [switch]$DryRun = $false,
    [switch]$Gui = $false,
    [switch]$Uninstall = $false
)

$ErrorActionPreference = 'Stop'

# --- TOOLKIT INTEGRATION ---
$toolkitPath = Join-Path $PSScriptRoot '..\..\vendor\toolkit'
$hasToolkit = $false
if (Test-Path "$toolkitPath\backup-engine\powershell\BackupEngine.psm1") {
    Import-Module "$toolkitPath\backup-engine\powershell\BackupEngine.psm1" -Force
    $hasToolkit = $true
} else {
    Write-Warning "Toolkit not found at $toolkitPath - backup protection disabled"
}

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
    if ($DryRun) { $argList += '-DryRun' }
    if ($Gui) { $argList += '-Gui' }
    if ($Uninstall) { $argList += '-Uninstall' }
    if ($Apps.Count -gt 0) { $argList += '-Apps'; $argList += ($Apps | ForEach-Object { "`"$_`"" }) }
    Start-Process powershell.exe -ArgumentList $argList -Verb RunAs -WindowStyle Normal
    exit
}

Write-Host "Running elevated. Started: $((Get-Date).ToString('u'))"
Write-Host "BackupEngine: $($hasToolkit ? 'ENABLED' : 'DISABLED')"
Write-Host "DryRun mode: $DryRun"
Write-Host ""

# --- 1. Validate shim ---
if (-not (Test-Path -LiteralPath $ShimPath)) {
    Write-Host "ERROR: shim not found at $ShimPath"
    Write-Host "Build it first: dotnet publish src\ElectronShim.csproj -c Release -r win-x64 -p:PublishSingleFile=true -o publish"
    exit 1
}
Write-Host "Shim: $ShimPath"
Write-Host ""

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

Write-Host "Target apps for IFEO registration:"
foreach ($name in $allApps) {
    Write-Host "  + $name"
}
Write-Host ""

# --- JEV TRIAGE (pre-flight) ---
if ($DryRun -and $hasToolkit -and (Test-Path "$toolkitPath\jev-router\jev_router.py")) {
    Write-Host "Running Jev Router triage..."
    $context = @{
        task_type = "electron_ifeo_registration"
        sensitive = $true
        target_apps = $allApps
        required_capabilities = @("system_admin", "registry", "ifeo")
    }
    $contextJson = $context | ConvertTo-Json -Depth 5
    
    try {
        $result = python "$toolkitPath\jev-router\jev_router.py" --choice "system_optimization" --context $contextJson 2>$null
        if ($result) {
            $decision = $result | ConvertFrom-Json
            Write-Host "  Jev Decision: $($decision.model_name) (confidence: $($decision.confidence * 100)%)"
            Write-Host "  Reasoning: $($decision.reasoning)"
            if ($decision.requires_human) {
                Write-Host "  ⚠ HUMAN REVIEW REQUIRED" -ForegroundColor Yellow
            }
            if ($decision.triggered_guardrails) {
                Write-Host "  Guardrails: $($decision.triggered_guardrails -join ', ')"
            }
        }
    } catch {
        Write-Warning "  Jev Router error: $($_.Exception.Message)"
    }
    Write-Host ""
}

if ($Uninstall) {
    Write-Host "Uninstalling IFEO entries and scheduled task..."
    
    $registryKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
    $regKeys = @()
    Get-ChildItem -LiteralPath $registryKey -ErrorAction SilentlyContinue | ForEach-Object {
        $dbg = (Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue).Debugger
        if ($dbg -like "*ElectronShim*") {
            $regKeys += $_.PSPath
            Write-Host "  - will remove: $($_.PSChildName)"
        }
    }
    
    # Also remove scheduled task
    schtasks.exe /Delete /TN ElectronAutoRegister /F 2>&1 | Out-Null
    Write-Host "  - removed scheduled task: ElectronAutoRegister"
    
    if ($regKeys.Count -gt 0) {
        if ($hasToolkit -and -not $DryRun) {
            Invoke-WithBackup -ToolName "electron-gpu-crash-fix" `
                -Description "Uninstall ElectronShim IFEO entries" `
                -RegistryKeys $regKeys `
                -ActionScriptBlock {
                    Get-ChildItem -LiteralPath $registryKey -ErrorAction SilentlyContinue | ForEach-Object {
                        $dbg = (Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue).Debugger
                        if ($dbg -like "*ElectronShim*") {
                            Remove-Item -LiteralPath $_.PSPath -Force -Recurse -ErrorAction SilentlyContinue
                        }
                    }
                }
            Write-Host "  ✓ IFEO entries removed with backup/rollback"
        } else {
            foreach ($k in $regKeys) {
                if (-not $DryRun) { Remove-Item -LiteralPath $k -Force -Recurse -ErrorAction SilentlyContinue }
                Write-Host "  - removed: $k"
            }
        }
    }
    Write-Host "Done."
    exit
}

# --- 3. Register IFEO entries ---
if (-not $Gui) {
    Write-Host "Registering IFEO Debugger entries (basenames):"
    foreach ($name in $allApps) {
        $key = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$name"
        
        if ($DryRun) {
            Write-Host "  [dryrun] $name -> $ShimPath"
            continue
        }
        
        if (-not (Test-Path -LiteralPath $key)) {
            New-Item -Path $key -Force | Out-Null
        }
        
        if ($hasToolkit) {
            try {
                $result = Invoke-WithBackup -ToolName "electron-gpu-crash-fix" `
                    -Description "Register IFEO Debugger for $name" `
                    -RegistryKeys $key `
                    -ActionScriptBlock {
                        Set-ItemProperty -Path $key -Name 'Debugger' -Value $ShimPath
                    }
                Write-Host "  ✓ $name (backup: $($result.BackupDir))"
            } catch {
                Write-Host "  ✗ $name FAILED: $($_.Exception.Message)" -ForegroundColor Red
            }
        } else {
            Set-ItemProperty -Path $key -Name 'Debugger' -Value $ShimPath
            Write-Host "  + $name (NO BACKUP)"
        }
    }
}

# --- 4. Scheduled task (optional) ---
if (-not $SkipTask -and -not $Gui) {
    Write-Host ""
    Write-Host "Installing SYSTEM scheduled task..."

    $scriptPath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'ElectronAutoRegister.ps1')).Path

    $startBoundary = (Get-Date).Date.AddDays(1).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Auto-detect newly-installed Electron apps and add IFEO Debugger entries to ensure they start with the proven Chromium flags. Idempotent. Runs as SYSTEM every 30 min. Includes backup protection.</Description>
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
        Write-Host "  ✓ \ElectronAutoRegister (SYSTEM, every 30 min + at startup)"
    } else {
        Write-Host "  ! task install failed: $reg" -ForegroundColor Red
    }
    Remove-Item -LiteralPath $xmlPath -Force -ErrorAction SilentlyContinue
}

# --- 5. Launch GUI if requested ---
if ($Gui) {
    $guiPath = Join-Path $PSScriptRoot '..\..\ElectronGpuCrashFixGUI.py'
    if (Test-Path $guiPath) {
        Write-Host ""
        Write-Host "Launching DarkTheme GUI..."
        python $guiPath
    } else {
        Write-Warning "GUI not found at $guiPath"
    }
}

Write-Host ""
Write-Host "Done. Restart any affected app."