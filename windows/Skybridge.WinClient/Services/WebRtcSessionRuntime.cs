using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

public interface IWebRtcSessionDataPlaneProvider
{
    LiveWebRtcSessionContext RequireLiveSession(ConnectionLaunchRequest request);
}

public sealed record LiveWebRtcSessionContext(
    ISkyBridgeDataPlane DataPlane,
    string PeerDeviceId,
    string PeerPublicKeyFingerprint,
    string SessionIdHex,
    string AdapterBinding,
    string LocalEndpoint,
    string RemoteEndpoint,
    string SelectedCandidatePair,
    ulong TimestampWindowMs,
    IReadOnlyList<ChannelMapping> ChannelMappings);

public interface IWebRtcSessionRuntimeConsumer
{
    Task StartAsync(
        LiveWebRtcSessionContext session,
        ConnectionLaunchRequest request,
        CancellationToken cancellationToken = default);

    Task StopAsync(CancellationToken cancellationToken = default);
}

public sealed class WebRtcControlSmokeOptions
{
    public WebRtcControlSmokeOptions(TimeSpan timeout, string? evidencePath = null)
    {
        if (timeout <= TimeSpan.Zero)
        {
            throw new InvalidOperationException("WebRTC control smoke timeout must be positive.");
        }

        Timeout = timeout;
        EvidencePath = string.IsNullOrWhiteSpace(evidencePath) ? null : Path.GetFullPath(evidencePath);
    }

    public TimeSpan Timeout { get; }

    public string? EvidencePath { get; }
}

