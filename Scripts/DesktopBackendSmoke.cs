using System.Diagnostics;
using System.Drawing.Imaging;
using System.Media;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text.Json;
using Concentus;
using Skybridge.WinClient.Services.RemoteControl;

[assembly: SupportedOSPlatform("windows10.0.19041")]

internal enum DesktopSmokeMode { Native, NativeGpu, ViewerInput }

internal static class DesktopBackendSmoke
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length == 2 && args[0] == "--scaler-check")
            return DesktopScalerSmoke.Run(Path.GetFullPath(args[1]));
        if (args.Length == 2 && args[0] == "--sync-refresh")
        {
            DesktopSyncRefreshSmoke.RunAsync(Path.GetFullPath(args[1])).GetAwaiter().GetResult();
            return 0;
        }
        if (args.Length == 2 && args[0] == "--audio-endpoints")
        {
            WindowsInteractiveDesktop.RequireAvailable();
            File.WriteAllText(Path.GetFullPath(args[1]), JsonSerializer.Serialize(DesktopAudioEndpointProbe.Read(), new JsonSerializerOptions { WriteIndented = true }));
            return 0;
        }
        if (args.Length == 2 && args[0] is "--encoder-budget" or "--encoder-budget-gpu")
        {
            DesktopEncoderBudgetProbe.RunAsync(Path.GetFullPath(args[1]), args[0] == "--encoder-budget-gpu").GetAwaiter().GetResult();
            return 0;
        }
        if (args.Length != 2) throw new ArgumentException("A mode and fresh evidence directory are required.");
        var mode = args[0] switch
        {
            "--evidence" => DesktopSmokeMode.Native,
            "--evidence-gpu" => DesktopSmokeMode.NativeGpu,
            "--viewer-input" => DesktopSmokeMode.ViewerInput,
            _ => throw new ArgumentException("Usage: --evidence, --evidence-gpu or --viewer-input <fresh directory>")
        };
        var evidence = Path.GetFullPath(args[1]);
        if (mode == DesktopSmokeMode.ViewerInput && Directory.Exists(evidence) && Directory.EnumerateFileSystemEntries(evidence).Any())
            throw new IOException("Viewer evidence directory must be new or empty; existing evidence was preserved.");
        Directory.CreateDirectory(evidence);
        if (File.Exists(Path.Combine(evidence, "native-result.json")) || File.Exists(Path.Combine(evidence, "viewer-input.json")) ||
            File.Exists(Path.Combine(evidence, "viewer-input.json.tmp")))
            throw new IOException("Desktop evidence already exists; choose a fresh directory.");
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        using var form = new SmokeWindow(evidence, mode);
        Application.Run(form);
        return form.ExitCode;
    }
}

