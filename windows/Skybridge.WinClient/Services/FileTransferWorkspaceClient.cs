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

    Task<FileTransferWorkspaceSnapshot> BuildReadOnlySnapshotAsync();
}

public sealed class FileTransferWorkspaceClient : IFileTransferWorkspaceClient
{
    private readonly CoreBridge _coreBridge;

    public FileTransferWorkspaceClient(CoreBridge coreBridge)
    {
        _coreBridge = coreBridge ?? throw new ArgumentNullException(nameof(coreBridge));
    }

    public string BuildPendingStatus() => DefaultPendingStatus;

    public string BuildInitialStatus() => DefaultInitialStatus;

    public string BuildCompletedStatus(FileTransferWorkspaceSnapshot snapshot) =>
        BuildDefaultCompletedStatus(snapshot);

    public string BuildCompletedStatusMessage() => DefaultCompletedStatusMessage;

    public static string DefaultInitialStatus { get; } = "Ready";

    public static string DefaultPendingStatus { get; } = "Refreshing...";

    public static string DefaultCompletedStatusMessage { get; } = "File transfer workspace updated";

    public static string BuildDefaultCompletedStatus(FileTransferWorkspaceSnapshot snapshot) =>
        $"Snapshot {snapshot.CapturedAt:HH:mm:ss} UTC";

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
