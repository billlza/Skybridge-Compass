using System.Buffers.Binary;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using System.Threading.Channels;
using Skybridge.WinClient.Services;
using Skybridge.WinClient.Services.RemoteControl;

internal static class RemoteControlHostSessionTests
{
    internal static IReadOnlyList<(string Name, Func<Task> Run)> Cases { get; } =
    [
        ("host stream validates format dimensions and authenticated audio target", ValidateConfigurations),
        ("host stream bounds preserve aspect ratio and real 2 FPS budget", ValidateOutputPolicy),
        ("host wire requires control fields and forbids duplicate JSON keys", ValidateWire),
        ("host acknowledges only prepared resources and retries configuration idempotently", AcknowledgementLifecycle),
        ("host rejects conflicting duplicate configurations", ConflictingConfiguration),
        ("host rejects input before acknowledgement and unknown pointer side effects", InputAdmission),
        ("host pointer mapping reaches physical desktop edges after downscaling", PointerDisplayEdges),
        ("host stop releases input and rejects subsequent input", StopReleasesInput),
        ("host preparation failure never sends a success acknowledgement", PreparationFailure),
        ("host missing audio device sends a bound rejection instead of an acknowledgement", AudioRejection),
        ("host cleanup retains failed input ownership for retry", CleanupRetry),
        ("host replacement waits for the old media owner before acknowledging new resources", ReplacementWaitsForMedia),
        ("host repeats a stopped configuration without releasing input twice", RepeatedStop),
        ("host drains media before retiring session keys", DisposeJoinsMedia),
        ("host retries only the retained input owner after media has ended", CleanupAfterWorkerCompletion),
        ("host worker failure cancels and joins the outstanding control reader", WorkerFailureJoinsReader),
        ("host reports both worker and control-reader failures", ConcurrentWorkerReaderFailure),
        ("host failed acknowledgements never start prepared media", FailedAcknowledgement),
        ("host reports rejection delivery and preparation failures together", FailedRejection),
        ("host queued duplicate failure emits one bound rejection and no success", DuplicateRejection),
        ("host presentation acknowledgements bind to frames sent in the current configuration", PresentationBoundaries),
        ("host sync refresh preserves held input and requests one keyframe", SyncRefreshPreservesInput),
        ("host sync refresh cannot reuse changed media settings", SyncRefreshWithChangedSettings),
        ("host replacing audio destinations preserves authenticated nonce continuity", AudioReplacement),
        ("host video reconfiguration preserves the audio session sample clock", AudioSampleClockContinuity),
        ("host audio sample clock preserves capture gaps and resets only for a new session", AudioSampleClockEpochs),
        ("host rejects invalid audio sample clocks before sending a datagram", InvalidAudioSampleClock),
        ("host preparation cancellation retains the owner until cleanup", CancelPreparation),
        ("host deadlines bound first configuration preparation and acknowledgement without ending active streams", ConfigurationDeadlines),
        ("host approval has its own bounded window before capture preparation starts", ApprovalDeadline),
        ("encrypted host sessions require local approval and coordinate two viewers with fresh input leases", ManagedSessionHandoff),
        ("host access negotiation cannot be downgraded by a later stream configuration", ManagedSessionDowngrade),
        ("TCP framing retains coalesced messages and accepts fragmented prefixes", FramingRoundTrip),
        ("TCP framing rejects oversized input before allocating its body", RejectLargeFrame),
        ("TCP transport enables bounded idle peer liveness on the actual socket", IdlePeerLiveness),
        ("TCP disposal cancels and drains an active reader", DisposeActiveReader),
        ("TCP write timeout preserves the cause when it cancels the active reader", WriteTimeoutPreservesCause),
        ("TCP cancellation before writing preserves the transport and framing", CancelledUnstartedSendPreservesTransport)
    ];

    private static RemoteStreamConfiguration Configuration() => new()
    {
        Width = 1280, Height = 720, TargetFrameRate = 2, KeyFrameInterval = 10,
        SupportedVideoFormats = ["h264"], ScreenFrameTransport = "sbrf-v1", AudioTransport = "disabled",
        StreamConfigurationTransaction = new(Guid.NewGuid()), SentAt = 1, FramePresentationAckVersion = 1
    };
    private static void Require(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
    private static T Throws<T>(Action action) where T : Exception
    {
        try { action(); } catch (T expected) { return expected; }
        throw new InvalidOperationException($"Expected {typeof(T).Name}.");
    }
    private static async Task<T> ThrowsAsync<T>(Func<Task> action) where T : Exception
    {
        try { await action(); } catch (T expected) { return expected; }
        throw new InvalidOperationException($"Expected {typeof(T).Name}.");
    }

    private static Task ValidateConfigurations()
    {
        var peer = IPAddress.Parse("192.0.2.12");
        var configuration = Configuration();
        configuration.Validate(peer, "session");
        Throws<InvalidDataException>(() => (configuration with { Width = 8192, Height = 8192 }).Validate(peer, "session"));
        Throws<InvalidDataException>(() => (configuration with { TargetFrameRate = -1 }).Validate(peer, "session"));
        Throws<NotSupportedException>(() => (configuration with { SupportedVideoFormats = ["hevc"] }).Validate(peer, "session"));
        Throws<NotSupportedException>(() => (configuration with { ClipboardSyncEnabled = true }).Validate(peer, "session"));
        var audio = configuration with { AudioRedirectionEnabled = true, AudioTransport = "pqc-media-v1",
            AudioMode = "low-latency", MediaSessionId = "session", AudioSampleRate = 48000, AudioChannelCount = 2,
            MediaAudioEndpoint = new("0.0.0.0", 5001) };
        audio.Validate(peer, "session");
        (audio with { MediaAudioEndpoint = new(peer.ToString(), 5001) }).Validate(peer, "session");
        Throws<InvalidDataException>(() => (audio with { MediaAudioEndpoint = new("192.0.2.20", 5001) }).Validate(peer, "session"));
        Throws<InvalidDataException>(() => (audio with { MediaAudioEndpoint = new("::", 5001) }).Validate(peer, "session"));
        Throws<InvalidDataException>(() => audio.Validate(peer, "other-session"));
        return Task.CompletedTask;
    }

    private static Task ValidateOutputPolicy()
    {
        Require(WindowsRemoteControlStream.FitOutput(5120, 2880, null, null) == (1920, 1080), "Auto mode exceeded the software encoding budget.");
        Require(WindowsRemoteControlStream.FitOutput(5120, 2880, 5120, 2880) == (5120, 2880), "An explicit 5K request was silently reduced.");
        Require(WindowsRemoteControlStream.FitOutput(3840, 2160, 1280, 720) == (1280, 720), "Background bounds changed.");
        Require(WindowsRemoteControlStream.FitOutput(1080, 1920, 1280, 720) == (404, 720), "Portrait aspect ratio changed.");
        Require(WindowsRemoteControlStream.CalculateBitrate(1280, 720, 2, 50) < WindowsRemoteControlStream.CalculateBitrate(1280, 720, 30, 50), "Background encoding ignored FPS.");
        return Task.CompletedTask;
    }

    private static Task ValidateWire()
    {
        Throws<JsonException>(() => RemoteControlWire.Decode<RemotePointerEvent>("{\"type\":\"mouseMoved\",\"timestamp\":1}"u8.ToArray()));
        Throws<JsonException>(() => RemoteControlWire.Decode<RemoteControlMessage>("{\"type\":\"x\",\"type\":\"y\",\"payload\":\"\"}"u8.ToArray()));
        var frame = RemoteControlWire.EncodeH264Frame([0, 0, 0, 1, 0x65], 1280, 720, 1.25, true, 7);
        Require(frame.Length == 41 && BinaryPrimitives.ReadUInt32BigEndian(frame) == 0x53425246 && frame[4] == 2 && frame[5] == 2, "SBRF format changed.");
        Require(BinaryPrimitives.ReadUInt64BigEndian(frame.AsSpan(16)) == 1_250_000 && BinaryPrimitives.ReadUInt64BigEndian(frame.AsSpan(24)) == 7, "SBRF timing or sequence changed.");
        return Task.CompletedTask;
    }

    private static async Task AcknowledgementLifecycle()
    {
        await using var fixture = new SessionFixture();
        var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        fixture.Prepare = ready.Task;
        var configuration = Configuration();
        await fixture.Send("streamConfiguration", configuration);
        var stream = await fixture.Created.Reader.ReadAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(3));
        Require(!fixture.Transport.Outgoing.Reader.TryRead(out _), "Acknowledgement preceded preparation.");
        ready.SetResult();
        var first = await fixture.ReadAcknowledgement();
        Require(first.Transaction == configuration.StreamConfigurationTransaction && stream.Starts == 1, "Stream was not acknowledged and started exactly once.");
        await fixture.Send("streamConfiguration", configuration);
        var repeated = await fixture.ReadAcknowledgement();
        Require(first == repeated && stream.Starts == 1 && fixture.StreamCount == 1, "Duplicate created resources or changed ACK.");
    }

