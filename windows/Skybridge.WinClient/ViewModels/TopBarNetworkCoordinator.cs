using System;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.UI.Dispatching;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

// =====================================================================================
//  TopBarNetworkCoordinator — drives the three live top-bar network pills (net speed /
//  latency / IP+proxy), the Windows port of the macOS TopBarNetworkStatusService loop.
//
//  CRITICAL ARCHITECTURE RULE (the escape hatch): this coordinator SELF-PROVISIONS its
//  ITopBarNetworkStatusClient (exactly like WeatherStateCoordinator owns its IWeatherClient
//  and AccountSessionCoordinator owns its Supabase client). It is NOT injected through
//  SessionViewModelDependencies or any *DependencyFactory — touching that composition root
//  merges into the user's backend wiring and breaks the build. The SessionViewModel just
//  `new`s one of these and forwards its four scalar values out.
//
//  It owns a single PeriodicTimer (2 s base tick, the Mac's startPeriodicRefresh cadence):
//    • net speed  — every tick (~2 s): read cumulative counters, delta ÷ elapsed = bytes/sec.
//    • latency    — every ~15 s (Mac refreshLatencyIfNeeded throttle).
//    • IP/proxy   — every ~300 s (Mac refreshLocationIfNeeded throttle).
//
//  THREADING: the timer loop runs on a thread-pool thread. The CLIENT calls (counter read,
//  HTTP probes, registry read) run there off the UI thread. But the four observable updates
//  must land on the UI thread, so every Set* delegate invocation is marshaled back via the
//  DispatcherQueue captured at construction (the VM is constructed on the UI thread). The
//  forwarded properties are STRING/bool scalars only — never ObservableCollection mutations —
//  so this path NEVER touches WorkspaceCollectionProjector and cannot reintroduce the
//  collection-projection flicker.
//
//  The Set* targets are passed in as Action delegates (thin, testable, no VM coupling), the
//  same shape WeatherStateCoordinator / DashboardMetricsUpdater use.
// =====================================================================================

public sealed class TopBarNetworkCoordinator : IDisposable
{
    private readonly ITopBarNetworkStatusClient _client;
    private readonly DispatcherQueue? _dispatcherQueue;
    private readonly Action<string> _setNetworkSpeed;
    private readonly Action<string> _setNetworkLatency;
    private readonly Action<string> _setIpLocation;
    private readonly Action<bool> _setIsSystemProxyEnabled;

    private readonly CancellationTokenSource _cts = new();
    private readonly object _sync = new();
    private PeriodicTimer? _timer;
    private Task? _loopTask;
    private bool _disposed;

    // Cadence: a 2 s base tick (matches the Mac startPeriodicRefresh). Latency and IP refresh
    // on a multiple of the tick (every 15 s / every 300 s) via the Mac's IfNeeded throttle —
    // here expressed as integer tick counts so a single timer drives all three.
    private static readonly TimeSpan TickInterval = TimeSpan.FromSeconds(2);

    private const int LatencyEveryTicks = 8;   // ~16 s (≈ Mac's 15 s latency throttle)

    private const int LocationEveryTicks = 150; // ~300 s (Mac's 300 s location throttle)

    // Net-speed baseline: the previous cumulative counter sample. The first tick primes this
    // (no delta yet → keep the loading placeholder); every subsequent tick differences against
    // it, exactly the Mac previousCounters/previousCounterDate math.
    private NetworkCounterSample? _previousCounters;

    private int _tickIndex;

    // Honest placeholders shown until the first real sample lands (and on failure). These match
    // the static XAML text the pills shipped with, so the UI never flips to a fabricated value.
    public const string PlaceholderSpeed = "↓ — · ↑ —"; // "↓ — · ↑ —"

    public const string PlaceholderLatency = "— ms";                        // "— ms"

    public const string PlaceholderLocationUnavailable = "IP · 不可用"; // "IP · 不可用"

    private const string ProxyOnSuffix = "代理"; // 代理

    private const string ProxyOffSuffix = "直连"; // 直连

