using System.Diagnostics;
using Skybridge.WinClient.Services;

internal static class WindowsPowerKeepAwakeTests
{
    internal static IEnumerable<(string Name, Func<Task> Run)> Cases
    {
        get
        {
            yield return ("power requests reject an empty reason and unsupported platforms", ValidateBoundaryAsync);
        }
    }

    private static Task ValidateBoundaryAsync()
    {
        try { using var invalid = WindowsPowerKeepAwake.Arm(" ", false); throw new InvalidOperationException("An empty power reason was accepted."); }
        catch (ArgumentException) { }
        if (!OperatingSystem.IsWindows())
        {
            try { using var invalid = WindowsPowerKeepAwake.Arm(); throw new InvalidOperationException("A non-Windows power request reported success."); }
            catch (PlatformNotSupportedException) { }
        }
        return Task.CompletedTask;
    }

    internal static async Task NativeOwnershipAsync()
    {
        if (!OperatingSystem.IsWindows() || Process.GetCurrentProcess().SessionId == 0)
            throw new InvalidOperationException("Native display power validation requires an interactive Windows session.");
        var marker = $"SkyBridge power lifecycle check {Guid.NewGuid():N}";
        var desktopReason = marker + " desktop";
        var transferReason = marker + " transfer";
        using (var desktop = WindowsPowerKeepAwake.Arm(desktopReason, keepDisplayAwake: true))
        {
            using (var transfer = WindowsPowerKeepAwake.Arm(transferReason, keepDisplayAwake: false))
            {
                var active = await ReadRequestsAsync();
                Require(Count(active, desktopReason) == 2, "Desktop capture did not retain both display and system requests.");
                Require(Count(active, transferReason) == 1, "File transfer changed the display power policy.");
                await Task.Run(transfer.Dispose);
            }
            var surviving = await ReadRequestsAsync();
            Require(Count(surviving, desktopReason) == 2, "Disposing another operation released the desktop request.");
            Require(Count(surviving, transferReason) == 0, "The transfer request remained on its original thread.");
            await Task.WhenAll(Task.Run(desktop.Dispose), Task.Run(desktop.Dispose));
        }
        Require(Count(await ReadRequestsAsync(), marker) == 0, "Power requests survived owner disposal.");
    }

    private static async Task<string> ReadRequestsAsync()
    {
        using var process = new Process
        {
            StartInfo = new ProcessStartInfo("powercfg.exe", "/requests")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            }
        };
        Require(process.Start(), "Windows did not start powercfg.");
        var output = process.StandardOutput.ReadToEndAsync();
        var error = process.StandardError.ReadToEndAsync();
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        try { await process.WaitForExitAsync(deadline.Token); }
        catch (OperationCanceledException)
        {
            process.Kill(entireProcessTree: true);
            await process.WaitForExitAsync();
            throw new TimeoutException("Power request inspection exceeded ten seconds.");
        }
        Require(process.ExitCode == 0, $"Power request inspection failed: {await error}");
        return await output;
    }

    private static int Count(string output, string reason) => output.Split('\n').Count(line => line.Contains(reason, StringComparison.Ordinal));
    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
