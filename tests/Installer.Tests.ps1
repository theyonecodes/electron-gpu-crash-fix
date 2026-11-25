# Pester tests for Electron GPU Crash Fix installer scripts
# Run with: Invoke-Pester tests/Installer.Tests.ps1

BeforeAll {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $projectRoot = Split-Path -Parent $scriptDir
    $installerPath = Join-Path $projectRoot "installer\install-electron-ifeo-and-task.ps1"
    $autoRegisterPath = Join-Path $projectRoot "installer\ElectronAutoRegister.ps1"
}

Describe "Installer Scripts Exist" {
    It "Main installer script exists" {
        $installerPath | Should -Exist
    }

    It "Auto-register script exists" {
        $autoRegisterPath | Should -Exist
    }
}

Describe "Main Installer Script" {
    $content = Get-Content $installerPath -Raw

    It "Has IFEO registration logic" {
        $content | Should -Match "Set-ItemProperty"
        $content | Should -Match "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options"
    }

    It "Has DEBUG_PROCESS pattern validation" {
        $content | Should -Match "DEBUG_PROCESS"
    }

    It "Has backup/rollback logic" {
        $content | Should -Match "BackupEngine"
        $content | Should -Match "Rollback"
    }

    It "Has Authenticode signature validation" {
        $content | Should -Match "Get-AuthenticodeSignature"
    }

    It "Has ACL hardening" {
        $content | Should -Match "icacls"
        $content | Should -Match "SYSTEM:\(RX\)"
        $content | Should -Match "Administrators:\(RX\)"
    }

    It "Has dry-run support" {
        $content | Should -Match "DryRun"
    }

    It "Has scheduled task registration" {
        $content | Should -Match "Register-ScheduledTask"
        $content | Should -Match "ElectronAutoRegister"
    }

    It "Has Jev AI triage integration" {
        $content | Should -Match "Jev"
    }
}

Describe "Auto-Register Script" {
    $content = Get-Content $autoRegisterPath -Raw

    It "Detects Electron apps" {
        $content | Should -Match "Electron"
        $content | Should -Match "Get-Process"
    }

    It "Runs periodically" {
        $content | Should -Match "30"
    }

    It "Has IFEO registration" {
        $content | Should -Match "Image File Execution Options"
    }
}

Describe "C# Shim Source" {
    $shimPath = Join-Path $projectRoot "src\ElectronShim.cs"
    $shimContent = Get-Content $shimPath -Raw

    It "Uses DEBUG_PROCESS flag" {
        $shimContent | Should -Match "DEBUG_PROCESS"
    }

    It "Calls DebugActiveProcessStop" {
        $shimContent | Should -Match "DebugActiveProcessStop"
    }

    It "Has CreateProcess with DEBUG_ONLY_THIS_PROCESS" {
        $shimContent | Should -Match "DEBUG_ONLY_THIS_PROCESS"
    }

    It "Has proper P/Invoke signatures" {
        $shimContent | Should -Match "DllImport"
        $shimContent | Should -Match "kernel32.dll"
    }
}