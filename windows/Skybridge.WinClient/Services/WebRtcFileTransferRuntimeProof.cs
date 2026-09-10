using System;
using System.Buffers.Binary;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;
using Payloads = Skybridge.WinClient.Services.WebRtcFileTransferProofPayloads;
using Validation = Skybridge.WinClient.Services.WebRtcFileTransferProofValidation;

namespace Skybridge.WinClient.Services;

public sealed class WebRtcFileTransferProofException : InvalidOperationException
{
    public WebRtcFileTransferProofException(string message)
        : base(message)
    {
    }

    public WebRtcFileTransferProofException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}

public sealed class WebRtcFileTransferProofOptions
{
    public WebRtcFileTransferProofOptions(
        TimeSpan timeout,
        int maxQueuedInboundMessages = 8,
        int maxFileBytes = 2048,
        int maxJsonPayloadBytes = 4096)
    {
        if (timeout <= TimeSpan.Zero)
        {
            throw new InvalidOperationException("WebRTC FileTransfer proof timeout must be positive.");
        }

        if (maxQueuedInboundMessages is < 1 or > 32)
        {
            throw new InvalidOperationException(
                "WebRTC FileTransfer proof inbound queue capacity must be between 1 and 32 messages.");
        }

        if (maxFileBytes is < 1 or > 4096)
        {
            throw new InvalidOperationException(
                "WebRTC FileTransfer proof max file bytes must be between 1 and 4096.");
        }

        if (maxJsonPayloadBytes is < 512 or > 7168)
        {
            throw new InvalidOperationException(
                "WebRTC FileTransfer proof JSON payload limit must be between 512 and 7168 bytes.");
        }

        Timeout = timeout;
        MaxQueuedInboundMessages = maxQueuedInboundMessages;
        MaxFileBytes = maxFileBytes;
        MaxJsonPayloadBytes = maxJsonPayloadBytes;
    }

    public static WebRtcFileTransferProofOptions Default { get; } = new(TimeSpan.FromSeconds(10));

    public TimeSpan Timeout { get; }

    public int MaxQueuedInboundMessages { get; }

    public int MaxFileBytes { get; }

    public int MaxJsonPayloadBytes { get; }
}

public sealed record WebRtcFileTransferProofResult(
    string SessionIdSha256,
    string TransferIdSha256,
    long TransferredBytes,
    int ChunkCount,
    int ChunkAckCount,
    bool CompleteAckReceived,
    string SentFileSha256,
    string FileSha256Receipt,
    bool ReceiptMatchesSentHash,
    int ProductSendCount,
    int ProductReceiveCount,
    ulong ManifestOutboundCounter,
    ulong ManifestAckInboundCounter,
    ulong ChunkOutboundCounter,
    ulong ChunkAckInboundCounter,
    ulong CompleteOutboundCounter,
    ulong CompleteAckInboundCounter,
    ulong SessionHash,
    ulong TranscriptPrefix);

public sealed record WebRtcFileTransferResponderResult(
    string SessionIdSha256,
    string TransferIdSha256,
    long ReceivedBytes,
    int ChunkCount,
    int ChunkAckCount,
    bool CompleteAckSent,
    string ReceivedFileSha256,
    string FileSha256Receipt,
    bool ReceiptMatchesReceivedHash,
    int ProductSendCount,
    int ProductReceiveCount,
    ulong ManifestInboundCounter,
    ulong ManifestAckOutboundCounter,
    ulong ChunkInboundCounter,
    ulong ChunkAckOutboundCounter,
    ulong CompleteInboundCounter,
    ulong CompleteAckOutboundCounter,
    ulong SessionHash,
    ulong TranscriptPrefix);

public sealed class WebRtcFileTransferProofClient
{
    private readonly WebRtcFileTransferProofOptions _options;
    private readonly WebRtcAppSecureReplayWindow _replayWindow = new();
    private readonly object _counterGate = new();
    private ulong _nextOutboundCounter = 1;

    public WebRtcFileTransferProofClient(WebRtcFileTransferProofOptions? options = null)
    {
        _options = options ?? WebRtcFileTransferProofOptions.Default;
    }

