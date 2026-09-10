using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;

namespace Skybridge.WinClient.Services;

/// <summary>One authenticated compatible-LAN control session shared by native feature operations.</summary>
internal sealed class LanProductControlSession : IAsyncDisposable
{
    private readonly TcpProductControlTransport _transport;
    private readonly ProductSessionKeys _keys;
    private readonly WebRtcAppSecureSessionKeys _appKeys;
    private readonly ProductHandshakePeerContext _peer;
    private readonly LanProductIdentity _localIdentity;
    private readonly DiscoveryPeerEndpoint _controlEndpoint;
    private readonly CancellationTokenSource _lifetime;
    private readonly TaskCompletionSource _admitted = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly object _stateGate = new();
    private readonly ulong _admissionPing = BinaryPrimitives.ReadUInt64BigEndian(RandomNumberGenerator.GetBytes(8));
    private readonly Task _receiver;
    private readonly Task _heartbeat;
    private readonly Task<Exception?> _completion;
    private readonly SemaphoreSlim _disposal = new(1, 1);
    private int _disposed;
    private int _admissionStarted;
    private bool _ready;
    private bool _receivedAdmissionPong;
    private LanProductIdentity? _remoteIdentity;

    internal LanProductControlSession(TcpProductControlTransport transport, ProductSessionKeys keys,
        ProductHandshakePeerContext peer, LanProductIdentity localIdentity, DiscoveryPeerEndpoint controlEndpoint,
        IPAddress remoteAddress, CancellationToken cancellationToken)
    {
        _transport = transport;
        _keys = keys.Clone();
        _appKeys = WebRtcProductHandshakeSessionKeys.ToWebRtcKeys(keys);
        _peer = peer;
        _localIdentity = localIdentity;
        _controlEndpoint = controlEndpoint;
        RemoteAddress = remoteAddress;
        _lifetime = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        Lifetime = _lifetime.Token;
        _receiver = ReceiveAsync();
        _heartbeat = HeartbeatAsync();
        _completion = ObserveAsync();
    }

    internal Task<Exception?> Completion => _completion;
    internal CancellationToken Lifetime { get; }
    internal IPAddress RemoteAddress { get; }
    internal string SessionId => _keys.SessionId;
    internal LanProductIdentity LocalIdentity => _localIdentity;
    internal bool IsReady => Volatile.Read(ref _ready) && !Lifetime.IsCancellationRequested && Volatile.Read(ref _disposed) == 0;