internal static class DesktopEncoderBudgetProbe
{
    internal static async Task RunAsync(string evidence, bool gpuScaling)
    {
        Directory.CreateDirectory(evidence);
        WindowsInteractiveDesktop.RequireAvailable();
        using var process = Process.GetCurrentProcess();
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        var display = WindowsDesktopCapture.EnumerateDisplays().Single(item => item.IsPrimary);
        var inputDesktop = new WindowsNativeInputPlatform(display).GetDesktopBounds();
        var results = new List<ProfileResult>();
        foreach (var profile in new[]
        {
            (Name: "5k-30fps", Width: 5120, Height: 2880, Bitrate: 50_000_000),
            (Name: "1080p-30fps", Width: 1920, Height: 1080, Bitrate: 8_000_000)
        })
        {
            var phase = "initialization";
            var clock = Stopwatch.StartNew();
            WindowsDesktopEncoder? encoder = null;
            WindowsDesktopCapture? capture = null;
            Exception? error = null;
            double? initializationMs = null, captureMs = null, encodeMs = null;
            int? frameBytes = null;
            try
            {
                cancellation.Token.ThrowIfCancellationRequested();
                encoder = new WindowsDesktopEncoder(new(profile.Width, profile.Height, 30, profile.Bitrate));
                initializationMs = clock.Elapsed.TotalMilliseconds;
                phase = "capture";
                capture = gpuScaling ? new WindowsDesktopCapture(display.Id, profile.Width, profile.Height) : new WindowsDesktopCapture(display.Id);
                using var frame = await capture.CaptureAsync(TimeSpan.FromSeconds(2), cancellation.Token) ??
                    throw new TimeoutException("The selected desktop produced no initial DXGI frame.");
                captureMs = clock.Elapsed.TotalMilliseconds - initializationMs;
                phase = "encode";
                var frames = encoder.Encode(frame, true);
                Require(frames.Count == 1 && frames[0].IsKeyFrame, "The low-latency H.264 encoder did not emit exactly one initial IDR.");
                encodeMs = clock.Elapsed.TotalMilliseconds - initializationMs - captureMs;
                await File.WriteAllBytesAsync(Path.Combine(evidence, profile.Name + ".h264"), frames[0].H264Bytes, cancellation.Token);
                frameBytes = frames[0].H264Bytes.Length;
            }
            catch (Exception failure) { error = failure; }
            finally
            {
                try { capture?.Dispose(); }
                catch (Exception failure) { error = error is null ? failure : new AggregateException(error, failure); }
                try { encoder?.Dispose(); }
                catch (Exception failure) { error = error is null ? failure : new AggregateException(error, failure); }
            }
            results.Add(new(profile.Name, error is null ? "passed" : "failed", profile.Width, profile.Height, 30,
                initializationMs, captureMs, encodeMs, frameBytes, frameBytes.HasValue, false,
                error is null ? null : phase, clock.Elapsed.TotalMilliseconds, error?.ToString()));
        }
        await File.WriteAllTextAsync(Path.Combine(evidence, "encoder-budget.json"), JsonSerializer.Serialize(new
        {
            Profile = "windows-desktop-encoder-budget", Status = "completed", SessionId = process.SessionId,
            NoInputInjected = true, NoForegroundChange = true, SourceWidth = display.Width, SourceHeight = display.Height,
            ValidatedInputDesktopBounds = inputDesktop,
            GpuCaptureScaling = gpuScaling,
            Profiles = results
        }, new JsonSerializerOptions { WriteIndented = true }));
    }
    private sealed record ProfileResult(string Profile, string Status, int Width, int Height, int TargetFps,
        double? InitializationMilliseconds, double? CaptureMilliseconds, double? EncodeMilliseconds,
        int? FirstFrameBytes, bool IsKeyFrame, bool HardwareAccelerated, string? FailedPhase, double ElapsedMilliseconds, string? Error);
    private static void Require(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}

internal sealed class SmokeWindow : Form
{
    private readonly string _evidence;
    private readonly DesktopSmokeMode _mode;
    private readonly bool _gpuScaling;
    private readonly StreamWriter _log;
    private readonly TextBox _target;
    private readonly System.Windows.Forms.Timer _paintTimer;
    private readonly CancellationTokenSource _lifetime;
    private readonly DesktopViewerInputReceipt? _viewerReceipt;
    private readonly Button? _viewerClickTarget;
    private readonly System.Windows.Forms.Timer? _viewerReceiptTimer;
    private Exception? _viewerFailure;
    private string? _viewerCompletionReason;
    private bool _viewerReceiptDirty;
    private int _paints, _mouseDown, _mouseUp, _keyDown, _keyUp;
    private bool _finished;
    internal int ExitCode { get; private set; } = 1;

