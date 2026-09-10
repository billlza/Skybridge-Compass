using System.Buffers.Binary;
using System.Threading.Channels;
using Skybridge.WinClient.Services;
using Skybridge.WinClient.Services.RemoteControl;

internal static class RemoteControlViewerSessionTests
{
    private static readonly RemoteControlSecurityIdentity ViewerIdentity = new(
        "Test account", "NEBULA-TEST", "id:11111111-1111-4111-8111-111111111111", "Test Windows device");
    internal static IReadOnlyList<(string Name, Func<Task> Run)> Cases { get; } =
    [
        ("viewer SBRF decoding validates framing, codec, geometry and keyframe metadata", DecodeScreen),
        ("viewer and host share one physical-key mapping with a canonical keypad Enter", PhysicalKeyMapping),
        ("viewer pointer uses frame pixels and excludes letterbox bars", ViewerPointerMapping),
        ("viewer approval metadata rejects incomplete identities and invalid UTF-8 bounds", ApprovalMetadata),
        ("viewer rejects authenticated video before local host approval", RejectUnapprovedVideo),
        ("viewer binds approval and subsequent input to the current host grant", ApprovalAndHandoff),
        ("viewer rejects acknowledgements for a different transaction", RejectDifferentTransaction),
        ("viewer media backpressure remains cancellable and protects key lifetime", CancelBackpressuredMedia),
        ("viewer video overflow resumes only from a complete refresh frame", VideoBufferRecovery),
        ("viewer video recovery deadline fails explicitly", VideoBufferDeadline),
        ("slow viewer decoding cannot delay host input revocation", RevocationWithSlowDecoder),
        ("live video presentation resumes on the local playback clock", VideoPresentationClock)
    ];

    // Structural access-unit fixture; native decoding is a separate platform test.
    private static readonly byte[] AccessUnit = [0, 0, 0, 1, 0x67, 0x42, 1, 0, 0, 0, 1, 0x68, 1, 0, 0, 0, 1, 0x65, 1];
    private static byte[] Frame(ulong sequence = 1) => RemoteControlWire.EncodeH264Frame(AccessUnit, 1280, 720, 1_788_860_000 + sequence, true, sequence);

    private static Task DecodeScreen()
    {
        var packet = Frame();
        var frame = RemoteControlWire.DecodeH264Frame(packet);
        Require(frame.Width == 1280 && frame.Height == 720 && frame.Sequence == 1 && frame.IsKeyFrame &&
            frame.Bytes.AsSpan().SequenceEqual(AccessUnit), "Decoded frame does not match the source access unit.");
        foreach (var offset in new[] { 0, 4, 5, 6, 7, 8, 12, 32 })
        {
            var invalid = packet.ToArray(); invalid[offset] ^= 0x80;
            Throws<InvalidDataException>(() => RemoteControlWire.DecodeH264Frame(invalid));
        }
        var missingSequence = packet.ToArray(); BinaryPrimitives.WriteUInt64BigEndian(missingSequence.AsSpan(24), 0);
        Throws<InvalidDataException>(() => RemoteControlWire.DecodeH264Frame(missingSequence));
        Throws<InvalidDataException>(() => RemoteControlWire.DecodeH264Frame(packet.AsSpan(0, 35)));
        Throws<InvalidDataException>(() => RemoteControlWire.DecodeH264Frame(packet.AsSpan(0, packet.Length - 1)));
        return Task.CompletedTask;
    }

