#requires -Version 5.1
<#
SYNOPSIS
  ElectronAutoRegister.ps1

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
#>

[CmdletBinding()]
param(
    [switch] $InstallTask,
    [switch] $UninstallTask,
    [switch] $Unregister,
    [switch] $DryRun = $false
)

$ErrorActionPreference = 'Stop'

$ShimExe     = if ($env:ELECTRON_SHIM_PATH) { $env:ELECTRON_SHIM_PATH } else { Join-Path $env:USERPROFILE 'Desktop\ElectronShim.exe' }
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
    param([string]$FullPath, [string]$Shim)
    $name  = [System.IO.Path]::GetFileName($FullPath)
    $key   = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$name"
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    $dbg   = if ($Shim -match '\s') { "`"$Shim`"" } else { $Shim }
    $cur = (Get-ItemProperty -Path $key -ErrorAction SilentlyContinue).Debugger
    if ($cur -ne $dbg) {
        Set-ItemProperty -Path $key -Name 'Debugger' -Value $dbg
        return $true
    }
    return $false
}

function Run-Sweep {
    param([switch]$DryRun)

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
                if (Register-IfeoEntry $exeFull $ShimExe) {
                    $added++
                    Write-Log "  [register] $name -> $ShimExe"
                    $alreadyRegNames[$name] = $true
                }
            }
        }
    }

    # Phase 3: persist ONLY Electron-detected (or already-registered) paths to seen list
    if (-not $DryRun) {
        # Merge new discoveries into existing seen set
        foreach ($p in $newSeen) { $seenHash[$p] = $true }
        # Write only Electron-relevant paths (not the raw scan dump).
        # A scanned path is "Electron-relevant" iff it's already in $seenHash (preserved
        # from prior runs or added in Phase 2 as confirmed Electron/Renderer basenames).
        @($seenHash.Keys) | Sort-Object -Unique | Set-Content -LiteralPath $LastSeenF -Encoding UTF8 -Force
    }

    Write-Log "sweep done. detected=$foundCount  added=$added"
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
    Get-ChildItem -LiteralPath $registryKey -ErrorAction SilentlyContinue | ForEach-Object {
        $dbg = (Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue).Debugger
        if ($dbg -like "*ElectronShim*") {
            Write-Host ("  - removing Debugger on " + $_.PSChildName)
            Remove-Item -LiteralPath $_.PSPath -Force -Recurse -ErrorAction SilentlyContinue
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

    # Once trigger starting tomorrow 00:00 with 30-min repetition for 5 years (1825 days).
    # Workaround: PowerShell -Daily + -RepetitionInterval is parameter-set conflict;
    # -Once + -RepetitionDuration ([TimeSpan]::MaxValue) fails XML serialization
    # (Duration:P99999999DT23H59M59S rejected). 5y finite duration fits XML and is
    # effectively perpetual from the user's perspective (window expires in 2031).
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

# Default: run a sweep now. If interactive (no -DryRun), also try to create the scheduled task silently via a separate, scheduled-task-only path?
# Keeping simple: just sweep.
Write-Log "---- ElectronAutoRegister begin (dryRun=$DryRun)"
Run-Sweep -DryRun:$DryRun
Write-Log "---- ElectronAutoRegister end"
