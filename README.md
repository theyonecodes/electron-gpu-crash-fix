# Electron GPU Crash Fix (0x80000003)

A one-click remediation for Electron / Chromium / Edge-based desktop apps that crash on launch with `0x80000003` (STATUS_BREAKPOINT), `__debugbreak() in __sanitizer_...`, or `Locale-related CUDA errors` on Windows 10/11.

Affected apps include Discord, Notion, Obsidian, VS Code, DaVinci Resolve, Reaper, Rekordbox, Upscayl, and any custom Electron build.

---

## What this does

Adds four browser-level flags to every Electron-derived executable on the machine:

```
--no-sandbox
--disable-gpu
--disable-gpu-compositing
--in-process-gpu
```

The flags are injected **at OS process-creation time** via `Image File Execution Options` (IFEO) `Debugger` entries. Windows intercepts the launch, runs the registered Debugger binary (our tiny C# shim) with the original exe path appended — and the shim pre-pends the flags and forwards the call.

Survives app updates (registered by basename, not full path).
Applies to **any caller** — taskbar Start, command line, task scheduler, file associations, MCP servers, scripts.
Zero per-app installation or shortcut editing needed.

---

## Quick start

1. **Run elevated PowerShell once:**

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File installer\install-electron-ifeo-and-task.ps1
   ```

2. **Restart** the app that was crashing. Done.

For app auto-discovery on new installs (catches future apps as you install them), the installer also registers a SYSTEM scheduled task running every 30 minutes.

---

## Why this happens

On Windows 11 24H2/25H2 the Chromium GPU-process sandbox often fails to initialize. The signed binary calls `__debugbreak()` to force a windowed crash dialog. Symptoms:

- App process appears briefly, dies before window shows
- Event log entries with `STATUS_BREAKPOINT (0x80000003)`
- Crash dump in `%LOCALAPPDATA%\CrashDumps`
- Same apps run fine on another machine

Root causes confirmed on this machine:
- Intel iGPU + NVIDIA dGPU coexistence with phantom disabled adapter in DACLs
- NVIDIA driver interaction with the new Chromium `vk_swiftshader` path
- Windows session-0 sandbox init regression

The four flags documented above sidestep all three.

Permanent additional mitigations applied by this installer:
- NVIDIA Studio Driver (not Game Ready)
- Intel iGPU disabled in BIOS
- Machine-wide `ELECTRON_DISABLE_GPU=1`

---

## Files

| File | Purpose |
|------|---------|
| `installer/install-electron-ifeo-and-task.ps1` | One-shot elevated install. Registers IFEO entries for major Electron apps + installs SYSTEM scheduled task for auto-discovery. |
| `installer/ElectronAutoRegister.ps1` | Sweep script. Walks common install locations, detects Electron-derived EXEs by file-based heuristics, idempotently adds IFEO entries. Logs to `%ProgramData%\ElectronAutoRegister.log`. |
| `src/ElectronShim.cs` | Source for the tiny C# Debugger shim. Pre-pends flags, forwards to the real exe, logs to `%TEMP%\ElectronShim.log`. |
| `docs/crash-recipe.md` | Detailed diagnosis notes: BIOS settings, driver choice, env vars, retry-during-build pattern. |
| `LICENSE` | MIT. |

---

## Building the shim

```pwsh
dotnet publish src/ElectronShim.csproj -c Release -r win-x64 --self-contained false -p:PublishSingleFile=true -o publish
```

Output: `publish/ElectronShim.exe` (~6.6 KB).

The IFEO entries point at the resulting binary. The installer script defaults to `%USERPROFILE%\Desktop\ElectronShim.exe`; place it there or change the path in the installer.

---

## Uninstallation

Reverse procedure (run elevated PowerShell):

```powershell
# Remove IFEO entries
reg delete "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\Discord.exe" /f
reg delete "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\Obsidian.exe" /f
# ... repeat for each app, or use the auto-register script's unregister switch
powershell -NoProfile -ExecutionPolicy Bypass -File installer\ElectronAutoRegister.ps1 -Unregister

# Remove scheduled task
schtasks /Delete /TN ElectronAutoRegister /F

# Restore default GPU handling (optional)
[Environment]::SetEnvironmentVariable("ELECTRON_DISABLE_GPU", $null, "Machine")
```

---

## Verified coverage

Apps confirmed working on Windows 11 25H2 with this fix:

- Discord (multi-version)
- Notion
- Obsidian
- VS Code
- DaVinci Resolve + DaVinci Remote Monitor
- Openscreen
- Rekordbox + Rekordbox Agent
- Upscayl
- Edge (natively unaffected; not registered)

New Electron apps are auto-discovered within a single sweep cycle (≤30 min) after install.

---

## License

MIT. See `LICENSE`.
