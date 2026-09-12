using System.Net;
using System.Text;
using Skybridge.WinClient.Services;
using Skybridge.WinClient.ViewModels;

internal static class NetworkTelemetryTests
{
    internal static Task ProxyResolutionAsync()
    {
        var destination = new Uri(TopBarNetworkStatusClient.LocationEndpoint);
        Require(!TopBarNetworkStatusClient.UsesProxy(new ProxyRoute(false, null), destination),
            "Windows may return IsBypassed=false and GetProxy=null for DIRECT; this must not display a proxy.");
        Require(!TopBarNetworkStatusClient.UsesProxy(new ProxyRoute(false, new Uri(destination.AbsoluteUri)), destination),
            "A GetProxy result equal to the destination means DIRECT even when IsBypassed=false.");
        var address = new Uri("http://127.0.0.1:8080");
        Require(TopBarNetworkStatusClient.UsesProxy(new ProxyRoute(false, address), destination),
            "A configured proxy route must display a proxy.");
        var bypassed = new ProxyRoute(true, address);
        Require(!TopBarNetworkStatusClient.UsesProxy(bypassed, destination) && bypassed.Resolutions == 0,
            "An explicit bypass must remain direct without resolving a proxy.");
        return Task.CompletedTask;
    }

    internal static async Task ProbeBoundariesAsync()
    {
        using var handler = new ProbeHandler();
        using var http = new HttpClient(handler);
        var client = new TopBarNetworkStatusClient(http, () => true);
        handler.Response = _ => new(HttpStatusCode.ServiceUnavailable);
        Require(await client.MeasureLatencyMillisecondsAsync() >= 1, "HTTP response must measure elapsed time, even for 503");
        Require(handler.Method == HttpMethod.Head && handler.Uri?.Host == "www.microsoft.com", "Latency must use the declared HEAD endpoint");
        handler.Response = _ => Json("{\"success\":true,\"ip\":\"203.0.113.8\",\"city\":null,\"country_code\":\"US\"}");
        var location = await client.ResolveLocationAsync();
        Require(location.PublicIpAddress == "203.0.113.8" && location.City is null && location.IsSystemProxyEnabled, "An IP without a city is still usable");
        Require(handler.Uri?.Host == "ipwho.is", "IP source must match the displayed source");
        foreach (var bad in new[] { "<html>blocked</html>", "[]", "null", "{\"success\":false}",
            "{\"success\":true,\"ip\":\"not-an-ip\"}", "{\"success\":true,\"ip\":\"127.0.0.1\"}",
            "{\"success\":true,\"ip\":\"203.0.113.8\",\"city\":3}", new string('x', 16 * 1024 + 1) })
        {
            handler.Response = _ => Json(bad);
            await ExpectFailure(client.ResolveLocationAsync, NetworkProbeFailure.InvalidResponse);
        }
        handler.Response = _ => new(HttpStatusCode.TooManyRequests);
        try { await client.ResolveLocationAsync(); throw new InvalidOperationException("Expected HTTP rejection"); }
        catch (NetworkProbeException ex) { Require(ex.StatusCode == HttpStatusCode.TooManyRequests && ex.Failure == NetworkProbeFailure.HttpStatus, "429 must stay explicit"); }
        handler.Response = _ => throw new HttpRequestException("connection failed");
        await ExpectFailure(client.ResolveLocationAsync, NetworkProbeFailure.Unreachable);
        handler.Response = _ => throw new TaskCanceledException("request timeout");
        await ExpectFailure(client.ResolveLocationAsync, NetworkProbeFailure.Timeout);
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        try { await client.ResolveLocationAsync(cancelled.Token); throw new InvalidOperationException("Cancellation was hidden"); }
        catch (OperationCanceledException) { }
        Require(TopBarNetworkCoordinator.RetryInterval(TimeSpan.FromMinutes(5), 1, null) == TimeSpan.FromSeconds(10), "Transient location failure must retry before the success cadence");
        Require(TopBarNetworkCoordinator.RetryInterval(TimeSpan.FromMinutes(5), 6, null) == TimeSpan.FromMinutes(5), "Retry backoff must stay bounded");
        Require(TopBarNetworkCoordinator.RetryInterval(TimeSpan.FromMinutes(5), 1, TimeSpan.FromDays(1)) == TimeSpan.FromDays(1), "Provider Retry-After must be respected");
        Require(TopBarNetworkStatusClient.FormatBytesPerSecond(1000) == "1.0 KB/s", "Decimal speed units");
        try { TopBarNetworkStatusClient.FormatBytesPerSecond(double.NaN); throw new InvalidOperationException("Invalid counter was hidden"); }
        catch (ArgumentOutOfRangeException) { }
    }

