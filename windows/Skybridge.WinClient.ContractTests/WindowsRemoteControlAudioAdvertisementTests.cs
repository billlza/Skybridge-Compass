using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;
using Concentus;
using Skybridge.WinClient.Services.RemoteControl;

namespace Skybridge.WinClient.ContractTests;

internal static class WindowsRemoteControlAudioAdvertisementTests
{
    public static IReadOnlyList<(string Name, Func<Task> Run)> Cases { get; } = new (string, Func<Task>)[]
    {
        ("remote audio packetizer retains partial stereo packets", PacketizerRetainsPartialPackets),
        ("remote audio discontinuity does not combine unrelated samples", PacketizerDiscontinuity),
        ("remote audio Opus packets decode real stereo samples", OpusRoundTrip),
        ("remote audio rejects unsupported modes and incomplete PCM", RejectInvalidAudio),
        ("remote audio startup waits for device readiness and stop drains owners", AudioLifecycle),
        ("remote audio delivery failure terminates capture", AudioDeliveryFailure),
        ("remote audio startup failure is observable", AudioStartupFailure),
        ("remote audio distinguishes a missing output from other device failures", AudioOutputFailureClassification),
        ("remote audio queue overflow is an explicit failure", AudioQueueOverflow),
        ("remote advertisement validates TXT identity and wire size", AdvertisementValidation),
        ("remote advertisement preserves valid system DNS names", AdvertisementHostNames),
        ("remote advertisement rejects malformed or oversized DNS names", AdvertisementInvalidHostNames),
        ("remote advertisement obtains its target from the native DNS hostname", AdvertisementNativeHostName),
        ("remote advertisement requires a live listener", AdvertisementRequiresListener),
        ("remote advertisement publishes only after native completion", AdvertisementAwaitsCompletion),
        ("remote advertisement cancellation removes a late registration", AdvertisementCancellation),
        ("remote advertisement failed removal retains exact owner for retry", AdvertisementRemovalRetry)
    };

    private static Task PacketizerRetainsPartialPackets()
    {
        var packetizer = new WindowsPcmAudioPacketizer();
        var frames = new List<WindowsPcmAudioFrame>();
        var samples = Enumerable.Range(0, 3840).Select(value => (short)value).ToArray();
        packetizer.Append(samples.AsSpan(0, 600), false, frames.Add);
        Equal(0, frames.Count, "Partial audio was emitted prematurely.");
        packetizer.Append(samples.AsSpan(600), false, frames.Add);
        Equal(2, frames.Count, "Audio packets were not assembled at exactly 20 ms.");
        Check(frames[0].Samples.SequenceEqual(samples.Take(1920)), "The first stereo packet was altered.");
        Check(frames[1].Samples.SequenceEqual(samples.Skip(1920)), "The second stereo packet was altered.");
        Equal(0UL, frames[0].TimestampSamples, "The sample clock did not start at zero.");
        Equal(960UL, frames[1].TimestampSamples, "The sample clock did not advance per channel.");
        return Task.CompletedTask;
    }

    private static Task PacketizerDiscontinuity()
    {
        var packetizer = new WindowsPcmAudioPacketizer();
        var frames = new List<WindowsPcmAudioFrame>();
        packetizer.Append(Enumerable.Repeat((short)1, 480).ToArray(), false, frames.Add);
        packetizer.Append(Enumerable.Repeat((short)2, 3840).ToArray(), true, frames.Add);
        Equal(2, frames.Count, "A discontinuity generated or dropped a complete packet.");
        Check(frames[0].Samples.All(value => value == 2), "Samples across a discontinuity were combined.");
        Check(frames[0].Discontinuity && !frames[1].Discontinuity, "The discontinuity was not reported exactly once.");
        Equal(240UL, frames[0].TimestampSamples, "Discarded partial samples disappeared from the local sample clock.");
        return Task.CompletedTask;
    }

