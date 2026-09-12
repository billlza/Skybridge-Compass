using System.Net;
using System.Text.Json;

namespace Skybridge.WinClient.Services.RemoteControl;

internal interface IRemoteControlHostStream : IAsyncDisposable
{
    Task Completion { get; }
    int Width { get; }
    int Height { get; }
    IWindowsRemoteInput Input { get; }
    Task PrepareAsync(CancellationToken cancellationToken);
    void Start();
    void RequestKeyFrame();
}

internal delegate IRemoteControlHostStream RemoteControlHostStreamFactory(
    RemoteStreamConfiguration configuration,
    Func<WindowsDesktopEncodedFrame, CancellationToken, Task> sendVideo,
    Func<WindowsOpusAudioFrame, CancellationToken, ValueTask> sendAudio);

/// <summary>One authenticated controller, one ordered configuration stream, one set of owned native resources.</summary>
internal sealed class RemoteControlHostSession : IAsyncDisposable
{
    private readonly IProductHandshakeTransport _transport;
    private readonly RemoteControlSecureSession _secure;
    private readonly RealtimeMediaPacketSender _audioSender;
    private readonly IPAddress _peerAddress;
    private readonly string _sessionId;
    private readonly RemoteControlHostStreamFactory _createStream;
    private readonly CancellationTokenSource _lifetime = new();
    private readonly Action<long, long> _reportCounters;
    private readonly RemoteControlHostAccessCoordinator _access;
    private readonly Guid _admissionId;
    private readonly SemaphoreSlim _configurationGate = new(1, 1);
    private readonly SemaphoreSlim _videoBoundary = new(1, 1);
    private bool _accessNegotiated;
    private int? _accessVersion;
    private IRemoteControlHostStream? _stream;
    private RemoteStreamConfiguration? _configuration;
    private byte[]? _lastConfiguration;
    private byte[]? _lastAcknowledgement;
    private System.Net.Sockets.UdpClient? _audioSocket;
    private ulong _sequence;
    private ulong _firstSequenceOfConfiguration = 1;
    private ulong _lastPresentedSequence;
    private long _framesSent;
    private long _audioPacketsSent;
    private ulong _nextAudioTimestampSamples;
    private bool _disposed;
    private bool _retired;
    private bool _secretsDisposed;

    internal RemoteControlHostSession(IProductHandshakeTransport transport, ProductSessionKeys keys,
        IPAddress peerAddress, RemoteControlHostStreamFactory createStream, Action<long, long> reportCounters,
        RemoteControlHostAccessCoordinator access, Guid admissionId)
    {
        _transport = transport;
        _secure = new RemoteControlSecureSession(keys);
        _audioSender = new RealtimeMediaPacketSender(keys);
        _peerAddress = peerAddress;
        _sessionId = keys.SessionId;
        _createStream = createStream;
        _reportCounters = reportCounters;
        _access = access;
        _admissionId = admissionId;
    }