    internal SmokeWindow(string evidence, DesktopSmokeMode mode)
    {
        _evidence = evidence;
        _mode = mode;
        _gpuScaling = mode == DesktopSmokeMode.NativeGpu;
        _lifetime = new(mode == DesktopSmokeMode.ViewerInput ? TimeSpan.FromMinutes(20) : TimeSpan.FromSeconds(60));
        _log = new StreamWriter(Path.Combine(evidence, "native-runtime.log"), false) { AutoFlush = true };
        Text = mode == DesktopSmokeMode.ViewerInput ? "SkyBridge Viewer Input Validation" : "SkyBridge Desktop Backend Validation";
        BackColor = Color.FromArgb(20, 32, 46);
        ForeColor = Color.White;
        WindowState = FormWindowState.Maximized;
        DoubleBuffered = true;
        Font = new Font("Segoe UI", 18);
        _target = new TextBox { Bounds = new Rectangle(90, 260, 760, 55), Font = new Font("Segoe UI", 24), ImeMode = ImeMode.Disable, MaxLength = 4096,
            Name = "ViewerInputTextBox", AccessibleName = "Viewer input text" };
        _target.MouseDown += (_, args) => ObserveMouse(DesktopViewerInputEventKind.MouseDown, "textBox", args);
        _target.MouseUp += (_, args) => ObserveMouse(DesktopViewerInputEventKind.MouseUp, "textBox", args);
        _target.MouseWheel += (_, args) => ObserveMouse(DesktopViewerInputEventKind.MouseWheel, "textBox", args);
        _target.KeyDown += (_, args) => { Interlocked.Increment(ref _keyDown); _viewerReceipt?.Key(DesktopViewerInputEventKind.KeyDown, args); ViewerInputChanged(); };
        _target.KeyUp += (_, args) => { Interlocked.Increment(ref _keyUp); _viewerReceipt?.Key(DesktopViewerInputEventKind.KeyUp, args); ViewerInputChanged(); };
        _target.TextChanged += (_, _) => { _viewerReceipt?.Text(_target.Text.Length); ViewerInputChanged(); };
        Controls.Add(_target);
        _paintTimer = new System.Windows.Forms.Timer { Interval = 80 };
        _paintTimer.Tick += (_, _) => { Interlocked.Increment(ref _paints); Invalidate(); };
        if (mode == DesktopSmokeMode.ViewerInput)
        {
            var receipt = new DesktopViewerInputReceipt(evidence);
            _viewerReceipt = receipt;
            _viewerClickTarget = new Button
            {
                Name = "ViewerClickTarget", AccessibleName = "Viewer click target", Text = "CLICK TARGET / 点击区域",
                Bounds = new Rectangle(90, 370, 640, 100), Font = new Font("Segoe UI", 24), TabStop = false
            };
            _viewerClickTarget.MouseDown += (_, args) => ObserveMouse(DesktopViewerInputEventKind.MouseDown, "clickTarget", args);
            _viewerClickTarget.MouseUp += (_, args) => ObserveMouse(DesktopViewerInputEventKind.MouseUp, "clickTarget", args);
            _viewerClickTarget.Click += (_, _) => { receipt.Click(); ViewerInputChanged(); };
            Controls.Add(_viewerClickTarget);
            _viewerReceiptTimer = new System.Windows.Forms.Timer { Interval = 250 };
            _viewerReceiptTimer.Tick += (_, _) => FlushViewerObservation();
        }
        Shown += Run;
        FormClosing += (_, args) =>
        {
            if (_finished) return;
            args.Cancel = true;
            if (_mode == DesktopSmokeMode.ViewerInput) _viewerCompletionReason = "window-closed";
            _lifetime.Cancel();
        };
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        var viewer = _mode == DesktopSmokeMode.ViewerInput;
        e.Graphics.DrawString(viewer ? "SkyBridge · Mac viewer input validation" : "SkyBridge · Native desktop validation", Font, Brushes.White, 90, 70);
        e.Graphics.DrawString(viewer ? "Click the target, then click the text box and type from the Mac viewer." :
            "DXGI → H.264 · 720p/2 FPS validation + 1080p throughput", Font, Brushes.LightSteelBlue, 90, 135);
        e.Graphics.DrawString(viewer ? "Observed input only · no local input injection · closes after 20 minutes" :
            "Keyboard and mouse target (this window only)", Font, Brushes.White, 90, 205);
        e.Graphics.FillRectangle(Brushes.OrangeRed, 15, 15, 36, 36);
        e.Graphics.FillRectangle(Brushes.LimeGreen, ClientSize.Width - 51, 15, 36, 36);
        e.Graphics.FillRectangle(Brushes.DodgerBlue, 15, ClientSize.Height - 51, 36, 36);
        e.Graphics.FillRectangle(Brushes.Gold, ClientSize.Width - 51, ClientSize.Height - 51, 36, 36);
        if (viewer)
        {
            e.Graphics.DrawString($"Keys ↓{_keyDown} ↑{_keyUp} · Mouse ↓{_mouseDown} ↑{_mouseUp} · Target clicks {_viewerReceipt?.ClickTargetClicks ?? 0}",
                Font, Brushes.White, 90, 540);
            return;
        }
        var frame = Volatile.Read(ref _paints);
        e.Graphics.FillRectangle(Brushes.Cyan, 90 + frame % 120 * 5, 400, 100, 80);
        e.Graphics.DrawString($"Animation update {frame:D4}", Font, Brushes.White, 90, 520);
    }