    public async Task<WebRtcFileTransferProofResult> ExchangeSingleChunkAsync(
        IWebRtcProductControlPlane controlPlane,
        WebRtcAppSecureSessionKeys keys,
        ReadOnlyMemory<byte> fileBytes,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(controlPlane);
        ArgumentNullException.ThrowIfNull(keys);
        Validation.RequireRole(keys, WebRtcAppSecureRole.Initiator, "WebRTC FileTransfer proof client");
        Validation.RequireConnected(controlPlane, "WebRTC FileTransfer proof client");
        var payload = Payloads.RequireFileBytes(fileBytes, _options.MaxFileBytes);
        var fileSha256 = Validation.Sha256Hex(payload);
        var transferId = Payloads.NewTransferId();
        var transferIdSha256 = Validation.Sha256Hex(Encoding.UTF8.GetBytes(transferId));

        await using var inbox = new WebRtcProductControlMessageInbox(
            controlPlane,
            _options.MaxQueuedInboundMessages,
            "WebRTC FileTransfer proof client",
            message => new WebRtcFileTransferProofException(message));

        var manifest = Payloads.BuildManifestPayload(transferId, payload.Length, fileSha256);
        var manifestCounter = await SendFileTransferPayloadAsync(
                controlPlane,
                keys,
                manifest,
                cancellationToken)
            .ConfigureAwait(false);
        var manifestAckFrame = await inbox
            .ReadAsync("FileTransfer manifest acknowledgement", _options.Timeout, cancellationToken)
            .ConfigureAwait(false);
        var manifestAck = OpenFileTransferPayload(manifestAckFrame, keys);
        Payloads.RequireManifestAck(manifestAck.Payload, transferId);

        var chunkSha256 = fileSha256;
        var chunk = Payloads.BuildChunkPayload(transferId, payload, chunkSha256);
        var chunkCounter = await SendFileTransferPayloadAsync(
                controlPlane,
                keys,
                chunk,
                cancellationToken)
            .ConfigureAwait(false);
        var chunkAckFrame = await inbox
            .ReadAsync("FileTransfer chunk acknowledgement", _options.Timeout, cancellationToken)
            .ConfigureAwait(false);
        var chunkAck = OpenFileTransferPayload(chunkAckFrame, keys);
        Payloads.RequireChunkAck(chunkAck.Payload, transferId, payload.Length);

        var complete = Payloads.BuildCompletePayload(transferId, payload.Length, fileSha256);
        var completeCounter = await SendFileTransferPayloadAsync(
                controlPlane,
                keys,
                complete,
                cancellationToken)
            .ConfigureAwait(false);
        var completeAckFrame = await inbox
            .ReadAsync("FileTransfer complete acknowledgement", _options.Timeout, cancellationToken)
            .ConfigureAwait(false);
        var completeAck = OpenFileTransferPayload(completeAckFrame, keys);
        var receipt = Payloads.RequireCompleteAck(completeAck.Payload, transferId, payload.Length, fileSha256);

        return new WebRtcFileTransferProofResult(
            SessionIdSha256: Validation.Sha256Hex(Encoding.UTF8.GetBytes(keys.SessionId)),
            TransferIdSha256: transferIdSha256,
            TransferredBytes: payload.Length,
            ChunkCount: 1,
            ChunkAckCount: 1,
            CompleteAckReceived: true,
            SentFileSha256: fileSha256,
            FileSha256Receipt: receipt.FileSha256,
            ReceiptMatchesSentHash: string.Equals(fileSha256, receipt.FileSha256, StringComparison.Ordinal),
            ProductSendCount: 3,
            ProductReceiveCount: 3,
            ManifestOutboundCounter: manifestCounter,
            ManifestAckInboundCounter: manifestAck.Counter,
            ChunkOutboundCounter: chunkCounter,
            ChunkAckInboundCounter: chunkAck.Counter,
            CompleteOutboundCounter: completeCounter,
            CompleteAckInboundCounter: completeAck.Counter,
            SessionHash: completeAck.SessionHash,
            TranscriptPrefix: completeAck.TranscriptPrefix);
    }

    private async Task<ulong> SendFileTransferPayloadAsync(
        IWebRtcProductControlPlane controlPlane,
        WebRtcAppSecureSessionKeys keys,
        byte[] plaintext,
        CancellationToken cancellationToken)
    {
        Payloads.RequireJsonPayloadWithinLimit(plaintext, _options.MaxJsonPayloadBytes, "WebRTC FileTransfer proof client");
        var counter = NextOutboundCounter();
        var ciphertext = WebRtcControlChannelCodec.EncryptAppPayload(
            plaintext,
            keys,
            WebRtcAppSecurePacketType.FileTransfer,
            counter);
        if (ciphertext.Length > WebRtcProductControlPlaneClient.MaxControlFrameChunkBytes)
        {
            throw new WebRtcFileTransferProofException(
                "WebRTC FileTransfer proof encrypted control frame exceeded the product-control IPC frame limit.");
        }

        await controlPlane.SendAsync(ciphertext, cancellationToken).ConfigureAwait(false);
        return counter;
    }

    private OpenedFileTransferPayload OpenFileTransferPayload(byte[] frame, WebRtcAppSecureSessionKeys keys)
    {
        var unwrapped = WebRtcProductControlTrafficPadding.UnwrapIfNeeded(
            frame,
            message => new WebRtcFileTransferProofException(message));
        try
        {
            var opened = WebRtcControlChannelCodec.DecryptAppPayload(
                unwrapped,
                keys,
                new[] { WebRtcAppSecurePacketType.FileTransfer });
            _replayWindow.ValidateAndRecord(opened);
            Payloads.RequireJsonPayloadWithinLimit(opened.Payload, _options.MaxJsonPayloadBytes, "WebRTC FileTransfer proof client");
            return new OpenedFileTransferPayload(
                opened.Payload,
                opened.Counter,
                opened.SessionHash,
                opened.TranscriptPrefix);
        }
        catch (Exception ex) when (ex is WebRtcAppSecureEnvelopeException or WebRtcAppSecureReplayException)
        {
            throw new WebRtcFileTransferProofException(
                "WebRTC FileTransfer proof client failed to authenticate inbound FileTransfer payload.",
                ex);
        }
    }

