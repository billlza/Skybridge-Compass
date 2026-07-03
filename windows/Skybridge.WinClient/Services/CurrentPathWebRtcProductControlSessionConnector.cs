using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

public sealed class CurrentPathWebRtcProductControlSessionConnectorOptions
{
    public CurrentPathWebRtcProductControlSessionConnectorOptions(
        string sessionId,
        string localDeviceId,
        string remoteDeviceId,
        string remotePublicKeyFingerprint,
        CurrentPathProtocolSigningAlgorithm remoteProtocolSigningAlgorithm,
        TimeSpan? signalFileTimeout = null,
        TimeSpan? remoteAnswerTimeout = null,
        int maxRemoteIceCandidates = 128)
    {
        SessionId = CurrentPathWebRtcSignalingEnvelope.NormalizeSessionId(sessionId);
        LocalDeviceId = CurrentPathProtocolIdentityBinding.NormalizeDeviceId(localDeviceId);
        RemoteDeviceId = CurrentPathProtocolIdentityBinding.NormalizeDeviceId(remoteDeviceId);
        ArgumentException.ThrowIfNullOrWhiteSpace(remotePublicKeyFingerprint);
        RemotePublicKeyFingerprint = remotePublicKeyFingerprint.Trim();
        if (!CurrentPathProtocolIdentityBinding.IsLowerHex(RemotePublicKeyFingerprint, 64))
        {
            throw new InvalidDataException("Current-path product-control remote public key fingerprint must be 64 lowercase hex characters.");
        }

        RemoteProtocolSigningAlgorithm = remoteProtocolSigningAlgorithm;
        if (RemoteProtocolSigningAlgorithm != CurrentPathProtocolSigningAlgorithm.MLDsa65)
        {
            throw new InvalidDataException("Current-path product-control remote identity must use ML-DSA-65.");
        }

        SignalFileTimeout = signalFileTimeout ?? TimeSpan.FromSeconds(30);
        RemoteAnswerTimeout = remoteAnswerTimeout ?? TimeSpan.FromSeconds(120);
        if (SignalFileTimeout <= TimeSpan.Zero)
        {
            throw new InvalidDataException("Current-path product-control signal file timeout must be positive.");
        }

        if (RemoteAnswerTimeout <= TimeSpan.Zero)
        {
            throw new InvalidDataException("Current-path product-control remote answer timeout must be positive.");
        }

        if (maxRemoteIceCandidates is < 0 or > 256)
        {
            throw new InvalidDataException("Current-path product-control remote ICE candidate limit must be between 0 and 256.");
        }

        MaxRemoteIceCandidates = maxRemoteIceCandidates;
    }

    public string SessionId { get; }

    public string LocalDeviceId { get; }

    public string RemoteDeviceId { get; }

    public string RemotePublicKeyFingerprint { get; }

    public CurrentPathProtocolSigningAlgorithm RemoteProtocolSigningAlgorithm { get; }

    public TimeSpan SignalFileTimeout { get; }

    public TimeSpan RemoteAnswerTimeout { get; }

    public int MaxRemoteIceCandidates { get; }
}

public sealed class CurrentPathWebRtcProductControlSessionConnector : IWebRtcProductControlSessionConnector
{
    private readonly IWebRtcHelperLaunchClient _helperLaunchClient;
    private readonly CurrentPathWebSocketSignalingClient _signalingClient;
    private readonly CurrentPathWebRtcHelperSignalingBridge _bridge;
    private readonly CurrentPathWebRtcProductControlSessionConnectorOptions _options;

    public CurrentPathWebRtcProductControlSessionConnector(
        IWebRtcHelperLaunchClient helperLaunchClient,
        CurrentPathWebSocketSignalingClient signalingClient,
        CurrentPathWebRtcHelperSignalingBridge bridge,
        CurrentPathWebRtcProductControlSessionConnectorOptions options)
    {
        _helperLaunchClient = helperLaunchClient ?? throw new ArgumentNullException(nameof(helperLaunchClient));
        _signalingClient = signalingClient ?? throw new ArgumentNullException(nameof(signalingClient));
        _bridge = bridge ?? throw new ArgumentNullException(nameof(bridge));
        _options = options ?? throw new ArgumentNullException(nameof(options));
    }

    public async Task<WebRtcHelperSession> ConnectAsync(
        WebRtcHelperProductControlSessionRequest sessionRequest,
        WindowsTransportAdapterRequest adapterRequest,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(sessionRequest);
        ArgumentNullException.ThrowIfNull(adapterRequest);
        ValidateAdapterRequest(adapterRequest);
        if (!_signalingClient.IsBound)
        {
            throw new InvalidOperationException("Current-path product-control connector requires a bound WebSocket signaling client.");
        }

        WebRtcHelperPendingSession? pendingSession = null;
        try
        {
            pendingSession = await _helperLaunchClient
                .StartProductControlSessionAsync(sessionRequest, cancellationToken)
                .ConfigureAwait(false);

            var bridgeOptions = new CurrentPathWebRtcHelperSignalingBridgeOptions(
                _options.SessionId,
                _options.LocalDeviceId,
                _options.RemoteDeviceId,
                pendingSession.LocalSignalPath,
                pendingSession.RemoteSignalPath,
                _options.SignalFileTimeout,
                _options.RemoteAnswerTimeout,
                _options.MaxRemoteIceCandidates);

            if (sessionRequest.AsAnswerer)
            {
                await _bridge.ExchangeAnswererAsync(_signalingClient, bridgeOptions, cancellationToken)
                    .ConfigureAwait(false);
            }
            else
            {
                await _bridge.ExchangeOffererAsync(_signalingClient, bridgeOptions, cancellationToken)
                    .ConfigureAwait(false);
            }

            var liveSession = await pendingSession.WaitReadyAsync(cancellationToken).ConfigureAwait(false);
            pendingSession = null;
            return liveSession;
        }
        finally
        {
            if (pendingSession is not null)
            {
                await pendingSession.DisposeAsync().ConfigureAwait(false);
            }
        }
    }

    private void ValidateAdapterRequest(WindowsTransportAdapterRequest request)
    {
        if (!string.Equals(request.PairingMaterial.DeviceId, _options.RemoteDeviceId, StringComparison.Ordinal) ||
            !string.Equals(request.DiscoveredPeer.DeviceId, _options.RemoteDeviceId, StringComparison.Ordinal))
        {
            throw new InvalidOperationException("Current-path product-control peer device id does not match the requested paired peer.");
        }

        if (!string.Equals(
                request.PairingMaterial.PublicKeyFingerprint,
                _options.RemotePublicKeyFingerprint,
                StringComparison.Ordinal) ||
            !string.Equals(
                request.DiscoveredPeer.PublicKeyFingerprint,
                _options.RemotePublicKeyFingerprint,
                StringComparison.Ordinal))
        {
            throw new InvalidOperationException("Current-path product-control peer fingerprint does not match the requested paired peer.");
        }
    }
}