    private static async Task ConflictingConfiguration()
    {
        await using var fixture = new SessionFixture();
        var configuration = Configuration();
        await fixture.Send("streamConfiguration", configuration);
        await fixture.ReadAcknowledgement();
        await fixture.Send("streamConfiguration", configuration with { TargetFrameRate = 30 });
        await fixture.ExpectFailure<InvalidDataException>();
        Require(fixture.StreamCount == 1, "A conflicting transaction allocated new resources.");
    }

    private static async Task InputAdmission()
    {
        await using (var fixture = new SessionFixture())
        {
            await fixture.Send("keyboardEvent", new RemoteKeyEvent("keyDown", 0, 1));
            await fixture.ExpectFailure<InvalidDataException>();
            Require(fixture.StreamCount == 0, "Unauthenticated configuration path allocated input.");
        }
        await using (var fixture = new SessionFixture())
        {
            await fixture.Send("streamConfiguration", Configuration());
            await fixture.ReadAcknowledgement();
            await fixture.Send("mouseEvent", new RemotePointerEvent("unknown", 100, 100, 1, null));
            await fixture.ExpectFailure<InvalidDataException>();
            Require(fixture.LastStream!.FakeInput.Actions.Count == 0, "Unknown pointer event moved the cursor.");
        }
    }

    private static async Task StopReleasesInput()
    {
        await using var fixture = new SessionFixture();
        var configuration = Configuration();
        await fixture.Send("streamConfiguration", configuration);
        await fixture.ReadAcknowledgement();
        await fixture.Send("keyboardEvent", new RemoteKeyEvent("keyDown", 56, 1));
        await fixture.Send("streamConfiguration", configuration with { TargetFrameRate = 0, StreamConfigurationTransaction = new(Guid.NewGuid()) });
        await fixture.ReadAcknowledgement();
        Require(fixture.LastStream!.FakeInput.Actions.SequenceEqual(new[] { "key:56:True", "release" }), "Stop did not release owned input.");
        await fixture.Send("keyboardEvent", new RemoteKeyEvent("keyUp", 56, 2));
        await fixture.ExpectFailure<InvalidDataException>();
    }

    private static async Task PointerDisplayEdges()
    {
        await using var fixture = new SessionFixture();
        var configuration = Configuration();
        await fixture.Send("streamConfiguration", configuration);
        await fixture.ReadAcknowledgement();
        var stream = fixture.LastStream ?? throw new InvalidOperationException("No input stream was prepared.");
        foreach (var point in new (double X, double Y)[]
        {
            (0, 0), ((stream.Width - 1) / 2d, (stream.Height - 1) / 2d),
            (stream.Width - 1, stream.Height - 1), (stream.Width - 0.25, stream.Height - 0.25)
        })
            await fixture.Send("mouseEvent", new RemotePointerEvent("mouseMoved", point.X, point.Y, 1, null));
        // The ordered configuration acknowledgement proves the earlier input was handled.
        await fixture.Send("streamConfiguration", configuration);
        await fixture.ReadAcknowledgement();
        Require(stream.FakeInput.Points.SequenceEqual(new[] { (0d, 0d), (0.5, 0.5), (1d, 1d), (1d, 1d) }),
            "The final displayed pixel cannot reach the physical desktop edge after scaling.");
        var display = new WindowsDesktopDisplay("primary", "Primary", 0, 0, 5120, 2880, true);
        var edge = stream.FakeInput.Points[2];
        var absolute = WindowsRemoteInputPolicy.MapPointer(edge.X, edge.Y, display, new WindowsDesktopBounds(0, 0, 5120, 2880));
        Require(absolute == (65535, 65535), "The last frame pixel leaves the physical bottom/right screen edges unreachable.");
        await fixture.Send("mouseEvent", new RemotePointerEvent("mouseMoved", stream.Width, 0, 1, null));
        await fixture.ExpectFailure<InvalidDataException>();
        Require(stream.FakeInput.Points.Count == 4, "Out-of-frame coordinates were clamped into a valid input event.");
    }

    private static async Task PreparationFailure()
    {
        await using var fixture = new SessionFixture { Prepare = Task.FromException(new IOException("capture unavailable")) };
        await fixture.Send("streamConfiguration", Configuration());
        await fixture.ExpectFailure<IOException>();
        Require(!fixture.Transport.Outgoing.Reader.TryRead(out _), "Failed preparation emitted success.");
    }

    private static async Task AudioRejection()
    {
        await using var fixture = new SessionFixture { Prepare = Task.FromException(new WindowsAudioOutputUnavailableException()) };
        var configuration = Configuration();
        await fixture.Send("streamConfiguration", configuration);
        await fixture.ExpectFailure<WindowsAudioOutputUnavailableException>();
        var message = await fixture.ReadMessage();
        Require(message.Type == "streamConfigurationRejected", "Missing audio must not emit a success acknowledgement.");
        var rejection = RemoteControlWire.Decode<RemoteStreamRejection>(message.Payload);
        Require(rejection.Transaction == configuration.StreamConfigurationTransaction && rejection.Code == "audio-device-unavailable" &&
            System.Text.Encoding.UTF8.GetByteCount(rejection.Message) <= 512, "Rejection must bind the exact pending request and provide a bounded reason.");
    }

    private static async Task CleanupRetry()
    {
        await using var fixture = new SessionFixture();
        await fixture.Send("streamConfiguration", Configuration());
        await fixture.ReadAcknowledgement();
        fixture.LastStream!.CleanupFailures = 1;
        await fixture.CancelRun();
        await ThrowsAsync<IOException>(() => fixture.Session.DisposeAsync().AsTask());
        await fixture.Session.DisposeAsync();
        Require(fixture.LastStream.DisposeCalls == 2, "Cleanup lost the original stream owner.");
    }

    private static async Task ReplacementWaitsForMedia()
    {
        await using var fixture = new SessionFixture();
        await fixture.Send("streamConfiguration", Configuration());
        await fixture.ReadAcknowledgement();
        var oldStream = fixture.LastStream!;
        var oldMediaDrained = NewSignal();
        oldStream.DisposeBarrier = oldMediaDrained.Task;
        var replacement = Configuration() with { TargetFrameRate = 30 };
        await fixture.Send("streamConfiguration", replacement);
        await oldStream.DisposeEntered.Task.WaitAsync(TimeSpan.FromSeconds(3));
        try
        {
            Require(fixture.StreamCount == 1 && !oldStream.Completion.IsCompleted,
                "Replacement allocated a second media owner before the first one had stopped.");
            Require(!fixture.Transport.Outgoing.Reader.TryRead(out _),
                "Replacement acknowledged resources while old media could still send.");
        }
        finally { oldMediaDrained.TrySetResult(); }
        var acknowledgement = await fixture.ReadAcknowledgement();
        Require(acknowledgement.Transaction == replacement.StreamConfigurationTransaction &&
            oldStream.Completion.IsCompletedSuccessfully && oldStream.FakeInput.Actions.SequenceEqual(new[] { "release" }) &&
            fixture.StreamCount == 2 && !ReferenceEquals(oldStream, fixture.LastStream),
            "Replacement did not release the exact old owner before starting the new configuration.");
    }

