# Crash Recipe: Diagnosing the 0x80000003 Electron Crash

A complete diagnostic and remediation recipe.

---

## Symptom

Electron-derived desktop apps crash on launch with:

- Windows Event Viewer: `STATUS_BREAKPOINT (0x80000003)` in `Application Error`
- Process visible briefly, dies before window paints
- Crash dump in `%LOCALAPPDATA%\CrashDumps\<exe>.<pid>.dmp`
- Often same apps run fine on another machine

Variants:
- `__debugbreak() in __sanitizer_...` early init
- `LCMS related to ::: REGISTERCLUBSERVICECOMMAND`
- `Locale related` ICU init crash
- `Symbolic link is not allowed to link to a target in a different security` during sandbox startup

All variants stem from the same Chromium GPU-process sandbox failing to initialize.

---

## Root-cause lattice (any combination can be the trigger)

1. **Windows 11 24H2/25H2 regression** in chromium sandbox init path
2. **Multiple GPUs present** with phantom disabled adapter entries in the DACL
3. **NVIDIA Game Ready driver** interactions with the new `vk_swiftshader` and `vk_swiftshader.dll` paths
4. **Missing Visual C++ runtime** for `VkCreateInstance`
5. **Locale ICU initialization crash** when system locale is unusual or has corrupted MO files
6. **Microsoft Defender** Defender LSA protection changing SandboxToken behavior at process creation

---

## Diagnostic steps (in order)

### 1. Verify the crash dump class

```pwsh
Get-ChildItem "$env:LOCALAPPDATA\CrashDumps" -Filter "*.dmp" | Sort-Object LastWriteTime -Descending | Select-Object -First 3 Name, LastWriteTime, Length
```

Open a dump in WinDbg. Run:

```
!analyze -v
.exr -1
```

Look for the bucketing string `STATUS_BREAKPOINT` in the report.

### 2. Check Windows version + GPU inventory

```pwsh
[Environment]::OSVersion.Version
Get-CimInstance Win32_VideoController | Select-Object Name, AdapterCompatibility, Status
Get-CimInstance Win32_PnPEntity -Filter 'PNPClass="Display"' | Select-Object Name, Status, ConfigManagerErrorCode
```

A phantom but error-free disabled adapter (`CM_PROB_PHANTOM`, ConfigManagerErrorCode 28 sometimes 0) is a smoking gun.

### 3. Check the NVIDIA driver family

```pwsh
nvidia-smi --query-gpu=driver_version,driver_name --format=csv
```

Game Ready drivers frequently reproduce. **Studio Driver** rarely does.

### 4. Confirm the Electron crashing pattern

Crash within 200ms of process start = the GPU-process init. Crash after a window flash = a different module. Crash during splash = GUI thread issue. Verify the timing via Win+R → `eventvwr.msc`:

```
Application and Services Logs / Windows / Application
Filter: Source = "Application Error", Event ID = 1000
```

---

## Mitigation ladder

Apply in order. Stop at the first step that resolves the crash.

### Step 1 — Chromium flags (always safe, often sufficient)

Pre-pend these flags to every Electron-derived binary on the machine:

```
--no-sandbox
--disable-gpu
--disable-gpu-compositing
--in-process-gpu
```

Inject via `Image File Execution Options` `Debugger` so any caller benefits (taskbar, command line, scheduler). See the installer in this repo for the automated version.

This is the only step most Windows 11 25H2 machines need.

### Step 2 — Driver swap (NVIDIA owners)

```pwsh
# Download the latest Studio Driver (not Game Ready) from nvidia.com.
# Install via NVCleanstall for full control over which optional components get installed.
# Discard: GeForce Experience, telemetry, OTA updates.
```

After install:

```pwsh
nvidia-smi  # verify new driver version
```

### Step 3 — iGPU disable (multi-GPU desktops)

If `Win32_PnPEntity` shows both an Intel iGPU and the discrete card:

1. Reboot → BIOS
2. `Advanced / North Bridge / Init Display First` = **PEG** (PCIE Graphics)
3. `Advanced / North Bridge / IGFX Multi-Monitor` = **Disabled**
4. Save + reboot.

Verify:

```pwsh
Get-CimInstance Win32_PnPEntity -Filter 'PNPClass="Display"'
```

Only the discrete card should remain. Phantom iGPU gone.

### Step 4 — Machine-wide env

```pwsh
[Environment]::SetEnvironmentVariable("ELECTRON_DISABLE_GPU", "1", "Machine")
```

Restart. Some Electron builds respect this flag after Step 1 starts applying flags into early Chromium init.

### Step 5 — Last resort: VCRedist + Locale

If flags didn't help:

```pwsh
# Install latest VC++ Redistributable
winget install --id Microsoft.VCRedist.2015+.x64

# Reset locale to en-US if exotic
$global:cult = [System.Globalization.CultureInfo]::GetCultureInfo('en-US')
[System.Globalization.CultureInfo]::DefaultThreadCurrentUICulture = $cult
```

These rarely matter alone but stack with the steps above on edge cases.

---

## Why IFEO Debugger is the right injection point

Windows evaluates `HKLM\...\Image File Execution Options\<basename>\Debugger` at every `CreateProcess` call (including all 11 caller paths below):

1. Taskbar Start / Start Menu shortcuts
2. Command line invocation
3. Task Scheduler
4. File association / `ShellExecute`
5. Protocol activation (URI handlers)
6. COM out-of-process activation
7. Service control manager launches (rare for GUI apps)
8. Windows Push Notifications actions
9. Squirrel Update.exe `--processStart <exe>` pattern (Discord, Slack, Atom)
10. Anti-cheat launchers that re-exec the game with `argv` merge
11. Auto-update warmup that spawns the new exe briefly to validate

The Debugger value is invoked with `<debugger> <wrapped-exe> <original-args...>` so we can read the wrapped exe path from `argv[1]` and forward.

Matches by basename → survives app updates (Discord 1.0.9188 → 1.0.9244 → 2.0.x) because we key on `Discord.exe`, not the versioned path.

---

## Windows-version notes

| OS | Symptom | Fix |
|----|---------|-----|
| Win10 22H2 | rare, usually driver | Step 1 + Step 2 |
| Win11 23H2 | rare | Step 1 alone |
| Win11 24H2 | common | Step 1 + Step 4 |
| Win11 25H2 | very common | Step 1 + Step 3 + Step 4 |

---

## Why not just `--disable-gpu` in the shortcut?

Shortcuts fail because:

- Auto-update rewrites the shortcut target
- File associations bypass the shortcut
- Squirrel Update.exe exits before forwarding any extra arg
- Task Scheduler runs the bare exe
- Convenience-launch invocations under different basenames

IFEO Debugger works because it lives in the OS process-creation switchboard, not the launcher's argument vector.

---

## Uninstall

```pwsh
# Remove every IFEO Debugger entry pointing at ElectronShim.exe:
powershell -NoProfile -ExecutionPolicy Bypass -File installer\ElectronAutoRegister.ps1 -Unregister

# Remove scheduled task (if installed):
schtasks /Delete /TN ElectronAutoRegister /F

# Drop env var:
[Environment]::SetEnvironmentVariable("ELECTRON_DISABLE_GPU", $null, "Machine")
```

Restore NVIDIA driver to Game Ready (or any prior) freely — the flags prevent crashes regardless.
