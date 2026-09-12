using System.Security.Cryptography;

namespace Skybridge.WinClient.Services.RemoteControl;

/// <summary>Viewer role on the existing authenticated remote-control channel.</summary>
internal sealed class RemoteControlViewerSession : IDisposable
{
    // Match RemoteControlStartupTiming: identity (2s), host approval (45s), configuration (30s).
    private static readonly TimeSpan StartupTimeout = TimeSpan.FromSeconds(77);
    private readonly IProductHandshakeTransport _transport;
    private readonly RemoteControlSecureSession _secure;
    private readonly Func<RemoteH264ScreenFrame, CancellationToken, Task> _receiveFrame;
    private readonly Action<RemoteControlAccess> _accessChanged;
    private readonly object _accessGate = new();
    private readonly TaskCompletionSource<RemoteControlAccess> _ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly RemoteStreamConfiguration _configuration;
    private RemoteControlAccess? _access;
    private bool _acknowledged;
    private bool _receivedSyncFrame;
    private ulong _lastSequence;
    private ulong _lastTimestamp;
    private int _running;
    private bool _stopped;
    private bool _disposed;

    internal RemoteControlViewerSession(IProductHandshakeTransport transport, ProductSessionKeys keys,
        RemoteControlSecurityIdentity localIdentity, Func<RemoteH264ScreenFrame, CancellationToken, Task> receiveFrame,
        Action<RemoteControlAccess> accessChanged)
    {
        ArgumentNullException.ThrowIfNull(localIdentity);
        localIdentity.Validate();
        _transport = transport ?? throw new ArgumentNullException(nameof(transport));
        _receiveFrame = receiveFrame ?? throw new ArgumentNullException(nameof(receiveFrame));
        _accessChanged = accessChanged ?? throw new ArgumentNullException(nameof(accessChanged));
        ArgumentNullException.ThrowIfNull(keys);
        _secure = new RemoteControlSecureSession(keys);
        _configuration = new RemoteStreamConfiguration
        {
            Width = 1280, Height = 720, TargetFrameRate = 30, KeyFrameInterval = 30,
            PreferredCodec = "h264", SupportedVideoFormats = ["h264"], LowLatencyMode = true,
            EnableHardwareAcceleration = true, EnableAppleSiliconOptimization = true, ClipboardSyncEnabled = false,
            // MediaPlayer presents complete decoded frames, so the host must not enable its optional damage-report channel.
            DamageTrackingEnabled = false,
            SeparateCursorChannelEnabled = false, InteractionOverlayChannelEnabled = false,
            ScreenFrameTransport = "sbrf-v1", AudioRedirectionEnabled = false, AudioTransport = "disabled",
            RemoteControlAccessVersion = RemoteControlAccess.CurrentVersion,
            RemoteControlSecurityIdentity = localIdentity,
            StreamConfigurationTransaction = new(Guid.NewGuid()), SentAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000d
        };
    }

    internal Task<RemoteControlAccess> Ready => _ready.Task;
    internal RemoteControlAccess? Access { get { lock (_accessGate) return _acknowledged ? _access : null; } }

    internal async Task RunAsync(CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (Interlocked.Exchange(ref _running, 1) != 0) throw new InvalidOperationException("A viewer session can only be run once.");
        using var startup = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        startup.CancelAfter(StartupTimeout);
        try
        {
            await SendControlAsync(RemoteControlWire.EncodeMessage("streamConfiguration", _configuration), startup.Token).ConfigureAwait(false);
            while (true)
            {
                var token = _acknowledged ? cancellationToken : startup.Token;
                var packet = await _transport.ReadAsync(token).ConfigureAwait(false);
                var opened = _secure.Open(packet.Span, [RemoteControlSecurePacketType.Control, RemoteControlSecurePacketType.Screen]);
                try
                {
                    if (opened.PacketType == RemoteControlSecurePacketType.Control)
                    {
                        HandleControl(RemoteControlWire.Decode<RemoteControlMessage>(opened.Payload));
                    }
                    else
                    {
                        if (!_acknowledged) throw new InvalidDataException("The host sent video before approving the requested stream.");
                        var frame = RemoteControlWire.DecodeH264Frame(opened.Payload);
                        if (frame.Sequence <= _lastSequence || frame.TimestampMicroseconds < _lastTimestamp)
                            throw new InvalidDataException("The ordered desktop stream moved backwards.");
                        if (!_receivedSyncFrame && !frame.IsKeyFrame)
                            throw new InvalidDataException("The desktop stream must begin with an H.264 decoder refresh frame.");
                        if (frame.IsKeyFrame)
                            _ = WindowsH264AccessUnit.Prepare(frame.Bytes, ReadOnlySpan<byte>.Empty, out _);
                        _receivedSyncFrame = true;
                        _lastSequence = frame.Sequence;
                        _lastTimestamp = frame.TimestampMicroseconds;
                        // The live media adapter owns bounded, keyframe-aware buffering.
                        // It must keep slow decoding from holding up host control messages.
                        await _receiveFrame(frame, cancellationToken).ConfigureAwait(false);
                    }
                }
                finally { CryptographicOperations.ZeroMemory(opened.Payload); }
            }
        }
        catch (OperationCanceledException error) when (startup.IsCancellationRequested && !cancellationToken.IsCancellationRequested && !_acknowledged)
        {
            var timeout = new TimeoutException("The host did not finish approval and stream preparation within 77 seconds.", error);
            _ready.TrySetException(timeout);
            throw timeout;
        }
        catch (Exception failure)
        {
            _ready.TrySetException(failure);
            throw;
        }
        finally { Volatile.Write(ref _stopped, true); }
    }