public sealed class WebRtcControlSmokeClient : IWebRtcSessionRuntimeConsumer
{
    private static readonly JsonSerializerOptions EvidenceJsonOptions = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        WriteIndented = true
    };

    private readonly WebRtcControlSmokeOptions _options;
    private readonly object _gate = new();
    private TaskCompletionSource<byte[]>? _ack;
    private byte[]? _probePayload;
    private ISkyBridgeDataPlane? _subscribedDataPlane;
    private bool _subscribed;

    public WebRtcControlSmokeClient(WebRtcControlSmokeOptions options)
    {
        _options = options ?? throw new ArgumentNullException(nameof(options));
    }

    public async Task StartAsync(
        LiveWebRtcSessionContext session,
        ConnectionLaunchRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(session);
        ArgumentNullException.ThrowIfNull(request);
        request.Plan.ValidateForLaunch(request.PairingMaterial);

        if (!session.DataPlane.IsConnected)
        {
            throw new InvalidOperationException("WebRTC control smoke requires a connected data plane.");
        }

        var nonce = Convert.ToHexString(RandomNumberGenerator.GetBytes(16)).ToLowerInvariant();
        var sentAt = DateTimeOffset.UtcNow;
        var payloadText =
            "skybridge-control-smoke:v1;"
            + $"nonce={nonce};"
            + $"peer={session.PeerDeviceId};"
            + $"session={session.SessionIdHex};"
            + $"candidate={session.SelectedCandidatePair}";
        var payload = Encoding.UTF8.GetBytes(payloadText);
        var ack = new TaskCompletionSource<byte[]>(TaskCreationOptions.RunContinuationsAsynchronously);

        lock (_gate)
        {
            if (_subscribed)
            {
                throw new InvalidOperationException("WebRTC control smoke is already running.");
            }

            _ack = ack;
            _probePayload = payload;
            _subscribedDataPlane = session.DataPlane;
            session.DataPlane.FrameReceived += OnFrameReceived;
            _subscribed = true;
        }

        try
        {
            await session.DataPlane
                .SendAsync(DataPlaneChannel.Control, payload, cancellationToken)
                .ConfigureAwait(false);

            var receivedPayload = await WaitForAckAsync(ack, cancellationToken).ConfigureAwait(false);
            var receivedAt = DateTimeOffset.UtcNow;
            WriteEvidence(
                session,
                request,
                payload,
                receivedPayload,
                nonce,
                sentAt,
                receivedAt);
        }
        finally
        {
            await StopAsync(cancellationToken).ConfigureAwait(false);
        }
    }

    public Task StopAsync(CancellationToken cancellationToken = default)
    {
        _ = cancellationToken;
        ISkyBridgeDataPlane? dataPlane;
        lock (_gate)
        {
            if (!_subscribed)
            {
                return Task.CompletedTask;
            }

            dataPlane = _subscribedDataPlane;
            _ack = null;
            _probePayload = null;
            _subscribedDataPlane = null;
            _subscribed = false;
        }

        if (dataPlane is not null)
        {
            dataPlane.FrameReceived -= OnFrameReceived;
        }

        return Task.CompletedTask;
    }

    private async Task<byte[]> WaitForAckAsync(
        TaskCompletionSource<byte[]> ack,
        CancellationToken cancellationToken)
    {
        var delay = Task.Delay(_options.Timeout, cancellationToken);
        var completed = await Task.WhenAny(ack.Task, delay).ConfigureAwait(false);
        if (completed == ack.Task)
        {
            return await ack.Task.ConfigureAwait(false);
        }

        cancellationToken.ThrowIfCancellationRequested();
        throw new TimeoutException(
            $"WebRTC control smoke did not receive its echoed control frame within {_options.Timeout.TotalSeconds:F0}s.");
    }

    private void OnFrameReceived(DataPlaneChannel channel, byte[] payload)
    {
        TaskCompletionSource<byte[]>? ack;
        byte[]? expected;
        lock (_gate)
        {
            ack = _ack;
            expected = _probePayload;
        }

        if (ack is null || expected is null)
        {
            return;
        }

        if (channel != DataPlaneChannel.Control)
        {
            ack.TrySetException(new InvalidDataException(
                $"WebRTC control smoke received an unexpected channel: {channel}."));
            return;
        }

        if (!payload.AsSpan().SequenceEqual(expected))
        {
            ack.TrySetException(new InvalidDataException(
                "WebRTC control smoke received a control frame with a mismatched nonce or payload."));
            return;
        }

        ack.TrySetResult(payload);
    }

    private void WriteEvidence(
        LiveWebRtcSessionContext session,
        ConnectionLaunchRequest request,
        byte[] sentPayload,
        byte[] receivedPayload,
        string nonce,
        DateTimeOffset sentAt,
        DateTimeOffset receivedAt)
    {
        if (_options.EvidencePath is null)
        {
            return;
        }

        var parent = Path.GetDirectoryName(_options.EvidencePath);
        if (!string.IsNullOrWhiteSpace(parent))
        {
            Directory.CreateDirectory(parent);
        }

        var evidence = new WebRtcControlSmokeEvidence(
            FactoryMode: "webrtc-session",
            RuntimeProfile: "windows-product-service",
            Consumer: nameof(WebRtcControlSmokeClient),
            DataPlaneProfile: "sbf1-multiplex-helper",
            PeerDeviceId: session.PeerDeviceId,
            PeerPublicKeyFingerprint: session.PeerPublicKeyFingerprint,
            SessionIdHex: session.SessionIdHex,
            AdapterBinding: session.AdapterBinding,
            LocalEndpoint: session.LocalEndpoint,
            RemoteEndpoint: session.RemoteEndpoint,
            SelectedCandidatePair: session.SelectedCandidatePair,
            TimestampWindowMs: session.TimestampWindowMs,
            PlanTransportKind: request.Plan.TransportKind.ToString(),
            PlanTransportAudit: request.Plan.TransportAudit.ToString(),
            ChannelMappings: session.ChannelMappings.Select(ChannelMappingEvidence.FromMapping).ToArray(),
            NonceHex: nonce,
            SentPayloadSha256Hex: Sha256Hex(sentPayload),
            ReceivedPayloadSha256Hex: Sha256Hex(receivedPayload),
            ProductSendCount: 1,
            ProductReceiveCount: 1,
            SentAtUnixMs: sentAt.ToUnixTimeMilliseconds(),
            ReceivedAtUnixMs: receivedAt.ToUnixTimeMilliseconds(),
            Scope: "Windows WinClient service runtime over live WebRTC helper session; Mac side is a temporary helper echo peer, not the Mac product app.");

        var json = JsonSerializer.Serialize(evidence, EvidenceJsonOptions);
        var tmp = _options.EvidencePath + ".tmp";
        File.WriteAllText(tmp, json, new UTF8Encoding(false));
        File.Move(tmp, _options.EvidencePath, overwrite: true);
    }

    private static string Sha256Hex(byte[] bytes) =>
        Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();

    private sealed record WebRtcControlSmokeEvidence(
        string FactoryMode,
        string RuntimeProfile,
        string Consumer,
        string DataPlaneProfile,
        string PeerDeviceId,
        string PeerPublicKeyFingerprint,
        string SessionIdHex,
        string AdapterBinding,
        string LocalEndpoint,
        string RemoteEndpoint,
        string SelectedCandidatePair,
        ulong TimestampWindowMs,
        string PlanTransportKind,
        string PlanTransportAudit,
        IReadOnlyList<ChannelMappingEvidence> ChannelMappings,
        string NonceHex,
        string SentPayloadSha256Hex,
        string ReceivedPayloadSha256Hex,
        int ProductSendCount,
        int ProductReceiveCount,
        long SentAtUnixMs,
        long ReceivedAtUnixMs,
        string Scope);

    private sealed record ChannelMappingEvidence(
        string Channel,
        string Reliability,
        ushort MaxRetransmits,
        string BindingKind,
        bool HeadOfLineIsolated)
    {
        public static ChannelMappingEvidence FromMapping(ChannelMapping mapping) =>
            new(
                mapping.Channel.ToString(),
                mapping.Reliability.ToString(),
                mapping.MaxRetransmits,
                mapping.BindingKind.ToString(),
                mapping.HeadOfLineIsolated);
    }
}
