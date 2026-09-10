using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

// Three independently owned loops prevent an external lookup from stalling local counters.
public sealed class TopBarNetworkCoordinator : IDisposable
{
    private readonly ITopBarNetworkStatusClient _client;
    private readonly Action<string> _setNetworkSpeed;
    private readonly Action<string> _setNetworkLatency;
    private readonly Action<string> _setIpLocation;
    private readonly Action<bool> _setProxyEnabled;
    private readonly Action<Action> _dispatch;
    private readonly Func<string, string> _text;
    private readonly TimeSpan _speedInterval;
    private readonly CancellationTokenSource _cancellation = new();
    private readonly object _sync = new();
    private NetworkCounterSample? _previousCounters;
    private volatile bool _disposed;
    private Task? _completion;
    private bool _loopsFinished;

    public const string PlaceholderSpeed = "↓ — · ↑ —";
    public const string PlaceholderLatency = "— ms";
    public const string PlaceholderLocationUnavailable = "IP · —";

    public TopBarNetworkCoordinator(Action<string> setNetworkSpeed, Action<string> setNetworkLatency,
        Action<string> setIpLocation, Action<bool> setProxyEnabled, Action<Action> dispatch,
        Func<string, string> text, ITopBarNetworkStatusClient? client = null)
        : this(setNetworkSpeed, setNetworkLatency, setIpLocation, setProxyEnabled, dispatch, text,
            client ?? new TopBarNetworkStatusClient(), TimeSpan.FromSeconds(2)) { }

    internal TopBarNetworkCoordinator(Action<string> setNetworkSpeed, Action<string> setNetworkLatency,
        Action<string> setIpLocation, Action<bool> setProxyEnabled, Action<Action> dispatch,
        Func<string, string> text, ITopBarNetworkStatusClient client, TimeSpan speedInterval)
    {
        _setNetworkSpeed = setNetworkSpeed ?? throw new ArgumentNullException(nameof(setNetworkSpeed));
        _setNetworkLatency = setNetworkLatency ?? throw new ArgumentNullException(nameof(setNetworkLatency));
        _setIpLocation = setIpLocation ?? throw new ArgumentNullException(nameof(setIpLocation));
        _setProxyEnabled = setProxyEnabled ?? throw new ArgumentNullException(nameof(setProxyEnabled));
        _dispatch = dispatch ?? throw new ArgumentNullException(nameof(dispatch));
        _text = text ?? throw new ArgumentNullException(nameof(text));
        _client = client ?? throw new ArgumentNullException(nameof(client));
        if (speedInterval <= TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(speedInterval));
        _speedInterval = speedInterval;
    }

    internal Task Completion { get { lock (_sync) return _completion ?? Task.CompletedTask; } }

    public void Start()
    {
        lock (_sync)
        {
            if (_disposed || _completion is not null) return;
            PostToUi(() =>
            {
                _setNetworkSpeed(PlaceholderSpeed);
                _setNetworkLatency(PlaceholderLatency);
                _setIpLocation(PlaceholderLocationUnavailable);
            });
            _completion = Task.Run(() => RunAsync(_cancellation.Token));
        }
    }

    private async Task RunAsync(CancellationToken token)
    {
        try
        {
            await Task.WhenAll(
                PollAsync(SampleSpeedAsync, _speedInterval, "speed", _setNetworkSpeed, token),
                PollAsync(SampleLatencyAsync, TimeSpan.FromSeconds(15), "latency", _setNetworkLatency, token),
                PollAsync(SampleLocationAsync, TimeSpan.FromMinutes(5), "location", _setIpLocation, token)).ConfigureAwait(false);
        }
        finally
        {
            lock (_sync)
            {
                _loopsFinished = true;
                if (_disposed) _cancellation.Dispose();
            }
        }
    }

