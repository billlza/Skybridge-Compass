using System;
using System.Collections.Generic;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using QRCoder;

namespace Skybridge.WinClient.Services;

public interface IFileTransferWorkspaceClient
{
    string BuildInitialStatus();

    string BuildPendingStatus();

    string BuildCompletedStatus(FileTransferWorkspaceSnapshot snapshot);

    string BuildCompletedStatusMessage();

    bool CanSelectFiles();

    bool CanSelectFolder();

    bool CanGenerateShareQr();

    string BuildSelectFilesPendingStatus();

    string BuildSelectFolderPendingStatus();

    string BuildShareQrPendingStatus();

    Task<FileTransferWorkspaceSnapshot> BuildReadOnlySnapshotAsync();

    Task<FileTransferWorkspaceActionResult> BuildSelectFilesActionAsync();

    Task<FileTransferWorkspaceActionResult> BuildSelectFolderActionAsync();

    Task<FileTransferWorkspaceActionResult> BuildShareQrActionAsync();
}

public interface IFileTransferShareIntentClient
{
    bool CanGenerateShareQr();

    FileTransferWorkspaceActionResult BuildShareQrIntent();
}

public interface IFileTransferSelectionIntentClient
{
    bool CanSelectFiles();

    bool CanSelectFolder();

    FileTransferSelectionIntentSnapshot CaptureSnapshot();

    FileTransferWorkspaceActionResult BuildSelectFilesIntent();

    FileTransferWorkspaceActionResult BuildSelectFolderIntent();
}

public sealed class InMemoryFileTransferSelectionIntentClient : IFileTransferSelectionIntentClient
{
    private readonly object _sync = new();
    private int _nextFilesIntentId;
    private int _nextFolderIntentId;
    private string? _latestFilesIntentId;
    private string? _latestFolderIntentId;
    private DateTimeOffset? _latestFilesIntentAt;
    private DateTimeOffset? _latestFolderIntentAt;

    public bool CanSelectFiles() => true;

    public bool CanSelectFolder() => true;

    public FileTransferSelectionIntentSnapshot CaptureSnapshot()
    {
        lock (_sync)
        {
            return new FileTransferSelectionIntentSnapshot(
                _latestFilesIntentId is not null,
                _latestFilesIntentId,
                _latestFilesIntentAt,
                _latestFolderIntentId is not null,
                _latestFolderIntentId,
                _latestFolderIntentAt);
        }
    }

    public FileTransferWorkspaceActionResult BuildSelectFilesIntent()
    {
        string intentId;
        lock (_sync)
        {
            _nextFilesIntentId++;
            intentId = $"FT-FILES-{_nextFilesIntentId:0000}";
            _latestFilesIntentId = intentId;
            _latestFilesIntentAt = DateTimeOffset.UtcNow;
        }

        return FileTransferWorkspaceClient.BuildSelectFilesIntentActionResult(intentId);
    }

    public FileTransferWorkspaceActionResult BuildSelectFolderIntent()
    {
        string intentId;
        lock (_sync)
        {
            _nextFolderIntentId++;
            intentId = $"FT-FOLDER-{_nextFolderIntentId:0000}";
            _latestFolderIntentId = intentId;
            _latestFolderIntentAt = DateTimeOffset.UtcNow;
        }

        return FileTransferWorkspaceClient.BuildSelectFolderIntentActionResult(intentId);
    }
}

public sealed class InMemoryFileTransferShareIntentClient : IFileTransferShareIntentClient
{
    private readonly object _sync = new();
    private int _nextIntentId;

    public bool CanGenerateShareQr() => true;

    public FileTransferWorkspaceActionResult BuildShareQrIntent()
    {
        int intentId;
        lock (_sync)
        {
            _nextIntentId++;
            intentId = _nextIntentId;
        }

        return FileTransferWorkspaceClient.BuildShareQrIntentActionResult($"FT-{intentId:0000}");
    }
}

public sealed class FileTransferWorkspaceClient : IFileTransferWorkspaceClient
{
    private const string DefaultFilesSelectionIntentId = "FT-FILES-0000";
    private const string DefaultFolderSelectionIntentId = "FT-FOLDER-0000";
    private const string ShareQrQueryPrefix = "skybridge://file-transfer?data=";
    private const int ShareQrVersion = 1;
    private const int ShareQrPixelsPerModule = 8;
    private const double ShareQrLifetimeSeconds = 300;
    private static readonly IReadOnlyList<string> ShareQrCapabilities = new[] { "file-transfer", "intent-only", "windows" };
    private static readonly JsonSerializerOptions QrJsonOptions = new(JsonSerializerDefaults.Web);

