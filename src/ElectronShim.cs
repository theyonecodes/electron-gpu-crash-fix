// ElectronShim.cs -- IFEO Debugger shim for Electron-derived apps crashing with 0x80000003
//
// Behavior:
//   Windows intercepts CreateProcess for any registered basename in
//   HKLM\...\Image File Execution Options\<exe>\Debugger. It launches
//   the Debugger value with the original exe path as argv[0].
//
//   This shim prepends four Chromium flags and forwards the call.
//   Logs every invocation to %TEMP%\ElectronShim.log so missed calls
//   can be debugged.
//
// Flags injected (order matters only for readability):
//   --no-sandbox
//   --disable-gpu
//   --disable-gpu-compositing
//   --in-process-gpu
//
// Why these flags: see docs/crash-recipe.md.
//
// Build (signed):
//   dotnet publish src/ElectronShim.csproj -c Release -r win-x64 --self-contained false -p:PublishSingleFile=true -o publish
//   signtool sign /a /fd SHA256 /tr http://timestamp.sectigo.com /td SHA256 publish/ElectronShim.exe
//   icacls publish/ElectronShim.exe /inheritance:r /grant:r "SYSTEM:(RX)" "Administrators:(RX)"

using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;

namespace ElectronShim;

internal static class Program
{
    private const string LogPath = "%TEMP%\\ElectronShim.log";

    private static readonly string[] InjectedFlags =
    {
        "--no-sandbox",
        "--disable-gpu",
        "--disable-gpu-compositing",
        "--in-process-gpu",
    };