    private ulong NextOutboundCounter()
    {
        lock (_counterGate)
        {
            if (_nextOutboundCounter == ulong.MaxValue)
            {
                throw new WebRtcFileTransferProofException(
                    "WebRTC FileTransfer proof client outbound counter exhausted.");
            }

            return _nextOutboundCounter++;
        }
    }
}

public sealed class WebRtcFileTransferResponderHost
{
    private readonly WebRtcFileTransferProofOptions _options;
    private readonly WebRtcAppSecureReplayWindow _replayWindow = new();
    private readonly object _counterGate = new();
    private ulong _nextOutboundCounter = 1;

    public WebRtcFileTransferResponderHost(WebRtcFileTransferProofOptions? options = null)
    {
        _options = options ?? WebRtcFileTransferProofOptions.Default;
    }

    public async Task<WebRtcFileTransferResponderResult> ReceiveSingleChunkAndAckAsync(
        IWebRtcProductControlPlane controlPlane,
        WebRtcAppSecureSessionKeys keys,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(controlPlane);
        ArgumentNullException.ThrowIfNull(keys);
        Validation.RequireRole(keys, WebRtcAppSecureRole.Responder, "WebRTC FileTransfer responder");
        Validation.RequireConnected(controlPlane, "WebRTC FileTransfer responder");

        await using var inbox = new WebRtcProductControlMessageInbox(
            controlPlane,
            _options.MaxQueuedInboundMessages,
            "WebRTC FileTransfer responder",
            message => new WebRtcFileTransferProofException(message));

        var manifestFrame = await inbox
            .ReadAsync("FileTransfer manifest", _options.Timeout, cancellationToken)
            .ConfigureAwait(false);
        var manifestPayload = OpenFileTransferPayload(manifestFrame, keys);
        var manifest = Payloads.RequireManifest(manifestPayload.Payload, _options.MaxFileBytes);

        var manifestAck = Payloads.BuildManifestAckPayload(manifest.TransferId);
        var manifestAckCounter = await SendFileTransferPayloadAsync(
                controlPlane,
                keys,
                manifestAck,
                cancellationToken)
            .ConfigureAwait(false);

        var chunkFrame = await inbox
            .ReadAsync("FileTransfer chunk", _options.Timeout, cancellationToken)
            .ConfigureAwait(false);
        var chunkPayload = OpenFileTransferPayload(chunkFrame, keys);
        var chunk = Payloads.RequireChunk(
            chunkPayload.Payload,
            manifest.TransferId,
            manifest.FileSize,
            manifest.FileSha256);

        var chunkAck = Payloads.BuildChunkAckPayload(manifest.TransferId, chunk.Bytes.Length);
        var chunkAckCounter = await SendFileTransferPayloadAsync(
                controlPlane,
                keys,
                chunkAck,
                cancellationToken)
            .ConfigureAwait(false);

        var completeFrame = await inbox
            .ReadAsync("FileTransfer complete", _options.Timeout, cancellationToken)
            .ConfigureAwait(false);
        var completePayload = OpenFileTransferPayload(completeFrame, keys);
        Payloads.RequireComplete(
            completePayload.Payload,
            manifest.TransferId,
            manifest.FileSize,
            manifest.FileSha256);

        var completeAck = Payloads.BuildCompleteAckPayload(manifest.TransferId, manifest.FileSize, manifest.FileSha256);
        var completeAckCounter = await SendFileTransferPayloadAsync(
                controlPlane,
                keys,
                completeAck,
                cancellationToken)
            .ConfigureAwait(false);

        return new WebRtcFileTransferResponderResult(
            SessionIdSha256: Validation.Sha256Hex(Encoding.UTF8.GetBytes(keys.SessionId)),
            TransferIdSha256: Validation.Sha256Hex(Encoding.UTF8.GetBytes(manifest.TransferId)),
            ReceivedBytes: chunk.Bytes.Length,
            ChunkCount: manifest.ChunkCount,
            ChunkAckCount: 1,
            CompleteAckSent: true,
            ReceivedFileSha256: manifest.FileSha256,
            FileSha256Receipt: manifest.FileSha256,
            ReceiptMatchesReceivedHash: string.Equals(manifest.FileSha256, Validation.Sha256Hex(chunk.Bytes), StringComparison.Ordinal),
            ProductSendCount: 3,
            ProductReceiveCount: 3,
            ManifestInboundCounter: manifestPayload.Counter,
            ManifestAckOutboundCounter: manifestAckCounter,
            ChunkInboundCounter: chunkPayload.Counter,
            ChunkAckOutboundCounter: chunkAckCounter,
            CompleteInboundCounter: completePayload.Counter,
            CompleteAckOutboundCounter: completeAckCounter,
            SessionHash: completePayload.SessionHash,
            TranscriptPrefix: completePayload.TranscriptPrefix);
    }