    private void HandleControl(RemoteControlMessage message)
    {
        switch (message.Type)
        {
            case "streamConfigurationAck":
                var acknowledgement = RemoteControlWire.Decode<RemoteStreamAcknowledgement>(message.Payload);
                if (acknowledgement.Transaction != _configuration.StreamConfigurationTransaction ||
                    acknowledgement.StreamRefreshToken is not null || acknowledgement.ScreenFrameTransport != "sbrf-v1" ||
                    acknowledgement.AudioEndpointPresent || acknowledgement.FramePresentationAckVersion is not null ||
                    !double.IsFinite(acknowledgement.AcceptedAt) || acknowledgement.AcceptedAt <= 0 ||
                    acknowledgement.ControlAccess is null)
                    throw new InvalidDataException("The host acknowledgement does not match this viewer's stream transaction and capabilities.");
                ApplyAccess(acknowledgement.ControlAccess);
                lock (_accessGate) _acknowledged = true;
                _ready.TrySetResult(acknowledgement.ControlAccess);
                break;
            case "controlAccess":
                ApplyAccess(RemoteControlWire.Decode<RemoteControlAccess>(message.Payload));
                break;
            case "streamConfigurationRejected":
                var rejection = RemoteControlWire.Decode<RemoteStreamRejection>(message.Payload);
                if (rejection.Transaction != _configuration.StreamConfigurationTransaction)
                    throw new InvalidDataException("The host rejected an unknown stream transaction.");
                throw new InvalidOperationException($"The host rejected remote viewing ({rejection.Code}): {rejection.Message}");
            default:
                throw new InvalidDataException($"Unsupported host control message: {message.Type}.");
        }
    }

    private void ApplyAccess(RemoteControlAccess access)
    {
        access.Validate();
        lock (_accessGate)
        {
            if (_access is { } previous && (access.Revision < previous.Revision ||
                (access.Revision == previous.Revision && access != previous)))
                throw new InvalidDataException("The host changed or replayed an earlier input grant.");
            if (access == _access) return;
            _access = access;
        }
        _accessChanged(access);
    }

    internal Task SendInputAsync<T>(string type, T payload, RemoteControlAccess expectedAccess, CancellationToken cancellationToken)
    {
        if (type is not ("mouseEvent" or "keyboardEvent")) throw new ArgumentOutOfRangeException(nameof(type));
        lock (_accessGate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (!_acknowledged || _access != expectedAccess || !expectedAccess.AllowsInput)
                throw new RemoteControlViewerInputAuthorityChangedException();
        }
        return SendControlAsync(RemoteControlWire.EncodeMessage(type, payload, expectedAccess.Lease), cancellationToken);
    }

    private async Task SendControlAsync(byte[] plaintext, CancellationToken cancellationToken)
    {
        try
        {
            var packet = _secure.Seal(plaintext, RemoteControlSecurePacketType.Control);
            await _transport.SendAsync(packet, cancellationToken).ConfigureAwait(false);
        }
        finally { CryptographicOperations.ZeroMemory(plaintext); }
    }

    public void Dispose()
    {
        lock (_accessGate)
        {
            if (_disposed) return;
            if (Volatile.Read(ref _running) != 0 && !Volatile.Read(ref _stopped))
                throw new InvalidOperationException("Cancel and await the viewer receive loop before retiring its session keys.");
            _disposed = true;
            _access = null;
            _secure.Dispose();
        }
    }
}

internal sealed class RemoteControlViewerInputAuthorityChangedException : InvalidOperationException
{
    internal RemoteControlViewerInputAuthorityChangedException() : base("The host changed input ownership before this event could be sent.") { }
}