    private static async Task RepeatedStop()
    {
        await using var fixture = new SessionFixture();
        var configuration = Configuration();
        await fixture.Send("streamConfiguration", configuration);
        await fixture.ReadAcknowledgement();
        var stream = fixture.LastStream!;
        var stop = configuration with { TargetFrameRate = 0, StreamConfigurationTransaction = new(Guid.NewGuid()) };
        await fixture.Send("streamConfiguration", stop);
        var first = await fixture.ReadAcknowledgement();
        await fixture.Send("streamConfiguration", stop);
        var second = await fixture.ReadAcknowledgement();
        Require(first == second && stream.DisposeCalls == 1 && stream.Starts == 1 && fixture.StreamCount == 1,
            "A duplicate stop changed the accepted transaction or repeated native cleanup.");
    }

    private static async Task DisposeJoinsMedia()
    {
        await using var fixture = new SessionFixture();
        await fixture.Send("streamConfiguration", Configuration());
        await fixture.ReadAcknowledgement();
        var stream = fixture.LastStream!;
        var drained = NewSignal();
        stream.DisposeBarrier = drained.Task;
        await fixture.CancelRun();
        var stop = fixture.Session.DisposeAsync().AsTask();
        await stream.DisposeEntered.Task.WaitAsync(TimeSpan.FromSeconds(3));
        try
        {
            Require(!stop.IsCompleted && !stream.Completion.IsCompleted,
                "Session teardown returned while a media owner was still draining.");
            // A dependency can still be finishing an already accepted frame while
            // its asynchronous stop is pending. Keys belong to that owner until it joins.
            await stream.SendVideo(CancellationToken.None);
            var frame = await fixture.ReadVideo();
            Require(BinaryPrimitives.ReadUInt64BigEndian(frame.AsSpan(24)) == 1,
                "The final in-flight frame lost its authenticated sequence during teardown.");
        }
        finally { drained.TrySetResult(); }
        await stop.WaitAsync(TimeSpan.FromSeconds(3));
        await fixture.Session.DisposeAsync();
        Require(stream.Completion.IsCompletedSuccessfully && stream.DisposeCalls == 1,
            "Completed session teardown repeated or abandoned native cleanup.");
    }

    private static async Task CleanupAfterWorkerCompletion()
    {
        await using var fixture = new SessionFixture();
        await fixture.Send("streamConfiguration", Configuration());
        await fixture.ReadAcknowledgement();
        var stream = fixture.LastStream!;
        stream.CompleteWorkersBeforeCleanupFailure = true;
        stream.CleanupFailures = 1;
        await fixture.CancelRun();
        await ThrowsAsync<IOException>(() => fixture.Session.DisposeAsync().AsTask());
        Require(stream.Completion.IsCompletedSuccessfully && stream.FakeInput.Actions.Count == 0,
            "A failed input release was confused with a running media worker or reported as released.");
        await fixture.Session.DisposeAsync();
        Require(stream.DisposeCalls == 2 && stream.FakeInput.Actions.SequenceEqual(new[] { "release" }),
            "Retry did not release the retained input owner exactly once after worker completion.");
    }

    private static async Task WorkerFailureJoinsReader()
    {
        await using var fixture = new SessionFixture();
        var configuration = Configuration();
        await fixture.Send("streamConfiguration", configuration);
        await fixture.ReadAcknowledgement();
        Require(fixture.Transport.ActiveReads == 1, "The control reader was not waiting during media streaming.");
        var failure = new IOException("capture device disconnected");
        fixture.LastStream!.FailWorker(failure);
        var observed = await fixture.ExpectFailure<IOException>();
        Require(ReferenceEquals(observed, failure) && fixture.Transport.ActiveReads == 0,
            "Worker failure lost its original cause or abandoned a pending control read.");
        Require(!fixture.Transport.Outgoing.Reader.TryRead(out _), "Runtime capture failure was mislabeled as a configuration acknowledgement.");
    }

    private static async Task ConcurrentWorkerReaderFailure()
    {
        await using var fixture = new SessionFixture();
        await fixture.Send("streamConfiguration", Configuration());
        await fixture.ReadAcknowledgement();
        var workerFailure = new IOException("media delivery failed");
        var readerFailure = new IOException("control reader shutdown failed");
        fixture.Transport.ReadCancellationFailure = readerFailure;
        fixture.LastStream!.FailWorker(workerFailure);
        var observed = await fixture.ExpectFailure<AggregateException>();
        Require(observed.InnerExceptions.Contains(workerFailure) && observed.InnerExceptions.Contains(readerFailure) &&
            fixture.Transport.ActiveReads == 0, "Concurrent media and reader failures were not both retained after joining the reader.");
    }

    private static async Task FailedAcknowledgement()
    {
        await using var fixture = new SessionFixture();
        var failure = new IOException("acknowledgement transport failed");
        fixture.Transport.BeforeSend = (_, _) => Task.FromException(failure);
        await fixture.Send("streamConfiguration", Configuration());
        var observed = await fixture.ExpectFailure<IOException>();
        var stream = fixture.LastStream ?? throw new InvalidOperationException("Acknowledgement failure did not retain its prepared stream.");
        Require(ReferenceEquals(observed, failure) && stream.Starts == 0 &&
            !fixture.Transport.Outgoing.Reader.TryRead(out _),
            "Prepared media started without a delivered acknowledgement or hid its transport failure.");
        await fixture.Session.DisposeAsync();
        Require(stream.DisposeCalls == 1, "Failed acknowledgement leaked its prepared media owner.");
    }

    private static async Task FailedRejection()
    {
        var preparationFailure = new WindowsAudioOutputUnavailableException();
        await using var fixture = new SessionFixture { Prepare = Task.FromException(preparationFailure) };
        var sendFailure = new IOException("rejection transport failed");
        fixture.Transport.BeforeSend = (_, _) => Task.FromException(sendFailure);
        await fixture.Send("streamConfiguration", Configuration());
        var observed = await fixture.ExpectFailure<AggregateException>();
        Require(observed.InnerExceptions.Contains(preparationFailure) && observed.InnerExceptions.Contains(sendFailure) &&
            fixture.LastStream!.Starts == 0 && !fixture.Transport.Outgoing.Reader.TryRead(out _),
            "Rejection delivery hid a preparation failure or started unacknowledged media.");
    }