    private async Task<ulong> SendFileTransferPayloadAsync(
        IWebRtcProductControlPlane controlPlane,
        WebRtcAppSecureSessionKeys keys,
        byte[] plaintext,
        CancellationToken cancellationToken)
    {
        Payloads.RequireJsonPayloadWithinLimit(plaintext, _options.MaxJsonPayloadBytes, "WebRTC FileTransfer responder");
        var counter = NextOutboundCounter();
        var ciphertext = WebRtcControlChannelCodec.EncryptAppPayload(
            plaintext,
            keys,
            WebRtcAppSecurePacketType.FileTransfer,
            counter);
        if (ciphertext.Length > WebRtcProductControlPlaneClient.MaxControlFrameChunkBytes)
        {
            throw new WebRtcFileTransferProofException(
                "WebRTC FileTransfer responder encrypted control frame exceeded the product-control IPC frame limit.");
        }

        await controlPlane.SendAsync(ciphertext, cancellationToken).ConfigureAwait(false);
        return counter;
    }

    private OpenedFileTransferPayload OpenFileTransferPayload(byte[] frame, WebRtcAppSecureSessionKeys keys)
    {
        var unwrapped = WebRtcProductControlTrafficPadding.UnwrapIfNeeded(
            frame,
            message => new WebRtcFileTransferProofException(message));
        try
        {
            var opened = WebRtcControlChannelCodec.DecryptAppPayload(
                unwrapped,
                keys,
                new[] { WebRtcAppSecurePacketType.FileTransfer });
            _replayWindow.ValidateAndRecord(opened);
            Payloads.RequireJsonPayloadWithinLimit(opened.Payload, _options.MaxJsonPayloadBytes, "WebRTC FileTransfer responder");
            return new OpenedFileTransferPayload(
                opened.Payload,
                opened.Counter,
                opened.SessionHash,
                opened.TranscriptPrefix);
        }
        catch (Exception ex) when (ex is WebRtcAppSecureEnvelopeException or WebRtcAppSecureReplayException)
        {
            throw new WebRtcFileTransferProofException(
                "WebRTC FileTransfer responder failed to authenticate inbound FileTransfer payload.",
                ex);
        }
    }

    private ulong NextOutboundCounter()
    {
        lock (_counterGate)
        {
            if (_nextOutboundCounter == ulong.MaxValue)
            {
                throw new WebRtcFileTransferProofException(
                    "WebRTC FileTransfer responder outbound counter exhausted.");
            }

            return _nextOutboundCounter++;
        }
    }
}

public static class WebRtcFileTransferProofEvidenceWriter
{
    private static readonly JsonSerializerOptions EvidenceJsonOptions = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        WriteIndented = true
    };

    public static void WriteLocalLoopEvidence(string path, WebRtcFileTransferProofResult result)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        ArgumentNullException.ThrowIfNull(result);
        if (!result.CompleteAckReceived ||
            result.TransferredBytes <= 0 ||
            result.ChunkCount <= 0 ||
            result.ChunkAckCount != result.ChunkCount ||
            !result.ReceiptMatchesSentHash ||
            !string.Equals(result.SentFileSha256, result.FileSha256Receipt, StringComparison.Ordinal))
        {
            throw new WebRtcFileTransferProofException(
                "WebRTC FileTransfer proof evidence requires completed transfer, full ACK coverage, and matching SHA-256 receipt.");
        }

        var evidence = new WebRtcFileTransferLocalLoopEvidence(
            Profile: "windows-sbwc-file-transfer-local-loop",
            EvidenceScope: "LocalClosedLoopSbwcFileTransferPacketReceipt",
            Status: "completed",
            SecureSessionState: "Established",
            SbwcPacketType: "FileTransfer",
            FileChannelObserved: true,
            ManifestFileCount: 1,
            ManifestBytes: result.TransferredBytes,
            TransferredBytes: result.TransferredBytes,
            ChunkCount: result.ChunkCount,
            ChunkAckCount: result.ChunkAckCount,
            CompleteAckReceived: result.CompleteAckReceived,
            SentFileSha256: result.SentFileSha256,
            FileSha256Receipt: result.FileSha256Receipt,
            ReceiptMatchesSentHash: result.ReceiptMatchesSentHash,
            SessionIdSha256: result.SessionIdSha256,
            TransferIdSha256: result.TransferIdSha256,
            ProductSendCount: result.ProductSendCount,
            ProductReceiveCount: result.ProductReceiveCount,
            SecretInputsCaptured: false,
            ConnectionCodeCaptured: false,
            HeaderValuesCaptured: false,
            RawLocalPathCaptured: false,
            RawRemotePathCaptured: false,
            RawSignalingCaptured: false,
            RawSdpCaptured: false,
            RawIceCredentialCaptured: false,
            RawPayloadCaptured: false,
            NotAppControlProof: true,
            RemoteProductAppObserved: false,
            PeerTrustPersistenceProof: false,
            NotMacProductAppProof: true,
            NotRealDeviceFileTransferProof: true,
            NotWindowsLiveFileTransferProof: true,
            RecordedAt: DateTimeOffset.UtcNow);
        var json = JsonSerializer.Serialize(evidence, EvidenceJsonOptions);
        WebRtcArtifactFileWriter.WriteUtf8TextAtomically(path, json);
    }

    private sealed record WebRtcFileTransferLocalLoopEvidence(
        string Profile,
        string EvidenceScope,
        string Status,
        string SecureSessionState,
        string SbwcPacketType,
        bool FileChannelObserved,
        int ManifestFileCount,
        long ManifestBytes,
        long TransferredBytes,
        int ChunkCount,
        int ChunkAckCount,
        bool CompleteAckReceived,
        string SentFileSha256,
        string FileSha256Receipt,
        bool ReceiptMatchesSentHash,
        string SessionIdSha256,
        string TransferIdSha256,
        int ProductSendCount,
        int ProductReceiveCount,
        bool SecretInputsCaptured,
        bool ConnectionCodeCaptured,
        bool HeaderValuesCaptured,
        bool RawLocalPathCaptured,
        bool RawRemotePathCaptured,
        bool RawSignalingCaptured,
        bool RawSdpCaptured,
        bool RawIceCredentialCaptured,
        bool RawPayloadCaptured,
        bool NotAppControlProof,
        bool RemoteProductAppObserved,
        bool PeerTrustPersistenceProof,
        bool NotMacProductAppProof,
        bool NotRealDeviceFileTransferProof,
        bool NotWindowsLiveFileTransferProof,
        DateTimeOffset RecordedAt);
}