    private async void Run(object? sender, EventArgs args)
    {
        if (_mode == DesktopSmokeMode.ViewerInput)
        {
            await RunViewerInputAsync();
            return;
        }
        try
        {
            _paintTimer.Start();
            await Task.Delay(750, _lifetime.Token);
            using var process = Process.GetCurrentProcess();
            Require(process.SessionId > 0, "Native smoke is running in SSH/session 0.");
            WindowsInteractiveDesktop.RequireAvailable();
            Log($"interactive session={process.SessionId} window={Handle}");
            var display = WindowsDesktopCapture.EnumerateDisplays().Single(item => item.IsPrimary);
            Log($"display width={display.Width} height={display.Height}");
            Activate(); _target.Focus();
            await Task.Delay(150, _lifetime.Token);
            await ValidateInputAsync(display);
            await File.WriteAllTextAsync(Path.Combine(_evidence, "native-input.json"), JsonSerializer.Serialize(new
            {
                Status = "passed", SessionId = process.SessionId, TextObserved = _target.Text, InputTargetOwned = true,
                MouseDownEvents = _mouseDown, MouseUpEvents = _mouseUp, KeyDownEvents = _keyDown, KeyUpEvents = _keyUp,
                NativeModifierReleased = true
            }, new JsonSerializerOptions { WriteIndented = true }));
            var ownedBounds = RectangleToScreen(ClientRectangle);
            var video = await Task.Run(() => ValidateVideoAsync(display, ownedBounds, _lifetime.Token), _lifetime.Token);
            await File.WriteAllTextAsync(Path.Combine(_evidence, "native-video.json"), JsonSerializer.Serialize(video, new JsonSerializerOptions { WriteIndented = true }));
            _paintTimer.Interval = 16;
            if (_gpuScaling)
            {
                var baseline = await Task.Run(() => MeasureVideoThroughputAsync(display, false,
                    "desktop-1080p-cpu-baseline.h264", _lifetime.Token), _lifetime.Token);
                await File.WriteAllTextAsync(Path.Combine(_evidence, "native-video-cpu-baseline.json"),
                    JsonSerializer.Serialize(baseline, new JsonSerializerOptions { WriteIndented = true }));
            }
            var throughput = await Task.Run(() => MeasureVideoThroughputAsync(display, _gpuScaling,
                "desktop-1080p-throughput.h264", _lifetime.Token), _lifetime.Token);
            await File.WriteAllTextAsync(Path.Combine(_evidence, "native-video-throughput.json"), JsonSerializer.Serialize(throughput, new JsonSerializerOptions { WriteIndented = true }));
            var endpoints = DesktopAudioEndpointProbe.Read();
            await File.WriteAllTextAsync(Path.Combine(_evidence, "native-audio-endpoints.json"), JsonSerializer.Serialize(endpoints, new JsonSerializerOptions { WriteIndented = true }));
            var audio = await ValidateAudioAsync(_lifetime.Token);
            var result = new
            {
                Profile = "windows-desktop-backend-native", Status = "completed", SessionId = process.SessionId,
                CaptureBackend = "DXGI Desktop Duplication", VideoEncoder = "Media Foundation system H.264",
                HardwareVideoEncoding = false, GpuCaptureScaling = _gpuScaling, InputTargetOwned = true, TextObserved = _target.Text,
                MouseDownEvents = _mouseDown, MouseUpEvents = _mouseUp, KeyDownEvents = _keyDown, KeyUpEvents = _keyUp,
                NativeModifierReleased = true, CaptureRecreatedAfterDispose = true, Video = video, Audio = audio
            };
            await File.WriteAllTextAsync(Path.Combine(_evidence, "native-result.json"), JsonSerializer.Serialize(result, new JsonSerializerOptions { WriteIndented = true }));
            Log("native desktop backend smoke: completed");
            ExitCode = 0;
        }
        catch (Exception failure)
        {
            Log(failure.ToString());
            await File.WriteAllTextAsync(Path.Combine(_evidence, "native-result.json"), JsonSerializer.Serialize(new
            {
                Profile = "windows-desktop-backend-native", Status = "failed", Error = failure.ToString()
            }, new JsonSerializerOptions { WriteIndented = true }));
        }
        finally
        {
            _finished = true;
            _paintTimer.Stop();
            Close();
        }
    }

    private void ObserveMouse(DesktopViewerInputEventKind kind, string target, MouseEventArgs args)
    {
        if (kind == DesktopViewerInputEventKind.MouseDown) Interlocked.Increment(ref _mouseDown);
        if (kind == DesktopViewerInputEventKind.MouseUp) Interlocked.Increment(ref _mouseUp);
        _viewerReceipt?.Mouse(kind, target, args);
        ViewerInputChanged();
    }

    private void ViewerInputChanged()
    {
        if (_mode != DesktopSmokeMode.ViewerInput) return;
        _viewerReceiptDirty = true;
        Invalidate();
    }

    private void WriteViewerReceipt(string status, string? reason, Exception? failure)
    {
        var receipt = _viewerReceipt ?? throw new InvalidOperationException("Viewer receipt was not initialized.");
        var target = _viewerClickTarget ?? throw new InvalidOperationException("Viewer click target was not initialized.");
        receipt.Write(this, _target, target, status, reason, _mouseDown, _mouseUp, _keyDown, _keyUp, failure);
    }

    private void FlushViewerObservation()
    {
        if (!_viewerReceiptDirty || _finished) return;
        try
        {
            WriteViewerReceipt("running", null, null);
            _viewerReceiptDirty = false;
        }
        catch (Exception failure)
        {
            _viewerFailure = failure;
            _viewerCompletionReason = "receipt-write-failed";
            _viewerReceiptTimer?.Stop();
            _lifetime.Cancel();
        }
    }