    private readonly CoreBridge _coreBridge;
    private readonly IFileTransferSelectionIntentClient _selectionIntentClient;
    private readonly IFileTransferShareIntentClient _shareIntentClient;

    public FileTransferWorkspaceClient(CoreBridge coreBridge)
        : this(
            coreBridge,
            new InMemoryFileTransferShareIntentClient(),
            new InMemoryFileTransferSelectionIntentClient())
    {
    }

    public FileTransferWorkspaceClient(
        CoreBridge coreBridge,
        IFileTransferShareIntentClient shareIntentClient)
        : this(coreBridge, shareIntentClient, new InMemoryFileTransferSelectionIntentClient())
    {
    }

    public FileTransferWorkspaceClient(
        CoreBridge coreBridge,
        IFileTransferShareIntentClient shareIntentClient,
        IFileTransferSelectionIntentClient selectionIntentClient)
    {
        _coreBridge = coreBridge ?? throw new ArgumentNullException(nameof(coreBridge));
        _shareIntentClient = shareIntentClient ?? throw new ArgumentNullException(nameof(shareIntentClient));
        _selectionIntentClient = selectionIntentClient ?? throw new ArgumentNullException(nameof(selectionIntentClient));
    }

    public string BuildPendingStatus() => DefaultPendingStatus;

    public string BuildInitialStatus() => DefaultInitialStatus;

    public string BuildCompletedStatus(FileTransferWorkspaceSnapshot snapshot) =>
        BuildDefaultCompletedStatus(snapshot);

    public string BuildCompletedStatusMessage() => DefaultCompletedStatusMessage;

    public bool CanSelectFiles() => _selectionIntentClient.CanSelectFiles();

    public bool CanSelectFolder() => _selectionIntentClient.CanSelectFolder();

    public bool CanGenerateShareQr() => _shareIntentClient.CanGenerateShareQr();

    public string BuildSelectFilesPendingStatus() => DefaultSelectFilesPendingStatus;

    public string BuildSelectFolderPendingStatus() => DefaultSelectFolderPendingStatus;

    public string BuildShareQrPendingStatus() => DefaultShareQrPendingStatus;

    public static string DefaultInitialStatus { get; } = "Ready";

    public static string DefaultPendingStatus { get; } = "Refreshing...";

    public static string DefaultCompletedStatusMessage { get; } = "File transfer workspace updated";

    public static string DefaultSelectFilesPendingStatus { get; } = "Preparing file picker...";

    public static string DefaultSelectFolderPendingStatus { get; } = "Preparing folder picker...";

    public static string DefaultShareQrPendingStatus { get; } = "Preparing QR...";

    public static string DefaultSelectFilesBlockedStatus { get; } = "File picker pending adapter";

    public static string DefaultSelectFilesBlockedMessage { get; } = "File selection remains fail-closed";

    public static string DefaultSelectFilesIntentReadyStatus { get; } = "File selection intent ready";

    public static string DefaultSelectFilesIntentReadyMessage { get; } =
        "File selection intent prepared in memory only; no file picker was opened.";

    public static string DefaultSelectFolderBlockedStatus { get; } = "Folder picker pending adapter";

    public static string DefaultSelectFolderBlockedMessage { get; } = "Folder selection remains fail-closed";

    public static string DefaultSelectFolderIntentReadyStatus { get; } = "Folder selection intent ready";

    public static string DefaultSelectFolderIntentReadyMessage { get; } =
        "Folder selection intent prepared in memory only; no folder picker was opened.";

    public static string DefaultShareQrBlockedStatus { get; } = "QR generation pending adapter";

    public static string DefaultShareQrBlockedMessage { get; } = "File transfer QR generation remains fail-closed";

    public static string DefaultShareQrReadyStatus { get; } = "QR share plan ready";

    public static string DefaultShareQrReadyMessage { get; } =
        "File transfer QR share plan prepared in memory only; no local files were read.";