    private static Task OpusRoundTrip()
    {
        foreach (var mode in new[] { "low-latency", "high-fidelity" })
        {
            using var encoder = new WindowsOpusAudioEncoder(mode);
            using var decoder = OpusCodecFactory.CreateDecoder(48_000, 2);
            double leftEnergy = 0;
            double rightEnergy = 0;
            double differenceEnergy = 0;
            for (var frameNumber = 0; frameNumber < 10; frameNumber++)
            {
                var samples = new short[1920];
                for (var sample = 0; sample < 960; sample++)
                {
                    var time = (frameNumber * 960 + sample) / 48_000.0;
                    samples[sample * 2] = (short)(12_000 * Math.Sin(2 * Math.PI * 440 * time));
                    samples[sample * 2 + 1] = (short)(8_000 * Math.Sin(2 * Math.PI * 880 * time));
                }

                var frame = encoder.Encode(new WindowsPcmAudioFrame(samples, (ulong)(frameNumber * 960), false));
                Check(frame.Payload.Length is > 0 and <= 1100, "The encoded packet exceeded the authenticated media MTU.");
                Equal(960, frame.SamplesPerChannel, "The packet duration changed.");
                var decoded = new short[1920];
                Equal(960, decoder.Decode(frame.Payload, decoded, 960), "Opus did not decode a 20 ms frame.");
                for (var sample = 0; sample < 960; sample++)
                {
                    leftEnergy += (double)decoded[sample * 2] * decoded[sample * 2];
                    rightEnergy += (double)decoded[sample * 2 + 1] * decoded[sample * 2 + 1];
                    var difference = decoded[sample * 2] - decoded[sample * 2 + 1];
                    differenceEnergy += (double)difference * difference;
                }
            }

            Check(leftEnergy > 1e9 && rightEnergy > 1e9, "The encoded audio was silent or lost a stereo channel.");
            Check(differenceEnergy > 1e9, "Distinct stereo channels were collapsed.");
        }

        return Task.CompletedTask;
    }

    private static Task RejectInvalidAudio()
    {
        Throws<ArgumentException>(() => new WindowsOpusAudioEncoder("default"));
        using var encoder = new WindowsOpusAudioEncoder("low-latency");
        Throws<InvalidDataException>(() => encoder.Encode(new WindowsPcmAudioFrame(new short[100], 0, false)));
        var packetizer = new WindowsPcmAudioPacketizer();
        Throws<InvalidDataException>(() => packetizer.Append(new short[3], false, _ => { }));
        return Task.CompletedTask;
    }

