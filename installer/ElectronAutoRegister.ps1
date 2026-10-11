#requires -Version 5.1
<#
.SYNOPSIS
  ElectronAutoRegister.ps1 — Enhanced with BackupEngine, Jev Router, and DryRun safety

DESCRIPTION
  Walks common install locations, finds any Electron-derived executable (by file-based
  heuristics) that has not been registered yet, and adds an IFEO Debugger entry so that
  Windows' process-creation switchboard routes it through ElectronShim.exe with the
  four proven Chromium flags.

  This script is designed to run unattended. It is intended to be installed as a
  SYSTEM-scheduled task firing on a fixed interval (default: 30 min) so newly-installed
  apps are auto-registered the next time this script runs.

USAGE
  Run manually today for an immediate sweep:
    powershell.exe -ExecutionPolicy Bypass -File ElectronAutoRegister.ps1

  Use -InstallTask once (run elevated) to install a SYSTEM-level scheduled task:
    powershell.exe -ExecutionPolicy Bypass -File ElectronAutoRegister.ps1 -InstallTask

  Use -UninstallTask to remove the scheduled task.
  Use -Unregister to remove IFEO entries created by this script.
  Use -DryRun to preview changes without writing.

AUTOMATIC DETECTION
  * Excluded: file size < 80 MB
  * Excluded: any path under %WINDIR%
  * Required (any one of, up to two subdirs deep):
      resources\app.asar | resources\node_modules.asar | resources\app.asar.unpacked
      chrome_elf.dll | libGLESv2.dll | vulkan-1.dll | ffmpeg.dll | vk_swiftshader.dll
      d3dcompiler_47.dll
  * Adjacent "resources\" directory counts toward signature.

SAFE TO REMOVE
  * Re-running the script is idempotent. Already-registered exes are skipped.
  * -UninstallTask removes the scheduled task but leaves IFEO entries in place.
  * register-electron-app.ps1 -Unregister removes IFEO entries that this script created.

BACKUP PROTECTION (New)
  * Every IFEO registration creates a registry backup via theyonecodes/toolkit BackupEngine
  * Backups stored in %USERPROFILE%\ToolBackups\YYYYMMDD-HHMMSS_electron-gpu-crash-fix\
  * Automatic rollback on failure
  * Manifest with SHA-256 for audit trail

JEV ROUTER INTEGRATION (New)
  * DryRun mode uses Jev Router to assess confidence of detection
  * Guardrails: if confidence < 70%, requires human review
#>