    public static string BuildDefaultCompletedStatus(FileTransferWorkspaceSnapshot snapshot) =>
        $"Snapshot {snapshot.CapturedAt:HH:mm:ss} UTC";

    public static FileTransferWorkspaceActionResult BuildDefaultSelectFilesActionResult() =>
        new(
            DefaultSelectFilesBlockedStatus,
            DefaultSelectFilesBlockedMessage,
            "No file picker was opened, no local files were read, and no transfer manifest was created.");

    public static FileTransferWorkspaceActionResult BuildSelectFilesIntentActionResult(string intentId) =>
        new(
            DefaultSelectFilesIntentReadyStatus,
            DefaultSelectFilesIntentReadyMessage,
            $"intent={NormalizeSelectionIntentId(intentId, DefaultFilesSelectionIntentId)}; no file picker was opened, no local files were read, and no transfer manifest was created.");

    public static FileTransferWorkspaceActionResult BuildDefaultSelectFolderActionResult() =>
        new(
            DefaultSelectFolderBlockedStatus,
            DefaultSelectFolderBlockedMessage,
            "No folder picker was opened, no directory was scanned, and no transfer manifest was created.");

    public static FileTransferWorkspaceActionResult BuildSelectFolderIntentActionResult(string intentId) =>
        new(
            DefaultSelectFolderIntentReadyStatus,
            DefaultSelectFolderIntentReadyMessage,
            $"intent={NormalizeSelectionIntentId(intentId, DefaultFolderSelectionIntentId)}; no folder picker was opened, no directory was scanned, and no transfer manifest was created.");

    public static FileTransferWorkspaceActionResult BuildDefaultShareQrActionResult() =>
        new(
            DefaultShareQrBlockedStatus,
            DefaultShareQrBlockedMessage,
            "No local files were read and no transport or signaling session was started.");

    public static FileTransferWorkspaceActionResult BuildShareQrIntentActionResult(string intentId) =>
        BuildShareQrIntentActionResultCore(NormalizeShareIntentId(intentId));

    private static FileTransferWorkspaceActionResult BuildShareQrIntentActionResultCore(string normalizedIntentId)
    {
        var shareQr = BuildSignedShareQrCode(normalizedIntentId);
        return new FileTransferWorkspaceActionResult(
            DefaultShareQrReadyStatus,
            DefaultShareQrReadyMessage,
            $"intent={normalizedIntentId}; qr={shareQr.Uri}; png={shareQr.PngByteLength} bytes; no local files were read, and no transport or signaling session was started.",
            shareQr.Uri,
            shareQr.PngBase64);
    }

    private static FileTransferShareQrCode BuildSignedShareQrCode(string intentId)
    {
        using var signingKey = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var publicKey = ExportRawP256PublicKey(signingKey);
        var publicKeyBase64 = Convert.ToBase64String(publicKey);
        var publicKeyFingerprint = Convert.ToHexString(SHA256.HashData(publicKey)).ToLowerInvariant();
        var timestampSeconds = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;
        var timestamp = timestampSeconds.ToString("0.###", CultureInfo.InvariantCulture);
        var expiresAt = (timestampSeconds + ShareQrLifetimeSeconds).ToString("0.###", CultureInfo.InvariantCulture);
        var payload = new FileTransferShareQrPayload(
            ShareQrVersion,
            intentId,
            Environment.MachineName,
            "Windows",
            "intent-only",
            0,
            0,
            expiresAt,
            ShareQrCapabilities);
        var canonical = BuildShareQrCanonicalPayload(payload, timestamp, publicKeyFingerprint);
        var signature = signingKey.SignData(
            Encoding.UTF8.GetBytes(canonical),
            HashAlgorithmName.SHA256,
            DSASignatureFormat.IeeeP1363FixedFieldConcatenation);
        var envelope = new FileTransferShareQrEnvelope(
            payload,
            Convert.ToBase64String(signature),
            publicKeyBase64,
            timestamp,
            publicKeyFingerprint);
        var envelopeJson = JsonSerializer.Serialize(envelope, QrJsonOptions);
        var uri = $"{ShareQrQueryPrefix}{Base64UrlEncode(Encoding.UTF8.GetBytes(envelopeJson))}";
        var pngBytes = PngByteQRCodeHelper.GetQRCode(
            uri,
            QRCodeGenerator.ECCLevel.Q,
            ShareQrPixelsPerModule);

        return new FileTransferShareQrCode(
            uri,
            Convert.ToBase64String(pngBytes),
            pngBytes.Length);
    }