    internal static async Task IndependentSamplingAsync()
    {
        var speed = Signal();
        var location = Signal();
        var fake = new BlockingLatencyClient();
        var publications = 0;
        using var monitor = new TopBarNetworkCoordinator(
            value => { Interlocked.Increment(ref publications); if (value.Contains("B/s")) speed.TrySetResult(value); },
            _ => Interlocked.Increment(ref publications),
            value => { Interlocked.Increment(ref publications); if (value.Contains("203.0.113.8")) location.TrySetResult(value); },
            _ => { }, action => action(), key => key, fake, TimeSpan.FromMilliseconds(20));
        monitor.Start();
        monitor.Start();
        await Task.WhenAll(speed.Task, location.Task).WaitAsync(TimeSpan.FromSeconds(5));
        Require(fake.LatencyCalls == 1, "Start must be idempotent and probes must not overlap");
        monitor.Dispose();
        await monitor.Completion.WaitAsync(TimeSpan.FromSeconds(5));
        var count = publications;
        monitor.Start();
        monitor.Dispose();
        Require(publications == count, "Disposed monitor must not publish or restart");
    }

    internal static async Task CounterResetAsync()
    {
        var reset = Signal();
        var recovered = Signal();
        var count = 0;
        var fake = new BlockingLatencyClient { ResetCounters = true };
        using var monitor = new TopBarNetworkCoordinator(value =>
        {
            if (Interlocked.Increment(ref count) > 1 && value == TopBarNetworkCoordinator.PlaceholderSpeed) reset.TrySetResult(value);
            if (value.Contains("B/s")) recovered.TrySetResult(value);
        }, _ => { }, _ => { }, _ => { }, action => action(), key => key, fake, TimeSpan.FromMilliseconds(20));
        monitor.Start();
        await Task.WhenAll(reset.Task, recovered.Task).WaitAsync(TimeSpan.FromSeconds(5));
        monitor.Dispose();
        await monitor.Completion.WaitAsync(TimeSpan.FromSeconds(5));
        using var stopped = new TopBarNetworkCoordinator(_ => { }, _ => { }, _ => { }, _ => { }, action => action(), key => key,
            new FaultedClient(), TimeSpan.FromMilliseconds(20));
        stopped.Start();
        await stopped.Completion.WaitAsync(TimeSpan.FromSeconds(5));
        stopped.Dispose();
    }

    private static TaskCompletionSource<string> Signal() => new(TaskCreationOptions.RunContinuationsAsynchronously);
    private static HttpResponseMessage Json(string body) => new(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
    private static void Require(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
    private static async Task ExpectFailure(Func<CancellationToken, Task<NetworkLocationSample>> probe, NetworkProbeFailure failure)
    {
        try { await probe(CancellationToken.None); throw new InvalidOperationException("Expected probe failure: " + failure); }
        catch (NetworkProbeException ex) { Require(ex.Failure == failure, "Wrong probe failure category"); }
    }

    private sealed class ProbeHandler : HttpMessageHandler
    {
        internal Func<HttpRequestMessage, HttpResponseMessage> Response { get; set; } = _ => throw new InvalidOperationException("No test response configured");
        internal HttpMethod? Method { get; private set; }
        internal Uri? Uri { get; private set; }
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Method = request.Method;
            Uri = request.RequestUri;
            return Task.FromResult(Response(request));
        }
    }

    private sealed class ProxyRoute(bool bypassed, Uri? endpoint) : IWebProxy
    {
        public ICredentials? Credentials { get; set; }
        internal int Resolutions { get; private set; }
        public bool IsBypassed(Uri destination) => bypassed;
        public Uri? GetProxy(Uri destination)
        {
            Resolutions++;
            return endpoint;
        }
    }

    private sealed class BlockingLatencyClient : ITopBarNetworkStatusClient
    {
        private int _samples;
        internal int LatencyCalls;
        internal bool ResetCounters;
        public NetworkCounterSample SampleInterfaceCounters()
        {
            var index = Interlocked.Increment(ref _samples);
            return new((ulong)(ResetCounters && index == 1 ? 50000 : index * 100), (ulong)index * 50,
                DateTimeOffset.UnixEpoch.AddSeconds(index));
        }
        public async Task<int> MeasureLatencyMillisecondsAsync(CancellationToken cancellationToken = default)
        {
            Interlocked.Increment(ref LatencyCalls);
            await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
            throw new InvalidOperationException("Infinite delay unexpectedly completed");
        }
        public Task<NetworkLocationSample> ResolveLocationAsync(CancellationToken cancellationToken = default) =>
            Task.FromResult(new NetworkLocationSample("203.0.113.8", null, "US", false));
        public bool IsSystemProxyEnabled() => false;
    }

    private sealed class FaultedClient : ITopBarNetworkStatusClient
    {
        public NetworkCounterSample SampleInterfaceCounters() => throw new InvalidOperationException("counter fault");
        public Task<int> MeasureLatencyMillisecondsAsync(CancellationToken cancellationToken = default) => throw new InvalidOperationException("latency fault");
        public Task<NetworkLocationSample> ResolveLocationAsync(CancellationToken cancellationToken = default) => throw new InvalidOperationException("location fault");
        public bool IsSystemProxyEnabled() => false;
    }
}
