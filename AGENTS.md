# Agent Instructions - electron-gpu-crash-fix

## Repository Overview

**Name**: electron-gpu-crash-fix
**Type**: C# IFEO Debugger shim + Python GUI for Electron GPU crash fix (0x80000003)
**Primary Language**: C# (shim), Python 3.11+ (GUI/installer)
**Package Manager**: .NET SDK 8.0, pip

## Architecture Overview

```
electron-gpu-crash-fix/
├── src/
│   ├── ElectronShim.cs          # C# IFEO Debugger shim (4.8 KB)
│   └── ElectronShim.csproj      # .NET 8.0 project
├── installer/
│   ├── install-electron-ifeo-and-task.ps1  # Main installer (IFEO + scheduled task)
│   └── ElectronAutoRegister.ps1            # Auto-registration task (runs every 30 min)
├── ElectronGpuCrashFixGUI.py    # Tkinter GUI (TO BE MIGRATED to PySide6)
├── SECURITY.md                  # Security policy
├── LICENSE                      # MIT License
└── README.md
```

## Key Components

| Component | Path | Description |
|-----------|------|-------------|
| ElectronShim | src/ElectronShim.cs | C# IFEO Debugger shim with DEBUG_PROCESS detach |
| Installer | installer/install-electron-ifeo-and-task.ps1 | Registers IFEO entries + scheduled task |
| Auto-Register | installer/ElectronAutoRegister.ps1 | Runs every 30 min, auto-detects new Electron apps |
| GUI | ElectronGpuCrashFixGUI.py | Tkinter GUI for app selection and monitoring |
| Jev Integration | Jev Router triage | AI confidence scoring for IFEO registration |

## Development Commands

```bash
# Build C# shim (signed)
dotnet publish src/ElectronShim.csproj -c Release -r win-x64 --self-contained false -p:PublishSingleFile=true -o publish
signtool sign /a /fd SHA256 /tr http://timestamp.sectigo.com /td SHA256 publish/ElectronShim.exe
icacls publish/ElectronShim.exe /inheritance:r /grant:r "SYSTEM:(RX)" "Administrators:(RX)"

# Run installer (elevated)
powershell -NoProfile -ExecutionPolicy Bypass -File installer/install-electron-ifeo-and-task.ps1

# Dry run with Jev triage
powershell -NoProfile -ExecutionPolicy Bypass -File installer/install-electron-ifeo-and-task.ps1 -DryRun

# Launch GUI
python ElectronGpuCrashFixGUI.py

# Run tests (when added)
pytest tests/
```

## Code Style & Conventions

- **C#**: .NET 8.0, nullable enabled, single-file publish
- **Python**: ruff for lint/formatting, pytest for tests
- **PowerShell**: PSScriptAnalyzer, strict mode
- **Commit Messages**: Conventional Commits

## IFEO Shim Security Invariants (Non-Negotiable)

1. **DEBUG_PROCESS Detach**: Must use `CreateProcess` with `DEBUG_PROCESS | DEBUG_ONLY_THIS_PROCESS` + immediate `DebugActiveProcessStop()` to prevent IFEO re-entry loops (MITRE T1546.012)
2. **Authenticode Signing**: Shim MUST be signed with valid EV certificate
3. **ACL Hardening**: Shim binary ACL locked to SYSTEM/Administrators (RX) only, inheritance removed
4. **Authenticode Verification**: Installer validates signature before registration
5. **Backup/Rollback**: Every IFEO registration backed up via BackupEngine with rollback capability

## CI/CD Pipeline

- **Provider**: GitHub Actions (`.github/workflows/ci.yml`)
- **Jobs**: 
  - Build: `dotnet publish` with single-file, self-contained=false
  - Sign: `signtool` with timestamp
  - ACL Hardening: `icacls` to lock to SYSTEM/Administrators
  - Test: Pester tests for IFEO registration/unregistration
  - Package: Single-file executable

## Security Considerations

- **Secrets**: Signing cert via GitHub Secrets
- **Dependencies**: Scanned via `cargo audit` equivalent (NuGet)
- **Supply Chain**: Dependencies pinned, signed releases
- **IFEO**: MITRE T1546.012 vector - mitigated by signing + ACL + DEBUG_PROCESS detach
- **Scheduled Task**: Runs as SYSTEM every 30 min, auto-detects new Electron apps

## Architecture Invariants (Non-Negotiable)

1. **DEBUG_PROCESS Detach**: C# shim MUST use `CreateProcess` with `DEBUG_PROCESS | DEBUG_ONLY_THIS_PROCESS` + immediate `DebugActiveProcessStop()`
2. **Authenticode Signing**: Shim MUST be signed with valid EV certificate
3. **ACL Hardening**: Shim binary ACL MUST be locked to SYSTEM/Administrators (RX) only
4. **Backup/Rollback**: Every IFEO change MUST have backup via BackupEngine

## Common Tasks

### Building and Signing the Shim
```bash
dotnet publish src/ElectronShim.csproj -c Release -r win-x64 --self-contained false -p:PublishSingleFile=true -o publish
signtool sign /a /fd SHA256 /tr http://timestamp.sectigo.com /td SHA256 publish/ElectronShim.exe
icacls publish/ElectronShim.exe /inheritance:r /grant:r "SYSTEM:(RX)" "Administrators:(RX)"
```

### Running Installer (Dry Run)
```bash
powershell -NoProfile -ExecutionPolicy Bypass -File installer/install-electron-ifeo-and-task.ps1 -DryRun
```

### Running Installer (Full)
```bash
powershell -NoProfile -ExecutionPolicy Bypass -File installer/install-electron-ifeo-and-task.ps1
```

### Launching GUI
```bash
python ElectronGpuCrashFixGUI.py
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Shim not signed | Run signtool with valid EV cert |
| IFEO not registering | Run installer as Administrator |
| Scheduled task not running | Check Task Scheduler history, ensure SYSTEM account |
| EDR blocking shim | Verify Authenticode signature + ACL hardening |

## Useful Links

- **Repo**: `https://github.com/theyonecodes/electron-gpu-crash-fix`
- **Issues**: `https://github.com/theyonecodes/electron-gpu-crash-fix/issues`
- **CI**: `https://github.com/theyonecodes/electron-gpu-crash-fix/actions`
- **Security**: `https://github.com/theyonecodes/electron-gpu-crash-fix/security/advisories`
- **MITRE T1546.012**: `https://attack.mitre.org/techniques/T1546/012/`