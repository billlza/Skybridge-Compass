using System.Diagnostics;
using System.Text.Json;
using Skybridge.WinClient.Services.RemoteControl;

/// <summary>Exercises the product capture and encoder without injecting input or changing focus.</summary>
internal static class DesktopSyncRefreshSmoke
{
    internal static async Task RunAsync(string evidence)
    {
        if (Directory.Exists(evidence) && Directory.EnumerateFileSystemEntries(evidence).Any())
            throw new IOException("Sync refresh evidence must be written to a fresh directory.");
        Directory.CreateDirectory(evidence);
        using var process = Process.GetCurrentProcess();
        Require(process.SessionId > 0, "Desktop refresh validation requires an interactive session.");
        WindowsInteractiveDesktop.RequireAvailable();
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(45));
        var display = WindowsDesktopCapture.EnumerateDisplays().Single(item => item.IsPrimary);
        var observations = new List<Observation>();
        var sawUnchangedDesktop = false;
        // One capture and encoder survive every refresh and compacting collection.
        using (var capture = new WindowsDesktopCapture(display.Id, 1280, 720))
        using (var encoder = new WindowsDesktopEncoder(new(1280, 720, 30, 4_000_000)))
        {
            using var initial = await capture.CaptureAsync(TimeSpan.FromSeconds(2), cancellation.Token)
                ?? throw new TimeoutException("DXGI did not deliver the initial desktop image.");
            var first = encoder.Encode(initial, forceKeyFrame: true);
            Require(first.Count == 1 && first[0].IsKeyFrame, "The initial desktop must produce one IDR.");
            var previousTimestamp = initial.TimestampTicks;
            for (var index = 0; index < 64; index++)
            {
                cancellation.Token.ThrowIfCancellationRequested();
                using var ordinary = await capture.CaptureAsync(TimeSpan.Zero, cancellation.Token);
                sawUnchangedDesktop |= ordinary is null;
                GC.Collect(GC.MaxGeneration, GCCollectionMode.Forced, blocking: true, compacting: true);
                using var refreshed = await capture.CaptureAsync(TimeSpan.Zero, cancellation.Token, includeUnchangedFrame: true)
                    ?? throw new InvalidOperationException("An explicit refresh lost the previously captured desktop.");
                Require(refreshed.TimestampTicks > previousTimestamp, "Refresh media timestamps must increase.");
                previousTimestamp = refreshed.TimestampTicks;
                encoder.RequestKeyFrame();
                var frames = encoder.Encode(refreshed);
                Require(frames.Count == 1 && frames[0].IsKeyFrame, "Every requested refresh must emit one IDR immediately.");
                Require(frames[0].Width == 1280 && frames[0].Height == 720, "Refresh changed the negotiated dimensions.");
                observations.Add(new(index, ordinary is null, frames[0].H264Bytes.Length, refreshed.TimestampTicks));
                await Task.Delay(35, cancellation.Token);
            }
            Require(sawUnchangedDesktop, "The desktop never became unchanged; the cached refresh path was not exercised.");
        }
        // Emit success only after both native owners have disposed successfully.
        await File.WriteAllTextAsync(Path.Combine(evidence, "sync-refresh.json"), JsonSerializer.Serialize(new
        {
            Profile = "windows-desktop-sync-refresh", Status = "passed", ProcessId = process.Id,
            SessionId = process.SessionId, CompletedAtUtc = DateTimeOffset.UtcNow,
            CaptureInstances = 1, EncoderInstances = 1, NoInputInjected = true, NoForegroundChange = true,
            SourceWidth = display.Width, SourceHeight = display.Height, SawUnchangedDesktop = sawUnchangedDesktop,
            Compactions = observations.Count, Observations = observations
        }, new JsonSerializerOptions { WriteIndented = true }), cancellation.Token);
    }

    private sealed record Observation(int Index, bool OrdinaryCaptureWasEmpty, int KeyFrameBytes, long TimestampTicks);
    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