    // Win32 API for DEBUG_PROCESS detach
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CreateProcess(
        string lpApplicationName,
        StringBuilder lpCommandLine,
        IntPtr lpProcessAttributes,
        IntPtr lpThreadAttributes,
        bool bInheritHandles,
        uint dwCreationFlags,
        IntPtr lpEnvironment,
        string lpCurrentDirectory,
        [In] ref STARTUPINFO lpStartupInfo,
        out PROCESS_INFORMATION lpProcessInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool DebugActiveProcessStop(uint dwProcessId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);

    private const uint DEBUG_PROCESS = 0x00000001;
    private const uint DEBUG_ONLY_THIS_PROCESS = 0x00000002;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFO
    {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public int dwX;
        public int dwY;
        public int dwXSize;
        public int dwYSize;
        public int dwXCountChars;
        public int dwYCountChars;
        public int dwFillAttribute;
        public int dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public uint dwProcessId;
        public uint dwThreadId;
    }

    private const string LogPath = "%TEMP%\\ElectronShim.log";

    private static readonly string[] InjectedFlags =
    {
        "--no-sandbox",
        "--disable-gpu",
        "--disable-gpu-compositing",
        "--in-process-gpu",
    };

    private static int Main(string[] args)
    {
        if (args.Length == 0)
        {
            Log("called with no args; nothing to launch");
            return 1;
        }

        bool isAdmin = IsAdministrator();
        string exePath = args[0];
        string[] userArgs = args.Skip(1).ToArray();

        if (!File.Exists(exePath))
        {
            Log($"target missing: {exePath}; passing through");
            return Forward(cmd: exePath, arguments: string.Join(' ', userArgs), wait: false);
        }

        string flagsString = string.Join(' ', InjectedFlags);
        string userArgsString = userArgs.Length == 0 ? "" : " " + string.Join(' ', userArgs);

        var env = new[]
        {
            ("ELECTRON_DISABLE_GPU", "1"),
        };

        Log($"admin={isAdmin} target={exePath} flags=[{flagsString}] userArgs=[{userArgsString}]");

        // Use DEBUG_PROCESS + DEBUG_ONLY_THIS_PROCESS to detach IFEO
        // This prevents the spawn loop where IFEO debugger keeps re-invoking itself
        return ForwardWithDetach(cmd: exePath, arguments: $"{flagsString}{userArgsString}".Trim(), env: env);
    }

    private static bool IsAdministrator()
    {
        using var id = WindowsIdentity.GetCurrent();
        var principal = new WindowsPrincipal(id);
        return principal.IsInRole(WindowsBuiltInRole.Administrator);
    }

    private static int ForwardWithDetach(string cmd, string arguments, (string Key, string Value)[]? env = null)
    {
        try
        {
            // Build full command line
            string fullCmd = $"{cmd} {arguments}".Trim();

            var si = new STARTUPINFO
            {
                cb = Marshal.SizeOf(typeof(STARTUPINFO)),
                dwFlags = 1, // STARTF_USESHOWWINDOW
                wShowWindow = 1 // SW_SHOWNORMAL
            };

            var pi = new PROCESS_INFORMATION();

            // Prepare environment block
            IntPtr envBlock = IntPtr.Zero;
            if (env != null)
            {
                var envStrings = new List<string>();
                foreach (var (k, v) in env)
                {
                    envStrings.Add($"{k}={v}");
                }
                envStrings.Add(""); // Double null terminator
                string envBlockStr = string.Join("\0", envStrings);
                var envBytes = Encoding.Unicode.GetBytes(envBlockStr);
                envBlock = Marshal.AllocHGlobal(envBytes.Length);
                Marshal.Copy(envBytes, 0, envBlock, envBytes.Length);
            }

            // Use DEBUG_PROCESS | DEBUG_ONLY_THIS_PROCESS to get control
            // but immediately detach to avoid IFEO re-entry loop
            bool success = CreateProcess(
                null,                           // lpApplicationName (use command line)
                new StringBuilder(fullCmd),     // lpCommandLine
                IntPtr.Zero,                    // lpProcessAttributes
                IntPtr.Zero,                    // lpThreadAttributes
                false,                          // bInheritHandles
                DEBUG_PROCESS | DEBUG_ONLY_THIS_PROCESS, // dwCreationFlags
                envBlock,                       // lpEnvironment
                null,                           // lpCurrentDirectory (use parent's)
                ref si,                         // lpStartupInfo
                out pi);                        // lpProcessInformation

            if (envBlock != IntPtr.Zero)
                Marshal.FreeHGlobal(envBlock);

            if (!success)
            {
                int err = Marshal.GetLastWin32Error();
                Log($"CreateProcess failed: 0x{err:X8} for {cmd}");
                // Fallback to Process.Start
                return Forward(cmd, arguments, wait: false, env);
            }

            // Immediately detach the debugger to avoid IFEO re-entry
            // This is the key fix for MITRE T1546.012 - prevents the debugger
            // from being invoked recursively on the child process
            if (!DebugActiveProcessStop(pi.dwProcessId))
            {
                int err = Marshal.GetLastWin32Error();
                Log($"DebugActiveProcessStop failed: 0x{err:X8} for PID {pi.dwProcessId}");
                // Not fatal - child will run with debugger attached but it works
            }

            // Clean up handles
            if (pi.hProcess != IntPtr.Zero) CloseHandle(pi.hProcess);
            if (pi.hThread != IntPtr.Zero) CloseHandle(pi.hThread);

            Log($"Detached IFEO debugger for PID {pi.dwProcessId}: {cmd} {arguments}");
            return 0;
        }
        catch (Exception ex)
        {
            Log($"forward failed for {cmd}: {ex.GetType().Name}: {ex.Message}");
            return Forward(cmd, arguments, wait: false, env);
        }
    }

    private static int Forward(string cmd, string arguments, bool wait, (string Key, string Value)[]? env = null)
    {
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = cmd,
                Arguments = arguments,
                UseShellExecute = false,
                CreateNoWindow = false,
            };
            if (env != null)
            {
                foreach (var (k, v) in env)
                {
                    psi.Environment[k] = v;
                }
            }
            var proc = Process.Start(psi);
            if (proc == null)
            {
                Log($"Process.Start returned null for {cmd}");
                return 1;
            }
            if (wait)
            {
                proc.WaitForExit();
                return proc.ExitCode;
            }
            return 0;
        }
        catch (Exception ex)
        {
            Log($"forward failed for {cmd}: {ex.GetType().Name}: {ex.Message}");
            return 1;
        }
    }

    private static bool IsAdministrator()
    {
        using var id = WindowsIdentity.GetCurrent();
        var principal = new WindowsPrincipal(id);
        return principal.IsInRole(WindowsBuiltInRole.Administrator);
    }

    private static void Log(string message)
    {
        try
        {
            string path = Environment.ExpandEnvironmentVariables(LogPath);
            string line = $"[{DateTime.UtcNow:O}] {message}{Environment.NewLine}";
            File.AppendAllText(path, line);
        }
        catch
        {
            // Logging is best-effort; never let path issues crash the wrapped app launch.
        }
    }
}