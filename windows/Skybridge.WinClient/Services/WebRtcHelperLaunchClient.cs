using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
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

    /// <summary>
    /// Launches the helper in Mac product-control transport mode
    /// (<c>--mode product-control-offer</c> or <c>--mode product-control-answer</c>). This is a
    /// sibling of the SBF1 session profile: it exposes a loopback IPC that carries raw
    /// <c>skybridge</c> control-channel chunks, not SBF1 frames.
    /// </summary>
    Task<WebRtcHelperSession> LaunchProductControlSessionAsync(
        WebRtcHelperProductControlSessionRequest request,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Starts the product-control helper and returns before the WebRTC answer has arrived. Callers
    /// that own a server-backed signaling plane can publish <see cref="WebRtcHelperPendingSession.OfferPath"/>,
    /// write the remote answer to <see cref="WebRtcHelperPendingSession.AnswerPath"/>, then call
    /// <see cref="WebRtcHelperPendingSession.WaitReadyAsync"/> to obtain the live IPC session.
    /// </summary>
    Task<WebRtcHelperPendingSession> StartProductControlSessionAsync(
        WebRtcHelperProductControlSessionRequest request,
        CancellationToken cancellationToken = default);
}

public sealed class WebRtcHelperLaunchClient : IWebRtcHelperLaunchClient
{
    private const string ProductControlIpcAuthTokenVariable = "SKYBRIDGE_PRODUCT_CONTROL_IPC_AUTH_TOKEN";
    private const int MaxCapturedHelperOutputCharacters = 8192;

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

        // Stale signaling/proof files must never satisfy a new launch. Remove them before starting
        // the helper; if removal fails, fail closed instead of consuming bytes from a previous run.
        DeleteStaleFile(proofPath, "proof");
        DeleteStaleFile(offerPath, "offer");
        DeleteStaleFile(answerPath, "answer");

        var startInfo = new ProcessStartInfo
        {
            FileName = helperPath,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = _options.WorkingDirectory,
        };
        RemoveSensitiveInheritedEnvironment(startInfo);
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
        AddLocalIceArguments(startInfo);

        using var process = new Process { StartInfo = startInfo };
        var stdout = new StringBuilder();
        var stderr = new StringBuilder();
        process.OutputDataReceived += (_, e) =>
        {
            if (e.Data is not null)
            {
                AppendBounded(stdout, e.Data);
            }
        };
        process.ErrorDataReceived += (_, e) =>
        {
            if (e.Data is not null)
            {
                AppendBounded(stderr, e.Data);
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
                $"stderr: {Trim(RedactProcessOutput(stderr.ToString()))}");
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
        return await LaunchPersistentSessionAndWaitAsync(
            request.AsAnswerer,
            request.PreferredIpcPort,
            offerMode: "session-offer",
            answerMode: "session-answer",
            readyMarker: "SKYBRIDGE_DATAPLANE_PORT=",
            readyName: "data plane",
            enableProductControlIpcAuth: false,
            cancellationToken).ConfigureAwait(false);
    }

    public async Task<WebRtcHelperSession> LaunchProductControlSessionAsync(
        WebRtcHelperProductControlSessionRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        await using var pending = await StartProductControlSessionAsync(request, cancellationToken)
            .ConfigureAwait(false);
        return await pending.WaitReadyAsync(cancellationToken).ConfigureAwait(false);
    }

    public async Task<WebRtcHelperPendingSession> StartProductControlSessionAsync(
        WebRtcHelperProductControlSessionRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        return await LaunchPersistentSessionAsync(
            request.AsAnswerer,
            request.PreferredIpcPort,
            offerMode: "product-control-offer",
            answerMode: "product-control-answer",
            readyMarker: "SKYBRIDGE_PRODUCT_CONTROL_PORT=",
            readyName: "product-control transport",
            enableProductControlIpcAuth: true,
            cancellationToken).ConfigureAwait(false);
    }