    private static string BuildShareQrCanonicalPayload(
        FileTransferShareQrPayload payload,
        string timestamp,
        string publicKeyFingerprint) =>
        string.Join(
            "|",
            "file-transfer",
            payload.Version.ToString(CultureInfo.InvariantCulture),
            payload.IntentId,
            payload.DeviceName,
            payload.DeviceType,
            payload.ShareMode,
            payload.ManifestFileCount.ToString(CultureInfo.InvariantCulture),
            payload.ManifestBytes.ToString(CultureInfo.InvariantCulture),
            payload.ExpiresAt,
            string.Join(",", payload.Capabilities),
            timestamp,
            publicKeyFingerprint);

    private static byte[] ExportRawP256PublicKey(ECDsa signingKey)
    {
        var publicParameters = signingKey.ExportParameters(false);
        if (publicParameters.Q.X is not { Length: 32 } x
            || publicParameters.Q.Y is not { Length: 32 } y)
        {
            throw new InvalidOperationException("File transfer QR signing key export must produce a raw P256 public key.");
        }

        var publicKey = new byte[64];
        Buffer.BlockCopy(x, 0, publicKey, 0, x.Length);
        Buffer.BlockCopy(y, 0, publicKey, x.Length, y.Length);
        return publicKey;
    }

    private static string Base64UrlEncode(byte[] bytes) =>
        Convert.ToBase64String(bytes)
            .TrimEnd('=')
            .Replace('+', '-')
            .Replace('/', '_');

    private static string NormalizeShareIntentId(string intentId)
    {
        var normalized = (intentId ?? "").Trim();
        return normalized.Length == 0 ? "FT-0000" : normalized;
    }

    private static string NormalizeSelectionIntentId(string? intentId, string fallback)
    {
        var normalized = (intentId ?? "").Trim();
        return normalized.Length == 0 ? fallback : normalized;
    }

    public async Task<FileTransferWorkspaceSnapshot> BuildReadOnlySnapshotAsync()
    {
        var selectionIntent = _selectionIntentClient.CaptureSnapshot();
        var plan = await _coreBridge.PlanConnectionAsync(
            PeerCapabilities.Windows(),
            PeerCapabilities.Apple(),
            NetworkPath.CrossNatPath(),
            CryptoProviderCapabilities.ResearchAll(),
            new ushort[] { 0x0001, 0x0101, 0x1001 },
            CryptoSuitePolicy.Compatibility(),
            TrafficPaddingPlan.Sbp2Fixed(512));
        var channelMappings = CoreChannelMappingResolver.RequireAll(plan.ChannelMappings);
        var fileChannel = CoreChannelMappingResolver.Require(channelMappings, CoreChannelKind.File);
        var planner = await _coreBridge.PlanFileTransferReadinessAsync(
            Array.Empty<FileTransferRouteCandidate>(),
            null,
            null,
            CoreFileTransferManifestMode.IntentOnly,
            Array.Empty<FileTransferManifestFile>(),
            1024 * 1024,
            channelMappings);
        var manifestPayload = Encoding.UTF8.GetBytes(BuildPlannerFramePayload(planner));
        var manifestFrame = await _coreBridge.EncodeFrameAsync(
            CoreChannelKind.File,
            1,
            manifestPayload);
        var metadata = await _coreBridge.DecodeFrameMetadataAsync(manifestFrame);
        var decodedPayload = await _coreBridge.DecodeFramePayloadAsync(manifestFrame);

        var queue = new List<FileTransferQueueItem>
        {
            new(
                "Manifest planner",
                planner.Status.ToString(),
                $"{planner.ManifestFileCount} files / {FormatPlannerBytes(planner.ManifestTotalBytes)}",
                BuildPlannerChannelValue(planner, fileChannel),
                $"code={planner.Code}; frame={metadata.EncodedLen} bytes; payload={decodedPayload.Length} bytes")
        };
        AddSelectionIntentQueueItems(queue, selectionIntent);
        var history = new List<FileTransferHistoryItem>
        {
            new(
                "Planner snapshot",
                planner.Status.ToString(),
                BuildManifestPlannerDetail(planner),
                "No file bytes dispatched")
        };
        var security = new List<FileTransferSecurityFact>
        {
            new("Transport plan", plan.Transport.Kind.ToString(), $"audit={plan.Transport.AuditCode}; channels={channelMappings.Count}"),
            new("Channel", fileChannel.BindingKind.ToString(), $"reliability={fileChannel.Reliability}; HOL isolated={fileChannel.HeadOfLineIsolated}"),
            new("Manifest planner", planner.Status.ToString(), BuildManifestPlannerDetail(planner)),
            new("Route readiness", planner.Code.ToString(), BuildPlannerRouteDetail(planner)),
            new("Manifest frame", $"{metadata.FrameHeaderLen} byte header", $"flags=0x{metadata.Flags:x4}; decoded={metadata.DecodedPayloadLen}"),
            new("Selection intent", BuildSelectionIntentState(selectionIntent), BuildSelectionIntentDetail(selectionIntent)),
            new("HMAC", "pending live transfer", BuildPlannerDigestDetail(planner)),
            new("Signature", "pending live transfer", "pairing/trust layer must verify sender identity")
        };

        return new FileTransferWorkspaceSnapshot(DateTimeOffset.UtcNow, queue, history, security);
    }

