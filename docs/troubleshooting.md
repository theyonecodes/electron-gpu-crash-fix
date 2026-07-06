# Troubleshooting

Common failures when applying the fix.

---

## "ElectronShim.exe not found"

The installer defaults to `%USERPROFILE%\Desktop\ElectronShim.exe`. If you placed it elsewhere:

```pwsh
.\install-electron-ifeo-and-task.ps1 -ShimPath "D:\Tools\ElectronShim.exe"
```

Or build it in place:

```pwsh
dotnet publish src\ElectronShim.csproj -c Release -r win-x64 -p:PublishSingleFile=true -o "%USERPROFILE%\Desktop"
```

---

## "Access is denied" / "Register-ScheduledTask failed"

The installer or script must run **elevated**. If double-clicking a `.cmd` produces no window, the UAC prompt was likely auto-dismissed. Run manually:

```pwsh
# Right-click PowerShell → Run as administrator
cd path\to\repo\installer
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-electron-ifeo-and-task.ps1
```

---

## App still crashes after install

Verify the IFEO entry actually points at your shim:

```pwsh
Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options' |
  Where-Object { $_.Name -in 'Discord.exe','Obsidian.exe','Notion.exe','Code.exe' } |
  ForEach-Object {
    $dbg = (Get-ItemProperty $_.PSPath).Debugger
    Write-Host "$($_.Name) = $dbg"
  }
```

If `Debugger` is empty or points at the wrong path, re-run the installer.

Verify electron is actually being wrapped:

```pwsh
Get-Content $env:TEMP\ElectronShim.log -Tail 20
```

Every app launch should append a line. If not — the IFEO basename doesn't match what the launcher is invoking. Verify the launcher:

```pwsh
# For Discord:
Get-Content "$env:LOCALAPPDATA\Discord\Update.exe" -TotalCount 1  # existence check
# Actual invocation:
& "$env:LOCALAPPDATA\Discord\Update.exe" --processStart Discord.exe
```

If the launcher uses `--processStart SomeOther.exe`, add that basename too.

---

## PowerShell 5.1 vs 7+

PowerShell 5.1 ships with Windows 10/11. PowerShell 7+ (`pwsh.exe`) is optional.

The installer uses only PS 5.1-compatible syntax. Confirm:

```pwsh
$PSVersionTable.PSVersion
```

`Major: 5` is enough.

---

## Task Scheduler triggers

If the installer reports a successful task install but Task Scheduler shows it missing, common culprits:

1. Win11 24H2+ kernel task cache lag — installs persist ~30 sec later.
2. Computer is domain-joined with GPO preventing SYSTEM-level scripts — check `gpresult /h`.
3. AV quarantining `electron-gpu-crash-fix` artifacts — exclude the repo folder.

To bypass and use only the IFEO registrations for known apps:

```pwsh
.\install-electron-ifeo-and-task.ps1 -SkipTask
```

---

## Performance concerns

Software rendering is slower than hardware, but for:

- Document editors: imperceptible
- Chat (Discord, Slack): imperceptible
- DAWs (Reaper, Resolve): the GPU-disabled UI is fine for editing/proxy work; GPU is still active for the actual render

For apps where GPU rendering matters and your drivers are unstable, prefer **Step 2** (driver swap) over the GPU flags.

---

## Removing the fix entirely

```pwsh
# 1. Remove IFEO entries
powershell -NoProfile -ExecutionPolicy Bypass -File installer\ElectronAutoRegister.ps1 -Unregister

# 2. Remove scheduled task
powershell -NoProfile -ExecutionPolicy Bypass -File installer\ElectronAutoRegister.ps1 -UninstallTask

# 3. Drop env var
[Environment]::SetEnvironmentVariable("ELECTRON_DISABLE_GPU", $null, "Machine")

# 4. (optional) Restore original GPU drivers
```