    private async Task<WebRtcHelperSession> LaunchPersistentSessionAndWaitAsync(
        bool asAnswerer,
        int preferredIpcPort,
        string offerMode,
        string answerMode,
        string readyMarker,
        string readyName,
        bool enableProductControlIpcAuth,
        CancellationToken cancellationToken)
    {
        await using var pending = await LaunchPersistentSessionAsync(
                asAnswerer,
                preferredIpcPort,
                offerMode,
                answerMode,
                readyMarker,
                readyName,
                enableProductControlIpcAuth,
                cancellationToken)
            .ConfigureAwait(false);
        return await pending.WaitReadyAsync(cancellationToken).ConfigureAwait(false);
    }

    private async Task<WebRtcHelperPendingSession> LaunchPersistentSessionAsync(
        bool asAnswerer,
        int preferredIpcPort,
        string offerMode,
        string answerMode,
        string readyMarker,
        string readyName,
        bool enableProductControlIpcAuth,
        CancellationToken cancellationToken)
    {
        ValidatePreferredIpcPort(preferredIpcPort);

        var mode = asAnswerer ? answerMode : offerMode;

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
        var ipcAuthToken = enableProductControlIpcAuth
            ? RandomNumberGenerator.GetBytes(WebRtcProductControlPlaneClient.IpcAuthTokenBytes)
            : null;
        DeleteStaleFile(offerPath, "offer");
        DeleteStaleFile(answerPath, "answer");

        var startInfo = new ProcessStartInfo
        {
            FileName = helperPath,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = _options.WorkingDirectory,
        };
        RemoveSensitiveInheritedEnvironment(startInfo);
        startInfo.ArgumentList.Add("--mode");
        startInfo.ArgumentList.Add(mode);
        startInfo.ArgumentList.Add("--offer-out");
        startInfo.ArgumentList.Add(offerPath);
        startInfo.ArgumentList.Add("--answer-in");
        startInfo.ArgumentList.Add(answerPath);
        startInfo.ArgumentList.Add("--offer-in");
        startInfo.ArgumentList.Add(offerPath);
        startInfo.ArgumentList.Add("--answer-out");
        startInfo.ArgumentList.Add(answerPath);
        startInfo.ArgumentList.Add("--ipc-port");
        startInfo.ArgumentList.Add(preferredIpcPort.ToString());
        if (ipcAuthToken is not null)
        {
            startInfo.ArgumentList.Add("--ipc-auth-token-env");
            startInfo.ArgumentList.Add(ProductControlIpcAuthTokenVariable);
            startInfo.Environment[ProductControlIpcAuthTokenVariable] = Convert.ToBase64String(ipcAuthToken);
        }

        if (!string.IsNullOrWhiteSpace(_options.IceServersCsv))
        {
            startInfo.ArgumentList.Add("--ice-servers");
            startInfo.ArgumentList.Add(_options.IceServersCsv!.Trim());
        }
        AddLocalIceArguments(startInfo);

        var process = new Process { StartInfo = startInfo };
        var portTcs = new TaskCompletionSource<int>(TaskCreationOptions.RunContinuationsAsynchronously);
        var stderr = new StringBuilder();

        process.OutputDataReceived += (_, e) =>
        {
            if (e.Data is null)
            {
                return;
            }

            var idx = e.Data.IndexOf(readyMarker, StringComparison.Ordinal);
            if (idx < 0)
            {
                return;
            }

            if (!int.TryParse(e.Data.AsSpan(idx + readyMarker.Length).Trim(), out var port))
            {
                portTcs.TrySetException(new InvalidOperationException(
                    $"WebRTC helper reported a malformed {readyName} port line: {e.Data}"));
                return;
            }

            if (port is > 0 and <= 65535)
            {
                portTcs.TrySetResult(port);
                return;
            }

            portTcs.TrySetException(new InvalidOperationException(
                $"WebRTC helper reported an invalid {readyName} port: {port}."));
        };
        process.ErrorDataReceived += (_, e) =>
        {
            if (e.Data is not null)
            {
                AppendBounded(stderr, e.Data);
            }
        };

        try
        {
            if (!process.Start())
            {
                process.Dispose();
                ZeroSecret(ipcAuthToken);
                throw new InvalidOperationException(
                    $"Failed to start the WebRTC helper process at '{helperPath}'.");
            }

            if (ipcAuthToken is not null)
            {
                startInfo.Environment.Remove(ProductControlIpcAuthTokenVariable);
            }
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            process.Dispose();
            ZeroSecret(ipcAuthToken);
            throw new InvalidOperationException(
                $"Failed to launch the WebRTC helper at '{helperPath}': {ex.Message}", ex);
        }

        process.BeginOutputReadLine();
        process.BeginErrorReadLine();

        _ = process.WaitForExitAsync().ContinueWith(
            _ => portTcs.TrySetException(new InvalidOperationException(
                $"WebRTC helper exited (code {SafeExitCode(process)}) before the {readyName} was ready. " +
                $"A reachable {(asAnswerer ? "offer" : "answer")} peer is required. stderr: {Trim(RedactProcessOutput(stderr.ToString()))}")),
            TaskScheduler.Default);

        return new WebRtcHelperPendingSession(
            process,
            portTcs,
            offerPath,
            answerPath,
            ipcAuthToken,
            _options.LaunchTimeout,
            readyMarker,
            readyName,
            asAnswerer);
    }

