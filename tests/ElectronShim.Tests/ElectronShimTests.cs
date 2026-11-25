using Xunit;
using System.IO;
using System.Reflection;

namespace ElectronShim.Tests;

public class ElectronShimTests
{
    [Fact]
    public void ProjectFile_Exists()
    {
        var projectPath = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "src", "ElectronShim.csproj"));
        Assert.True(File.Exists(projectPath), "ElectronShim.csproj should exist");
    }

    [Fact]
    public void SourceFile_Exists()
    {
        var sourcePath = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "src", "ElectronShim.cs"));
        Assert.True(File.Exists(sourcePath), "ElectronShim.cs should exist");
    }

    [Fact]
    public void SourceFile_ContainsRequiredImports()
    {
        var sourcePath = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "src", "ElectronShim.cs"));
        var content = File.ReadAllText(sourcePath);
        
        Assert.Contains("using System.Diagnostics;", content);
        Assert.Contains("using System.Runtime.InteropServices;", content);
        Assert.Contains("DEBUG_PROCESS", content);
        Assert.Contains("DebugActiveProcessStop", content);
    }

    [Fact]
    public void SourceFile_HasMainEntryPoint()
    {
        var sourcePath = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "src", "ElectronShim.cs"));
        var content = File.ReadAllText(sourcePath);
        
        Assert.Contains("static void Main", content);
    }

    [Fact]
    public void SourceFile_HasSecurityInvariants()
    {
        var sourcePath = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "src", "ElectronShim.cs"));
        var content = File.ReadAllText(sourcePath);
        
        // Check for security invariants from AGENTS.md
        Assert.Contains("DEBUG_PROCESS", content); // DEBUG_PROCESS detach pattern
        Assert.Contains("DebugActiveProcessStop", content); // Immediate detach
    }
}