    private async Task RunViewerInputAsync()
    {
        try
        {
            WindowsInteractiveDesktop.RequireAvailable();
            WriteViewerReceipt("running", null, null);
            var timer = _viewerReceiptTimer ?? throw new InvalidOperationException("Viewer receipt timer was not initialized.");
            timer.Start();
            try { await Task.Delay(Timeout.InfiniteTimeSpan, _lifetime.Token); }
            catch (OperationCanceledException) when (_lifetime.IsCancellationRequested) { }
        }
        catch (Exception failure)
        {
            _viewerFailure = failure;
            _viewerCompletionReason ??= "initialization-failed";
        }
        finally
        {
            _viewerReceiptTimer?.Stop();
            _viewerCompletionReason ??= "deadline";
            ExitCode = _viewerFailure is null ? 0 : 1;
            try { WriteViewerReceipt(ExitCode == 0 ? "completed" : "failed", _viewerCompletionReason, _viewerFailure); }
            catch (Exception failure)
            {
                ExitCode = 1;
                Console.Error.WriteLine(_viewerFailure is null ? failure : new AggregateException(_viewerFailure, failure));
            }
            _finished = true;
            Close();
        }
    }

    private async Task ValidateInputAsync(WindowsDesktopDisplay display)
    {
        RequireForeground();
        Require((GetAsyncKeyState(0xa0) & 0x8000) == 0 && (GetAsyncKeyState(0xa2) & 0x8000) == 0,
            "A local Shift/Control key is held; input smoke will not interfere with it.");
        using var input = new WindowsRemoteInput(display);
        var target = _target.PointToScreen(new Point(50, _target.Height / 2));
        RequireForeground();
        input.MovePointer((target.X - display.Left) / (double)(display.Width - 1), (target.Y - display.Top) / (double)(display.Height - 1));
        input.SetMouseButton(WindowsRemoteMouseButton.Left, true);
        input.SetMouseButton(WindowsRemoteMouseButton.Left, false);
        await Task.Delay(100, _lifetime.Token);
        RequireForeground();
        input.SetKey(0x38, true); input.SetKey(0x00, true); input.SetKey(0x00, false); input.SetKey(0x38, false);
        input.TypeText(" 验证🌐");
        await Task.Delay(200, _lifetime.Token);
        Require(_target.Text == "A 验证🌐", "The owned textbox did not receive exact physical-key and Unicode input: " + _target.Text);
        Require(_mouseDown > 0 && _mouseUp > 0 && _keyDown > 0 && _keyUp > 0, "The owned window did not observe real input events.");
        RequireForeground();
        input.SetKey(0x3b, true);
        await Task.Delay(100, _lifetime.Token);
        Require((GetAsyncKeyState(0xa2) & 0x8000) != 0, "The Windows input state did not observe the remote Control press.");
        input.ReleaseAll();
        await Task.Delay(100, _lifetime.Token);
        Require((GetAsyncKeyState(0xa2) & 0x8000) == 0, "Remote Control remained down after ReleaseAll.");
        Log("owned-window input and native modifier release: passed");
    }

    private async Task<object> ValidateVideoAsync(WindowsDesktopDisplay display, Rectangle ownedBounds, CancellationToken token)
    {
        var times = new List<double>();
        var changes = 0;
        var totalBytes = 0L;
        byte[]? previous = null;
        var watch = Stopwatch.StartNew();
        using (var capture = _gpuScaling ? new WindowsDesktopCapture(display.Id, 1280, 720) : new WindowsDesktopCapture(display.Id))
        using (var encoder = new WindowsDesktopEncoder(new(1280, 720, 2, 1_500_000)))
        using (var stream = File.Create(Path.Combine(_evidence, "desktop-720p-2fps.h264")))
        {
            PeriodicTimer? timer = null;
            try
            {
            while (times.Count < 8)
            {
                token.ThrowIfCancellationRequested();
                if (watch.Elapsed > TimeSpan.FromSeconds(12)) throw new TimeoutException("DXGI/MF did not produce eight live desktop frames.");
                using var frame = await capture.CaptureAsync(TimeSpan.FromMilliseconds(100), token);
                if (frame is not null)
                {
                    var pixels = frame.BgraPixels;
                    if (previous is not null && !pixels.Span.SequenceEqual(previous)) changes++;
                    if (previous is null) SaveOwnedSnapshot(frame, ownedBounds, display);
                    previous = pixels.ToArray();
                    foreach (var encoded in encoder.Encode(frame, times.Count % 4 == 0))
                    {
                        Require(encoded.Width == 1280 && encoded.Height == 720, "MF output dimensions did not honor 720p configuration.");
                        Require(encoded.TimestampUnixSeconds > 1_700_000_000, "The encoded timestamp is not UTC Unix seconds.");
                        if (times.Count == 0) Require(encoded.IsKeyFrame, "The first frame is not an IDR frame.");
                        stream.Write(encoded.H264Bytes);
                        totalBytes += encoded.H264Bytes.Length;
                        // The first output initializes the processor/encoder. Start
                        // the pacing clock afterwards so no stale timer tick can burst.
                        if (times.Count == 0) { watch.Restart(); timer = new PeriodicTimer(TimeSpan.FromMilliseconds(500)); }
                        times.Add(watch.Elapsed.TotalSeconds);
                    }
                }
                if (times.Count < 8 && timer is not null) await timer.WaitForNextTickAsync(token);
            }
            }
            finally { timer?.Dispose(); }
        }
        Require(changes >= 3, "DXGI captured no meaningful changing desktop content.");
        var fps = (times.Count - 1) / (times[^1] - times[0]);
        Require(fps is >= 1.5 and <= 2.05, $"Observed steady frame rate {fps:F3} did not honor the 2 FPS configuration.");
        // A process can hold only one duplication per output. Reopening proves the
        // first capture released its actual native duplication, not just a flag.
        using (var replacement = new WindowsDesktopCapture(display.Id))
        using (var frame = await replacement.CaptureAsync(TimeSpan.FromSeconds(1), token))
            Require(frame is not null, "DXGI could not acquire after exact capture disposal and recreation.");
        Log($"video frames={times.Count} changes={changes} bytes={totalBytes} observedFps={fps:F3}");
        return new { Status = "passed", Width = 1280, Height = 720, FrameCount = times.Count, PixelChanges = changes, Bytes = totalBytes, ObservedFps = fps,
            CaptureRecreatedAfterDispose = true, HardwareVideoEncoding = false, GpuCaptureScaling = _gpuScaling, OutputTimesSeconds = times };
    }

