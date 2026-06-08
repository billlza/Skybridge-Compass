using System;
using System.Collections.Generic;
using System.Text;
using System.Threading.Tasks;

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
    private readonly CoreBridge _coreBridge;
    private readonly IFileTransferShareIntentClient _shareIntentClient;

    public FileTransferWorkspaceClient(CoreBridge coreBridge)
        : this(coreBridge, new InMemoryFileTransferShareIntentClient())
    {
    }

    public FileTransferWorkspaceClient(
        CoreBridge coreBridge,
        IFileTransferShareIntentClient shareIntentClient)
    {
        _coreBridge = coreBridge ?? throw new ArgumentNullException(nameof(coreBridge));
        _shareIntentClient = shareIntentClient ?? throw new ArgumentNullException(nameof(shareIntentClient));
    }

    public string BuildPendingStatus() => DefaultPendingStatus;

    public string BuildInitialStatus() => DefaultInitialStatus;

    public string BuildCompletedStatus(FileTransferWorkspaceSnapshot snapshot) =>
        BuildDefaultCompletedStatus(snapshot);

    public string BuildCompletedStatusMessage() => DefaultCompletedStatusMessage;

    public bool CanSelectFiles() => false;

    public bool CanSelectFolder() => false;

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

    public static string DefaultSelectFolderBlockedStatus { get; } = "Folder picker pending adapter";

    public static string DefaultSelectFolderBlockedMessage { get; } = "Folder selection remains fail-closed";

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

    public static FileTransferWorkspaceActionResult BuildDefaultSelectFolderActionResult() =>
        new(
            DefaultSelectFolderBlockedStatus,
            DefaultSelectFolderBlockedMessage,
            "No folder picker was opened, no directory was scanned, and no transfer manifest was created.");

    public static FileTransferWorkspaceActionResult BuildDefaultShareQrActionResult() =>
        new(
            DefaultShareQrBlockedStatus,
            DefaultShareQrBlockedMessage,
            "No local files were read and no transport or signaling session was started.");

    public static FileTransferWorkspaceActionResult BuildShareQrIntentActionResult(string intentId) =>
        new(
            DefaultShareQrReadyStatus,
            DefaultShareQrReadyMessage,
            $"intent={NormalizeShareIntentId(intentId)}; no QR payload was emitted, and no transport or signaling session was started.");

    private static string NormalizeShareIntentId(string intentId)
    {
        var normalized = (intentId ?? "").Trim();
        return normalized.Length == 0 ? "FT-0000" : normalized;
    }

    public async Task<FileTransferWorkspaceSnapshot> BuildReadOnlySnapshotAsync()
    {
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
        var manifestPayload = Encoding.UTF8.GetBytes("file-manifest:name=sample.mov;bytes=73400320");
        var manifestFrame = await _coreBridge.EncodeFrameAsync(
            CoreChannelKind.File,
            1,
            manifestPayload);
        var metadata = await _coreBridge.DecodeFrameMetadataAsync(manifestFrame);
        var decodedPayload = await _coreBridge.DecodeFramePayloadAsync(manifestFrame);

        var queue = new List<FileTransferQueueItem>
        {
            new(
                "sample.mov",
                "Queued",
                "70 MB",
                fileChannel.BindingKind.ToString(),
                $"frame={metadata.EncodedLen} bytes; payload={decodedPayload.Length} bytes")
        };
        var history = new List<FileTransferHistoryItem>
        {
            new(
                "archive.zip",
                "Verified",
                "HMAC tag recorded",
                "Signature OK")
        };
        var security = new List<FileTransferSecurityFact>
        {
            new("Transport plan", plan.Transport.Kind.ToString(), $"audit={plan.Transport.AuditCode}; channels={channelMappings.Count}"),
            new("Channel", fileChannel.BindingKind.ToString(), $"reliability={fileChannel.Reliability}; HOL isolated={fileChannel.HeadOfLineIsolated}"),
            new("Manifest frame", $"{metadata.FrameHeaderLen} byte header", $"flags=0x{metadata.Flags:x4}; decoded={metadata.DecodedPayloadLen}"),
            new("HMAC", "pending live transfer", "mac parity placeholder; no local files are read"),
            new("Signature", "pending live transfer", "pairing/trust layer must verify sender identity")
        };

        return new FileTransferWorkspaceSnapshot(DateTimeOffset.UtcNow, queue, history, security);
    }

    public Task<FileTransferWorkspaceActionResult> BuildSelectFilesActionAsync() =>
        Task.FromResult(BuildDefaultSelectFilesActionResult());

    public Task<FileTransferWorkspaceActionResult> BuildSelectFolderActionAsync() =>
        Task.FromResult(BuildDefaultSelectFolderActionResult());

    public Task<FileTransferWorkspaceActionResult> BuildShareQrActionAsync() =>
        Task.FromResult(_shareIntentClient.BuildShareQrIntent());
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

public sealed record FileTransferWorkspaceActionResult(
    string Status,
    string Message,
    string Detail);