    private static async Task AudioLifecycle()
    {
        using var readyGate = new ManualResetEventSlim();
        var entered = Signal();
        var stopped = Signal();
        var source = new WindowsLoopbackAudioSource(new CaptureStub((_, onReady, token) =>
        {
            entered.TrySetResult();
            readyGate.Wait(token);
            onReady();
            token.WaitHandle.WaitOne();
            stopped.TrySetResult();
        }));
        try
        {
            var start = source.StartAsync((_, _) => ValueTask.CompletedTask);
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(3));
            Check(!start.IsCompleted, "Audio startup reported success before the native device was ready.");
            readyGate.Set();
            await start.WaitAsync(TimeSpan.FromSeconds(3));
            await source.StopAsync().WaitAsync(TimeSpan.FromSeconds(3));
            Check(stopped.Task.IsCompletedSuccessfully && source.Completion.IsCompletedSuccessfully, "Audio stop returned before its native owner terminated.");
            await ThrowsAsync<InvalidOperationException>(() => source.StartAsync((_, _) => ValueTask.CompletedTask));
        }
        finally
        {
            await source.DisposeAsync();
        }
    }

    private static async Task AudioDeliveryFailure()
    {
        var source = new WindowsLoopbackAudioSource(new CaptureStub((onFrame, onReady, token) =>
        {
            onReady();
            onFrame(new WindowsPcmAudioFrame(new short[1920], 0, false));
            token.WaitHandle.WaitOne();
        }));
        await source.StartAsync((_, _) => ValueTask.FromException(new IOException("delivery failed")));
        await ThrowsAsync<IOException>(() => source.Completion.WaitAsync(TimeSpan.FromSeconds(3)));
        await ThrowsAsync<IOException>(() => source.DisposeAsync().AsTask());
    }

    private static async Task AudioStartupFailure()
    {
        var source = new WindowsLoopbackAudioSource(new CaptureStub((_, _, _) => throw new IOException("device unavailable")));
        await ThrowsAsync<IOException>(() => source.StartAsync((_, _) => ValueTask.CompletedTask));
        await ThrowsAsync<IOException>(() => source.DisposeAsync().AsTask());
    }

    private static Task AudioOutputFailureClassification()
    {
        WindowsWasapiLoopbackCapture.RequireDefaultAudioOutput(0);
        Throws<WindowsAudioOutputUnavailableException>(() =>
            WindowsWasapiLoopbackCapture.RequireDefaultAudioOutput(unchecked((int)0x80070490)));
        try
        {
            WindowsWasapiLoopbackCapture.RequireDefaultAudioOutput(unchecked((int)0x80070005));
            throw new InvalidOperationException("Audio endpoint access denial was accepted.");
        }
        catch (IOException failure)
        {
            Check(failure is not WindowsAudioOutputUnavailableException,
                "An access failure was incorrectly reported as an absent output device.");
            Check(failure.Message.Contains("0x80070005", StringComparison.Ordinal),
                "The actual audio endpoint failure HRESULT was lost.");
        }

        return Task.CompletedTask;
    }

    private static async Task AudioQueueOverflow()
    {
        var source = new WindowsLoopbackAudioSource(new CaptureStub((onFrame, onReady, _) =>
        {
            onReady();
            for (var index = 0; index < 32; index++)
            {
                onFrame(new WindowsPcmAudioFrame(new short[1920], (ulong)(index * 960), false));
            }
        }));
        await source.StartAsync(async (_, token) => await Task.Delay(Timeout.InfiniteTimeSpan, token));
        await ThrowsAsync<InvalidOperationException>(() => source.Completion.WaitAsync(TimeSpan.FromSeconds(3)));
        await ThrowsAsync<InvalidOperationException>(() => source.DisposeAsync().AsTask());
    }

    private static Task AdvertisementValidation()
    {
        var properties = Txt();
        properties["pubKeyFP"] = new string('A', 64);
        Throws<InvalidDataException>(() => Options(12345, properties));
        properties = Txt();
        properties["deviceId"] = "peer;token=not-public";
        Throws<InvalidDataException>(() => Options(12345, properties));
        properties = Txt();
        properties["deviceId"] = new string('x', 128);
        Throws<InvalidDataException>(() => Options(12345, properties));
        properties = Txt();
        properties["remoteControlPort"] = "1";
        Throws<InvalidDataException>(() => Options(12345, properties));
        properties = Txt();
        properties["capabilities"] = "remoteControl";
        Throws<InvalidDataException>(() => Options(12345, properties));
        properties = Txt();
        properties["platform"] = "Windows";
        Throws<InvalidDataException>(() => Options(12345, properties));
        properties = Txt();
        properties["version"] = "1";
        Throws<InvalidDataException>(() => Options(12345, properties));
        var options = Options(12345);
        Equal("Windows._skybridge-rd._tcp.local", options.ServiceName, "The canonical remote-control service changed.");
        Equal(12345, options.Port, "The real listener port was not retained for the SRV record.");
        Equal(4, options.TxtProperties.Count, "Version-2 discovery did not retain its exact four-field contract.");
        Check(!options.TxtProperties.ContainsKey("remoteControlPort"), "A mutable endpoint was duplicated into version-2 TXT.");
        return Task.CompletedTask;
    }

    private static async Task AdvertisementRequiresListener()
    {
        using var listener = new TcpListener(IPAddress.Any, 0);
        var backend = new AdvertisementBackendStub();
        await using var advertisement = new WindowsRemoteControlAdvertisement(backend);
        await ThrowsAsync<InvalidOperationException>(() => advertisement.StartAsync(listener, Options(12345)));
        Equal(0, backend.RegisterCalls, "An unready listener reached the native registration API.");
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        await ThrowsAsync<InvalidOperationException>(() => advertisement.StartAsync(listener, Options(port == 65535 ? port - 1 : port + 1)));
        Equal(0, backend.RegisterCalls, "A mismatched listener reached the native registration API.");
    }

    private static async Task AdvertisementAwaitsCompletion()
    {
        using var listener = Listening();
        var backend = new AdvertisementBackendStub { HoldRegistration = true, HoldRemoval = true };
        await using var advertisement = new WindowsRemoteControlAdvertisement(backend);
        var start = advertisement.StartAsync(listener, Options(((IPEndPoint)listener.LocalEndpoint).Port));
        await backend.RegisterEntered.Task;
        Check(!start.IsCompleted && !advertisement.IsRegistered, "Registration was published before the system callback.");
        backend.RegisterCompleted.SetResult();
        await start;
        Check(advertisement.IsRegistered, "Native registration completion did not publish readiness.");
        var stop = advertisement.StopAsync();
        await backend.RemoveEntered.Task;
        Check(!stop.IsCompleted && advertisement.IsRegistered, "Deregistration was reported before the system callback.");
        backend.RemoveCompleted.SetResult();
        await stop;
        Check(!advertisement.IsRegistered, "Deregistration did not clear readiness.");
    }

    private static async Task AdvertisementCancellation()
    {
        using var listener = Listening();
        using var cancellation = new CancellationTokenSource();
        var backend = new AdvertisementBackendStub { HoldRegistration = true };
        await using var advertisement = new WindowsRemoteControlAdvertisement(backend);
        var start = advertisement.StartAsync(listener, Options(((IPEndPoint)listener.LocalEndpoint).Port), cancellation.Token);
        await backend.RegisterEntered.Task;
        cancellation.Cancel();
        Check(!advertisement.IsRegistered, "Cancelled startup published readiness.");
        backend.RegisterCompleted.SetResult();
        await ThrowsAsync<OperationCanceledException>(() => start);
        Check(!backend.IsRegistered && !advertisement.IsRegistered, "A late registration survived startup cancellation.");
        Equal(1, backend.RemoveCalls, "Late startup did not remove its exact native registration once.");
    }

    private static async Task AdvertisementRemovalRetry()
    {
        using var listener = Listening();
        var backend = new AdvertisementBackendStub { FailNextRemoval = true };
        await using var advertisement = new WindowsRemoteControlAdvertisement(backend);
        await advertisement.StartAsync(listener, Options(((IPEndPoint)listener.LocalEndpoint).Port));
        await ThrowsAsync<IOException>(() => advertisement.StopAsync());
        Check(advertisement.IsRegistered && backend.IsRegistered, "A failed deregistration abandoned its native owner.");
        await advertisement.StopAsync();
        Check(!advertisement.IsRegistered && !backend.IsRegistered, "Retry did not remove the retained registration.");
        Equal(2, backend.RemoveCalls, "Cleanup did not retry the same retained owner.");
    }

    private static Task AdvertisementHostNames()
    {
        foreach (var host in new[]
        {
            "WORKSTATION-42.local", "long-workstation-dns-name-over-fifteen.local",
            "桌面电脑.local", "büro.local", "工作站_甲.local",
            new string('a', 63) + ".local", new string('桌', 21) + ".local"
        })
        {
            var options = new WindowsRemoteControlAdvertisementOptions("Remote desktop", host,
                IPAddress.Parse("192.0.2.10"), 49152, 1, Txt());
            Equal(host, options.HostName, "A system hostname was shortened, renamed or converted to an unadvertised ASCII alias.");
            var rooted = new WindowsRemoteControlAdvertisementOptions("Different display name", host + ".",
                IPAddress.Parse("192.0.2.10"), 49152, 1, Txt());
            Equal(host, rooted.HostName, "The optional DNS root label changed the target name.");
        }

        return Task.CompletedTask;
    }

    private static Task AdvertisementInvalidHostNames()
    {
        foreach (var host in new[]
        {
            "windows.example", "192.0.2.10", "windows..local", "windows.local..", ".local",
            "-windows.local", "windows-.local", "windows host.local", "windows/local",
            "windows\\host.local", "windows\0.local", "windows\uD800.local",
            new string('a', 64) + ".local", new string('桌', 22) + ".local",
            string.Join('.', Enumerable.Repeat(new string('a', 63), 4)) + ".local"
        })
        {
            Throws<ArgumentException>(() => new WindowsRemoteControlAdvertisementOptions("Remote desktop", host,
                IPAddress.Parse("192.0.2.10"), 49152, 1, Txt()));
        }

        return Task.CompletedTask;
    }

    private static Task AdvertisementNativeHostName()
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10))
        {
            Throws<PlatformNotSupportedException>(() => WindowsDnsSdAdvertisementBackend.GetLocalHostName());
            return Task.CompletedTask;
        }

        var expectedHost = System.Net.NetworkInformation.IPGlobalProperties.GetIPGlobalProperties().HostName;
        Equal(expectedHost + ".local", WindowsDnsSdAdvertisementBackend.GetLocalHostName(),
            "The SRV target did not use the system DNS hostname.");
        return Task.CompletedTask;
    }

    private static TcpListener Listening()
    {
        var listener = new TcpListener(IPAddress.Any, 0);
        listener.Start();
        return listener;
    }

    private static WindowsRemoteControlAdvertisementOptions Options(int port, IReadOnlyDictionary<string, string>? properties = null) =>
        new("Windows", "windows.local", IPAddress.Parse("192.0.2.10"), port, 1, properties ?? Txt());

    private static Dictionary<string, string> Txt() => new()
    {
        ["deviceId"] = "windows-test-device",
        ["version"] = "2",
        ["pubKeyFP"] = new string('a', 64),
        ["platform"] = "windows"
    };

    private sealed class CaptureStub(Action<Action<WindowsPcmAudioFrame>, Action, CancellationToken> run) : IWindowsLoopbackCapture
    {
        public void Run(Action<WindowsPcmAudioFrame> onFrame, Action onReady, CancellationToken token) => run(onFrame, onReady, token);
    }

    private sealed class AdvertisementBackendStub : IWindowsDnsSdAdvertisementBackend
    {
        public bool IsRegistered { get; private set; }
        public bool HoldRegistration { get; init; }
        public bool HoldRemoval { get; init; }
        public bool FailNextRemoval { get; set; }
        public int RegisterCalls { get; private set; }
        public int RemoveCalls { get; private set; }
        public TaskCompletionSource RegisterEntered { get; } = Signal();
        public TaskCompletionSource RegisterCompleted { get; } = Signal();
        public TaskCompletionSource RemoveEntered { get; } = Signal();
        public TaskCompletionSource RemoveCompleted { get; } = Signal();

        public async Task RegisterAsync(WindowsRemoteControlAdvertisementOptions options)
        {
            RegisterCalls++;
            RegisterEntered.TrySetResult();
            if (HoldRegistration)
            {
                await RegisterCompleted.Task;
            }

            IsRegistered = true;
        }

        public async Task DeregisterAsync()
        {
            if (!IsRegistered)
            {
                return;
            }

            RemoveCalls++;
            RemoveEntered.TrySetResult();
            if (HoldRemoval)
            {
                await RemoveCompleted.Task;
            }

            if (FailNextRemoval)
            {
                FailNextRemoval = false;
                throw new IOException("deregistration failed");
            }

            IsRegistered = false;
        }
    }

    private static TaskCompletionSource Signal() => new(TaskCreationOptions.RunContinuationsAsynchronously);
    private static void Check(bool value, string message)
    {
        if (!value) throw new InvalidOperationException(message);
    }

    private static void Equal<T>(T expected, T actual, string message) => Check(EqualityComparer<T>.Default.Equals(expected, actual), message);
    private static void Throws<T>(Action action) where T : Exception
    {
        try { action(); }
        catch (T) { return; }
        throw new InvalidOperationException($"Expected {typeof(T).Name}.");
    }

    private static async Task ThrowsAsync<T>(Func<Task> action) where T : Exception
    {
        try { await action(); }
        catch (T) { return; }
        throw new InvalidOperationException($"Expected {typeof(T).Name}.");
    }
}