    private void SaveOwnedSnapshot(WindowsDesktopFrame frame, Rectangle ownedBounds, WindowsDesktopDisplay display)
    {
        using var bitmap = new Bitmap(frame.Width, frame.Height, PixelFormat.Format32bppArgb);
        var locked = bitmap.LockBits(new Rectangle(0, 0, bitmap.Width, bitmap.Height), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        try
        {
            var pixels = frame.BgraPixels.ToArray();
            for (var row = 0; row < frame.Height; row++) Marshal.Copy(pixels, row * frame.Stride, locked.Scan0 + row * locked.Stride, frame.Stride);
        }
        finally { bitmap.UnlockBits(locked); }
        var scaleX = frame.Width / (double)display.Width;
        var scaleY = frame.Height / (double)display.Height;
        var region = Rectangle.Intersect(new Rectangle(0, 0, frame.Width, frame.Height), Rectangle.FromLTRB(
            (int)Math.Floor((ownedBounds.Left - display.Left) * scaleX),
            (int)Math.Floor((ownedBounds.Top - display.Top) * scaleY),
            (int)Math.Ceiling((ownedBounds.Right - display.Left) * scaleX),
            (int)Math.Ceiling((ownedBounds.Bottom - display.Top) * scaleY)));
        Require(region.Width > 0 && region.Height > 0, "The owned test window is not on the selected capture display.");
        using var cropped = bitmap.Clone(region, PixelFormat.Format24bppRgb);
        cropped.Save(Path.Combine(_evidence, "native-owned-window.png"), ImageFormat.Png);
        Require(cropped.Width > 66 && cropped.Height > 66, "The owned capture region cannot contain its corner markers.");
        foreach (var marker in new[]
        {
            (X: 33, Y: 33, Color: Color.OrangeRed),
            (X: ownedBounds.Width - 33, Y: 33, Color: Color.LimeGreen),
            (X: 33, Y: ownedBounds.Height - 33, Color: Color.DodgerBlue),
            (X: ownedBounds.Width - 33, Y: ownedBounds.Height - 33, Color: Color.Gold)
        })
            Require(cropped.GetPixel(
                (int)Math.Round((ownedBounds.Left - display.Left + marker.X) * scaleX) - region.Left,
                (int)Math.Round((ownedBounds.Top - display.Top + marker.Y) * scaleY) - region.Top).ToArgb() == marker.Color.ToArgb(),
                "The initial DXGI frame did not preserve the owned window's four corner markers.");
    }

    private async Task<object> MeasureVideoThroughputAsync(WindowsDesktopDisplay display, bool gpuScaling, string fileName, CancellationToken token)
    {
        using var capture = gpuScaling ? new WindowsDesktopCapture(display.Id, 1920, 1080) : new WindowsDesktopCapture(display.Id);
        using var encoder = new WindowsDesktopEncoder(new(1920, 1080, 30, 8_000_000));
        await using var stream = File.Create(Path.Combine(_evidence, fileName));
        using (var first = await capture.CaptureAsync(TimeSpan.FromSeconds(2), token) ??
            throw new TimeoutException("The desktop produced no initial image for the throughput measurement."))
        {
            var initial = encoder.Encode(first, true);
            Require(initial.Count == 1 && initial[0].IsKeyFrame, "The throughput stream must start with a real H.264 IDR.");
            await stream.WriteAsync(initial[0].H264Bytes, token);
        }
        var captureMilliseconds = new List<double>();
        var encodeMilliseconds = new List<double>();
        var outputTimes = new List<double>();
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(1d / 30));
        var measurement = Stopwatch.StartNew();
        while (measurement.Elapsed < TimeSpan.FromSeconds(3))
        {
            await timer.WaitForNextTickAsync(token);
            var phase = Stopwatch.StartNew();
            using var frame = await capture.CaptureAsync(TimeSpan.FromMilliseconds(100), token);
            if (frame is null) continue;
            captureMilliseconds.Add(phase.Elapsed.TotalMilliseconds);
            phase.Restart();
            var encoded = encoder.Encode(frame);
            encodeMilliseconds.Add(phase.Elapsed.TotalMilliseconds);
            foreach (var item in encoded)
            {
                outputTimes.Add(measurement.Elapsed.TotalSeconds);
                await stream.WriteAsync(item.H264Bytes, token);
            }
        }
        Require(outputTimes.Count > 0, "The encoder produced no steady-state frames during the throughput measurement.");
        var elapsed = measurement.Elapsed.TotalSeconds;
        var fps = outputTimes.Count / elapsed;
        Log($"throughput 1920x1080 targetFps=30 observedFps={fps:F3} frames={outputTimes.Count} gpuScaling={gpuScaling} encoderHardware=false");
        return new
        {
            Status = "measured", Width = 1920, Height = 1080, TargetFps = 30, HardwareVideoEncoding = false, GpuCaptureScaling = gpuScaling,
            StimulusIntervalMilliseconds = 16,
            WarmupFramesExcluded = 1, FrameCount = outputTimes.Count, ElapsedSeconds = elapsed, ObservedFps = fps,
            EncodeP50Milliseconds = Percentile(encodeMilliseconds, 0.50), EncodeP95Milliseconds = Percentile(encodeMilliseconds, 0.95),
            CaptureP50Milliseconds = Percentile(captureMilliseconds, 0.50), CaptureP95Milliseconds = Percentile(captureMilliseconds, 0.95),
            OutputTimesSeconds = outputTimes
        };
    }