    internal static async Task<LanProductControlSession> ConnectAsync(ProductPeerAuthentication authentication,
        ushort? localFileTransferPort, CancellationToken cancellationToken)
    {
        using var authority = authentication;
        var endpoint = authority.Endpoint;
        if (endpoint.Service != SkyBridgeProtocolConstants.TcpControlDnsSdService || endpoint.Provenance != "resolved-dns-sd-endpoint" ||
            string.IsNullOrWhiteSpace(endpoint.HostName) || endpoint.Port == 0)
            throw new InvalidDataException("LAN control requires the selected resolved product-control endpoint.");
        var client = new TcpClient();
        TcpProductControlTransport? transport = null;
        LanProductControlSession? session = null;
        try
        {
            using (var connecting = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken))
            {
                connecting.CancelAfter(TimeSpan.FromSeconds(10));
                try { await client.ConnectAsync(endpoint.HostName, endpoint.Port, connecting.Token).ConfigureAwait(false); }
                catch (OperationCanceledException error) when (!cancellationToken.IsCancellationRequested && connecting.IsCancellationRequested)
                { throw new TimeoutException("The selected peer did not accept the LAN control connection within 10 seconds.", error); }
            }
            transport = new(client, LanProductControlMessages.MaximumFrameBytes, LanProductControlMessages.MaximumFrameBytes);
            using var handshake = await new ProductHandshakeCore(authority.Crypto)
                .StartInitiatorAsync(transport, authority.Peer, cancellationToken).ConfigureAwait(false);
            var remoteAddress = (client.Client.RemoteEndPoint as IPEndPoint)?.Address
                ?? throw new IOException("The authenticated TCP connection has no IP endpoint.");
            session = new(transport, handshake.Keys, authority.Peer,
                LanProductControlMessages.LocalIdentity(authority, localFileTransferPort, DateTimeOffset.UtcNow),
                endpoint, remoteAddress, cancellationToken);
            transport = null;
            await session.CompleteAdmissionAsync(cancellationToken).ConfigureAwait(false);
            return session;
        }
        catch (Exception failure)
        {
            try
            {
                if (session is not null) await session.DisposeAsync().ConfigureAwait(false);
                else if (transport is not null) await transport.DisposeAsync().ConfigureAwait(false);
                else client.Dispose();
            }
            catch (Exception cleanup) { throw new AggregateException("LAN connection and cleanup failed.", failure, cleanup); }
            throw;
        }
    }

    internal async Task CompleteAdmissionAsync(CancellationToken cancellationToken)
    {
        if (Interlocked.Exchange(ref _admissionStarted, 1) != 0)
            throw new InvalidOperationException("This control session has already started peer admission.");
        await SendAsync(LanControlMessageKind.Identity, _localIdentity, cancellationToken).ConfigureAwait(false);
        await SendAsync(LanControlMessageKind.Ping, new LanProductPing(_admissionPing), cancellationToken).ConfigureAwait(false);
        // This ordered pong follows the peer's identity/approval commit and its
        // admission of the exact control-session keys for classic transfers.
        var admission = await Task.WhenAny(_admitted.Task, _completion)
            .WaitAsync(TimeSpan.FromSeconds(60), cancellationToken).ConfigureAwait(false);
        if (admission == _completion)
            throw new IOException("The peer did not complete authenticated LAN admission.", await _completion.ConfigureAwait(false));
        await _admitted.Task.ConfigureAwait(false);
        if (Lifetime.IsCancellationRequested) throw new IOException("The LAN session ended during peer admission.");
        Volatile.Write(ref _ready, true);
    }

    internal byte[] AuthorizeFileTransfer(DiscoveryBrowserPeerCandidate candidate, string transferId)
    {
        ArgumentNullException.ThrowIfNull(candidate);
        lock (_stateGate)
        {
            RequireFileTransferRoute(candidate);
            return FileTransfer.ClassicFileTransferWire.DeriveTransferKey(_keys, transferId);
        }
    }

    internal void RequireFileTransferRoute(DiscoveryBrowserPeerCandidate candidate)
    {
        lock (_stateGate)
        {
            if (!IsReady) throw new InvalidOperationException("An established LAN control session is required for file transfer.");
            var identity = Volatile.Read(ref _remoteIdentity) ?? throw new InvalidOperationException("Peer identity is not established.");
            var route = candidate.Routes.FileTransfer ?? throw new InvalidOperationException("The peer has no resolved file-transfer route.");
            var control = candidate.Routes.Control ?? throw new InvalidOperationException("The peer has no resolved control route.");
            if (RemoteControlHandshakeBinding.CanonicalDeviceId(candidate.Peer.DeviceId) != _peer.PeerDeviceId ||
                candidate.Peer.PublicKeyFingerprint != _peer.PeerPublicKeyFingerprint || control != _controlEndpoint ||
                route.Service != SkyBridgeProtocolConstants.FileTransferDnsSdService || route.Provenance != "resolved-dns-sd-endpoint" ||
                !string.Equals(route.HostName.TrimEnd('.'), control.HostName.TrimEnd('.'), StringComparison.OrdinalIgnoreCase) ||
                route.Port != identity.FileTransferPort || identity.Capabilities?.Contains("file_transfer", StringComparer.Ordinal) != true)
                throw new InvalidDataException("The authenticated control identity did not admit the selected file-transfer route.");
        }
    }

    internal byte[] AuthorizeIncomingTransfer(FileTransfer.ClassicFileMetadata metadata, IPAddress remoteAddress)
    {
        lock (_stateGate)
        {
            if (!IsReady || !RemoteAddress.MapToIPv6().Equals(remoteAddress.MapToIPv6()) || metadata.SenderDeviceId is null ||
                RemoteControlHandshakeBinding.CanonicalDeviceId(metadata.SenderDeviceId) != _peer.PeerDeviceId)
                throw new InvalidDataException("The incoming transfer has no matching live authenticated peer session.");
            var key = FileTransfer.ClassicFileTransferWire.DeriveTransferKey(_keys, metadata.TransferId);
            try
            {
                FileTransfer.ClassicFileTransferWire.Verify(metadata, key);
                return key;
            }
            catch
            {
                CryptographicOperations.ZeroMemory(key);
                throw;
            }
        }
    }

    private async Task SendAsync<T>(LanControlMessageKind kind, T message, CancellationToken cancellationToken)
    {
        var plaintext = LanProductControlMessages.Encode(kind, message);
        try
        {
            var encrypted = WebRtcControlChannelCodec.EncryptAppleLegacyAppPayload(plaintext, _appKeys);
            await _transport.SendAsync(ProductControlTrafficPadding.Wrap(encrypted), cancellationToken).ConfigureAwait(false);
        }
        finally { CryptographicOperations.ZeroMemory(plaintext); }
    }

    private async Task ReceiveAsync()
    {
        while (true)
        {
            var frame = await _transport.ReadAsync(_lifetime.Token).ConfigureAwait(false);
            var encrypted = ProductControlTrafficPadding.Unwrap(frame.ToArray());
            var plaintext = WebRtcControlChannelCodec.DecryptAppleLegacyAppPayload(encrypted, _appKeys);
            try
            {
                var message = LanProductControlMessages.Decode(plaintext);
                switch (message.Kind)
                {
                    case LanControlMessageKind.Identity:
                        var identity = LanProductControlMessages.Payload<LanProductIdentity>(message);
                        LanProductControlMessages.ValidateIdentity(identity, _peer);
                        Volatile.Write(ref _remoteIdentity, identity);
                        if (_receivedAdmissionPong) _admitted.TrySetResult();
                        break;
                    case LanControlMessageKind.Heartbeat:
                        var heartbeat = LanProductControlMessages.Payload<LanProductHeartbeat>(message);
                        if (!double.IsFinite(heartbeat.SentAt) || (heartbeat.DeviceId is not null &&
                            RemoteControlHandshakeBinding.CanonicalDeviceId(heartbeat.DeviceId) != _peer.PeerDeviceId))
                            throw new InvalidDataException("Heartbeat identity conflicts with this authenticated peer.");
                        break;
                    case LanControlMessageKind.Ping:
                        await SendAsync(LanControlMessageKind.Pong, LanProductControlMessages.Payload<LanProductPing>(message), _lifetime.Token).ConfigureAwait(false);
                        break;
                    case LanControlMessageKind.Pong:
                        if (LanProductControlMessages.Payload<LanProductPing>(message).Id != _admissionPing)
                            throw new InvalidDataException("Peer admission pong does not match the current request.");
                        _receivedAdmissionPong = true;
                        if (_remoteIdentity is not null) _admitted.TrySetResult();
                        break;
                    case LanControlMessageKind.Disconnecting:
                        throw new IOException("The peer ended its LAN control session.");
                    default: throw new InvalidDataException("Unsupported LAN control message.");
                }
            }
            finally { CryptographicOperations.ZeroMemory(plaintext); }
        }
    }

    private async Task HeartbeatAsync()
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(20));
        while (await timer.WaitForNextTickAsync(_lifetime.Token).ConfigureAwait(false))
            await SendAsync(LanControlMessageKind.Heartbeat, new LanProductHeartbeat(
                LanProductControlMessages.Timestamp(DateTimeOffset.UtcNow), _localIdentity.DeviceId,
                _localIdentity.Capabilities, _localIdentity.FileTransferPort), _lifetime.Token).ConfigureAwait(false);
    }

    private async Task<Exception?> ObserveAsync()
    {
        var first = await Task.WhenAny(_receiver, _heartbeat).ConfigureAwait(false);
        var failures = new List<Exception>();
        try { await first.ConfigureAwait(false); }
        catch (OperationCanceledException) when (_lifetime.IsCancellationRequested) { }
        catch (Exception error) { failures.Add(error); }
        Volatile.Write(ref _ready, false);
        _lifetime.Cancel();
        _transport.Close();
        foreach (var worker in new[] { _receiver, _heartbeat })
        {
            try { await worker.ConfigureAwait(false); }
            catch (OperationCanceledException) when (_lifetime.IsCancellationRequested) { }
            catch (Exception error) { if (!failures.Contains(error)) failures.Add(error); }
        }
        var failure = failures.Count switch
        {
            0 => null,
            1 => failures[0],
            _ => new AggregateException("LAN session workers failed.", failures)
        };
        return failure;
    }

    public async ValueTask DisposeAsync()
    {
        await _disposal.WaitAsync().ConfigureAwait(false);
        try
        {
            if (Volatile.Read(ref _disposed) != 0) return;
            _lifetime.Cancel();
            _transport.Close();
            await _completion.ConfigureAwait(false);
            await _transport.DisposeAsync().ConfigureAwait(false);
            lock (_stateGate)
            {
                _appKeys.Dispose();
                _keys.Dispose();
                _lifetime.Dispose();
                Volatile.Write(ref _disposed, 1);
            }
        }
        finally { _disposal.Release(); }
    }
}