    private static Task PhysicalKeyMapping()
    {
        foreach (var mac in new ushort[] { 0x00, 0x24, 0x38, 0x3c, 0x3b, 0x3e, 0x3a, 0x3d, 0x36, 0x37, 0x4c, 0x7b, 0x7e })
            Require(WindowsRemoteInputPolicy.TryMapWindowsKey(WindowsRemoteInputPolicy.MapMacKey(mac), out var restored) && restored == mac,
                $"Physical key 0x{mac:x2} did not preserve its side and scan-code semantics.");
        Require(WindowsRemoteInputPolicy.TryMapWindowsKey(WindowsRemoteInputPolicy.MapMacKey(0x34), out var enter) && enter == 0x4c,
            "The legacy keypad Enter alias must use its canonical sending position.");
        Require(!WindowsRemoteInputPolicy.TryMapWindowsKey(new(0xffff), out _), "An unknown scan code must not become an arbitrary remote key.");
        return Task.CompletedTask;
    }

    private static Task ViewerPointerMapping()
    {
        Require(WindowsRemoteInputPolicy.MapViewerPointer(500, 500, 1000, 1000, 800, 400, false) == (400d, 200d),
            "The host expects visible-frame pixels, not normalized coordinates.");
        Require(WindowsRemoteInputPolicy.MapViewerPointer(500, 250, 1000, 500, 800, 800, false) == (400d, 400d),
            "Horizontal letterboxing must preserve the image center.");
        Require(WindowsRemoteInputPolicy.MapViewerPointer(100, 249, 1000, 1000, 800, 400, false) is null &&
            WindowsRemoteInputPolicy.MapViewerPointer(249, 100, 1000, 500, 800, 800, false) is null,
            "Black bars must not emit remote pointer presses.");
        Require(WindowsRemoteInputPolicy.MapViewerPointer(1200, 1200, 1000, 1000, 800, 400, true) == (799d, 399d) &&
            WindowsRemoteInputPolicy.MapViewerPointer(-1, -1, 1000, 1000, 800, 400, true) == (0d, 0d),
            "A captured drag release must remain inside the final visible pixel.");
        foreach (var invalid in new[] { double.NaN, double.PositiveInfinity, double.NegativeInfinity })
            Throws<ArgumentOutOfRangeException>(() => WindowsRemoteInputPolicy.MapViewerPointer(invalid, 0, 1000, 1000, 800, 400, false));
        Throws<ArgumentOutOfRangeException>(() => WindowsRemoteInputPolicy.MapViewerPointer(0, 0, 0, 1000, 800, 400, false));
        return Task.CompletedTask;
    }