    private async Task PollAsync(Func<CancellationToken, Task> sample, TimeSpan interval, string category,
        Action<string> setError, CancellationToken token)
    {
        try
        {
            using var timer = new PeriodicTimer(interval);
            var failures = 0;
            do
            {
                token.ThrowIfCancellationRequested();
                try
                {
                    await sample(token).ConfigureAwait(false);
                    failures = 0;
                    timer.Period = interval;
                }
                catch (NetworkProbeException ex)
                {
                    // Known transient failures remain observable, and only this probe retries at its cadence.
                    WindowsRuntimeLog.Write(WindowsLogLevel.Warning, "network." + category,
                        $"{ex.Failure}; HTTP status={(int?)ex.StatusCode}");
                    PostToUi(() => setError(FormatFailure(ex)));
                    failures = Math.Min(failures + 1, 6);
                    timer.Period = RetryInterval(interval, failures, ex.RetryAfter);
                }
            } while (await timer.WaitForNextTickAsync(token).ConfigureAwait(false));
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch (Exception ex)
        {
            // The UI lifetime boundary reports an unexpected fault and stops this sampler.
            WindowsRuntimeLog.Write(WindowsLogLevel.Error, "network." + category, "Sampler stopped: " + ex.GetType().Name);
            PostToUi(() => setError(_text("NetworkProbeStopped")));
        }
    }

    internal static TimeSpan RetryInterval(TimeSpan normalInterval, int failures, TimeSpan? retryAfter) =>
        retryAfter is { } requested && requested > TimeSpan.Zero
            ? requested
            : TimeSpan.FromSeconds(Math.Min(normalInterval.TotalSeconds, 10 * Math.Pow(2, Math.Clamp(failures - 1, 0, 5))));

    private string FormatFailure(NetworkProbeException error) => error.StatusCode is { } code
        ? $"HTTP {(int)code}"
        : _text("NetworkProbe" + error.Failure);

    private Task SampleSpeedAsync(CancellationToken token)
    {
        NetworkCounterSample current;
        try { current = _client.SampleInterfaceCounters(); }
        catch (NetworkProbeException) { _previousCounters = null; throw; }
        var previous = _previousCounters;
        _previousCounters = current;
        if (previous is not { } baseline) return Task.CompletedTask;
        var seconds = (current.SampledAt - baseline.SampledAt).TotalSeconds;
        if (seconds <= 0 || current.BytesReceived < baseline.BytesReceived || current.BytesSent < baseline.BytesSent)
        {
            PostToUi(() => _setNetworkSpeed(PlaceholderSpeed));
            return Task.CompletedTask;
        }
        var down = TopBarNetworkStatusClient.FormatBytesPerSecond((current.BytesReceived - baseline.BytesReceived) / seconds);
        var up = TopBarNetworkStatusClient.FormatBytesPerSecond((current.BytesSent - baseline.BytesSent) / seconds);
        PostToUi(() => _setNetworkSpeed($"↓ {down} · ↑ {up}"));
        return Task.CompletedTask;
    }

    private async Task SampleLatencyAsync(CancellationToken token)
    {
        var milliseconds = await _client.MeasureLatencyMillisecondsAsync(token).ConfigureAwait(false);
        PostToUi(() => _setNetworkLatency($"{milliseconds} ms"));
    }

    private async Task SampleLocationAsync(CancellationToken token)
    {
        var sample = await _client.ResolveLocationAsync(token).ConfigureAwait(false);
        PostToUi(() =>
        {
            var place = sample.City ?? sample.PublicIpAddress;
            _setIpLocation($"{place} · {_text(sample.IsSystemProxyEnabled ? "NetworkProxy" : "NetworkDirect")}");
            _setProxyEnabled(sample.IsSystemProxyEnabled);
        });
    }

    private void PostToUi(Action action)
    {
        if (_disposed) return;
        _dispatch(() => { if (!_disposed) action(); });
    }

    public void Dispose()
    {
        lock (_sync)
        {
            if (_disposed) return;
            _disposed = true;
            _cancellation.Cancel();
            // A started loop releases its own token source only after all probes have completed.
            if (_completion is null || _loopsFinished) _cancellation.Dispose();
        }
    }
}