internal static class WebRtcProductControlTrafficPadding
{
    public static byte[] UnwrapIfNeeded(byte[] frame, Func<string, Exception> failureFactory)
    {
        ArgumentNullException.ThrowIfNull(frame);
        ArgumentNullException.ThrowIfNull(failureFactory);
        if (frame.Length < 8 ||
            frame[0] != 0x53 ||
            frame[1] != 0x42 ||
            frame[2] != 0x50 ||
            frame[3] != 0x32)
        {
            return frame;
        }

        var actualLength = BinaryPrimitives.ReadUInt32BigEndian(frame.AsSpan(4, 4));
        if (actualLength > frame.Length - 8)
        {
            throw failureFactory("WebRTC product-control received malformed SBP2 traffic padding.");
        }

        return frame.AsSpan(8, checked((int)actualLength)).ToArray();
    }
}

internal sealed record OpenedFileTransferPayload(
    byte[] Payload,
    ulong Counter,
    ulong SessionHash,
    ulong TranscriptPrefix);

internal sealed record FileTransferManifest(
    string TransferId,
    int FileSize,
    int ChunkCount,
    string FileSha256);

internal sealed record FileTransferChunk(
    int Index,
    byte[] Bytes,
    string ChunkSha256);

internal sealed record FileTransferReceipt(string FileSha256, int Bytes);

internal static class WebRtcFileTransferProofPayloads
{
    private const int WireVersion = 1;

    private static readonly JsonWriterOptions JsonWriterOptions = new()
    {
        Indented = false
    };