    private static string BuildPlannerFramePayload(FileTransferPlannerVerdict planner) =>
        string.Format(
            CultureInfo.InvariantCulture,
            "file-transfer-plan:status={0};code={1};files={2};bytes={3};chunks={4}",
            planner.Status,
            planner.Code,
            planner.ManifestFileCount,
            planner.ManifestTotalBytes,
            planner.ManifestTotalChunks);

    private static string BuildPlannerChannelValue(
        FileTransferPlannerVerdict planner,
        ChannelMapping fileChannel) =>
        planner.FileChannelBindingKind?.ToString() ?? fileChannel.BindingKind.ToString();

    private static string BuildManifestPlannerDetail(FileTransferPlannerVerdict planner) =>
        string.Format(
            CultureInfo.InvariantCulture,
            "code={0}; files={1}; bytes={2}; chunks={3}; audit={4}",
            planner.Code,
            planner.ManifestFileCount,
            planner.ManifestTotalBytes,
            planner.ManifestTotalChunks,
            planner.Audit);

    private static string BuildPlannerRouteDetail(FileTransferPlannerVerdict planner)
    {
        if (planner.SelectedHost is null || planner.SelectedPort is null)
        {
            return string.Format(
                CultureInfo.InvariantCulture,
                "route=none; addressClass={0}; source={1}",
                planner.SelectedAddressClass,
                planner.SelectedRouteSource);
        }

        return string.Format(
            CultureInfo.InvariantCulture,
            "route={0}:{1}; addressClass={2}; source={3}",
            planner.SelectedHost,
            planner.SelectedPort,
            planner.SelectedAddressClass,
            planner.SelectedRouteSource);
    }

    private static string BuildPlannerDigestDetail(FileTransferPlannerVerdict planner) =>
        planner.ManifestDigest is null
            ? "pending real manifest; no local files are read"
            : $"manifest digest={Convert.ToHexString(planner.ManifestDigest).ToLowerInvariant()}";

    private static string FormatPlannerBytes(ulong bytes)
    {
        if (bytes < 1024)
        {
            return string.Format(CultureInfo.InvariantCulture, "{0} B", bytes);
        }

        var kib = bytes / 1024.0;
        if (kib < 1024)
        {
            return string.Format(CultureInfo.InvariantCulture, "{0:0.#} KiB", kib);
        }

        var mib = kib / 1024.0;
        return string.Format(CultureInfo.InvariantCulture, "{0:0.#} MiB", mib);
    }

    public Task<FileTransferWorkspaceActionResult> BuildSelectFilesActionAsync() =>
        Task.FromResult(_selectionIntentClient.BuildSelectFilesIntent());

    public Task<FileTransferWorkspaceActionResult> BuildSelectFolderActionAsync() =>
        Task.FromResult(_selectionIntentClient.BuildSelectFolderIntent());

    public Task<FileTransferWorkspaceActionResult> BuildShareQrActionAsync() =>
        Task.FromResult(_shareIntentClient.BuildShareQrIntent());