    private static int SafeExitCode(Process process)
    {
        try
        {
            return process.HasExited ? process.ExitCode : -1;
        }
        catch
        {
            return -1;
        }
    }

    private void AddLocalIceArguments(ProcessStartInfo startInfo)
    {
        if (!string.IsNullOrWhiteSpace(_options.BindAddress))
        {
            startInfo.ArgumentList.Add("--bind-address");
            startInfo.ArgumentList.Add(_options.BindAddress);
        }

        if (_options.IncludeAllIceInterfaceAddresses)
        {
            startInfo.ArgumentList.Add("--ice-include-all-interfaces");
            startInfo.ArgumentList.Add("true");
        }
    }

    private static void ValidatePreferredIpcPort(int preferredPort)
    {
        if (preferredPort is < 0 or > 65535)
        {
            throw new InvalidOperationException(
                "WebRTC helper preferred IPC port must be 0 for an OS-assigned port, or a TCP port in the range 1-65535.");
        }
    }

    private static string Trim(string value)
    {
        var trimmed = RedactProcessOutput(value).Trim();
        const int max = 600;
        return trimmed.Length <= max ? trimmed : trimmed[..max] + "...";
    }

    private static void AppendBounded(StringBuilder builder, string line)
    {
        if (builder.Length >= MaxCapturedHelperOutputCharacters)
        {
            return;
        }

        var remaining = MaxCapturedHelperOutputCharacters - builder.Length;
        var redactedLine = RedactProcessOutput(line);
        if (redactedLine.Length + Environment.NewLine.Length <= remaining)
        {
            builder.AppendLine(redactedLine);
            return;
        }

        builder.Append(redactedLine.AsSpan(0, Math.Max(0, remaining)));
    }

    private static void RemoveSensitiveInheritedEnvironment(ProcessStartInfo startInfo)
    {
        var namesToRemove = new List<string>();
        foreach (string name in startInfo.Environment.Keys)
        {
            if (IsSensitiveEnvironmentVariableName(name))
            {
                namesToRemove.Add(name);
            }
        }

        foreach (var name in namesToRemove)
        {
            startInfo.Environment.Remove(name);
        }
    }