    private static double Percentile(List<double> values, double percentile)
    {
        var ordered = values.Order().ToArray();
        return ordered[Math.Clamp((int)Math.Ceiling(ordered.Length * percentile) - 1, 0, ordered.Length - 1)];
    }

    private async Task<object> ValidateAudioAsync(CancellationToken token)
    {
        using var decoder = OpusCodecFactory.CreateDecoder(48_000, 2);
        await using var source = new WindowsLoopbackAudioSource();
        using var wave = new MemoryStream(BuildTone());
        using var player = new SoundPlayer(wave);
        var packets = 0;
        var maximumToneAmplitude = 0d;
        ulong? lastTimestamp = null;
        await source.StartAsync((frame, cancellationToken) =>
        {
            cancellationToken.ThrowIfCancellationRequested();
            var decoded = new short[1920];
            Require(decoder.Decode(frame.Payload, decoded, 960) == 960, "Captured Opus did not decode as 20ms stereo.");
            if (lastTimestamp is { } last) Require(frame.TimestampSamples > last, "Captured audio timestamps did not advance.");
            lastTimestamp = frame.TimestampSamples;
            double sine = 0, cosine = 0;
            for (var index = 0; index < 960; index++)
            {
                var phase = 2 * Math.PI * 1000 * index / 48000;
                sine += decoded[index * 2] * Math.Sin(phase);
                cosine += decoded[index * 2] * Math.Cos(phase);
            }
            maximumToneAmplitude = Math.Max(maximumToneAmplitude, 2 * Math.Sqrt(sine * sine + cosine * cosine) / 960);
            packets++;
            return ValueTask.CompletedTask;
        }, "low-latency", token);
        try
        {
            player.PlayLooping();
            await Task.Delay(TimeSpan.FromSeconds(2), token);
        }
        finally { player.Stop(); await source.StopAsync(CancellationToken.None); }
        await source.Completion;
        var stoppedCount = source.EncodedFrames;
        await Task.Delay(100, token);
        Require(source.EncodedFrames == stoppedCount, "Audio encoding continued after native capture stopped.");
        Require(packets >= 20 && maximumToneAmplitude > 30, "Loopback/Opus did not preserve the controlled 1kHz tone; the render endpoint may be unavailable or muted.");
        Log($"audio packets={packets} matched1kHzAmplitude={maximumToneAmplitude:F2} captureStopped=true");
        return new { Packets = packets, MatchedToneAmplitude = maximumToneAmplitude, source.CapturedFrames, source.EncodedFrames, source.Discontinuities, Stopped = true };
    }