    private static void AddSelectionIntentQueueItems(
        List<FileTransferQueueItem> queue,
        FileTransferSelectionIntentSnapshot selectionIntent)
    {
        if (selectionIntent.HasFilesIntent)
        {
            queue.Insert(
                0,
                new FileTransferQueueItem(
                    "Selected files intent",
                    "Intent ready",
                    "0 files",
                    "Picker pending",
                    BuildFilesSelectionIntentDetail(selectionIntent)));
        }

        if (selectionIntent.HasFolderIntent)
        {
            queue.Insert(
                0,
                new FileTransferQueueItem(
                    "Selected folder intent",
                    "Intent ready",
                    "0 folders",
                    "Picker pending",
                    BuildFolderSelectionIntentDetail(selectionIntent)));
        }
    }

    private static string BuildSelectionIntentState(FileTransferSelectionIntentSnapshot selectionIntent)
    {
        if (selectionIntent.HasFilesIntent && selectionIntent.HasFolderIntent)
        {
            return "files/folder intents ready";
        }

        if (selectionIntent.HasFilesIntent)
        {
            return "files intent ready";
        }

        if (selectionIntent.HasFolderIntent)
        {
            return "folder intent ready";
        }

        return "ready";
    }

    private static string BuildSelectionIntentDetail(FileTransferSelectionIntentSnapshot selectionIntent)
    {
        if (!selectionIntent.HasFilesIntent && !selectionIntent.HasFolderIntent)
        {
            return "Selection actions prepare in-memory intents only; no picker is opened and no files are read.";
        }

        return $"{BuildFilesSelectionIntentDetail(selectionIntent)}; {BuildFolderSelectionIntentDetail(selectionIntent)}";
    }

    private static string BuildFilesSelectionIntentDetail(FileTransferSelectionIntentSnapshot selectionIntent) =>
        selectionIntent.HasFilesIntent && selectionIntent.FilesIntentCreatedAt.HasValue
            ? $"files={NormalizeSelectionIntentId(selectionIntent.FilesIntentId, DefaultFilesSelectionIntentId)} at {selectionIntent.FilesIntentCreatedAt.Value:HH:mm:ss} UTC"
            : "files=not prepared";

    private static string BuildFolderSelectionIntentDetail(FileTransferSelectionIntentSnapshot selectionIntent) =>
        selectionIntent.HasFolderIntent && selectionIntent.FolderIntentCreatedAt.HasValue
            ? $"folder={NormalizeSelectionIntentId(selectionIntent.FolderIntentId, DefaultFolderSelectionIntentId)} at {selectionIntent.FolderIntentCreatedAt.Value:HH:mm:ss} UTC"
            : "folder=not prepared";
}

public sealed record FileTransferWorkspaceSnapshot(
    DateTimeOffset CapturedAt,
    IReadOnlyList<FileTransferQueueItem> Queue,
    IReadOnlyList<FileTransferHistoryItem> History,
    IReadOnlyList<FileTransferSecurityFact> Security);

public sealed record FileTransferQueueItem(
    string Name,
    string State,
    string Size,
    string Binding,
    string Detail);

public sealed record FileTransferHistoryItem(
    string Name,
    string Result,
    string Hmac,
    string Signature);

public sealed record FileTransferSecurityFact(
    string Label,
    string Value,
    string Detail);

public sealed record FileTransferSelectionIntentSnapshot(
    bool HasFilesIntent,
    string? FilesIntentId,
    DateTimeOffset? FilesIntentCreatedAt,
    bool HasFolderIntent,
    string? FolderIntentId,
    DateTimeOffset? FolderIntentCreatedAt);

public sealed record FileTransferWorkspaceActionResult(
    string Status,
    string Message,
    string Detail,
    string? ShareQrPayload = null,
    string? ShareQrPngBase64 = null);

internal sealed record FileTransferShareQrPayload(
    int Version,
    string IntentId,
    string DeviceName,
    string DeviceType,
    string ShareMode,
    int ManifestFileCount,
    long ManifestBytes,
    string ExpiresAt,
    IReadOnlyList<string> Capabilities);

internal sealed record FileTransferShareQrEnvelope(
    FileTransferShareQrPayload Payload,
    string SignatureBase64,
    string PublicKeyBase64,
    string Timestamp,
    string PublicKeyFingerprint);

internal sealed record FileTransferShareQrCode(
    string Uri,
    string PngBase64,
    int PngByteLength);