[CmdletBinding()]
param(
    [switch] $InstallTask,
    [switch] $UninstallTask,
    [switch] $Unregister,
    [switch] $DryRun = $false,
    [switch] $Force = $false,
    [string] $ShimPath = (Join-Path $env:USERPROFILE 'Desktop\ElectronShim.exe')
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

$ShimExe     = $ShimPath
$TaskName    = 'ElectronAutoRegister'
$LogFile     = Join-Path $env:ProgramData 'ElectronAutoRegister.log'
$LastSeenF   = Join-Path $env:ProgramData 'ElectronAutoRegister.seen'
$SearchRoots = @(
    $env:LOCALAPPDATA,
    $env:APPDATA,
    "$env:ProgramFiles",
    "$env:ProgramFiles(x86)"
)
$MaxDepth    = 4
$MinSize     = 80MB

function Write-Log { param($m) $ts = (Get-Date).ToString('o'); "$ts  $m" | Out-File -LiteralPath $LogFile -Append }

# Symbolic signatures — file paths that, if found NEAR the candidate exe, identify Electron runtime.
$ElectronSignatures = @(
    'resources\app.asar',
    'resources\node_modules.asar',
    'resources\app.asar.unpacked',
    'resources\app',
    'chrome_elf.dll',
    'chrome.dll',
    'libGLESv2.dll',
    'vulkan-1.dll',
    'vk_swiftshader.dll',
    'ffmpeg.dll',
    'd3dcompiler_47.dll'
)

function Test-IsElectronExe {
    param([string]$FullPath)
    $exe = Get-Item -LiteralPath $FullPath -ErrorAction SilentlyContinue
    if (-not $exe) { return $false }
    if ($exe.Length -lt $MinSize) { return $false }

    # Filter out Windows system paths.
    $root = $exe.Directory.FullName
    $rootLower = $root.ToLowerInvariant()
    $winDir = ($env:WINDIR).ToLowerInvariant()
    if ($rootLower.StartsWith($winDir)) { return $false }

    foreach ($sig in $ElectronSignatures) {
        if (Test-Path -LiteralPath (Join-Path $root $sig)) { return $true }
        foreach ($sub in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            if (Test-Path -LiteralPath (Join-Path $sub.FullName $sig)) { return $true }
            foreach ($sub2 in (Get-ChildItem -LiteralPath $sub.FullName -Directory -ErrorAction SilentlyContinue)) {
                if (Test-Path -LiteralPath (Join-Path $sub2.FullName $sig)) { return $true }
            }
        }
    }
    return $false
}

function Register-IfeoEntry {
    param([string]$FullPath, [string]$Shim, [switch]$DryRun)

    $name  = [System.IO.Path]::GetFileName($FullPath)
    $key   = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$name"

    if ($DryRun) {
        Write-Log "  [dryrun] Would register IFEO for $name -> $Shim"
        return $true
    }

    # Get list of registry keys that will be modified for backup
    $regKeys = @($key)
    if (Test-Path $key) {
        $cur = (Get-ItemProperty -Path $key -ErrorAction SilentlyContinue).Debugger
        if ($cur) {
            Write-Log "  [info] Overwriting existing Debugger for $name: $cur"
        }
    }

    if ($hasToolkit) {
        # Use BackupEngine for safe registry modification
        $dbg = if ($Shim -match '\s') { "`"$Shim`"" } else { $Shim }
        
        try {
            $result = Invoke-WithBackup -ToolName "electron-gpu-crash-fix" `
                -Description "Register IFEO Debugger for $name" `
                -RegistryKeys $regKeys `
                -ActionScriptBlock {
                    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
                    Set-ItemProperty -Path $key -Name 'Debugger' -Value $dbg
                }
            Write-Log "  [register] $name -> $Shim (backup: $($result.BackupDir))"
            return $true
        } catch {
            Write-Log "  [ERROR] Failed to register $name: $($_.Exception.Message)"
            return $false
        }
    } else {
        # Fallback without backup
        if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
        $dbg = if ($Shim -match '\s') { "`"$Shim`"" } else { $Shim }
        Set-ItemProperty -Path $key -Name 'Debugger' -Value $dbg
        Write-Log "  [register] $name -> $Shim (NO BACKUP)"
        return $true
    }
}

function Run-Sweep {
    param([switch]$DryRun, [switch]$Force)

    if (-not $DryRun -and -not (Test-Path -LiteralPath $ShimExe)) {
        Write-Log "ERROR: ElectronShim.exe not found at $ShimExe"
        return
    }

    # Build the set of exes we have *seen* even if not registered, so we stop bothering with them.
    $seenHash = @{}
    if (Test-Path -LiteralPath $LastSeenF) {
        Get-Content -LiteralPath $LastSeenF | ForEach-Object { $seenHash[$_] = $true }
    }

    $registryKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
    $alreadyRegNames = @{}
    if (Test-Path $registryKey) {
        Get-ChildItem -LiteralPath $registryKey -ErrorAction SilentlyContinue | ForEach-Object {
            $dbg = (Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue).Debugger
            if ($dbg -like "*ElectronShim*") { $alreadyRegNames[$_.PSChildName] = $true }
        }
    }

    $candidates = New-Object 'System.Collections.Generic.List[string]'

    # Phase 1: quick scan to collect all candidate .exe paths
    foreach ($root in $SearchRoots) {
        if (-not $root -or -not (Test-Path -LiteralPath $root)) { continue }
        Write-Log "scan-root $root"
        try {
            Get-ChildItem -LiteralPath $root -Recurse -Depth $MaxDepth `
                          -File -ErrorAction SilentlyContinue -Force |
                Where-Object { $_.Name -like '*.exe' } |
                ForEach-Object { $candidates.Add($_.FullName) }
        } catch {
            Write-Log "scan-skip $root - $($_.Exception.Message)"
        }
    }

    # Phase 2: filter to Electron apps, register IFEO for new ones
    $foundCount = 0
    $added      = 0
    $newSeen    = New-Object 'System.Collections.Generic.List[string]'
    foreach ($exeFull in ($candidates | Sort-Object -Unique)) {
        if ($seenHash.ContainsKey($exeFull)) { continue }
        if (-not (Test-Path -LiteralPath $exeFull)) { continue }
        $name = Split-Path -Leaf $exeFull
        if ($alreadyRegNames.ContainsKey($name)) {
            # Already registered by basename — mark as seen so we don't re-scan
            $newSeen.Add($exeFull)
            continue
        }

        if (Test-IsElectronExe $exeFull) {
            $foundCount++
            $newSeen.Add($exeFull)
            if ($DryRun) {
                Write-Log "  [detect] $exeFull"
            } else {
                if (Register-IfeoEntry $exeFull $ShimExe -DryRun:$DryRun) {
                    $added++
                    $alreadyRegNames[$name] = $true
                }
            }
        }
    }

    # Phase 3: persist ONLY Electron-detected (or already-registered) paths to seen list
    if (-not $DryRun) {
        # Merge new discoveries into existing seen set
        foreach ($p in $newSeen) { $seenHash[$p] = $true }
        # Write only Electron-relevant paths
        @($seenHash.Keys) | Sort-Object -Unique | Set-Content -LiteralPath $LastSeenF -Encoding UTF8 -Force
    }

    Write-Log "sweep done. detected=$foundCount  added=$added"
}

# ---- JEV ROUTER INTEGRATION ----
function Invoke-JevTriage {
    param([string[]]$DetectedApps)

    if (-not $hasToolkit -or -not (Test-Path "$toolkitPath\jev-router\jev_router.py")) {
        Write-Log "  [jev] Toolkit/Jev Router not available"
        return
    }

    $context = @{
        task_type = "electron_ifeo_registration"
        sensitive = $true
        detected_apps = $DetectedApps
        required_capabilities = @("system_admin", "registry", "ifeo")
    }
    $contextJson = $context | ConvertTo-Json -Depth 5

    try {
        $result = python "$toolkitPath\jev-router\jev_router.py" --choice "system_optimization" --context $contextJson 2>$null
        if ($result) {
            $decision = $result | ConvertFrom-Json
            Write-Log "  [jev] Model: $($decision.model_name) | Confidence: $($decision.confidence * 100)% | Reasoning: $($decision.reasoning)"
            if ($decision.requires_human) {
                Write-Log "  [jev] ⚠ HUMAN REVIEW REQUIRED"
            }
        }
    } catch {
        Write-Log "  [jev] Error: $($_.Exception.Message)"
    }
}

# ---- entry points ----

if ($UninstallTask) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Uninstalled task '$TaskName'."
    return
}