    private static async Task VideoBufferRecovery()
    {
        var buffer = new RemoteControlVideoFrameBuffer();
        RemoteH264ScreenFrame Picture(ulong sequence, bool key) =>
            new(AccessUnit, 1280, 720, sequence * 33_333, sequence, key);
        buffer.Enqueue(Picture(1, true));
        buffer.Enqueue(Picture(2, false));
        buffer.Enqueue(Picture(3, false));
        buffer.Enqueue(Picture(4, false));
        buffer.Enqueue(Picture(5, false));
        Require(buffer.Count == 0 && buffer.DroppedFrames == 5,
            "An overloaded prediction chain must retire as a whole.");
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(3));
        var next = buffer.ReadAsync(deadline.Token).AsTask();
        Require(!next.IsCompleted, "A dependent frame escaped before refresh.");
        buffer.Enqueue(Picture(6, true));
        buffer.Enqueue(Picture(7, false));
        Require((await next).Sequence == 6 && (await buffer.ReadAsync(deadline.Token)).Sequence == 7,
            "Refresh and its dependent frame changed order.");
        var stopped = buffer.ReadAsync(deadline.Token).AsTask();
        buffer.Complete();
        await ThrowsAsync<ChannelClosedException>(() => stopped);
        Throws<ObjectDisposedException>(() => buffer.Enqueue(Picture(8, true)));
    }

    private static Task VideoBufferDeadline()
    {
        var time = new VideoBufferTime();
        var buffer = new RemoteControlVideoFrameBuffer(time);
        for (ulong sequence = 1; sequence <= 4; sequence++)
            buffer.Enqueue(new(AccessUnit, 1280, 720, sequence, sequence, sequence == 1));
        time.Advance(RemoteControlVideoFrameBuffer.RefreshDeadline - TimeSpan.FromTicks(1));
        buffer.RequireRefreshDeadline();
        time.Advance(TimeSpan.FromTicks(1));
        Throws<TimeoutException>(buffer.RequireRefreshDeadline);
        Throws<TimeoutException>(() => buffer.Enqueue(new(AccessUnit, 1280, 720, 5, 5, true)));
        buffer.Complete();
        return Task.CompletedTask;
    }

    private static async Task RevocationWithSlowDecoder()
    {
        using var fixture = new Fixture();
        var buffer = new RemoteControlVideoFrameBuffer();
        var revoked = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var session = fixture.Session((frame, _) => { buffer.Enqueue(frame); return Task.CompletedTask; },
            access => { if (!access.AllowsInput) revoked.TrySetResult(); });
        var run = session.RunAsync(fixture.Token);
        await fixture.Acknowledge(await fixture.ReadConfiguration(), new RemoteControlAccess(1, 1, "controller", Guid.NewGuid()));
        _ = await session.Ready;
        for (ulong sequence = 1; sequence <= 10; sequence++)
            await fixture.Send(Frame(sequence), RemoteControlSecurePacketType.Screen);
        await fixture.Send(RemoteControlWire.EncodeMessage("controlAccess", new RemoteControlAccess(1, 2, "observer", null)), RemoteControlSecurePacketType.Control);
        await revoked.Task.WaitAsync(fixture.Token);
        Require(buffer.Count <= RemoteControlVideoFrameBuffer.Capacity && buffer.DroppedFrames > 0 && session.Access?.AllowsInput == false,
            "Slow decoding blocked revocation or escaped its frame bound.");
        fixture.Cancel();
        await ThrowsAsync<OperationCanceledException>(() => run);
        buffer.Complete();
    }

    private sealed class VideoBufferTime : TimeProvider
    {
        private long _timestamp;
        public override long TimestampFrequency => TimeSpan.TicksPerSecond;
        public override long GetTimestamp() => _timestamp;
        internal void Advance(TimeSpan elapsed) => _timestamp += elapsed.Ticks;
    }

    private static Task VideoPresentationClock()
    {
        var timeline = new RemoteControlVideoTimeline();
        Require(timeline.Next(TimeSpan.Zero) == TimeSpan.Zero, "Initial live video must start immediately.");
        Require(timeline.Next(TimeSpan.Zero) == RemoteControlVideoTimeline.FrameDuration,
            "The decoder's buffered samples must preserve order.");
        Require(timeline.Next(TimeSpan.FromSeconds(5)) == TimeSpan.FromSeconds(5),
            "Resuming after a stall must catch up to the player's current clock.");
        Require(timeline.Next(TimeSpan.FromSeconds(5)) == TimeSpan.FromSeconds(5) + RemoteControlVideoTimeline.FrameDuration,
            "A clock paused for buffering must not introduce a remote capture-time gap.");
        Throws<ArgumentOutOfRangeException>(() => timeline.Next(TimeSpan.FromTicks(-1)));
        return Task.CompletedTask;
    }

    private static async Task RejectUnapprovedVideo()
    {
        using var fixture = new Fixture();
        using var session = fixture.Session((_, _) => throw new InvalidOperationException("Unapproved pixels reached the renderer."));
        var run = session.RunAsync(fixture.Token);
        _ = await fixture.ReadConfiguration();
        await fixture.Send(Frame(), RemoteControlSecurePacketType.Screen);
        await ThrowsAsync<InvalidDataException>(() => run);
        await ThrowsAsync<InvalidDataException>(async () => _ = await session.Ready);
    }

    private static Task ApprovalMetadata()
    {
        ViewerIdentity.Validate();
        foreach (var invalid in new[]
        {
            ViewerIdentity with { AccountDisplayName = "" },
            ViewerIdentity with { NebulaId = " " },
            ViewerIdentity with { DeviceId = "bad\nidentity" },
            ViewerIdentity with { DeviceName = new string('界', 43) }
        }) Throws<InvalidDataException>(invalid.Validate);
        return Task.CompletedTask;
    }

    private static async Task ApprovalAndHandoff()
    {
        using var fixture = new Fixture();
        var rendered = new TaskCompletionSource<RemoteH264ScreenFrame>(TaskCreationOptions.RunContinuationsAsynchronously);
        var observerArrived = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var session = fixture.Session((frame, _) => { rendered.TrySetResult(frame); return Task.CompletedTask; },
            access => { if (!access.AllowsInput) observerArrived.TrySetResult(); });
        var run = session.RunAsync(fixture.Token);
        var configuration = await fixture.ReadConfiguration();
        Require(configuration.RemoteControlAccessVersion == 1 && configuration.PreferredCodec == "h264" &&
            configuration.AudioTransport == "disabled" && configuration.EnableHardwareAcceleration &&
            configuration.EnableAppleSiliconOptimization && configuration.DamageTrackingEnabled == false,
            "Viewer must include the required optimization flag and explicitly disable the optional damage-report channel.");
        Require(configuration.RemoteControlSecurityIdentity == ViewerIdentity,
            "The host approval request lost the current account or authenticated device identity.");
        var grant = new RemoteControlAccess(1, 1, "controller", Guid.NewGuid());
        await fixture.Acknowledge(configuration, grant);
        Require(await session.Ready == grant, "Viewer did not commit the host's approved grant.");
        await fixture.Send(Frame(), RemoteControlSecurePacketType.Screen);
        Require((await rendered.Task.WaitAsync(fixture.Token)).Sequence == 1, "Approved frame was not delivered.");
        await session.SendInputAsync("keyboardEvent", new RemoteKeyEvent("keyDown", 0, 1), grant, fixture.Token);
        var input = fixture.PeerSecure.Open((await fixture.Peer.ReadAsync(fixture.Token)).Span, [RemoteControlSecurePacketType.Control]);
        var message = RemoteControlWire.Decode<RemoteControlMessage>(input.Payload);
        Require(message.InputControlLease == grant.Lease && message.Type == "keyboardEvent", "Input lost its authenticated lease.");
        await fixture.Send(RemoteControlWire.EncodeMessage("controlAccess", new RemoteControlAccess(1, 2, "observer", null)), RemoteControlSecurePacketType.Control);
        await observerArrived.Task.WaitAsync(fixture.Token);
        await ThrowsAsync<RemoteControlViewerInputAuthorityChangedException>(() =>
            session.SendInputAsync("keyboardEvent", new RemoteKeyEvent("keyUp", 0, 2), grant, fixture.Token));
        fixture.Cancel();
        await ThrowsAsync<OperationCanceledException>(() => run);
    }

    private static async Task RejectDifferentTransaction()
    {
        using var fixture = new Fixture();
        using var session = fixture.Session((_, _) => Task.CompletedTask);
        var run = session.RunAsync(fixture.Token);
        var configuration = await fixture.ReadConfiguration();
        await fixture.Acknowledge(configuration with { StreamConfigurationTransaction = new(Guid.NewGuid()) },
            new RemoteControlAccess(1, 1, "observer", null));
        await ThrowsAsync<InvalidDataException>(() => run);
        await ThrowsAsync<InvalidDataException>(async () => _ = await session.Ready);
    }

    private static async Task CancelBackpressuredMedia()
    {
        using var fixture = new Fixture();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var session = fixture.Session(async (_, token) =>
        {
            entered.TrySetResult();
            await Task.Delay(Timeout.InfiniteTimeSpan, token);
        });
        var run = session.RunAsync(fixture.Token);
        await fixture.Acknowledge(await fixture.ReadConfiguration(), new RemoteControlAccess(1, 1, "observer", null));
        _ = await session.Ready;
        await fixture.Send(Frame(), RemoteControlSecurePacketType.Screen);
        await entered.Task.WaitAsync(fixture.Token);
        Throws<InvalidOperationException>(() => session.Dispose());
        fixture.Cancel();
        await ThrowsAsync<OperationCanceledException>(() => run);
    }

    private sealed class Fixture : IDisposable
    {
        private readonly CancellationTokenSource _deadline = new(TimeSpan.FromSeconds(5));
        private readonly ProductSessionKeys _keys;
        internal readonly RemoteControlSecureSession PeerSecure;
        internal readonly Transport Local;
        internal readonly Transport Peer;
        internal CancellationToken Token => _deadline.Token;
        internal Fixture()
        {
            _keys = ProductHandshakeKeyDerivation.Derive(new byte[32], 0x0102, new byte[32], new byte[32],
                new byte[32], new byte[32], ProductHandshakeRole.Initiator);
            using var peerKeys = ProductHandshakeKeyDerivation.Derive(new byte[32], 0x0102, new byte[32], new byte[32],
                new byte[32], new byte[32], ProductHandshakeRole.Responder);
            PeerSecure = new(peerKeys);
            (Local, Peer) = Transport.Pair();
        }
        internal RemoteControlViewerSession Session(Func<RemoteH264ScreenFrame, CancellationToken, Task> frame,
            Action<RemoteControlAccess>? access = null) => new(Local, _keys, ViewerIdentity, frame, access ?? (_ => { }));
        internal async Task<RemoteStreamConfiguration> ReadConfiguration()
        {
            var packet = PeerSecure.Open((await Peer.ReadAsync(Token)).Span, [RemoteControlSecurePacketType.Control]);
            var message = RemoteControlWire.Decode<RemoteControlMessage>(packet.Payload);
            Require(message.Type == "streamConfiguration", "The viewer must request its stream before input or video.");
            return RemoteControlWire.Decode<RemoteStreamConfiguration>(message.Payload);
        }
        internal Task Acknowledge(RemoteStreamConfiguration configuration, RemoteControlAccess access) => Send(
            RemoteControlWire.EncodeMessage("streamConfigurationAck", new RemoteStreamAcknowledgement(1,
                configuration.StreamConfigurationTransaction, null, false, "sbrf-v1", null, access)), RemoteControlSecurePacketType.Control);
        internal Task Send(byte[] data, RemoteControlSecurePacketType type) => Peer.SendAsync(PeerSecure.Seal(data, type), Token);
        internal void Cancel() => _deadline.Cancel();
        public void Dispose() { _deadline.Cancel(); _deadline.Dispose(); PeerSecure.Dispose(); _keys.Dispose(); }
    }

    internal sealed class Transport(ChannelReader<ReadOnlyMemory<byte>> reader, ChannelWriter<ReadOnlyMemory<byte>> writer) : IProductHandshakeTransport
    {
        public Task<ReadOnlyMemory<byte>> ReadAsync(CancellationToken token) => reader.ReadAsync(token).AsTask();
        public Task SendAsync(ReadOnlyMemory<byte> data, CancellationToken token) => writer.WriteAsync(data.ToArray(), token).AsTask();
        internal static (Transport, Transport) Pair()
        {
            var left = Channel.CreateBounded<ReadOnlyMemory<byte>>(4);
            var right = Channel.CreateBounded<ReadOnlyMemory<byte>>(4);
            return (new(left.Reader, right.Writer), new(right.Reader, left.Writer));
        }
    }
    private static void Require(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
    private static void Throws<T>(Action action) where T : Exception
    {
        try { action(); } catch (T) { return; }
        throw new InvalidOperationException($"Expected {typeof(T).Name}.");
    }
    private static async Task ThrowsAsync<T>(Func<Task> action) where T : Exception
    {
        try { await action(); } catch (T) { return; }
        throw new InvalidOperationException($"Expected {typeof(T).Name}.");
    }
}
