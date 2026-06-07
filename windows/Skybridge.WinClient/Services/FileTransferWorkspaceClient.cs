using System;
using System.Collections.Generic;
using System.Text;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

public interface IFileTransferWorkspaceClient
{
    Task<FileTransferWorkspaceSnapshot> BuildReadOnlySnapshotAsync();
}

public sealed class FileTransferWorkspaceClient : IFileTransferWorkspaceClient
{
    private readonly CoreBridge _coreBridge;

    public FileTransferWorkspaceClient(CoreBridge coreBridge)
    {
        _coreBridge = coreBridge ?? throw new ArgumentNullException(nameof(coreBridge));
    }

    public async Task<FileTransferWorkspaceSnapshot> BuildReadOnlySnapshotAsync()
    {
        var fileChannel = await _coreBridge.MapChannelAsync(
            CoreTransportKind.WebRtcDataChannel,
            CoreChannelKind.File);
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