    public static byte[] BuildManifestPayload(string transferId, int fileSize, string fileSha256)
    {
        RequireTransferId(transferId);
        WebRtcFileTransferProofValidation.RequireLowerSha256(fileSha256, "FileTransfer manifest SHA-256");
        if (fileSize <= 0)
        {
            throw new WebRtcFileTransferProofException(
                "WebRTC FileTransfer manifest file size must be positive.");
        }

        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream, JsonWriterOptions))
        {
            writer.WriteStartObject();
            WriteHeader(writer, "metadata", transferId);
            writer.WriteString("fileName", "runtime-smoke.bin");
            writer.WriteNumber("fileSize", fileSize);
            writer.WriteNumber("chunkSize", fileSize);
            writer.WriteNumber("totalChunks", 1);
            writer.WriteBase64String("fileSha256", HexToBytes(fileSha256));
            writer.WriteEndObject();
        }

        return stream.ToArray();
    }

    public static byte[] BuildManifestAckPayload(string transferId)
    {
        RequireTransferId(transferId);
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream, JsonWriterOptions))
        {
            writer.WriteStartObject();
            WriteHeader(writer, "metadataAck", transferId);
            writer.WriteEndObject();
        }

        return stream.ToArray();
    }

    public static byte[] BuildChunkPayload(string transferId, byte[] bytes, string chunkSha256)
    {
        RequireTransferId(transferId);
        WebRtcFileTransferProofValidation.RequireLowerSha256(chunkSha256, "FileTransfer chunk SHA-256");
        if (bytes.Length == 0)
        {
            throw new WebRtcFileTransferProofException(
                "WebRTC FileTransfer chunk bytes must not be empty.");
        }

        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream, JsonWriterOptions))
        {
            writer.WriteStartObject();
            WriteHeader(writer, "chunk", transferId);
            writer.WriteNumber("chunkIndex", 0);
            writer.WriteBase64String("chunkData", bytes);
            writer.WriteBase64String("chunkSha256", HexToBytes(chunkSha256));
            writer.WriteNumber("rawSize", bytes.Length);
            writer.WriteEndObject();
        }

        return stream.ToArray();
    }

    public static byte[] BuildChunkAckPayload(string transferId, int receivedBytes)
    {
        RequireTransferId(transferId);
        if (receivedBytes <= 0)
        {
            throw new WebRtcFileTransferProofException(
                "WebRTC FileTransfer chunk acknowledgement received bytes must be positive.");
        }

        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream, JsonWriterOptions))
        {
            writer.WriteStartObject();
            WriteHeader(writer, "chunkAck", transferId);
            writer.WriteNumber("chunkIndex", 0);
            writer.WriteNumber("receivedBytes", receivedBytes);
            writer.WriteEndObject();
        }

        return stream.ToArray();
    }

    public static byte[] BuildCompletePayload(string transferId, int bytes, string fileSha256)
    {
        RequireTransferId(transferId);
        WebRtcFileTransferProofValidation.RequireLowerSha256(fileSha256, "FileTransfer complete SHA-256");
        if (bytes <= 0)
        {
            throw new WebRtcFileTransferProofException(
                "WebRTC FileTransfer complete bytes must be positive.");
        }

        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream, JsonWriterOptions))
        {
            writer.WriteStartObject();
            WriteHeader(writer, "complete", transferId);
            writer.WriteNumber("receivedBytes", bytes);
            writer.WriteBase64String("fileSha256", HexToBytes(fileSha256));
            writer.WriteEndObject();
        }

        return stream.ToArray();
    }

    public static byte[] BuildCompleteAckPayload(string transferId, int bytes, string fileSha256)
    {
        RequireTransferId(transferId);
        WebRtcFileTransferProofValidation.RequireLowerSha256(fileSha256, "FileTransfer receipt SHA-256");
        if (bytes <= 0)
        {
            throw new WebRtcFileTransferProofException(
                "WebRTC FileTransfer complete acknowledgement bytes must be positive.");
        }

        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream, JsonWriterOptions))
        {
            writer.WriteStartObject();
            WriteHeader(writer, "completeAck", transferId);
            writer.WriteNumber("receivedBytes", bytes);
            writer.WriteBase64String("fileSha256", HexToBytes(fileSha256));
            writer.WriteEndObject();
        }

        return stream.ToArray();
    }

    public static FileTransferManifest RequireManifest(ReadOnlySpan<byte> payload, int maxFileBytes)
    {
        using var document = ParsePayload(payload, "FileTransfer manifest");
        var root = document.RootElement;
        RequireOp(root, "metadata", "FileTransfer manifest");
        var transferId = RequireString(root, "transferId", "FileTransfer manifest");
        RequireTransferId(transferId);
        var fileSize = RequirePositiveInt(root, "fileSize", "FileTransfer manifest");
        if (fileSize > maxFileBytes)
        {
            throw new WebRtcFileTransferProofException(
                "WebRTC FileTransfer manifest file size exceeded the proof limit.");
        }

        var chunkSize = RequirePositiveInt(root, "chunkSize", "FileTransfer manifest");
        if (chunkSize != fileSize)
        {
            throw new WebRtcFileTransferProofException(
                "WebRTC FileTransfer proof currently requires a single chunk whose chunkSize matches fileSize.");
        }

        var totalChunks = RequirePositiveInt(root, "totalChunks", "FileTransfer manifest");
        if (totalChunks != 1)
        {
            throw new WebRtcFileTransferProofException(
                "WebRTC FileTransfer proof currently requires exactly one chunk.");
        }

        var fileSha256 = RequireBase64Sha256(root, "fileSha256", "FileTransfer manifest");
        return new FileTransferManifest(transferId, fileSize, totalChunks, fileSha256);
    }

    public static void RequireManifestAck(ReadOnlySpan<byte> payload, string expectedTransferId)
    {
        using var document = ParsePayload(payload, "FileTransfer manifest acknowledgement");
        var root = document.RootElement;
        RequireOp(root, "metadataAck", "FileTransfer manifest acknowledgement");
        RequireTransferIdMatches(root, expectedTransferId, "FileTransfer manifest acknowledgement");
    }

    public static FileTransferChunk RequireChunk(
        ReadOnlySpan<byte> payload,
        string expectedTransferId,
        int expectedBytes,
        string expectedFileSha256)
    {
        using var document = ParsePayload(payload, "FileTransfer chunk");
        var root = document.RootElement;
        RequireOp(root, "chunk", "FileTransfer chunk");
        RequireTransferIdMatches(root, expectedTransferId, "FileTransfer chunk");
        var index = RequireNonNegativeInt(root, "chunkIndex", "FileTransfer chunk");
        if (index != 0)
        {
            throw new WebRtcFileTransferProofException(
                "WebRTC FileTransfer proof expected chunk index 0.");
        }

        if (!root.TryGetProperty("chunkData", out var bytesElement) ||
            bytesElement.ValueKind != JsonValueKind.String)
        {
            throw new WebRtcFileTransferProofException(
                "WebRTC FileTransfer chunk is missing base64 bytes.");
        }

        byte[] bytes;
        try
        {
            bytes = bytesElement.GetBytesFromBase64();
        }
        catch (FormatException ex)
        {
            throw new WebRtcFileTransferProofException(
                "WebRTC FileTransfer chunk contained malformed base64 bytes.",
                ex);
        }

        if (bytes.Length != expectedBytes)
        {
            throw new WebRtcFileTransferProofException(
                "WebRTC FileTransfer chunk byte length did not match the manifest.");
        }

        var chunkSha256 = RequireBase64Sha256(root, "chunkSha256", "FileTransfer chunk");
        if (!string.Equals(chunkSha256, WebRtcFileTransferProofValidation.Sha256Hex(bytes), StringComparison.Ordinal) ||
            !string.Equals(chunkSha256, expectedFileSha256, StringComparison.Ordinal))
        {
            throw new WebRtcFileTransferProofException(
                "WebRTC FileTransfer chunk SHA-256 did not match the manifest.");
        }

        if (root.TryGetProperty("rawSize", out var rawSize) &&
            (!rawSize.TryGetInt32(out var parsedRawSize) || parsedRawSize != bytes.Length))
        {
            throw new WebRtcFileTransferProofException(
                "WebRTC FileTransfer chunk rawSize did not match decoded bytes.");
        }

        return new FileTransferChunk(index, bytes, chunkSha256);
    }

    public static void RequireChunkAck(
        ReadOnlySpan<byte> payload,
        string expectedTransferId,
        int expectedReceivedBytes)
    {
        using var document = ParsePayload(payload, "FileTransfer chunk acknowledgement");
        var root = document.RootElement;
        RequireOp(root, "chunkAck", "FileTransfer chunk acknowledgement");
        RequireTransferIdMatches(root, expectedTransferId, "FileTransfer chunk acknowledgement");
        var index = RequireNonNegativeInt(root, "chunkIndex", "FileTransfer chunk acknowledgement");
        if (index != 0)
        {
            throw new WebRtcFileTransferProofException(
                "WebRTC FileTransfer proof expected chunk acknowledgement index 0.");
        }

        if (root.TryGetProperty("receivedBytes", out var receivedBytes))
        {
            if (!receivedBytes.TryGetInt32(out var parsedReceivedBytes) ||
                parsedReceivedBytes != expectedReceivedBytes)
            {
                throw new WebRtcFileTransferProofException(
                    "WebRTC FileTransfer chunk acknowledgement receivedBytes did not match the sent chunk.");
            }
        }
    }

    public static void RequireComplete(
        ReadOnlySpan<byte> payload,
        string expectedTransferId,
        int expectedBytes,
        string expectedFileSha256)
    {
        using var document = ParsePayload(payload, "FileTransfer complete");
        var root = document.RootElement;
        RequireOp(root, "complete", "FileTransfer complete");
        RequireTransferIdMatches(root, expectedTransferId, "FileTransfer complete");
        RequireBytesAndSha256(root, expectedBytes, expectedFileSha256, "FileTransfer complete");
    }

    public static FileTransferReceipt RequireCompleteAck(
        ReadOnlySpan<byte> payload,
        string expectedTransferId,
        int expectedBytes,
        string expectedFileSha256)
    {
        using var document = ParsePayload(payload, "FileTransfer complete acknowledgement");
        var root = document.RootElement;
        RequireOp(root, "completeAck", "FileTransfer complete acknowledgement");
        RequireTransferIdMatches(root, expectedTransferId, "FileTransfer complete acknowledgement");

        return RequireBytesAndSha256(
            root,
            expectedBytes,
            expectedFileSha256,
            "FileTransfer complete acknowledgement");
    }

    public static void RequireJsonPayloadWithinLimit(ReadOnlySpan<byte> payload, int maxBytes, string context)
    {
        if (payload.Length == 0 || payload.Length > maxBytes)
        {
            throw new WebRtcFileTransferProofException(
                $"{context} JSON payload length must be in the range 1..{maxBytes} bytes.");
        }
    }

    public static byte[] RequireFileBytes(ReadOnlyMemory<byte> fileBytes, int maxFileBytes)
    {
        if (fileBytes.Length == 0)
        {
            throw new WebRtcFileTransferProofException(
                "WebRTC FileTransfer proof requires a non-empty file payload.");
        }

        if (fileBytes.Length > maxFileBytes)
        {
            throw new WebRtcFileTransferProofException(
                "WebRTC FileTransfer proof file payload exceeded the configured proof limit.");
        }

        return fileBytes.ToArray();
    }

    public static string NewTransferId() =>
        Guid.NewGuid().ToString("D").ToLowerInvariant();

    private static void WriteHeader(Utf8JsonWriter writer, string op, string transferId)
    {
        writer.WriteNumber("version", WireVersion);
        writer.WriteString("op", op);
        writer.WriteString("transferId", transferId);
    }

    private static JsonDocument ParsePayload(ReadOnlySpan<byte> payload, string context)
    {
        try
        {
            return JsonDocument.Parse(payload.ToArray());
        }
        catch (JsonException ex)
        {
            throw new WebRtcFileTransferProofException(
                $"WebRTC {context} payload was malformed JSON.",
                ex);
        }
    }

    private static void RequireOp(JsonElement root, string expectedOp, string context)
    {
        if (root.ValueKind != JsonValueKind.Object ||
            !root.TryGetProperty("op", out var op) ||
            op.ValueKind != JsonValueKind.String ||
            !string.Equals(op.GetString(), expectedOp, StringComparison.Ordinal))
        {
            throw new WebRtcFileTransferProofException(
                $"WebRTC {context} payload had an unexpected message op.");
        }

        if (root.TryGetProperty("version", out var version) &&
            (!version.TryGetInt32(out var parsedVersion) || parsedVersion != WireVersion))
        {
            throw new WebRtcFileTransferProofException(
                $"WebRTC {context} payload had an unsupported version.");
        }
    }

    private static void RequireTransferIdMatches(JsonElement root, string expectedTransferId, string context)
    {
        var transferId = RequireString(root, "transferId", context);
        RequireTransferId(transferId);
        if (!string.Equals(transferId, expectedTransferId, StringComparison.Ordinal))
        {
            throw new WebRtcFileTransferProofException(
                $"WebRTC {context} transfer id did not match the active transfer.");
        }
    }

    private static string RequireString(JsonElement root, string name, string context)
    {
        if (!root.TryGetProperty(name, out var value) ||
            value.ValueKind != JsonValueKind.String ||
            string.IsNullOrWhiteSpace(value.GetString()))
        {
            throw new WebRtcFileTransferProofException(
                $"WebRTC {context} payload is missing a required string field.");
        }

        return value.GetString()!;
    }

    private static int RequirePositiveInt(JsonElement root, string name, string context)
    {
        var value = RequireNonNegativeInt(root, name, context);
        if (value <= 0)
        {
            throw new WebRtcFileTransferProofException(
                $"WebRTC {context} payload requires a positive integer field.");
        }

        return value;
    }

    private static int RequireNonNegativeInt(JsonElement root, string name, string context)
    {
        if (!root.TryGetProperty(name, out var value) ||
            value.ValueKind != JsonValueKind.Number ||
            !value.TryGetInt32(out var parsed) ||
            parsed < 0)
        {
            throw new WebRtcFileTransferProofException(
                $"WebRTC {context} payload is missing a required non-negative integer field.");
        }

        return parsed;
    }

    private static FileTransferReceipt RequireBytesAndSha256(
        JsonElement root,
        int expectedBytes,
        string expectedFileSha256,
        string context)
    {
        var bytes = RequirePositiveInt(root, "receivedBytes", context);
        if (bytes != expectedBytes)
        {
            throw new WebRtcFileTransferProofException(
                $"WebRTC {context} byte count did not match the manifest.");
        }

        var fileSha256 = RequireBase64Sha256(root, "fileSha256", context);
        if (!string.Equals(fileSha256, expectedFileSha256, StringComparison.Ordinal))
        {
            throw new WebRtcFileTransferProofException(
                $"WebRTC {context} SHA-256 did not match the manifest.");
        }

        return new FileTransferReceipt(fileSha256, bytes);
    }

    private static string RequireBase64Sha256(JsonElement root, string name, string context)
    {
        if (!root.TryGetProperty(name, out var value) ||
            value.ValueKind != JsonValueKind.String)
        {
            throw new WebRtcFileTransferProofException(
                $"WebRTC {context} payload is missing a required SHA-256 field.");
        }

        byte[] bytes;
        try
        {
            bytes = value.GetBytesFromBase64();
        }
        catch (FormatException ex)
        {
            throw new WebRtcFileTransferProofException(
                $"WebRTC {context} payload contained malformed base64 SHA-256.",
                ex);
        }

        if (bytes.Length != 32)
        {
            throw new WebRtcFileTransferProofException(
                $"WebRTC {context} SHA-256 must be 32 bytes.");
        }

        return Convert.ToHexString(bytes).ToLowerInvariant();
    }

    private static byte[] HexToBytes(string value)
    {
        WebRtcFileTransferProofValidation.RequireLowerSha256(value, "FileTransfer SHA-256");
        return Convert.FromHexString(value);
    }

    private static void RequireTransferId(string transferId)
    {
        if (transferId.Trim() != transferId ||
            !Guid.TryParseExact(transferId, "D", out var parsed) ||
            !string.Equals(parsed.ToString("D"), transferId, StringComparison.Ordinal))
        {
            throw new WebRtcFileTransferProofException(
                "WebRTC FileTransfer transfer id must be a canonical lowercase UUID.");
        }
    }
}

internal static class WebRtcFileTransferProofValidation
{
    public static void RequireRole(
        WebRtcAppSecureSessionKeys keys,
        WebRtcAppSecureRole expectedRole,
        string context)
    {
        if (keys.Role != expectedRole)
        {
            throw new WebRtcFileTransferProofException(
                $"{context} requires {expectedRole} SBWC session keys.");
        }
    }

    public static void RequireConnected(IWebRtcProductControlPlane controlPlane, string context)
    {
        if (!controlPlane.IsConnected)
        {
            throw new WebRtcFileTransferProofException(
                $"{context} requires a connected product-control plane.");
        }
    }

    public static void RequireLowerSha256(string value, string label)
    {
        if (value.Length != 64 || !IsLowerHex(value))
        {
            throw new WebRtcFileTransferProofException(
                $"{label} must be lowercase SHA-256 hex.");
        }
    }

    public static string Sha256Hex(byte[] bytes) =>
        Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();

    public static bool IsLowerHex(string value)
    {
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
