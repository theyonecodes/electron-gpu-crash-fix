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
// Build:
//   dotnet publish src/ElectronShim.csproj -c Release -r win-x64 --self-contained false -p:PublishSingleFile=true -o publish

using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Security.Principal;

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

    private static int Main(string[] args)
    {
        // IFEO passes the original command line as argv[0] (the exe path),
        // followed by any user-supplied args.
        if (args.Length == 0)
        {
            Log("called with no args; nothing to launch");
            return 1;
        }

        bool isAdmin = IsAdministrator();
        string exePath = args[0];
        string[] userArgs = args.Skip(1).ToArray();

        // Some Electron hosts (Squirrel Update.exe --processStart <exe>) launch the real
        // exe without using bash-style quoting. Skip wrapping when the real exe is not
        // present; fall back to running the launcher verbatim.
        if (!File.Exists(exePath))
        {
            Log($"target missing: {exePath}; passing through");
            // Forward without flag injection; preserve user args.
            return Forward(cmd: exePath, arguments: string.Join(' ', userArgs), wait: false);
        }

        string flagsString = string.Join(' ', InjectedFlags);
        string userArgsString = userArgs.Length == 0 ? "" : " " + string.Join(' ', userArgs);

        // Prepare env augmentation. ELECTRON_DISABLE_GPU is honored by some Chromium builds
        // after the GPU-process init; flag injection covers the rest.
        var env = new[]
        {
            ("ELECTRON_DISABLE_GPU", "1"),
        };

        Log($"admin={isAdmin} target={exePath} flags=[{flagsString}] userArgs=[{userArgsString}]");

        // Run without Wait so IFEO returns immediately and the real process owns its
        // lifetime. /WAIT would deadlock IFEO because the original caller never returns
        // until this Debugger exits -- if we wait on the child, we never exit.
        return Forward(cmd: exePath, arguments: $"{flagsString}{userArgsString}".Trim(), wait: false, env: env);
    }

    private static bool IsAdministrator()
    {
        using var id = WindowsIdentity.GetCurrent();
        var principal = new WindowsPrincipal(id);
        return principal.IsInRole(WindowsBuiltInRole.Administrator);
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
            // Without Wait, do not capture exit code.
            return 0;
        }
        catch (Exception ex)
        {
            Log($"forward failed for {cmd}: {ex.GetType().Name}: {ex.Message}");
            return 1;
        }
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