    public async Task RunAsync(CancellationToken cancellationToken)
    {
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, _lifetime.Token);
        using var initialConfigurationDeadline = CancellationTokenSource.CreateLinkedTokenSource(linked.Token);
        initialConfigurationDeadline.CancelAfter(TimeSpan.FromSeconds(30));
        while (true)
        {
            var read = _transport.ReadAsync(_configuration is null ? initialConfigurationDeadline.Token : linked.Token);
            if (_stream is { } stream && await Task.WhenAny(read, stream.Completion).ConfigureAwait(false) == stream.Completion)
            {
                await linked.CancelAsync().ConfigureAwait(false);
                Exception? readFailure = null;
                try { await read.ConfigureAwait(false); }
                catch (OperationCanceledException) when (linked.IsCancellationRequested) { }
                catch (Exception failure) { readFailure = failure; }
                try { await stream.Completion.ConfigureAwait(false); }
                catch (Exception failure) when (readFailure is not null)
                { throw new AggregateException("Both desktop streaming and its control reader failed.", failure, readFailure); }
                throw new IOException("Desktop streaming ended while its control session was still active.", readFailure);
            }
            ReadOnlyMemory<byte> frame;
            try { frame = await read.ConfigureAwait(false); }
            catch (OperationCanceledException failure) when (_configuration is null &&
                initialConfigurationDeadline.IsCancellationRequested && !linked.IsCancellationRequested)
            {
                throw new TimeoutException("No desktop configuration arrived within thirty seconds.", failure);
            }
            var opened = _secure.Open(frame.Span, [RemoteControlSecurePacketType.Control]);
            var message = RemoteControlWire.Decode<RemoteControlMessage>(opened.Payload);
            switch (message.Type)
            {
                case "streamConfiguration":
                    await ApplyConfigurationAsync(message.Payload, linked.Token).ConfigureAwait(false);
                    initialConfigurationDeadline.CancelAfter(Timeout.InfiniteTimeSpan);
                    break;
                case "mouseEvent":
                    RequireActiveStream();
                    var pointer = RemoteControlWire.Decode<RemotePointerEvent>(message.Payload);
                    await _access.ApplyInputAsync(_admissionId, message.InputControlLease, () => HandlePointer(pointer), linked.Token).ConfigureAwait(false);
                    break;
                case "keyboardEvent":
                    RequireActiveStream();
                    var key = RemoteControlWire.Decode<RemoteKeyEvent>(message.Payload);
                    await _access.ApplyInputAsync(_admissionId, message.InputControlLease, () => HandleKey(key), linked.Token).ConfigureAwait(false);
                    break;
                case "framePresentationAck": HandlePresentation(RemoteControlWire.Decode<RemoteFrameAcknowledgement>(message.Payload)); break;
                default: throw new InvalidDataException($"Unsupported remote-control message type: {message.Type}.");
            }
        }
    }

    private async Task ApplyConfigurationAsync(ReadOnlyMemory<byte> payload, CancellationToken cancellationToken)
    {
        await _configurationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { await ApplyConfigurationOperationAsync(payload, cancellationToken).ConfigureAwait(false); }
        finally { _configurationGate.Release(); }
    }

    private async Task ApplyConfigurationOperationAsync(ReadOnlyMemory<byte> payload, CancellationToken cancellationToken)
    {
        var configuration = RemoteControlWire.Decode<RemoteStreamConfiguration>(payload);
        try
        {
            await EnsureAccessApprovedAsync(configuration, cancellationToken).ConfigureAwait(false);
            using var phase = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            phase.CancelAfter(TimeSpan.FromSeconds(30));
            try
            {
                await ApplyConfigurationCoreAsync(configuration, phase.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException failure) when (phase.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
            {
                throw new ConfigurationDeadlineException(failure);
            }
        }
        catch (Exception failure) when (RejectionFor(configuration, failure) is not null)
        {
            var rejection = RejectionFor(configuration, failure)
                ?? throw new InvalidOperationException("The configuration failure has no rejection classification.", failure);
            try
            {
                await SendControlAsync(RemoteControlWire.EncodeMessage("streamConfigurationRejected", rejection), cancellationToken).ConfigureAwait(false);
            }
            catch (Exception sendFailure)
            {
                throw new AggregateException("Stream preparation failed and its rejection could not be delivered.", failure, sendFailure);
            }
            throw;
        }
    }

    private static RemoteStreamRejection? RejectionFor(RemoteStreamConfiguration configuration, Exception failure)
    {
        if (configuration.StreamConfigurationTransaction is not { Id: var id } transaction || id == Guid.Empty) return null;
        return failure switch
        {
            WindowsAudioOutputUnavailableException => new(transaction, "audio-device-unavailable",
                "这台电脑没有可用的系统声音输出。请连接音频输出设备，或关闭远程声音后重新连接。"),
            WindowsDesktopException { Failure: WindowsDesktopFailure.InteractiveDesktopUnavailable } => new(transaction,
                "desktop-unavailable", "Windows 桌面已锁定、断开或无法访问。请回到已登录桌面后重新连接。"),
            WindowsDesktopException => new(transaction, "capture-start-failed", "Windows 无法准备桌面画面，请在被控电脑上查看错误并重试。"),
            ApprovalDeadlineException => new(transaction, "approval-timeout", "等待被控电脑批准已超时。请重新连接，并在被控电脑上批准请求。"),
            ConfigurationDeadlineException => new(transaction, "configuration-timeout", "Windows 未能及时完成桌面配置，请稍后重新连接。"),
            TimeoutException => new(transaction, "capture-start-timeout", "Windows 未能及时准备桌面画面，请在被控电脑上查看错误并重试。"),
            InvalidDataException => new(transaction, "invalid-configuration", "控制器请求的桌面配置无效。"),
            NotSupportedException => new(transaction, "unsupported-configuration", "这台电脑不支持控制器请求的桌面配置。"),
            _ => null
        };
    }

    private sealed class ConfigurationDeadlineException(Exception failure)
        : TimeoutException("The desktop configuration did not complete within thirty seconds.", failure);

    private sealed class ApprovalDeadlineException(Exception failure)
        : TimeoutException("The host did not approve remote access within forty-five seconds.", failure);

    private async Task EnsureAccessApprovedAsync(RemoteStreamConfiguration configuration, CancellationToken cancellationToken)
    {
        configuration.Validate(_peerAddress, _sessionId);
        if (_accessNegotiated && _accessVersion != configuration.RemoteControlAccessVersion)
            throw new InvalidDataException("Remote input access negotiation cannot change within an authenticated session.");
        if (!_accessNegotiated)
        {
            // Match the existing cross-platform approval budget. Capture preparation
            // receives its own deadline only after the local host grants access.
            using var approval = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            approval.CancelAfter(TimeSpan.FromSeconds(45));
            try
            {
                await _access.RequestApprovalAsync(
                    _admissionId,
                    configuration.RemoteControlAccessVersion == RemoteControlAccess.CurrentVersion,
                    new RemoteControlHostAccessOperations(ReleaseInputAsync, PublishAccessAsync),
                    approval.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException failure) when (approval.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
            {
                throw new ApprovalDeadlineException(failure);
            }
            _accessVersion = configuration.RemoteControlAccessVersion;
            _accessNegotiated = true;
        }
    }

    private async Task ApplyConfigurationCoreAsync(RemoteStreamConfiguration configuration, CancellationToken cancellationToken)
    {
        var normalized = JsonSerializer.SerializeToUtf8Bytes(configuration, RemoteControlWire.JsonOptions);
        if (_configuration?.StreamConfigurationTransaction == configuration.StreamConfigurationTransaction)
        {
            if (_lastConfiguration is null || !normalized.AsSpan().SequenceEqual(_lastConfiguration))
                throw new InvalidDataException("A repeated stream transaction changed its configuration.");
            await SendControlAsync(_lastAcknowledgement!, cancellationToken).ConfigureAwait(false);
            return;
        }

        var previous = _configuration;
        var reuse = configuration.StreamRefreshToken is not null && _stream is not null &&
            previous is { IsStop: false } && !configuration.IsStop &&
            JsonSerializer.SerializeToUtf8Bytes(configuration with
            {
                StreamConfigurationTransaction = previous.StreamConfigurationTransaction,
                StreamRefreshToken = previous.StreamRefreshToken,
                SentAt = previous.SentAt
            }, RemoteControlWire.JsonOptions).AsSpan().SequenceEqual(_lastConfiguration);
        if (!reuse) await StopStreamAsync().ConfigureAwait(false);
        if (!reuse && !configuration.IsStop)
        {
            if (configuration.AudioRedirectionEnabled == true)
            {
                var endpoint = configuration.MediaAudioEndpoint!; // Validate binds this numeric endpoint to the authenticated peer.
                _audioSocket = new System.Net.Sockets.UdpClient(_peerAddress.AddressFamily);
                _audioSocket.Connect(_peerAddress, endpoint.Port);
            }
            var audioOutputOrigin = _nextAudioTimestampSamples;
            ulong? audioInputOrigin = null;
            _stream = _createStream(configuration, SendVideoAsync, (audio, token) =>
            {
                // Capture owns a local sample clock. A replacement starts where
                // the joined stream ended, retaining this epoch's actual sample gaps.
                audioInputOrigin ??= audio.TimestampSamples;
                return SendAudioAsync(audio, configuration.AudioMode!, audioInputOrigin.Value, audioOutputOrigin, token);
            });
            await _stream.PrepareAsync(cancellationToken).ConfigureAwait(false);
        }
        await _videoBoundary.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var acknowledgement = RemoteControlWire.EncodeMessage("streamConfigurationAck", new RemoteStreamAcknowledgement(
                DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000d,
                configuration.StreamConfigurationTransaction, configuration.StreamRefreshToken,
                !configuration.IsStop && configuration.MediaAudioEndpoint is not null,
                configuration.ScreenFrameTransport, configuration.FramePresentationAckVersion,
                _access.AccessForReceipt(_admissionId)));
            await SendControlAsync(acknowledgement, cancellationToken).ConfigureAwait(false);
            if (_sequence == ulong.MaxValue) throw new InvalidDataException("Video sequence exhausted; reconnect the session.");
            _firstSequenceOfConfiguration = _sequence + 1;
            _configuration = configuration;
            _lastConfiguration = normalized;
            _lastAcknowledgement = acknowledgement;
            if (!reuse) _stream?.Start();
            else if (configuration.StreamRefreshToken is not null && configuration.StreamRefreshToken != previous?.StreamRefreshToken)
                (_stream ?? throw new InvalidOperationException("The refresh lost its active desktop stream.")).RequestKeyFrame();
            _access.MarkReady(_admissionId);
        }
        finally { _videoBoundary.Release(); }
    }

    private async Task ReleaseInputAsync(CancellationToken cancellationToken)
    {
        await _configurationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { _stream?.Input.ReleaseAll(); }
        finally { _configurationGate.Release(); }
    }

    private Task PublishAccessAsync(RemoteControlAccess access, CancellationToken cancellationToken) =>
        SendControlAsync(RemoteControlWire.EncodeMessage("controlAccess", access), cancellationToken);

    private void HandlePointer(RemotePointerEvent pointer)
    {
        var stream = RequireActiveStream();
        if (!double.IsFinite(pointer.X) || !double.IsFinite(pointer.Y) || !double.IsFinite(pointer.Timestamp) ||
            pointer.Timestamp <= 0 || pointer.X < 0 || pointer.Y < 0 || pointer.X >= stream.Width || pointer.Y >= stream.Height ||
            pointer.ClickCount is < 1 or > 2 ||
            pointer.Type is not ("mouseMoved" or "leftMouseDown" or "leftMouseUp" or "rightMouseDown" or "rightMouseUp" or "scrollUp" or "scrollDown"))
            throw new InvalidDataException("Remote pointer event is outside the acknowledged frame.");
        // The viewer clamps positions to the final pixel. Map that pixel to
        // the physical edge so downscaling does not make desktop hot corners
        // or an auto-hidden taskbar unreachable. Subpixel positions inside
        // the final pixel share the same edge; out-of-frame values were rejected above.
        stream.Input.MovePointer(
            Math.Min(pointer.X, stream.Width - 1d) / (stream.Width - 1d),
            Math.Min(pointer.Y, stream.Height - 1d) / (stream.Height - 1d));
        switch (pointer.Type)
        {
            case "mouseMoved": break;
            case "leftMouseDown": stream.Input.SetMouseButton(WindowsRemoteMouseButton.Left, true); break;
            case "leftMouseUp": stream.Input.SetMouseButton(WindowsRemoteMouseButton.Left, false); break;
            case "rightMouseDown": stream.Input.SetMouseButton(WindowsRemoteMouseButton.Right, true); break;
            case "rightMouseUp": stream.Input.SetMouseButton(WindowsRemoteMouseButton.Right, false); break;
            case "scrollUp": stream.Input.Scroll(0, 120); break;
            case "scrollDown": stream.Input.Scroll(0, -120); break;
            default: throw new InvalidDataException("Unknown remote pointer event.");
        }
    }

    private void HandleKey(RemoteKeyEvent key)
    {
        var stream = RequireActiveStream();
        if (key.KeyCode is < 0 or > ushort.MaxValue || !double.IsFinite(key.Timestamp) || key.Timestamp <= 0 ||
            key.Type is not ("keyDown" or "keyUp"))
            throw new InvalidDataException("Malformed remote keyboard event.");
        stream.Input.SetKey((ushort)key.KeyCode, key.Type == "keyDown");
    }

    private void HandlePresentation(RemoteFrameAcknowledgement acknowledgement)
    {
        if (_configuration is null || acknowledgement.Version != 1 || acknowledgement.SequenceNumber == 0)
            throw new InvalidDataException("Malformed frame presentation acknowledgement.");
        // An old renderer callback may arrive after the next ordered stream configuration.
        if (acknowledgement.StreamTransaction != _configuration.StreamConfigurationTransaction) return;
        if (_configuration.FramePresentationAckVersion != 1 || acknowledgement.SequenceNumber < _firstSequenceOfConfiguration ||
            acknowledgement.SequenceNumber > _sequence)
            throw new InvalidDataException("The viewer acknowledged a frame that was not sent in its negotiated stream.");
        _lastPresentedSequence = Math.Max(_lastPresentedSequence, acknowledgement.SequenceNumber);
    }

    internal ulong LastPresentedSequence => _lastPresentedSequence;

    private IRemoteControlHostStream RequireActiveStream() =>
        _configuration is { IsStop: false } && _stream is { } stream
            ? stream : throw new InvalidDataException("Input arrived before an acknowledged active stream.");

    private Task SendControlAsync(byte[] payload, CancellationToken cancellationToken) =>
        _transport.SendAsync(_secure.Seal(payload, RemoteControlSecurePacketType.Control), cancellationToken);

    private async Task SendVideoAsync(WindowsDesktopEncodedFrame frame, CancellationToken cancellationToken)
    {
        await _videoBoundary.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (_sequence == ulong.MaxValue) throw new InvalidDataException("Video sequence exhausted; reconnect the session.");
            var payload = RemoteControlWire.EncodeH264Frame(frame.H264Bytes, frame.Width, frame.Height,
                frame.TimestampUnixSeconds, frame.IsKeyFrame, ++_sequence);
            await _transport.SendAsync(_secure.Seal(payload, RemoteControlSecurePacketType.Screen), cancellationToken).ConfigureAwait(false);
            Interlocked.Increment(ref _framesSent);
            _reportCounters(Interlocked.Read(ref _framesSent), Interlocked.Read(ref _audioPacketsSent));
        }
        finally { _videoBoundary.Release(); }
    }

    private async ValueTask SendAudioAsync(WindowsOpusAudioFrame frame, string mode,
        ulong inputOrigin, ulong outputOrigin, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var socket = _audioSocket ?? throw new InvalidOperationException("Audio has no accepted destination.");
        if (frame.SamplesPerChannel != WindowsOpusAudioEncoder.SamplesPerChannel || frame.TimestampSamples < inputOrigin)
            throw new InvalidDataException("Audio capture returned an invalid frame duration or a sample clock preceding its epoch.");
        ulong timestamp;
        ulong nextTimestamp;
        try
        {
            timestamp = checked(outputOrigin + (frame.TimestampSamples - inputOrigin));
            nextTimestamp = checked(timestamp + (ulong)frame.SamplesPerChannel);
        }
        catch (OverflowException failure)
        {
            throw new InvalidDataException("The session audio sample clock is exhausted; reconnect the session.", failure);
        }
        if (timestamp < _nextAudioTimestampSamples)
            throw new InvalidDataException("Audio capture returned overlapping or regressing samples.");
        var packet = _audioSender.SealNext(frame.Payload, timestamp, mode == "high-fidelity" ? (ushort)2 : (ushort)1);
        var sent = await socket.SendAsync(packet, cancellationToken).ConfigureAwait(false);
        if (sent != packet.Length) throw new IOException("The audio socket did not send a complete datagram.");
        _nextAudioTimestampSamples = nextTimestamp;
        Interlocked.Increment(ref _audioPacketsSent);
    }

    private async Task StopStreamAsync()
    {
        var stream = _stream;
        try
        {
            if (stream is not null) await stream.DisposeAsync().ConfigureAwait(false);
            _stream = null;
        }
        finally { _audioSocket?.Dispose(); _audioSocket = null; }
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed) return;
        if (!_retired)
        {
            _retired = true;
            await _lifetime.CancelAsync().ConfigureAwait(false);
        }
        try
        {
            await _configurationGate.WaitAsync().ConfigureAwait(false);
            try
            {
                await StopStreamAsync().ConfigureAwait(false);
                _disposed = true;
            }
            finally { _configurationGate.Release(); }
        }
        finally
        {
            // Capture/encoding may still be completing a frame when cancellation
            // arrives. Retire keys only after their worker has joined. A failed
            // input release retains its stream owner for the next cleanup attempt.
            if (!_secretsDisposed && (_stream is null || _stream.Completion.IsCompleted))
            {
                _secure.Dispose();
                _audioSender.Dispose();
                _lifetime.Dispose();
                _videoBoundary.Dispose();
                _secretsDisposed = true;
            }
        }
    }
}
