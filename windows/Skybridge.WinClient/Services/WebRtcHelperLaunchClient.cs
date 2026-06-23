using System;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

/// <summary>
/// Launches the SkyBridge WebRTC DataChannel helper (Skybridge.WebRtcHelper.exe) as the OFFERER
/// for a single paired peer, then returns the path to the fresh proof JSON the helper emits.
///
/// Contract (matches windows/Skybridge.WebRtcHelper/Program.cs):
///   Skybridge.WebRtcHelper.exe --mode offer
///       --peer-device-id  &lt;DeviceId&gt;                (real paired identity)
///       --peer-fingerprint &lt;PublicKeyFingerprint&gt;    (64 lowercase hex)
///       --proof-out  &lt;freshProofPath&gt;
///       --offer-out  &lt;offer.json&gt;
///       --answer-in  &lt;answer.json&gt;
///       [--ice-servers &lt;csv&gt;]
///
/// The helper returns exit code 0 ONLY when it reached a live DataChannel AND verified the SBF1
/// echo (Program.CompleteOffererAsync). It returns non-zero otherwise. So "exit 0" == a real,
/// verified DataChannel was opened against the peer's answerer.
///
/// IMPORTANT (honest scope): this service only launches the OFFERER and produces the proof. A
/// reachable ANSWER peer (the Apple side, or a second box running `--mode answer`) MUST be writing
/// the answer file at <c>--answer-in</c>, or the offerer blocks waiting for the answer and then
/// times out with a non-zero exit. The offer/answer file exchange + the Apple-side answerer is a
/// SEPARATE integration item; this service makes the signaling file paths + ICE servers
/// configurable so that exchange can be wired without touching this code.
/// </summary>
public interface IWebRtcHelperLaunchClient
{
    /// <summary>
    /// Launches the offerer helper for the given paired peer and waits for it to exit. On exit 0
    /// (live DataChannel + verified SBF1 echo) returns the fresh proof file path. Throws fail-closed
    /// on any non-zero exit, missing exe, or missing proof.
    /// </summary>
    Task<WebRtcHelperLaunchResult> LaunchOffererAsync(
        WebRtcHelperLaunchRequest request,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Launches the helper in DATA-PLANE session mode (<c>--mode session-offer</c> or
    /// <c>--mode session-answer</c>). Unlike the one-shot offerer, this process does NOT exit on
    /// success: it opens the loopback SBF1 IPC and runs the persistent bidirectional pump. This
    /// method starts the process, waits for the helper to print its bound IPC port
    /// (<c>SKYBRIDGE_DATAPLANE_PORT=&lt;n&gt;</c>) once the DataChannel is open, and returns a live
    /// <see cref="WebRtcHelperSession"/> that owns the process and exposes the port to connect
    /// <see cref="SkyBridgeDataPlaneClient"/> to. Disposing the session stops the helper.
    /// Fail-closed: if the helper exits or never reports a port within the timeout, throws.
    /// </summary>
    Task<WebRtcHelperSession> LaunchSessionAsync(
        WebRtcHelperSessionRequest request,
        CancellationToken cancellationToken = default);
}

public sealed class WebRtcHelperLaunchClient : IWebRtcHelperLaunchClient
{
    private readonly WebRtcHelperLaunchOptions _options;

    public WebRtcHelperLaunchClient(WebRtcHelperLaunchOptions options)
    {
        _options = options ?? throw new ArgumentNullException(nameof(options));
    }

    public async Task<WebRtcHelperLaunchResult> LaunchOffererAsync(
        WebRtcHelperLaunchRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);

        var deviceId = (request.PeerDeviceId ?? string.Empty).Trim();
        if (string.IsNullOrEmpty(deviceId))
        {
            throw new InvalidOperationException(
                "WebRTC helper launch requires a real paired peer device id; refusing to launch a placeholder-bound offerer.");
        }

        var fingerprint = (request.PeerPublicKeyFingerprint ?? string.Empty).Trim();
        if (!IsLowerHexFingerprint(fingerprint))
        {
            throw new InvalidOperationException(
                "WebRTC helper launch requires a 64 lowercase hex peer public key fingerprint from the paired material.");
        }

        var helperPath = _options.HelperExecutablePath;
        if (!File.Exists(helperPath))
        {
            throw new InvalidOperationException(
                $"WebRTC helper executable was not found at '{helperPath}'. " +
                "Set SKYBRIDGE_WINDOWS_WEBRTC_HELPER_PATH to the built Skybridge.WebRtcHelper.exe, " +
                "or place it next to the app.");
        }

        var proofPath = _options.ResolveProofPath();
        var offerPath = _options.ResolveOfferPath();
        var answerPath = _options.ResolveAnswerPath();

        // A stale proof from a previous run must never satisfy the freshness gate. Remove it before
        // launch so a missing proof after a non-zero exit fails closed instead of replaying old bytes.
        DeleteStaleFile(proofPath);

        var startInfo = new ProcessStartInfo
        {
            FileName = helperPath,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = _options.WorkingDirectory,
        };
        startInfo.ArgumentList.Add("--mode");
        startInfo.ArgumentList.Add("offer");
        startInfo.ArgumentList.Add("--peer-device-id");
        startInfo.ArgumentList.Add(deviceId);
        startInfo.ArgumentList.Add("--peer-fingerprint");
        startInfo.ArgumentList.Add(fingerprint);
        startInfo.ArgumentList.Add("--proof-out");
        startInfo.ArgumentList.Add(proofPath);
        startInfo.ArgumentList.Add("--offer-out");
        startInfo.ArgumentList.Add(offerPath);
        startInfo.ArgumentList.Add("--answer-in");
        startInfo.ArgumentList.Add(answerPath);
        if (!string.IsNullOrWhiteSpace(_options.IceServersCsv))
        {
            startInfo.ArgumentList.Add("--ice-servers");
            startInfo.ArgumentList.Add(_options.IceServersCsv!.Trim());
        }

        using var process = new Process { StartInfo = startInfo };
        var stdout = new StringBuilder();
        var stderr = new StringBuilder();
        process.OutputDataReceived += (_, e) =>
        {
            if (e.Data is not null)
            {
                stdout.AppendLine(e.Data);
            }
        };
        process.ErrorDataReceived += (_, e) =>
        {
            if (e.Data is not null)
            {
                stderr.AppendLine(e.Data);
            }
        };

        try
        {
            if (!process.Start())
            {
                throw new InvalidOperationException(
                    $"Failed to start the WebRTC helper process at '{helperPath}'.");
            }
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            throw new InvalidOperationException(
                $"Failed to launch the WebRTC helper at '{helperPath}': {ex.Message}", ex);
        }

        process.BeginOutputReadLine();
        process.BeginErrorReadLine();

        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutCts.CancelAfter(_options.LaunchTimeout);

        try
        {
            await process.WaitForExitAsync(timeoutCts.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (timeoutCts.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
        {
            TryKill(process);
            throw new InvalidOperationException(
                $"WebRTC helper did not complete a verified DataChannel within {_options.LaunchTimeout.TotalSeconds:F0}s. " +
                "A reachable answer peer (Apple side or a second box running `--mode answer`) writing " +
                $"'{answerPath}' is required for the offerer to reach exit 0.");
        }
        catch (OperationCanceledException)
        {
            TryKill(process);
            throw;
        }

        if (process.ExitCode != 0)
        {
            throw new InvalidOperationException(
                $"WebRTC helper exited with code {process.ExitCode}; no verified DataChannel was established. " +
                $"stderr: {Trim(stderr.ToString())}");
        }

        if (!File.Exists(proofPath))
        {
            throw new InvalidOperationException(
                "WebRTC helper exited 0 but did not write the proof file; refusing to proceed without a fresh proof.");
        }

        return new WebRtcHelperLaunchResult(proofPath, offerPath, answerPath);
    }

    public async Task<WebRtcHelperSession> LaunchSessionAsync(
        WebRtcHelperSessionRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);

        var mode = request.AsAnswerer ? "session-answer" : "session-offer";

        var helperPath = _options.HelperExecutablePath;
        if (!File.Exists(helperPath))
        {
            throw new InvalidOperationException(
                $"WebRTC helper executable was not found at '{helperPath}'. " +
                "Set SKYBRIDGE_WINDOWS_WEBRTC_HELPER_PATH to the built Skybridge.WebRtcHelper.exe, " +
                "or place it next to the app.");
        }

        var offerPath = _options.ResolveOfferPath();
        var answerPath = _options.ResolveAnswerPath();
        var ipcToken = GenerateIpcToken();

        var startInfo = new ProcessStartInfo
        {
            FileName = helperPath,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = _options.WorkingDirectory,
        };
        startInfo.ArgumentList.Add("--mode");
        startInfo.ArgumentList.Add(mode);
        // Offerer writes offer.json / reads answer.json; answerer is the mirror.
        startInfo.ArgumentList.Add("--offer-out");
        startInfo.ArgumentList.Add(offerPath);
        startInfo.ArgumentList.Add("--answer-in");
        startInfo.ArgumentList.Add(answerPath);
        startInfo.ArgumentList.Add("--offer-in");
        startInfo.ArgumentList.Add(offerPath);
        startInfo.ArgumentList.Add("--answer-out");
        startInfo.ArgumentList.Add(answerPath);
        // 0 => OS-chosen free loopback port; the helper prints the actual port.
        startInfo.ArgumentList.Add("--ipc-port");
        startInfo.ArgumentList.Add(request.PreferredIpcPort.ToString());
        startInfo.ArgumentList.Add("--ipc-token");
        startInfo.ArgumentList.Add(ipcToken);
        if (!string.IsNullOrWhiteSpace(_options.IceServersCsv))
        {
            startInfo.ArgumentList.Add("--ice-servers");
            startInfo.ArgumentList.Add(_options.IceServersCsv!.Trim());
        }

        var process = new Process { StartInfo = startInfo };
        var portTcs = new TaskCompletionSource<int>(TaskCreationOptions.RunContinuationsAsynchronously);
        var stderr = new StringBuilder();

        process.OutputDataReceived += (_, e) =>
        {
            if (e.Data is null)
            {
                return;
            }

            // The helper prints "SKYBRIDGE_DATAPLANE_PORT=<n>" once the DataChannel
            // is open and the loopback IPC is bound. That is our "ready" signal.
            const string marker = "SKYBRIDGE_DATAPLANE_PORT=";
            var idx = e.Data.IndexOf(marker, StringComparison.Ordinal);
            if (idx >= 0 && int.TryParse(e.Data.AsSpan(idx + marker.Length).Trim(), out var port))
            {
                portTcs.TrySetResult(port);
            }
        };
        process.ErrorDataReceived += (_, e) =>
        {
            if (e.Data is not null)
            {
                stderr.AppendLine(e.Data);
            }
        };

        try
        {
            if (!process.Start())
            {
                process.Dispose();
                throw new InvalidOperationException(
                    $"Failed to start the WebRTC helper process at '{helperPath}'.");
            }
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            process.Dispose();
            throw new InvalidOperationException(
                $"Failed to launch the WebRTC helper at '{helperPath}': {ex.Message}", ex);
        }

        process.BeginOutputReadLine();
        process.BeginErrorReadLine();

        // If the helper exits before reporting a port, fail closed (no peer answer,
        // signaling never completed, etc.).
        _ = process.WaitForExitAsync().ContinueWith(
            _ => portTcs.TrySetException(new InvalidOperationException(
                $"WebRTC helper exited (code {SafeExitCode(process)}) before the data plane was ready. " +
                $"A reachable {(request.AsAnswerer ? "offer" : "answer")} peer is required. stderr: {Trim(stderr.ToString())}")),
            TaskScheduler.Default);

        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutCts.CancelAfter(_options.LaunchTimeout);

        int boundPort;
        try
        {
            boundPort = await portTcs.Task.WaitAsync(timeoutCts.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (timeoutCts.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
        {
            TryKill(process);
            process.Dispose();
            throw new InvalidOperationException(
                $"WebRTC helper did not open the data plane within {_options.LaunchTimeout.TotalSeconds:F0}s " +
                $"(no SKYBRIDGE_DATAPLANE_PORT). A reachable {(request.AsAnswerer ? "offer" : "answer")} peer is required.");
        }
        catch
        {
            TryKill(process);
            process.Dispose();
            throw;
        }

        return new WebRtcHelperSession(process, boundPort, offerPath, answerPath, ipcToken);
    }

    private static int SafeExitCode(Process process)
    {
        try
        {
            return process.HasExited ? process.ExitCode : -1;
        }
        catch (InvalidOperationException)
        {
            return -1;
        }
    }

    private static string Trim(string value)
    {
        var trimmed = value.Trim();
        const int max = 600;
        return trimmed.Length <= max ? trimmed : trimmed[..max] + "...";
    }

    private static void DeleteStaleFile(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            throw new InvalidOperationException(
                $"Could not remove stale WebRTC proof '{path}'; refusing to launch with replayable proof state.", ex);
        }
    }

    private static string GenerateIpcToken()
    {
        var bytes = RandomNumberGenerator.GetBytes(32);
        return Convert.ToBase64String(bytes)
            .TrimEnd('=')
            .Replace('+', '-')
            .Replace('/', '_');
    }

    private static void TryKill(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
        }
        catch (Exception ex) when (ex is InvalidOperationException or System.ComponentModel.Win32Exception)
        {
        }
    }

    private static bool IsLowerHexFingerprint(string value)
    {
        if (value.Length != 64)
        {
            return false;
        }

        foreach (var ch in value)
        {
            if (!((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f')))
            {
                return false;
            }
        }

        return true;
    }
}

/// <summary>
/// Per-connect inputs for launching the offerer helper: the REAL paired identity (never a
/// placeholder) the helper binds the proof to and the adapter later cross-checks against
/// <see cref="PairingMaterial"/>.
/// </summary>
public sealed record WebRtcHelperLaunchRequest(
    string PeerDeviceId,
    string PeerPublicKeyFingerprint);

/// <summary>
/// The fresh artifacts an offerer run produced. <see cref="ProofPath"/> is fed straight into
/// <see cref="WindowsVerifiedWebRtcDataChannelOptions"/> so the verified adapter validates it within
/// the freshness window.
/// </summary>
public sealed record WebRtcHelperLaunchResult(
    string ProofPath,
    string OfferPath,
    string AnswerPath);

/// <summary>
/// Inputs for launching a DATA-PLANE session helper. <see cref="AsAnswerer"/> selects
/// <c>session-answer</c> (this box waits for an offer) vs. <c>session-offer</c> (this box drives the
/// offer). <see cref="PreferredIpcPort"/> is 0 to let the OS pick a free loopback port (recommended);
/// the helper reports the actual bound port back via stdout.
/// </summary>
public sealed record WebRtcHelperSessionRequest(
    bool AsAnswerer = false,
    int PreferredIpcPort = 0);

/// <summary>
/// A live data-plane helper process. Owns the child process and exposes <see cref="IpcPort"/> — the
/// loopback port a <see cref="SkyBridgeDataPlaneClient"/> connects to. Disposing stops the helper
/// (which tears the DataChannel + IPC down). This is the session-mode analog of
/// <see cref="WebRtcHelperLaunchResult"/>; it plugs into the same env-driven
/// <see cref="WebRtcHelperLaunchOptions"/> the one-shot offerer uses, so the one-shot launch is
/// untouched.
/// </summary>
public sealed class WebRtcHelperSession : IAsyncDisposable
{
    private readonly Process _process;

    internal WebRtcHelperSession(
        Process process,
        int ipcPort,
        string offerPath,
        string answerPath,
        string ipcToken)
    {
        _process = process ?? throw new ArgumentNullException(nameof(process));
        IpcPort = ipcPort;
        OfferPath = offerPath;
        AnswerPath = answerPath;
        IpcToken = string.IsNullOrWhiteSpace(ipcToken)
            ? throw new ArgumentException("WebRTC helper session requires an IPC token.", nameof(ipcToken))
            : ipcToken;
    }

    /// <summary>The loopback TCP port the helper's SBF1 IPC is listening on (127.0.0.1).</summary>
    public int IpcPort { get; }

    public string OfferPath { get; }

    public string AnswerPath { get; }

    public string IpcToken { get; }

    /// <summary>True while the helper process is still running (data plane live).</summary>
    public bool IsRunning
    {
        get
        {
            try
            {
                return !_process.HasExited;
            }
                catch (InvalidOperationException)
                {
                    return false;
                }
        }
    }

    public async ValueTask DisposeAsync()
    {
        try
        {
            if (!_process.HasExited)
            {
                _process.Kill(entireProcessTree: true);
                await _process.WaitForExitAsync().ConfigureAwait(false);
            }
        }
        catch (Exception ex) when (ex is InvalidOperationException or System.ComponentModel.Win32Exception)
        {
        }
        finally
        {
            _process.Dispose();
        }
    }
}

/// <summary>
/// Resolved, validated launch configuration. The helper exe path, signaling file paths, ICE servers,
/// and timeout are all configurable inputs (env-driven in the factory) so a live offer/answer
/// exchange with the Apple side can be wired without code changes.
/// </summary>
public sealed class WebRtcHelperLaunchOptions
{
    public WebRtcHelperLaunchOptions(
        string helperExecutablePath,
        string signalingDirectory,
        string? proofFileName = null,
        string? offerFileName = null,
        string? answerFileName = null,
        string? iceServersCsv = null,
        TimeSpan? launchTimeout = null)
    {
        if (string.IsNullOrWhiteSpace(helperExecutablePath))
        {
            throw new InvalidOperationException("WebRTC helper launch requires an executable path.");
        }

        if (string.IsNullOrWhiteSpace(signalingDirectory))
        {
            throw new InvalidOperationException("WebRTC helper launch requires a signaling directory.");
        }

        var timeout = launchTimeout ?? TimeSpan.FromSeconds(200);
        if (timeout <= TimeSpan.Zero)
        {
            throw new InvalidOperationException("WebRTC helper launch timeout must be positive.");
        }

        HelperExecutablePath = Path.GetFullPath(helperExecutablePath.Trim());
        SignalingDirectory = Path.GetFullPath(signalingDirectory.Trim());
        ProofFileName = string.IsNullOrWhiteSpace(proofFileName) ? "skybridge-webrtc-proof.json" : proofFileName.Trim();
        OfferFileName = string.IsNullOrWhiteSpace(offerFileName) ? "skybridge-webrtc-offer.json" : offerFileName.Trim();
        AnswerFileName = string.IsNullOrWhiteSpace(answerFileName) ? "skybridge-webrtc-answer.json" : answerFileName.Trim();
        IceServersCsv = string.IsNullOrWhiteSpace(iceServersCsv) ? null : iceServersCsv.Trim();
        LaunchTimeout = timeout;
        WorkingDirectory = SignalingDirectory;
    }

    public string HelperExecutablePath { get; }

    public string SignalingDirectory { get; }

    public string ProofFileName { get; }

    public string OfferFileName { get; }

    public string AnswerFileName { get; }

    public string? IceServersCsv { get; }

    public TimeSpan LaunchTimeout { get; }

    public string WorkingDirectory { get; }

    public string ResolveProofPath() => ResolvePath(ProofFileName);

    public string ResolveOfferPath() => ResolvePath(OfferFileName);

    public string ResolveAnswerPath() => ResolvePath(AnswerFileName);

    private string ResolvePath(string fileName)
    {
        EnsureSignalingDirectory();
        var candidate = Path.IsPathRooted(fileName)
            ? Path.GetFullPath(fileName)
            : Path.GetFullPath(Path.Combine(SignalingDirectory, fileName));
        var root = Path.GetFullPath(SignalingDirectory)
            .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
            + Path.DirectorySeparatorChar;

        if (!candidate.StartsWith(root, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException(
                $"WebRTC helper signaling artifact '{fileName}' must resolve inside '{SignalingDirectory}'.");
        }

        return candidate;
    }

    private void EnsureSignalingDirectory()
    {
        if (!Directory.Exists(SignalingDirectory))
        {
            Directory.CreateDirectory(SignalingDirectory);
        }
    }
}

/// <summary>
/// Connection preflight that, for a webrtc-verified-launch peer, first launches the WebRTC helper
/// offerer to produce a FRESH proof bound to the real paired identity, then runs the standard Core
/// preflight against a runtime verified adapter pointed at that fresh proof. This is the
/// runtime-proof path that closes the env-at-startup vs. 60s-freshness-window gap: the proof is
/// produced moments before the adapter reads it, so it is always within the freshness window.
///
/// Fail-closed: if the helper exits non-zero (no verified DataChannel) or writes no proof, the
/// launch throws and no preflight snapshot is produced, so the connect stays disconnected. The
/// verified adapter still INDEPENDENTLY re-validates the proof (identity, SBF1 echo, freshness),
/// so this decorator never weakens any existing gate.
/// </summary>
public sealed class LaunchingWebRtcVerifiedPreflightClient : IConnectionPreflightClient
{
    private readonly CoreBridge _coreBridge;
    private readonly IWebRtcHelperLaunchClient _helperLaunchClient;
    private readonly ulong _proofMaxAgeMs;

    public LaunchingWebRtcVerifiedPreflightClient(
        CoreBridge coreBridge,
        IWebRtcHelperLaunchClient helperLaunchClient,
        ulong proofMaxAgeMs)
    {
        _coreBridge = coreBridge ?? throw new ArgumentNullException(nameof(coreBridge));
        _helperLaunchClient = helperLaunchClient ?? throw new ArgumentNullException(nameof(helperLaunchClient));
        if (proofMaxAgeMs == 0)
        {
            throw new InvalidOperationException("WebRTC verified preflight requires a non-zero proof max age.");
        }

        _proofMaxAgeMs = proofMaxAgeMs;
    }

    public string BuildPendingStatus() => "Launching verified WebRTC helper...";

    public async Task<ConnectionPreflightSnapshot> BuildReadOnlySnapshotAsync(
        DiscoveredPeer discoveredPeer,
        PairingMaterial pairingMaterial)
    {
        ArgumentNullException.ThrowIfNull(discoveredPeer);
        ArgumentNullException.ThrowIfNull(pairingMaterial);

        // Launch the offerer with the REAL paired identity. Exit 0 means a live DataChannel + verified
        // SBF1 echo; any other outcome throws here and the connect never reaches EngineConnect.
        var launchResult = await _helperLaunchClient.LaunchOffererAsync(
            new WebRtcHelperLaunchRequest(
                pairingMaterial.DeviceId,
                pairingMaterial.PublicKeyFingerprint)).ConfigureAwait(false);

        // Point a runtime verified adapter at the just-written fresh proof; the standard preflight then
        // re-validates it (identity/echo/freshness) and flips IsLiveAdapterReady=true on success.
        var runtimeAdapter = new VerifiedWebRtcDataChannelTransportAdapterClient(
            _coreBridge,
            new WindowsVerifiedWebRtcDataChannelOptions(launchResult.ProofPath, _proofMaxAgeMs));
        var inner = new ConnectionPreflightClient(_coreBridge, runtimeAdapter);
        return await inner.BuildReadOnlySnapshotAsync(discoveredPeer, pairingMaterial).ConfigureAwait(false);
    }
}