    private static byte[] BuildTone()
    {
        const int samples = 48000;
        using var stream = new MemoryStream();
        using var writer = new BinaryWriter(stream);
        writer.Write("RIFF"u8); writer.Write(36 + samples * 4); writer.Write("WAVEfmt "u8);
        writer.Write(16); writer.Write((ushort)1); writer.Write((ushort)2); writer.Write(48000);
        writer.Write(192000); writer.Write((ushort)4); writer.Write((ushort)16); writer.Write("data"u8); writer.Write(samples * 4);
        for (var index = 0; index < samples; index++)
        {
            var value = (short)(491 * Math.Sin(2 * Math.PI * 1000 * index / 48000));
            writer.Write(value); writer.Write(value);
        }
        return stream.ToArray();
    }

    private void RequireForeground() => Require(GetForegroundWindow() == Handle, "The owned test window lost foreground; refusing to inject into another application.");
    private static void Require(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
    private void Log(string message) { lock (_log) { _log.WriteLine($"{DateTimeOffset.UtcNow:O} {message}"); } }
    protected override void Dispose(bool disposing)
    {
        if (disposing) { _viewerReceiptTimer?.Dispose(); _viewerClickTarget?.Dispose(); _paintTimer.Dispose(); _lifetime.Dispose(); _target.Dispose(); _log.Dispose(); }
        base.Dispose(disposing);
    }
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int keyCode);
}

internal static class DesktopAudioEndpointProbe
{
    internal static object Read()
    {
        Marshal.ThrowExceptionForHR(CoInitializeEx(IntPtr.Zero, 2));
        try { return ReadInitialized(); }
        finally { CoUninitialize(); }
    }

    private static object ReadInitialized()
    {
        using var process = Process.GetCurrentProcess();
        var classId = new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E");
        var interfaceId = typeof(IDeviceEnumerator).GUID;
        Marshal.ThrowExceptionForHR(CoCreateInstance(in classId, IntPtr.Zero, 1, in interfaceId, out var enumerator));
        try
        {
            Marshal.ThrowExceptionForHR(enumerator.EnumAudioEndpoints(0, 1, out var active));
            uint activeCount;
            try { Marshal.ThrowExceptionForHR(active.GetCount(out activeCount)); }
            finally { Marshal.ReleaseComObject(active); }
            Marshal.ThrowExceptionForHR(enumerator.EnumAudioEndpoints(0, 15, out var all));
            var states = new List<uint>();
            try
            {
                Marshal.ThrowExceptionForHR(all.GetCount(out var count));
                for (uint index = 0; index < count; index++)
                {
                    Marshal.ThrowExceptionForHR(all.Item(index, out var device));
                    try { Marshal.ThrowExceptionForHR(device.GetState(out var state)); states.Add(state); }
                    finally { Marshal.ReleaseComObject(device); }
                }
            }
            finally { Marshal.ReleaseComObject(all); }
            var roles = new List<object>();
            foreach (var role in new[] { (Id: 0, Name: "console"), (Id: 1, Name: "multimedia"), (Id: 2, Name: "communications") })
            {
                var result = enumerator.GetDefaultAudioEndpoint(0, role.Id, out var device);
                uint? state = null;
                if (result >= 0 && device is not null)
                {
                    try { Marshal.ThrowExceptionForHR(device.GetState(out var value)); state = value; }
                    finally { Marshal.ReleaseComObject(device); }
                }
                else if (result != unchecked((int)0x80070490)) Marshal.ThrowExceptionForHR(result);
                roles.Add(new { Role = role.Name, HResult = $"0x{result:X8}", State = state });
            }
            return new { Profile = "windows-audio-endpoint-diagnostic", SessionId = process.SessionId, ActiveRenderEndpointCount = activeCount, RenderEndpointStates = states, DefaultRoles = roles };
        }
        finally { Marshal.ReleaseComObject(enumerator); }
    }

    [DllImport("ole32.dll", ExactSpelling = true)]
    private static extern int CoCreateInstance(in Guid classId, IntPtr outer, uint context, in Guid interfaceId, out IDeviceEnumerator enumerator);
    [DllImport("ole32.dll", ExactSpelling = true)] private static extern int CoInitializeEx(IntPtr reserved, uint model);
    [DllImport("ole32.dll", ExactSpelling = true)] private static extern void CoUninitialize();
    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IDeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(int flow, uint stateMask, out IDeviceCollection devices);
        [PreserveSig] int GetDefaultAudioEndpoint(int flow, int role, out IDevice? device);
    }
    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IDeviceCollection
    {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int Item(uint index, out IDevice device);
    }
    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IDevice
    {
        [PreserveSig] int Activate(in Guid iid, uint context, IntPtr activationParameters, out IntPtr instance);
        [PreserveSig] int OpenPropertyStore(uint access, out IntPtr properties);
        [PreserveSig] int GetId(out IntPtr id);
        [PreserveSig] int GetState(out uint state);
    }
}