    private static async Task DuplicateRejection()
    {
        var preparation = NewSignal();
        await using var fixture = new SessionFixture { Prepare = preparation.Task };
        var configuration = Configuration();
        await fixture.Send("streamConfiguration", configuration);
        await fixture.Created.Reader.ReadAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(3));
        await fixture.Send("streamConfiguration", configuration);
        preparation.SetException(new WindowsAudioOutputUnavailableException());
        await fixture.ExpectFailure<WindowsAudioOutputUnavailableException>();
        var message = await fixture.ReadMessage();
        var rejection = RemoteControlWire.Decode<RemoteStreamRejection>(message.Payload);
        Require(message.Type == "streamConfigurationRejected" && rejection.Transaction == configuration.StreamConfigurationTransaction &&
            fixture.StreamCount == 1 && fixture.LastStream!.Starts == 0 && !fixture.Transport.Outgoing.Reader.TryRead(out _),
            "A queued duplicate failure produced a second owner, an extra response, or a success acknowledgement.");
    }

    private static async Task PresentationBoundaries()
    {
        await using var fixture = new SessionFixture();
        var first = Configuration();
        await fixture.Send("streamConfiguration", first);
        await fixture.ReadAcknowledgement();
        await fixture.LastStream!.SendVideo(CancellationToken.None);
        await fixture.ReadVideo();
        await fixture.Send("framePresentationAck", new RemoteFrameAcknowledgement(1, 1, first.StreamConfigurationTransaction!));
        await fixture.Send("streamConfiguration", first);
        await fixture.ReadAcknowledgement();
        Require(fixture.Session.LastPresentedSequence == 1, "A valid presented frame was not recorded.");
        var second = Configuration();
        await fixture.Send("streamConfiguration", second);
        await fixture.ReadAcknowledgement();
        await fixture.LastStream!.SendVideo(CancellationToken.None);
        var frame = await fixture.ReadVideo();
        Require(BinaryPrimitives.ReadUInt64BigEndian(frame.AsSpan(24)) == 2, "Configuration replacement reset the session frame sequence.");
        await fixture.Send("framePresentationAck", new RemoteFrameAcknowledgement(1, 1, first.StreamConfigurationTransaction!));
        await fixture.Send("framePresentationAck", new RemoteFrameAcknowledgement(1, 2, second.StreamConfigurationTransaction!));
        await fixture.Send("framePresentationAck", new RemoteFrameAcknowledgement(1, 2, second.StreamConfigurationTransaction!));
        await fixture.Send("streamConfiguration", second);
        await fixture.ReadAcknowledgement();
        Require(fixture.Session.LastPresentedSequence == 2, "Stale or duplicate presentation callbacks damaged the current frame acknowledgement.");
        await fixture.Send("framePresentationAck", new RemoteFrameAcknowledgement(1, 1, second.StreamConfigurationTransaction!));
        await fixture.ExpectFailure<InvalidDataException>();
        Require(fixture.Session.LastPresentedSequence == 2, "An old frame relabeled with the current transaction changed presentation state.");
    }

    private static async Task SyncRefreshPreservesInput()
    {
        await using var fixture = new SessionFixture();
        var initial = Configuration();
        await fixture.Send("streamConfiguration", initial);
        await fixture.ReadAcknowledgement();
        var stream = fixture.LastStream ?? throw new InvalidOperationException("No desktop stream.");
        await fixture.Send("keyboardEvent", new RemoteKeyEvent("keyDown", 56, 1));
        var refresh = initial with { StreamRefreshToken = 1, StreamConfigurationTransaction = new(Guid.NewGuid()), SentAt = 2 };
        await fixture.Send("streamConfiguration", refresh);
        var ack = await fixture.ReadAcknowledgement();
        await fixture.Send("streamConfiguration", refresh);
        await fixture.ReadAcknowledgement();
        Require(ReferenceEquals(stream, fixture.LastStream) && fixture.StreamCount == 1 && stream.DisposeCalls == 0 &&
            stream.Starts == 1 && stream.KeyFrameRequests == 1 &&
            stream.FakeInput.Actions.SequenceEqual(["key:56:True"]) &&
            ack.Transaction == refresh.StreamConfigurationTransaction && ack.StreamRefreshToken == 1,
            "A sync-only refresh restarted capture, released held input, or repeated its keyframe request.");
        await stream.SendVideo(default);
        var frame = await fixture.ReadVideo();
        var sequence = BinaryPrimitives.ReadUInt64BigEndian(frame.AsSpan(24));
        await fixture.Send("framePresentationAck", new RemoteFrameAcknowledgement(1, sequence, refresh.StreamConfigurationTransaction));
        await fixture.Send("keyboardEvent", new RemoteKeyEvent("keyUp", 56, 2));
        await fixture.Send("streamConfiguration", refresh);
        await fixture.ReadAcknowledgement();
        Require(fixture.Session.LastPresentedSequence == sequence &&
            stream.FakeInput.Actions.SequenceEqual(["key:56:True", "key:56:False"]),
            "The refreshed stream lost sequence ownership or the matching physical key release.");
    }

    private static async Task SyncRefreshWithChangedSettings()
    {
        await using var fixture = new SessionFixture();
        var initial = Configuration();
        await fixture.Send("streamConfiguration", initial);
        await fixture.ReadAcknowledgement();
        var stream = fixture.LastStream ?? throw new InvalidOperationException("No desktop stream.");
        var replacement = initial with
        {
            StreamRefreshToken = 1, StreamConfigurationTransaction = new(Guid.NewGuid()), Width = 640, Height = 360
        };
        await fixture.Send("streamConfiguration", replacement);
        await fixture.ReadAcknowledgement();
        Require(fixture.StreamCount == 2 && stream.DisposeCalls == 1 && stream.KeyFrameRequests == 0,
            "A refresh token must not keep a capture whose media settings changed.");
    }

    private static async Task AudioReplacement()
    {
        using var firstOutput = new UdpClient(new IPEndPoint(IPAddress.Loopback, 0));
        using var secondOutput = new UdpClient(new IPEndPoint(IPAddress.Loopback, 0));
        await using var fixture = new SessionFixture();
        var first = AudioConfiguration(((IPEndPoint)firstOutput.Client.LocalEndPoint!).Port);
        await fixture.Send("streamConfiguration", first);
        var firstAck = await fixture.ReadAcknowledgement();
        Require(firstAck.AudioEndpointPresent, "Prepared audio was not reflected in the acknowledgement.");
        var firstStream = fixture.LastStream!;
        await firstStream.SendAudio(0);
        var packet = fixture.OpenAudio((await firstOutput.ReceiveAsync().WaitAsync(TimeSpan.FromSeconds(3))).Buffer);
        Require(packet.Sequence == 0 && packet.NonceCounter == 1 && packet.TimestampSamples == 0,
            "The first audio packet did not use the authenticated session's initial counters.");
        var drained = NewSignal();
        firstStream.DisposeBarrier = drained.Task;
        var second = AudioConfiguration(((IPEndPoint)secondOutput.Client.LocalEndPoint!).Port) with { AudioMode = "high-fidelity" };
        await fixture.Send("streamConfiguration", second);
        await firstStream.DisposeEntered.Task.WaitAsync(TimeSpan.FromSeconds(3));
        try
        {
            await firstStream.SendAudio(960);
            packet = fixture.OpenAudio((await firstOutput.ReceiveAsync().WaitAsync(TimeSpan.FromSeconds(3))).Buffer);
            Require(packet.Sequence == 1 && packet.NonceCounter == 2 && secondOutput.Available == 0 && fixture.StreamCount == 1,
                "An old audio worker was rebound to the replacement destination before it stopped.");
        }
        finally { drained.TrySetResult(); }
        await fixture.ReadAcknowledgement();
        await fixture.LastStream!.SendAudio(0);
        packet = fixture.OpenAudio((await secondOutput.ReceiveAsync().WaitAsync(TimeSpan.FromSeconds(3))).Buffer);
        Require(packet.TimestampSamples == 1920,
            $"Replacing the audio source reset its session sample clock: expected 1920, received {packet.TimestampSamples}.");
        Require(packet.Sequence == 2 && packet.NonceCounter == 3 && packet.Flags == 2 && firstOutput.Available == 0,
            "Replacing the audio source reused a nonce, lost its mode, or sent to the old destination.");
    }

    private static async Task AudioSampleClockContinuity()
    {
        using var output = new UdpClient(new IPEndPoint(IPAddress.Loopback, 0));
        await using var fixture = new SessionFixture();
        var configuration = AudioConfiguration(((IPEndPoint)output.Client.LocalEndPoint!).Port);
        var packets = new List<RealtimeMediaOpenedPacket>();
        for (var epoch = 0; epoch < 2; epoch++)
        {
            configuration = configuration with { TargetFrameRate = epoch == 0 ? 2 : 30, StreamConfigurationTransaction = new(Guid.NewGuid()) };
            await fixture.Send("streamConfiguration", configuration);
            await fixture.ReadAcknowledgement();
            foreach (var nativeTimestamp in new[] { 0UL, 960UL })
            {
                await fixture.LastStream!.SendAudio(nativeTimestamp);
                packets.Add(fixture.OpenAudio((await output.ReceiveAsync().WaitAsync(TimeSpan.FromSeconds(3))).Buffer));
            }
        }
        await fixture.Send("streamConfiguration", configuration);
        await fixture.ReadAcknowledgement();
        await fixture.LastStream!.SendAudio(1920);
        packets.Add(fixture.OpenAudio((await output.ReceiveAsync().WaitAsync(TimeSpan.FromSeconds(3))).Buffer));
        Require(packets.Select(packet => packet.TimestampSamples).SequenceEqual(new ulong[] { 0, 960, 1920, 2880, 3840 }) &&
            packets.Select(packet => packet.Sequence).SequenceEqual(new ulong[] { 0, 1, 2, 3, 4 }) &&
            packets.Select(packet => packet.NonceCounter).SequenceEqual(new ulong[] { 1, 2, 3, 4, 5 }) &&
            fixture.StreamCount == 2,
            "Equivalent audio reconfiguration or duplicate ACK reset the sample clock, sequence, nonce, or capture owner.");
    }

    private static async Task AudioSampleClockEpochs()
    {
        using var output = new UdpClient(new IPEndPoint(IPAddress.Loopback, 0));
        var configuration = AudioConfiguration(((IPEndPoint)output.Client.LocalEndPoint!).Port);
        await using (var fixture = new SessionFixture())
        {
            await fixture.Send("streamConfiguration", configuration);
            await fixture.ReadAcknowledgement();
            foreach (var (nativeTimestamp, wireTimestamp) in new[] { (10_000UL, 0UL), (10_960UL, 960UL), (12_160UL, 2160UL) })
            {
                await fixture.LastStream!.SendAudio(nativeTimestamp);
                var packet = fixture.OpenAudio((await output.ReceiveAsync().WaitAsync(TimeSpan.FromSeconds(3))).Buffer);
                Require(packet.TimestampSamples == wireTimestamp, "Audio epoch normalization changed an actual captured-sample gap.");
            }
            await fixture.Send("streamConfiguration", Configuration());
            Require(!(await fixture.ReadAcknowledgement()).AudioEndpointPresent, "Disabled audio retained an active endpoint.");
            await fixture.Send("streamConfiguration", Configuration() with { TargetFrameRate = 0 });
            await fixture.ReadAcknowledgement();
            await fixture.Send("streamConfiguration", configuration with { StreamConfigurationTransaction = new(Guid.NewGuid()) });
            await fixture.ReadAcknowledgement();
            await fixture.LastStream!.SendAudio(73_000);
            var resumed = fixture.OpenAudio((await output.ReceiveAsync().WaitAsync(TimeSpan.FromSeconds(3))).Buffer);
            Require(resumed.TimestampSamples == 3120 && resumed.Sequence == 3 && resumed.NonceCounter == 4,
                "Disabling or stopping capture discarded the authenticated session's sample or nonce continuity.");
        }
        const string nextSession = "next-authenticated-session";
        await using (var fixture = new SessionFixture(nextSession))
        {
            await fixture.Send("streamConfiguration", configuration with { MediaSessionId = nextSession });
            await fixture.ReadAcknowledgement();
            await fixture.LastStream!.SendAudio(91_000);
            var restarted = fixture.OpenAudio((await output.ReceiveAsync().WaitAsync(TimeSpan.FromSeconds(3))).Buffer);
            Require(restarted.TimestampSamples == 0 && restarted.Sequence == 0 && restarted.NonceCounter == 1,
                "A new authenticated session inherited the retired session's sample clock or counters.");
        }
    }

    private static async Task InvalidAudioSampleClock()
    {
        using var output = new UdpClient(new IPEndPoint(IPAddress.Loopback, 0));
        await using var fixture = new SessionFixture();
        var configuration = AudioConfiguration(((IPEndPoint)output.Client.LocalEndPoint!).Port);
        await fixture.Send("streamConfiguration", configuration);
        await fixture.ReadAcknowledgement();
        var stream = fixture.LastStream ?? throw new InvalidOperationException("Audio configuration did not create its capture owner.");
        await stream.SendAudio(0);
        await output.ReceiveAsync().WaitAsync(TimeSpan.FromSeconds(3));
        await ThrowsAsync<InvalidDataException>(() => stream.SendAudio(0).AsTask());
        await ThrowsAsync<InvalidDataException>(() => stream.SendAudio(480).AsTask());
        await ThrowsAsync<InvalidDataException>(() => stream.SendAudio(960, samplesPerChannel: 0).AsTask());
        await ThrowsAsync<InvalidDataException>(() => stream.SendAudio(ulong.MaxValue).AsTask());
        Require(output.Available == 0, "An overlapping, malformed, or overflowing sample clock reached UDP.");
        await stream.SendAudio(960);
        var recovered = fixture.OpenAudio((await output.ReceiveAsync().WaitAsync(TimeSpan.FromSeconds(3))).Buffer);
        Require(recovered.TimestampSamples == 960 && recovered.Sequence == 1 && recovered.NonceCounter == 2,
            "Rejected sample clocks consumed a timestamp or nonce before validation.");
        await fixture.Send("streamConfiguration", configuration with { StreamConfigurationTransaction = new(Guid.NewGuid()) });
        await fixture.ReadAcknowledgement();
        var next = fixture.LastStream ?? throw new InvalidOperationException("Audio replacement did not create its capture owner.");
        await next.SendAudio(10_000);
        await output.ReceiveAsync().WaitAsync(TimeSpan.FromSeconds(3));
        await ThrowsAsync<InvalidDataException>(() => next.SendAudio(9_000).AsTask());
        Require(output.Available == 0, "A timestamp preceding the capture epoch's origin reached UDP.");
    }

    private static async Task CancelPreparation()
    {
        await using var fixture = new SessionFixture { Prepare = NewSignal().Task };
        await fixture.Send("streamConfiguration", Configuration());
        var stream = await fixture.Created.Reader.ReadAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(3));
        await fixture.CancelRun();
        Require(stream.Starts == 0 && !fixture.Transport.Outgoing.Reader.TryRead(out _),
            "Cancelled preparation acknowledged or started an incomplete stream.");
        await fixture.Session.DisposeAsync();
        Require(stream.DisposeCalls == 1 && stream.FakeInput.Actions.SequenceEqual(new[] { "release" }),
            "Cancelled preparation lost its allocated native owner.");
    }

    private static async Task ConfigurationDeadlines()
    {
        // These use the product's real 30-second deadlines. Run the independent
        // phases together so the test never substitutes caller cancellation for timeout.
        var elapsed = Stopwatch.StartNew();
        await using var idle = new SessionFixture();
        await using var preparing = new SessionFixture { Prepare = NewSignal().Task };
        await using var acknowledging = new SessionFixture();
        await using var active = new SessionFixture();
        var preparation = Configuration();
        var acknowledgement = Configuration();
        var running = Configuration();
        var sendAttempts = 0;
        acknowledging.Transport.BeforeSend = async (_, token) =>
        {
            if (Interlocked.Increment(ref sendAttempts) == 1)
                await Task.Delay(Timeout.InfiniteTimeSpan, token);
        };
        await preparing.Send("streamConfiguration", preparation);
        await acknowledging.Send("streamConfiguration", acknowledgement);
        await active.Send("streamConfiguration", running);
        var accepted = await active.ReadAcknowledgement();
        var limit = TimeSpan.FromSeconds(40);
        await Task.WhenAll(idle.ExpectFailure<TimeoutException>(limit),
            preparing.ExpectFailure<TimeoutException>(limit), acknowledging.ExpectFailure<TimeoutException>(limit));
        Require(elapsed.Elapsed >= TimeSpan.FromSeconds(28) && elapsed.Elapsed < limit,
            "A phase failed before the real deadline or continued beyond its bound.");
        Require(idle.StreamCount == 0 && idle.Transport.ActiveReads == 0 && !idle.Transport.Outgoing.Reader.TryRead(out _),
            "The initial configuration deadline allocated resources, invented a transaction, or left its reader active.");
        foreach (var (fixture, configuration) in new[] { (preparing, preparation), (acknowledging, acknowledgement) })
        {
            var stream = fixture.LastStream ?? throw new InvalidOperationException("A timed-out configuration lost its prepared stream.");
            var message = await fixture.ReadMessage();
            var rejection = RemoteControlWire.Decode<RemoteStreamRejection>(message.Payload);
            Require(message.Type == "streamConfigurationRejected" && rejection.Code == "configuration-timeout" &&
                rejection.Transaction == configuration.StreamConfigurationTransaction && stream.Starts == 0 &&
                !fixture.Transport.Outgoing.Reader.TryRead(out _),
                "A timed-out phase started media, lost its exact transaction, or sent a success acknowledgement.");
            await fixture.Session.DisposeAsync();
            Require(stream.DisposeCalls == 1, "A timed-out configuration lost its prepared owner during cleanup.");
        }
        Require(sendAttempts == 2, "ACK timeout did not use the still-live session to deliver exactly one rejection.");
        await active.Send("keyboardEvent", new RemoteKeyEvent("keyDown", 0, 1));
        await active.Send("streamConfiguration", running);
        var repeated = await active.ReadAcknowledgement();
        Require(repeated == accepted && active.LastStream!.Starts == 1 &&
            active.LastStream.FakeInput.Actions.SequenceEqual(new[] { "key:0:True" }),
            "An expired preparation deadline cancelled or recreated an already accepted stream.");
    }

    private static TaskCompletionSource NewSignal() => new(TaskCreationOptions.RunContinuationsAsynchronously);

    private static async Task ApprovalDeadline()
    {
        var access = new RemoteControlHostAccessCoordinator();
        await using var delayed = new SessionFixture("delayed-approval", access, autoApprove: false);
        await using var expired = new SessionFixture("expired-approval", autoApprove: false);
        var configuration = Configuration() with { RemoteControlAccessVersion = 1 };
        var elapsed = Stopwatch.StartNew();
        await delayed.Send("streamConfiguration", configuration);
        await expired.Send("streamConfiguration", configuration);
        await Task.WhenAll(delayed.ApprovalRequested.Task, expired.ApprovalRequested.Task).WaitAsync(TimeSpan.FromSeconds(3));

        // Cross the former configuration timeout while approval is still pending.
        await Task.Delay(TimeSpan.FromSeconds(32));
        Require(delayed.StreamCount == 0 && expired.StreamCount == 0 &&
            !delayed.Transport.Outgoing.Reader.TryRead(out _) && !expired.Transport.Outgoing.Reader.TryRead(out _),
            "Pending approval consumed the capture deadline, started capture or acknowledged without permission.");
        await access.ApproveAsync(delayed.AdmissionId, true, default);
        var accepted = await delayed.ReadAcknowledgement();
        Require(accepted.Transaction == configuration.StreamConfigurationTransaction && accepted.ControlAccess?.AllowsInput == true &&
            delayed.LastStream?.Starts == 1, "Approval after thirty seconds did not receive a fresh capture-preparation budget.");

        await expired.ExpectFailure<TimeoutException>(TimeSpan.FromSeconds(20));
        var message = await expired.ReadMessage();
        var rejected = RemoteControlWire.Decode<RemoteStreamRejection>(message.Payload);
        Require(elapsed.Elapsed >= TimeSpan.FromSeconds(44) && elapsed.Elapsed < TimeSpan.FromSeconds(55) &&
            message.Type == "streamConfigurationRejected" && rejected.Code == "approval-timeout" &&
            rejected.Transaction == configuration.StreamConfigurationTransaction && expired.StreamCount == 0 &&
            !expired.Transport.Outgoing.Reader.TryRead(out _),
            "Unapproved access was not rejected once, on its exact transaction, within the real approval deadline.");
    }

    private static async Task ManagedSessionHandoff()
    {
        var access = new RemoteControlHostAccessCoordinator();
        await using var first = new SessionFixture("first", access, autoApprove: false);
        await using var second = new SessionFixture("second", access, autoApprove: false);
        var firstConfiguration = Configuration() with { RemoteControlAccessVersion = 1 };
        var secondConfiguration = Configuration() with { RemoteControlAccessVersion = 1 };
        await first.Send("streamConfiguration", firstConfiguration);
        await first.ApprovalRequested.Task.WaitAsync(TimeSpan.FromSeconds(3));
        Require(first.StreamCount == 0 && !first.Transport.Outgoing.Reader.TryRead(out _), "A trusted connection captured or acknowledged before local approval.");
        await access.ApproveAsync(first.AdmissionId, true, default);
        var firstAck = await first.ReadAcknowledgement();
        var firstLease = firstAck.ControlAccess?.Lease ?? throw new InvalidOperationException("The initial controller ACK lost its grant.");
        await second.Send("streamConfiguration", secondConfiguration);
        await second.ApprovalRequested.Task.WaitAsync(TimeSpan.FromSeconds(3));
        await access.ApproveAsync(second.AdmissionId, false, default);
        var secondAck = await second.ReadAcknowledgement();
        var firstStream = first.LastStream ?? throw new InvalidOperationException("The first acknowledged session lost its stream.");
        var secondStream = second.LastStream ?? throw new InvalidOperationException("The second acknowledged session lost its stream.");
        Require(secondAck.ControlAccess is { Role: "observer", Lease: null } && first.StreamCount == 1 && second.StreamCount == 1,
            "Two approved viewing sessions did not retain independent streams.");
        await first.Send("keyboardEvent", new RemoteKeyEvent("keyDown", 0, 1), firstLease);
        await first.Send("streamConfiguration", firstConfiguration);
        await first.ReadAcknowledgement();
        await second.Send("keyboardEvent", new RemoteKeyEvent("keyDown", 1, 1), Guid.NewGuid());
        await second.Send("streamConfiguration", secondConfiguration);
        await second.ReadAcknowledgement();
        Require(firstStream.FakeInput.Actions.SequenceEqual(["key:0:True"]) && secondStream.FakeInput.Actions.Count == 0,
            "Observer input crossed the real encrypted session boundary.");
        await access.TransferInputAsync(second.AdmissionId, default);
        var revocation = await first.ReadMessage();
        var grantMessage = await second.ReadMessage();
        var grant = RemoteControlWire.Decode<RemoteControlAccess>(grantMessage.Payload);
        Require(revocation.Type == "controlAccess" && RemoteControlWire.Decode<RemoteControlAccess>(revocation.Payload).Role == "observer" &&
            grantMessage.Type == "controlAccess" && grant.Role == "controller" && grant.Lease != firstLease,
            "Host handoff used a configuration ACK or revived the previous lease.");
        await first.Send("keyboardEvent", new RemoteKeyEvent("keyDown", 2, 2), firstLease);
        await first.Send("streamConfiguration", firstConfiguration);
        await first.ReadAcknowledgement();
        await second.Send("keyboardEvent", new RemoteKeyEvent("keyDown", 3, 2), grant.Lease);
        await second.Send("streamConfiguration", secondConfiguration);
        await second.ReadAcknowledgement();
        Require(firstStream.FakeInput.Actions.SequenceEqual(["key:0:True", "release"]) &&
            secondStream.FakeInput.Actions.SequenceEqual(["key:3:True"]),
            "Old queued input was rebound to the new controller or held input was not released.");
    }

    private static async Task ManagedSessionDowngrade()
    {
        await using var fixture = new SessionFixture();
        var configuration = Configuration() with { RemoteControlAccessVersion = 1 };
        await fixture.Send("streamConfiguration", configuration);
        await fixture.ReadAcknowledgement();
        await fixture.Send("streamConfiguration", configuration with
        {
            RemoteControlAccessVersion = null,
            StreamConfigurationTransaction = new(Guid.NewGuid())
        });
        await fixture.ExpectFailure<InvalidDataException>();
        Require(fixture.StreamCount == 1, "Negotiation downgrade allocated a replacement capture.");
    }

    private static RemoteStreamConfiguration AudioConfiguration(int port) => Configuration() with
    {
        AudioRedirectionEnabled = true, AudioTransport = "pqc-media-v1", AudioMode = "low-latency",
        MediaSessionId = "test-session", AudioSampleRate = 48_000, AudioChannelCount = 2,
        MediaAudioEndpoint = new("127.0.0.1", port)
    };

    private static async Task<(TcpClient Sender, TcpProductControlTransport Receiver)> ConnectedTcp()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        try
        {
            var sender = new TcpClient();
            await sender.ConnectAsync((IPEndPoint)listener.LocalEndpoint);
            return (sender, new TcpProductControlTransport(await listener.AcceptTcpClientAsync(), RemoteControlWire.MaximumInboundFrameBytes, RemoteControlWire.MaximumOutboundFrameBytes));
        }
        finally { listener.Stop(); }
    }

    private static async Task FramingRoundTrip()
    {
        var pair = await ConnectedTcp();
        using var sender = pair.Sender;
        await using var receiver = pair.Receiver;
        byte[] bytes = [0, 0, 0, 3, 1, 2, 3, 0, 0, 0, 2, 4, 5];
        await sender.GetStream().WriteAsync(bytes.AsMemory(0, 2));
        await sender.GetStream().WriteAsync(bytes.AsMemory(2));
        var first = await receiver.ReadAsync(default).WaitAsync(TimeSpan.FromSeconds(3));
        var second = await receiver.ReadAsync(default).WaitAsync(TimeSpan.FromSeconds(3));
        Require(first.Span.SequenceEqual(new byte[] { 1, 2, 3 }) && second.Span.SequenceEqual(new byte[] { 4, 5 }), "Coalesced frame bytes were lost.");
    }

    private static async Task IdlePeerLiveness()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        try
        {
            using var peer = new TcpClient();
            await peer.ConnectAsync((IPEndPoint)listener.LocalEndpoint);
            using var accepted = await listener.AcceptTcpClientAsync();
            await using var transport = new TcpProductControlTransport(accepted, RemoteControlWire.MaximumInboundFrameBytes, RemoteControlWire.MaximumOutboundFrameBytes);
            Require(accepted.Client.GetSocketOption(SocketOptionLevel.Socket, SocketOptionName.KeepAlive) is int enabled && enabled != 0 &&
                accepted.Client.GetSocketOption(SocketOptionLevel.Tcp, SocketOptionName.TcpKeepAliveTime) is 10 &&
                accepted.Client.GetSocketOption(SocketOptionLevel.Tcp, SocketOptionName.TcpKeepAliveInterval) is 3 &&
                accepted.Client.GetSocketOption(SocketOptionLevel.Tcp, SocketOptionName.TcpKeepAliveRetryCount) is 3,
                "The accepted socket can retain an absent idle controller indefinitely.");
        }
        finally { listener.Stop(); }
    }

    private static async Task RejectLargeFrame()
    {
        var pair = await ConnectedTcp();
        using var sender = pair.Sender;
        await using var receiver = pair.Receiver;
        await sender.GetStream().WriteAsync(new byte[] { 0, 1, 0, 1 });
        await ThrowsAsync<InvalidDataException>(() => receiver.ReadAsync(default).WaitAsync(TimeSpan.FromSeconds(3)));
    }

    private static async Task DisposeActiveReader()
    {
        var pair = await ConnectedTcp();
        using var sender = pair.Sender;
        var read = pair.Receiver.ReadAsync(default);
        await pair.Receiver.DisposeAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(3));
        await ThrowsAsync<OperationCanceledException>(async () => await read);
        await pair.Receiver.DisposeAsync();
    }

    private static async Task WriteTimeoutPreservesCause()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        try
        {
            using var peer = new TcpClient { ReceiveBufferSize = 4096 };
            await peer.ConnectAsync((IPEndPoint)listener.LocalEndpoint);
            using var accepted = await listener.AcceptTcpClientAsync();
            // Windows overlapped sends may complete after copying the entire
            // buffer into Winsock even with a small SO_SNDBUF. Disable that copy
            // so this test measures actual peer backpressure on both hosts.
            accepted.SendBufferSize = OperatingSystem.IsWindows() ? 0 : 4096;
            await using var transport = new TcpProductControlTransport(accepted, RemoteControlWire.MaximumInboundFrameBytes, RemoteControlWire.MaximumOutboundFrameBytes, TimeSpan.FromSeconds(1));
            var read = transport.ReadAsync(default);
            TimeoutException? sendFailure = null;
            try
            {
                var payload = new byte[RemoteControlWire.MaximumOutboundFrameBytes];
                for (var i = 0; i < 8; i++)
                    await transport.SendAsync(payload, default).WaitAsync(TimeSpan.FromSeconds(5));
                throw new InvalidOperationException("A non-reading peer must exhaust the bounded send deadline.");
            }
            catch (TimeoutException failure)
            {
                sendFailure = failure;
                Require(failure.Message.Contains("writing the frame body", StringComparison.Ordinal) &&
                    failure.InnerException is OperationCanceledException,
                    "Write timeout lost its phase or was confused with the test deadline.");
            }
            try { await read; throw new InvalidOperationException("The failed writer left its reader active."); }
            catch (AggregateException failure)
            {
                Require(failure.InnerExceptions.Count == 2 && ReferenceEquals(failure.InnerExceptions[0], sendFailure) &&
                    failure.InnerExceptions[1] is OperationCanceledException or IOException or ObjectDisposedException,
                    $"The read-side interruption hid the write timeout that ended the session: {failure}");
            }
        }
        finally { listener.Stop(); }
    }

    private static async Task CancelledUnstartedSendPreservesTransport()
    {
        var pair = await ConnectedTcp();
        using var peer = pair.Sender;
        await using var transport = pair.Receiver;
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        await ThrowsAsync<OperationCanceledException>(() => transport.SendAsync(new byte[] { 9 }, cancelled.Token));
        var payload = new byte[] { 1, 2, 3 };
        await transport.SendAsync(payload, default);
        var received = new byte[7];
        await peer.GetStream().ReadExactlyAsync(received).AsTask().WaitAsync(TimeSpan.FromSeconds(3));
        Require(received.AsSpan().SequenceEqual(new byte[] { 0, 0, 0, 3, 1, 2, 3 }),
            "Cancellation before a frame begins must not close the carrier or write a prefix.");
    }

    private sealed class SessionFixture : IAsyncDisposable
    {
        private readonly CancellationTokenSource _cancel = new();
        private readonly RemoteControlSecureSession _viewer;
        private readonly RealtimeMediaPacketKeys _audioKeys;
        private readonly Task _run;
        private bool _observed;
        private readonly RemoteControlHostAccessCoordinator _access;
        private readonly Guid _admissionId;
        private readonly Action<IReadOnlyList<RemoteControlHostSessionStatus>> _approvalHandler;
        private Task _approval = Task.CompletedTask;
        internal TestTransport Transport { get; } = new();
        internal RemoteControlHostSession Session { get; }
        internal Task Prepare { get; set; } = Task.CompletedTask;
        internal FakeStream? LastStream { get; private set; }
        internal int StreamCount { get; private set; }
        internal Channel<FakeStream> Created { get; } = Channel.CreateBounded<FakeStream>(4);
        internal TaskCompletionSource ApprovalRequested { get; } = NewSignal();
        internal Guid AdmissionId => _admissionId;
        internal SessionFixture(string sessionId = "test-session", RemoteControlHostAccessCoordinator? access = null, bool autoApprove = true)
        {
            _access = access ?? new RemoteControlHostAccessCoordinator();
            _admissionId = _access.Reserve(_cancel.Cancel);
            _access.Authenticate(_admissionId, "test-controller", "Test Controller");
            _approvalHandler = snapshot =>
            {
                if (snapshot.Any(row => row.Id == _admissionId && row.Phase == RemoteControlHostSessionPhase.AwaitingApproval))
                {
                    ApprovalRequested.TrySetResult();
                    if (autoApprove) _approval = _access.ApproveAsync(_admissionId, true, _cancel.Token);
                }
            };
            _access.Changed += _approvalHandler;
            using var hostKeys = new ProductSessionKeys(ProductHandshakeRole.Responder, sessionId, new byte[32], Enumerable.Repeat((byte)1, 32).ToArray(), Enumerable.Repeat((byte)2, 32).ToArray());
            using var viewerKeys = new ProductSessionKeys(ProductHandshakeRole.Initiator, sessionId, hostKeys.TranscriptHash, hostKeys.ReceiveKey, hostKeys.SendKey);
            _viewer = new RemoteControlSecureSession(viewerKeys);
            _audioKeys = RealtimeMediaPacketCodec.DeriveReceiveKeys(viewerKeys);
            Session = new RemoteControlHostSession(Transport, hostKeys, IPAddress.Loopback, (_, sendVideo, sendAudio) =>
            {
                StreamCount++;
                LastStream = new FakeStream(Prepare, sendVideo, sendAudio);
                if (!Created.Writer.TryWrite(LastStream)) throw new InvalidOperationException("Too many test streams.");
                return LastStream;
            }, (_, _) => { }, _access, _admissionId);
            _run = Session.RunAsync(_cancel.Token);
        }
        internal ValueTask Send<T>(string type, T payload, Guid? inputControlLease = null) => Transport.Incoming.Writer.WriteAsync(
            _viewer.Seal(RemoteControlWire.EncodeMessage(type, payload, inputControlLease), RemoteControlSecurePacketType.Control));
        internal async Task<RemoteControlMessage> ReadMessage()
        {
            var packet = await Transport.Outgoing.Reader.ReadAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(3));
            var plaintext = _viewer.Open(packet.Span, [RemoteControlSecurePacketType.Control]);
            return RemoteControlWire.Decode<RemoteControlMessage>(plaintext.Payload);
        }
        internal async Task<RemoteStreamAcknowledgement> ReadAcknowledgement()
        {
            var message = await ReadMessage();
            Require(message.Type == "streamConfigurationAck", "Expected stream acknowledgement.");
            return RemoteControlWire.Decode<RemoteStreamAcknowledgement>(message.Payload);
        }
        internal async Task<byte[]> ReadVideo()
        {
            var packet = await Transport.Outgoing.Reader.ReadAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(3));
            return _viewer.Open(packet.Span, [RemoteControlSecurePacketType.Screen]).Payload;
        }
        internal RealtimeMediaOpenedPacket OpenAudio(byte[] packet) => RealtimeMediaPacketCodec.Open(packet, _audioKeys);
        internal async Task<T> ExpectFailure<T>(TimeSpan? timeout = null) where T : Exception
        {
            try { return await ThrowsAsync<T>(() => _run.WaitAsync(timeout ?? TimeSpan.FromSeconds(3))); }
            finally { if (_run.IsCompleted) _observed = true; }
        }
        internal async Task CancelRun()
        {
            await _cancel.CancelAsync();
            if (!_observed)
            {
                try { await _run.WaitAsync(TimeSpan.FromSeconds(3)); }
                catch (OperationCanceledException) when (_cancel.IsCancellationRequested) { }
                _observed = true;
            }
        }
        public async ValueTask DisposeAsync()
        {
            await CancelRun();
            await Session.DisposeAsync();
            await _approval;
            _access.Changed -= _approvalHandler;
            _access.Retire(_admissionId);
            _viewer.Dispose();
            _audioKeys.Dispose();
            _cancel.Dispose();
        }
    }

    private sealed class TestTransport : IProductHandshakeTransport
    {
        internal Channel<ReadOnlyMemory<byte>> Incoming { get; } = Channel.CreateBounded<ReadOnlyMemory<byte>>(8);
        internal Channel<ReadOnlyMemory<byte>> Outgoing { get; } = Channel.CreateBounded<ReadOnlyMemory<byte>>(8);
        internal Func<ReadOnlyMemory<byte>, CancellationToken, Task>? BeforeSend { get; set; }
        internal Exception? ReadCancellationFailure { get; set; }
        private int _activeReads;
        internal int ActiveReads => Volatile.Read(ref _activeReads);
        public async Task SendAsync(ReadOnlyMemory<byte> frame, CancellationToken cancellationToken = default)
        {
            if (BeforeSend is not null) await BeforeSend(frame, cancellationToken);
            await Outgoing.Writer.WriteAsync(frame.ToArray(), cancellationToken);
        }
        public async Task<ReadOnlyMemory<byte>> ReadAsync(CancellationToken cancellationToken = default)
        {
            Interlocked.Increment(ref _activeReads);
            try { return await Incoming.Reader.ReadAsync(cancellationToken); }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested && ReadCancellationFailure is not null)
            { throw ReadCancellationFailure; }
            finally { Interlocked.Decrement(ref _activeReads); }
        }
    }
    private sealed class FakeStream(Task prepare,
        Func<WindowsDesktopEncodedFrame, CancellationToken, Task> sendVideo,
        Func<WindowsOpusAudioFrame, CancellationToken, ValueTask> sendAudio) : IRemoteControlHostStream
    {
        private readonly TaskCompletionSource _completion = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal FakeInput FakeInput { get; } = new();
        internal int Starts { get; private set; }
        internal int KeyFrameRequests { get; private set; }
        internal int CleanupFailures { get; set; }
        internal int DisposeCalls { get; private set; }
        internal bool CompleteWorkersBeforeCleanupFailure { get; set; }
        internal Task DisposeBarrier { get; set; } = Task.CompletedTask;
        internal TaskCompletionSource DisposeEntered { get; } = NewSignal();
        private bool _disposed;
        public Task Completion => _completion.Task;
        public int Width => 1280;
        public int Height => 720;
        public IWindowsRemoteInput Input => FakeInput;
        public Task PrepareAsync(CancellationToken cancellationToken) => prepare.WaitAsync(cancellationToken);
        public void Start() => Starts++;
        public void RequestKeyFrame() => KeyFrameRequests++;
        internal Task SendVideo(CancellationToken cancellationToken) => sendVideo(new WindowsDesktopEncodedFrame(
            [0, 0, 0, 1, 0x65], true, Width, Height, 1), cancellationToken);
        internal ValueTask SendAudio(ulong timestampSamples, int samplesPerChannel = 960) => sendAudio(new WindowsOpusAudioFrame(
            [1, 2, 3], timestampSamples, samplesPerChannel, false), CancellationToken.None);
        internal void FailWorker(Exception failure) => _completion.SetException(failure);
        public async ValueTask DisposeAsync()
        {
            if (_disposed) return;
            DisposeCalls++;
            DisposeEntered.TrySetResult();
            if (CompleteWorkersBeforeCleanupFailure) _completion.TrySetResult();
            if (CleanupFailures-- > 0) throw new IOException("desktop release temporarily unavailable");
            await DisposeBarrier;
            FakeInput.ReleaseAll();
            _completion.TrySetResult();
            _disposed = true;
        }
    }
    private sealed class FakeInput : IWindowsRemoteInput
    {
        internal List<string> Actions { get; } = [];
        internal List<(double X, double Y)> Points { get; } = [];
        public void MovePointer(double x, double y) { Actions.Add("move"); Points.Add((x, y)); }
        public void SetMouseButton(WindowsRemoteMouseButton button, bool down) => Actions.Add("button");
        public void Scroll(int x, int y) => Actions.Add("scroll");
        public void SetKey(ushort code, bool down, WindowsRemoteModifiers modifiers = WindowsRemoteModifiers.None) => Actions.Add($"key:{code}:{down}");
        public void TypeText(string text) => Actions.Add("text");
        public void ReleaseAll() => Actions.Add("release");
        public void Dispose() => ReleaseAll();
    }
}