    public TopBarNetworkCoordinator(
        Action<string> setNetworkSpeed,
        Action<string> setNetworkLatency,
        Action<string> setIpLocation,
        Action<bool> setIsSystemProxyEnabled,
        ITopBarNetworkStatusClient? client = null)
    {
        _setNetworkSpeed = setNetworkSpeed ?? throw new ArgumentNullException(nameof(setNetworkSpeed));
        _setNetworkLatency = setNetworkLatency ?? throw new ArgumentNullException(nameof(setNetworkLatency));
        _setIpLocation = setIpLocation ?? throw new ArgumentNullException(nameof(setIpLocation));
        _setIsSystemProxyEnabled = setIsSystemProxyEnabled ?? throw new ArgumentNullException(nameof(setIsSystemProxyEnabled));

        // Self-provision the real sampler by default (the escape hatch); tests may inject a fake.
        _client = client ?? new TopBarNetworkStatusClient();

        // Capture the UI dispatcher at construction (the VM is built on the UI thread). If this
        // ever runs without a dispatcher (e.g. a unit test on a worker thread), the updates are
        // invoked inline — the consumer just needs the values, not the thread affinity.
        _dispatcherQueue = DispatcherQueue.GetForCurrentThread();
    }

    // ---- Lifecycle ------------------------------------------------------------------

    /// <summary>
    /// Starts the periodic sampling loop. Idempotent and non-blocking — the loop runs on a
    /// thread-pool task and pushes scalar updates onto the UI dispatcher. Safe to call from
    /// the SessionViewModel ctor alongside the other startup kicks.
    /// </summary>
    public void Start()
    {
        lock (_sync)
        {
            if (_disposed || _loopTask is not null)
            {
                return;
            }

            // Prime the placeholders immediately so the pills read honestly before the first
            // real sample (the XAML already ships these, but a fresh VM with no static text
            // still gets them here).
            _setNetworkSpeed(PlaceholderSpeed);
            _setNetworkLatency(PlaceholderLatency);
            _setIpLocation(PlaceholderLocationUnavailable);
            _setIsSystemProxyEnabled(false);

            _timer = new PeriodicTimer(TickInterval);
            _loopTask = Task.Run(() => RunLoopAsync(_cts.Token));
        }
    }

    private async Task RunLoopAsync(CancellationToken token)
    {
        var timer = _timer;
        if (timer is null)
        {
            return;
        }

        // Sample once up front (do not wait a full 2 s for the first counter/latency/IP).
        await SampleSpeedAsync().ConfigureAwait(false);
        await SampleLatencyAsync(token).ConfigureAwait(false);
        await SampleLocationAsync(token).ConfigureAwait(false);

        try
        {
            while (await timer.WaitForNextTickAsync(token).ConfigureAwait(false))
            {
                _tickIndex++;

                await SampleSpeedAsync().ConfigureAwait(false);

                if (_tickIndex % LatencyEveryTicks == 0)
                {
                    await SampleLatencyAsync(token).ConfigureAwait(false);
                }

                if (_tickIndex % LocationEveryTicks == 0)
                {
                    await SampleLocationAsync(token).ConfigureAwait(false);
                }
            }
        }
        catch (OperationCanceledException)
        {
            // Normal teardown (Dispose cancelled the token / disposed the timer).
        }
        catch (Exception)
        {
            // Defensive: a sampler must never throw (all are result-or-null), but never let the
            // loop crash the process — just stop sampling.
        }
    }

    // ---- Net speed (every tick) -----------------------------------------------------