    private static bool IsSensitiveEnvironmentVariableName(string name)
    {
        if (name.StartsWith("SKYBRIDGE_CURRENT_PATH_", StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        return name.Contains("TOKEN", StringComparison.OrdinalIgnoreCase) ||
               name.Contains("SECRET", StringComparison.OrdinalIgnoreCase) ||
               name.Contains("PRIVATE_KEY", StringComparison.OrdinalIgnoreCase) ||
               name.Contains("BEARER", StringComparison.OrdinalIgnoreCase) ||
               name.Contains("PASSWORD", StringComparison.OrdinalIgnoreCase) ||
               name.Contains("CONNECTION_CODE", StringComparison.OrdinalIgnoreCase);
    }

    private static string RedactProcessOutput(string value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return value;
        }

        var redacted = Regex.Replace(
            value,
            @"(?i)\b([A-Z0-9_]*(?:TOKEN|SECRET|PRIVATE_KEY|BEARER|PASSWORD|CONNECTION_CODE)[A-Z0-9_]*\s*[:=]\s*)[^\s,;]+",
            "$1<redacted>");
        redacted = Regex.Replace(
            redacted,
            @"(?i)\b(Authorization\s*:\s*Bearer\s+)[^\s,;]+",
            "$1<redacted>");
        redacted = Regex.Replace(
            redacted,
            @"(?i)([?&](?:token|authToken|sessionToken|bearer|code|connectionCode)=)[^&\s]+",
            "$1<redacted>");
        return redacted;
    }

    private static void DeleteStaleFile(string path, string artifactName)
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
                $"WebRTC helper refused to start because stale {artifactName} artifact '{path}' could not be removed. " +
                "Delete or unlock the artifact and retry so this session cannot consume stale signaling data.",
                ex);
        }
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

    private static void ZeroSecret(byte[]? secret)
    {
        if (secret is not null)
        {
            CryptographicOperations.ZeroMemory(secret);
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
/// Inputs for launching the Mac product-control helper transport. It uses the same file signaling
/// and loopback-port selection as <see cref="WebRtcHelperSessionRequest"/>, but the helper mode is
/// <c>product-control-offer</c>/<c>product-control-answer</c> and the IPC carries raw
/// <c>skybridge</c> control-channel chunks instead of SBF1 frames.
/// </summary>
public sealed record WebRtcHelperProductControlSessionRequest(
    bool AsAnswerer = false,
    int PreferredIpcPort = 0);

/// <summary>
/// A helper process that has started but has not reached the live IPC-ready state yet. This is the
/// explicit lifecycle gap needed by server-backed signaling: the helper can write its local offer,
/// a caller can exchange SDP/ICE through current-path, then <see cref="WaitReadyAsync"/> transfers
/// ownership to a live <see cref="WebRtcHelperSession"/>.
/// </summary>
public sealed class WebRtcHelperPendingSession : IAsyncDisposable
{
    private readonly TaskCompletionSource<int> _portTask;
    private readonly TimeSpan _launchTimeout;
    private readonly string _readyMarker;
    private readonly string _readyName;
    private readonly bool _asAnswerer;
    private Process? _process;
    private byte[]? _ipcAuthToken;
    private bool _transferred;

    internal WebRtcHelperPendingSession(
        Process process,
        TaskCompletionSource<int> portTask,
        string offerPath,
        string answerPath,
        byte[]? ipcAuthToken,
        TimeSpan launchTimeout,
        string readyMarker,
        string readyName,
        bool asAnswerer)
    {
        _process = process ?? throw new ArgumentNullException(nameof(process));
        _portTask = portTask ?? throw new ArgumentNullException(nameof(portTask));
        OfferPath = offerPath;
        AnswerPath = answerPath;
        _ipcAuthToken = ipcAuthToken;
        _launchTimeout = launchTimeout;
        _readyMarker = readyMarker;
        _readyName = readyName;
        _asAnswerer = asAnswerer;
    }

    public string OfferPath { get; }

    public string AnswerPath { get; }

    public bool AsAnswerer => _asAnswerer;

    public string LocalSignalPath => _asAnswerer ? AnswerPath : OfferPath;

    public string RemoteSignalPath => _asAnswerer ? OfferPath : AnswerPath;

    public string LocalSignalType => _asAnswerer ? "answer" : "offer";

    public string RemoteSignalType => _asAnswerer ? "offer" : "answer";

    public async Task<WebRtcHelperSession> WaitReadyAsync(CancellationToken cancellationToken = default)
    {
        if (_transferred)
        {
            throw new InvalidOperationException("WebRTC helper pending session has already been transferred.");
        }

        var process = _process ?? throw new ObjectDisposedException(nameof(WebRtcHelperPendingSession));
        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutCts.CancelAfter(_launchTimeout);

        int boundPort;
        try
        {
            boundPort = await _portTask.Task.WaitAsync(timeoutCts.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (timeoutCts.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
        {
            await DisposeAsync().ConfigureAwait(false);
            throw new InvalidOperationException(
                $"WebRTC helper did not open the {_readyName} within {_launchTimeout.TotalSeconds:F0}s " +
                $"(no {_readyMarker.TrimEnd('=')}). A reachable {(_asAnswerer ? "offer" : "answer")} peer is required.");
        }
        catch
        {
            await DisposeAsync().ConfigureAwait(false);
            throw;
        }

        _transferred = true;
        _process = null;
        var ipcAuthToken = _ipcAuthToken;
        _ipcAuthToken = null;
        return new WebRtcHelperSession(process, boundPort, OfferPath, AnswerPath, ipcAuthToken, ownsIpcAuthToken: true);
    }

    public async ValueTask DisposeAsync()
    {
        if (_transferred)
        {
            return;
        }

        var process = _process;
        _process = null;
        try
        {
            if (process is not null && !process.HasExited)
            {
                process.Kill(entireProcessTree: true);
                await process.WaitForExitAsync().ConfigureAwait(false);
            }
        }
        catch (Exception ex) when (ex is InvalidOperationException or System.ComponentModel.Win32Exception)
        {
        }
        finally
        {
            if (_ipcAuthToken is not null)
            {
                CryptographicOperations.ZeroMemory(_ipcAuthToken);
                _ipcAuthToken = null;
            }

            process?.Dispose();
        }
    }
}

/// <summary>
/// A live helper process. Owns the child process and exposes <see cref="IpcPort"/> — the loopback
/// port either <see cref="SkyBridgeDataPlaneClient"/> (SBF1 session profile) or
/// <see cref="WebRtcProductControlPlaneClient"/> (Mac product-control profile) connects to.
/// Disposing stops the helper (which tears the DataChannel + IPC down). This is the session-mode
/// analog of
/// <see cref="WebRtcHelperLaunchResult"/>; it plugs into the same env-driven
/// <see cref="WebRtcHelperLaunchOptions"/> the one-shot offerer uses, so the one-shot launch is
/// untouched.
/// </summary>
public sealed class WebRtcHelperSession : IAsyncDisposable
{
    private readonly Process _process;

    private byte[]? _ipcAuthToken;

    internal WebRtcHelperSession(
        Process process,
        int ipcPort,
        string offerPath,
        string answerPath,
        byte[]? ipcAuthToken = null,
        bool ownsIpcAuthToken = false)
    {
        _process = process ?? throw new ArgumentNullException(nameof(process));
        IpcPort = ipcPort;
        OfferPath = offerPath;
        AnswerPath = answerPath;
        _ipcAuthToken = ipcAuthToken is not null && ownsIpcAuthToken
            ? ipcAuthToken
            : ipcAuthToken?.ToArray();
    }

    /// <summary>The loopback TCP port the helper's SBF1 IPC is listening on (127.0.0.1).</summary>
    public int IpcPort { get; }

    public string OfferPath { get; }

    public string AnswerPath { get; }

    internal ReadOnlyMemory<byte> RequireProductControlIpcAuthToken()
    {
        if (_ipcAuthToken is null)
        {
            throw new InvalidOperationException(
                "WebRTC product-control helper session did not provide an IPC authentication token.");
        }

        return _ipcAuthToken;
    }

    /// <summary>True while the helper process is still running (data plane live).</summary>
    public bool IsRunning
    {
        get
        {
            try
            {
                return !_process.HasExited;
            }
            catch
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
            if (_ipcAuthToken is not null)
            {
                CryptographicOperations.ZeroMemory(_ipcAuthToken);
                _ipcAuthToken = null;
            }

            _process.Dispose();
            DeleteSessionArtifactIfExists(OfferPath);
            DeleteSessionArtifactIfExists(AnswerPath);
            DeleteSessionArtifactIfExists(OfferPath + ".tmp");
            DeleteSessionArtifactIfExists(AnswerPath + ".tmp");
        }
    }

    private static void DeleteSessionArtifactIfExists(string path)
    {
        if (File.Exists(path))
        {
            File.Delete(path);
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
        string? bindAddress = null,
        bool includeAllIceInterfaceAddresses = false,
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
        BindAddress = NormalizeBindAddress(bindAddress);
        IncludeAllIceInterfaceAddresses = includeAllIceInterfaceAddresses;
        LaunchTimeout = timeout;
        WorkingDirectory = SignalingDirectory;
    }

    public string HelperExecutablePath { get; }

    public string SignalingDirectory { get; }

    public string ProofFileName { get; }

    public string OfferFileName { get; }

    public string AnswerFileName { get; }

    public string? IceServersCsv { get; }

    public string? BindAddress { get; }

    public bool IncludeAllIceInterfaceAddresses { get; }

    public TimeSpan LaunchTimeout { get; }

    public string WorkingDirectory { get; }

    public string ResolveProofPath() => ResolvePath(ProofFileName);

    public string ResolveOfferPath() => ResolvePath(OfferFileName);

    public string ResolveAnswerPath() => ResolvePath(AnswerFileName);

    private string ResolvePath(string fileName)
    {
        var trimmed = fileName.Trim();
        if (string.IsNullOrWhiteSpace(trimmed))
        {
            throw new InvalidOperationException("WebRTC helper signaling file name must not be empty.");
        }

        if (Path.IsPathRooted(trimmed) ||
            Path.GetFileName(trimmed) != trimmed ||
            trimmed == "." ||
            trimmed == "..")
        {
            throw new InvalidOperationException(
                "WebRTC helper signaling file names must be file names inside the configured signaling directory, not absolute paths or relative paths.");
        }

        var resolvedPath = Path.GetFullPath(Path.Combine(SignalingDirectory, trimmed));
        var comparison = OperatingSystem.IsWindows()
            ? StringComparison.OrdinalIgnoreCase
            : StringComparison.Ordinal;
        if (!resolvedPath.StartsWith(EnsureTrailingSeparator(SignalingDirectory), comparison))
        {
            throw new InvalidOperationException(
                "WebRTC helper signaling file resolved outside the configured signaling directory.");
        }

        EnsureSignalingDirectory();
        return resolvedPath;
    }

    private void EnsureSignalingDirectory()
    {
        if (!Directory.Exists(SignalingDirectory))
        {
            Directory.CreateDirectory(SignalingDirectory);
        }
    }

    private static string EnsureTrailingSeparator(string path)
    {
        return path.EndsWith(Path.DirectorySeparatorChar) || path.EndsWith(Path.AltDirectorySeparatorChar)
            ? path
            : path + Path.DirectorySeparatorChar;
    }

    private static string? NormalizeBindAddress(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw))
        {
            return null;
        }

        var trimmed = raw.Trim();
        if (!IPAddress.TryParse(trimmed, out var parsed))
        {
            throw new InvalidOperationException("WebRTC helper bind address must be a valid IP address.");
        }

        if (IPAddress.IsLoopback(parsed) ||
            IPAddress.Any.Equals(parsed) ||
            IPAddress.IPv6Any.Equals(parsed))
        {
            throw new InvalidOperationException("WebRTC helper bind address must be a concrete non-loopback local interface address.");
        }

        return parsed.ToString();
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
            new WindowsVerifiedWebRtcDataChannelOptions(launchResult.ProofPath, _proofMaxAgeMs));
        var inner = new ConnectionPreflightClient(_coreBridge, runtimeAdapter);
        return await inner.BuildReadOnlySnapshotAsync(discoveredPeer, pairingMaterial).ConfigureAwait(false);
    }
}