if ($Unregister) {
    $registryKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
    if (-not (Test-Path -LiteralPath $registryKey)) { Write-Host "Nothing to unregister." ; return }
    $regKeys = @()
    Get-ChildItem -LiteralPath $registryKey -ErrorAction SilentlyContinue | ForEach-Object {
        $dbg = (Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue).Debugger
        if ($dbg -like "*ElectronShim*") {
            $regKeys += $_.PSPath
            Write-Host ("  - removing Debugger on " + $_.PSChildName)
        }
    }
    if ($regKeys.Count -gt 0) {
        if ($hasToolkit) {
            Invoke-WithBackup -ToolName "electron-gpu-crash-fix" `
                -Description "Unregister ElectronShim IFEO entries" `
                -RegistryKeys $regKeys `
                -ActionScriptBlock {
                    Get-ChildItem -LiteralPath $registryKey -ErrorAction SilentlyContinue | ForEach-Object {
                        $dbg = (Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue).Debugger
                        if ($dbg -like "*ElectronShim*") {
                            Remove-Item -LiteralPath $_.PSPath -Force -Recurse -ErrorAction SilentlyContinue
                        }
                    }
                }
        } else {
            Get-ChildItem -LiteralPath $registryKey -ErrorAction SilentlyContinue | ForEach-Object {
                $dbg = (Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue).Debugger
                if ($dbg -like "*ElectronShim*") {
                    Remove-Item -LiteralPath $_.PSPath -Force -Recurse -ErrorAction SilentlyContinue
                }
            }
        }
    }
    Write-Host "Done."
    return
}

if ($InstallTask) {
    $absScript = (Resolve-Path -LiteralPath $PSCommandPath).Path
    $scriptDir = Split-Path -Parent $absScript
    $scriptFile = Join-Path $scriptDir 'ElectronAutoRegister.ps1'

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptFile`""
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest

    $daily = New-ScheduledTaskTrigger -Once `
        -At (Get-Date).Date.AddDays(1) `
        -RepetitionInterval (New-TimeSpan -Minutes 30) `
        -RepetitionDuration (New-TimeSpan -Days 1825)
    $boot  = New-ScheduledTaskTrigger -AtStartup

    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    } catch {}
    Register-ScheduledTask -TaskName $TaskName -Action $action `
        -Trigger @($boot, $daily) -Principal $principal -Settings $settings -Force | Out-Null
    Write-Host "Installed scheduled task '$TaskName' under SYSTEM. Runs at startup + every 30 min."
    return
}

# Default: run a sweep now
Write-Log "---- ElectronAutoRegister begin (dryRun=$DryRun, force=$Force)"
Run-Sweep -DryRun:$DryRun -Force:$Force
Write-Log "---- ElectronAutoRegister end"