    private Task SampleSpeedAsync()
    {
        // Synchronous counter read (cheap), but keep the signature async so the loop body reads
        // uniformly. No await needed.
        var sample = _client.SampleInterfaceCounters();
        if (sample is not { } current)
        {
            // Counters unreadable this tick — keep the last shown value (do not blank).
            return Task.CompletedTask;
        }

        var previous = _previousCounters;
        _previousCounters = current;

        if (previous is not { } baseline)
        {
            // First sample primes the baseline; no delta to show yet (keep placeholder).
            return Task.CompletedTask;
        }

        var elapsedSeconds = (current.SampledAt - baseline.SampledAt).TotalSeconds;
        if (elapsedSeconds <= 0)
        {
            return Task.CompletedTask;
        }

        // Cumulative counters only increase; clamp a counter reset/wrap to 0 (Mac does the same
        // with the bytesIn >= previous guard).
        var inboundDelta = current.BytesReceived >= baseline.BytesReceived
            ? current.BytesReceived - baseline.BytesReceived
            : 0;
        var outboundDelta = current.BytesSent >= baseline.BytesSent
            ? current.BytesSent - baseline.BytesSent
            : 0;

        var inboundPerSecond = inboundDelta / elapsedSeconds;
        var outboundPerSecond = outboundDelta / elapsedSeconds;

        var text = $"↓ {TopBarNetworkStatusClient.FormatBytesPerSecond(inboundPerSecond)}" +
                   $" · ↑ {TopBarNetworkStatusClient.FormatBytesPerSecond(outboundPerSecond)}";

        PostToUi(() => _setNetworkSpeed(text));
        return Task.CompletedTask;
    }

    // ---- Latency (every ~15 s) ------------------------------------------------------

    private async Task SampleLatencyAsync(CancellationToken token)
    {
        var milliseconds = await _client.MeasureLatencyMillisecondsAsync(token).ConfigureAwait(false);
        if (token.IsCancellationRequested)
        {
            return;
        }

        // Honest: a successful probe shows "N ms"; a failure shows the "— ms" placeholder.
        var text = milliseconds is { } ms ? $"{ms} ms" : PlaceholderLatency;
        PostToUi(() => _setNetworkLatency(text));
    }

    // ---- IP + proxy (every ~300 s) --------------------------------------------------

    private async Task SampleLocationAsync(CancellationToken token)
    {
        var sample = await _client.ResolveLocationAsync(token).ConfigureAwait(false);
        if (token.IsCancellationRequested)
        {
            return;
        }

        if (sample is { } location && !string.IsNullOrWhiteSpace(location.City))
        {
            // "City · 代理" (proxy on) / "City · 直连" (off), matching the Mac.
            var suffix = location.IsSystemProxyEnabled ? ProxyOnSuffix : ProxyOffSuffix;
            var text = $"{location.City} · {suffix}";
            PostToUi(() =>
            {
                _setIpLocation(text);
                _setIsSystemProxyEnabled(location.IsSystemProxyEnabled);
            });
            return;
        }

        // No city resolved (lookup failed / rate-limited) — show the honest unavailable
        // placeholder, but still report the locally-read proxy state for the icon color.
        var proxyEnabled = sample?.IsSystemProxyEnabled ?? _client.IsSystemProxyEnabled();
        PostToUi(() =>
        {
            _setIpLocation(PlaceholderLocationUnavailable);
            _setIsSystemProxyEnabled(proxyEnabled);
        });
    }

    // ---- UI marshaling --------------------------------------------------------------

    // Push a scalar-property update onto the captured UI dispatcher. If there is no dispatcher
    // (non-UI host / test), invoke inline. The action only ever calls the Set* delegates, which
    // mutate SetField-backed string/bool props — no collections, so no projection/flicker path.
    private void PostToUi(Action action)
    {
        var queue = _dispatcherQueue;
        if (queue is null || queue.HasThreadAccess)
        {
            action();
            return;
        }

        queue.TryEnqueue(() =>
        {
            if (!_disposed)
            {
                action();
            }
        });
    }

    // ---- Teardown -------------------------------------------------------------------

    public void Dispose()
    {
        lock (_sync)
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
        }

        // Cancel the loop, stop the timer, and release it. The loop observes the cancelled
        // token (and WaitForNextTickAsync throws OperationCanceledException, swallowed above).
        try
        {
            _cts.Cancel();
        }
        catch (Exception)
        {
            // Already disposed token source — ignore.
        }

        _timer?.Dispose();
        _timer = null;
        _cts.Dispose();
    }
}
