using System.Diagnostics;
using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Net.NetworkInformation;
using System.Text.Json;

namespace Skybridge.WinClient.Services;

public interface ITopBarNetworkStatusClient
{
    NetworkCounterSample SampleInterfaceCounters();
    Task<int> MeasureLatencyMillisecondsAsync(CancellationToken cancellationToken = default);
    Task<NetworkLocationSample> ResolveLocationAsync(CancellationToken cancellationToken = default);
    bool IsSystemProxyEnabled();
}

public readonly record struct NetworkCounterSample(ulong BytesReceived, ulong BytesSent, DateTimeOffset SampledAt);
public readonly record struct NetworkLocationSample(string PublicIpAddress, string? City, string? CountryCode, bool IsSystemProxyEnabled);

public enum NetworkProbeFailure { Timeout, Unreachable, HttpStatus, InvalidResponse, CountersUnavailable }

public sealed class NetworkProbeException : Exception
{
    public NetworkProbeException(NetworkProbeFailure failure, string message, Exception? innerException = null,
        HttpStatusCode? statusCode = null, TimeSpan? retryAfter = null) : base(message, innerException)
    {
        Failure = failure;
        StatusCode = statusCode;
        RetryAfter = retryAfter;
    }

    public NetworkProbeFailure Failure { get; }
    public HttpStatusCode? StatusCode { get; }
    public TimeSpan? RetryAfter { get; }
}

// Network I/O and counter reads stay here; the coordinator owns cadence and UI publication.
public sealed class TopBarNetworkStatusClient : ITopBarNetworkStatusClient
{
    public const string LatencyEndpoint = "https://www.microsoft.com/";
    public const string LocationEndpoint = "https://ipwho.is/?fields=success,ip,city,country_code";
    private const int MaximumLocationBytes = 16 * 1024;
    private static readonly HttpClient SharedHttpClient = CreateHttpClient();
    private readonly HttpClient _httpClient;
    private readonly Func<bool> _readProxy;

    public TopBarNetworkStatusClient() : this(SharedHttpClient, ReadEffectiveProxy) { }

    // The caller owns an injected client; the production client is shared for the process lifetime.
    internal TopBarNetworkStatusClient(HttpClient httpClient, Func<bool> readProxy)
    {
        _httpClient = httpClient ?? throw new ArgumentNullException(nameof(httpClient));
        _readProxy = readProxy ?? throw new ArgumentNullException(nameof(readProxy));
    }

    private static HttpClient CreateHttpClient() => new(new SocketsHttpHandler
    {
        PooledConnectionLifetime = TimeSpan.FromMinutes(2),
        ConnectTimeout = TimeSpan.FromSeconds(5),
        UseCookies = false
    }) { Timeout = Timeout.InfiniteTimeSpan };

    public NetworkCounterSample SampleInterfaceCounters()
    {
        try
        {
            ulong received = 0, sent = 0;
            var count = 0;
            foreach (var adapter in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (adapter.OperationalStatus != OperationalStatus.Up ||
                    adapter.NetworkInterfaceType is NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel)
                    continue;
                var statistics = adapter.GetIPStatistics();
                if (statistics.BytesReceived < 0 || statistics.BytesSent < 0)
                    throw new NetworkProbeException(NetworkProbeFailure.CountersUnavailable, "Interface counters are invalid.");
                received = checked(received + (ulong)statistics.BytesReceived);
                sent = checked(sent + (ulong)statistics.BytesSent);
                count++;
            }
            if (count == 0)
                throw new NetworkProbeException(NetworkProbeFailure.CountersUnavailable, "No active network interface.");
            return new(received, sent, DateTimeOffset.UtcNow);
        }
        catch (NetworkInformationException ex)
        {
            throw new NetworkProbeException(NetworkProbeFailure.CountersUnavailable, "Network counters cannot be read.", ex);
        }
    }

    public async Task<int> MeasureLatencyMillisecondsAsync(CancellationToken cancellationToken = default)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(5));
        try
        {
            using var request = CreateRequest(HttpMethod.Head, LatencyEndpoint);
            var stopwatch = Stopwatch.StartNew();
            using var response = await _httpClient.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false);
            // Any HTTP response proves a round trip; this measures HTTPS response time, not ICMP RTT.
            return Math.Max(1, checked((int)stopwatch.Elapsed.TotalMilliseconds));
        }
        catch (OperationCanceledException ex) when (!cancellationToken.IsCancellationRequested)
        {
            throw new NetworkProbeException(NetworkProbeFailure.Timeout, "The latency probe timed out.", ex);
        }
        catch (HttpRequestException ex)
        {
            throw new NetworkProbeException(NetworkProbeFailure.Unreachable, "The latency endpoint is unreachable.", ex);
        }
    }

    public async Task<NetworkLocationSample> ResolveLocationAsync(CancellationToken cancellationToken = default)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(8));
        try
        {
            using var request = CreateRequest(HttpMethod.Get, LocationEndpoint);
            using var response = await _httpClient.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
            {
                var retryAfter = response.Headers.RetryAfter?.Delta
                    ?? (response.Headers.RetryAfter?.Date - DateTimeOffset.UtcNow);
                if (response.StatusCode == HttpStatusCode.TooManyRequests && (retryAfter is null || retryAfter <= TimeSpan.Zero))
                    retryAfter = TimeSpan.FromDays(1);
                throw new NetworkProbeException(NetworkProbeFailure.HttpStatus, "IP lookup was rejected by the service.",
                    statusCode: response.StatusCode, retryAfter: retryAfter);
            }
            if (response.Content.Headers.ContentLength > MaximumLocationBytes)
                throw InvalidResponse();
            await using var stream = await response.Content.ReadAsStreamAsync(timeout.Token).ConfigureAwait(false);
            var buffer = new byte[MaximumLocationBytes + 1];
            var bytes = 0;
            while (bytes < buffer.Length)
            {
                var read = await stream.ReadAsync(buffer.AsMemory(bytes), timeout.Token).ConfigureAwait(false);
                if (read == 0) break;
                bytes += read;
            }
            if (bytes > MaximumLocationBytes) throw InvalidResponse();
            using var document = JsonDocument.Parse(buffer.AsMemory(0, bytes));
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object ||
                !root.TryGetProperty("success", out var success) || success.ValueKind != JsonValueKind.True)
                throw InvalidResponse();
            var ipText = ReadString(root, "ip");
            if (!IPAddress.TryParse(ipText, out var ip) || IPAddress.IsLoopback(ip) || ip.Equals(IPAddress.Any) || ip.Equals(IPAddress.IPv6Any))
                throw InvalidResponse();
            return new(ip.ToString(), ReadString(root, "city"), ReadString(root, "country_code"), IsSystemProxyEnabled());
        }
        catch (OperationCanceledException ex) when (!cancellationToken.IsCancellationRequested)
        {
            throw new NetworkProbeException(NetworkProbeFailure.Timeout, "The IP lookup timed out.", ex);
        }
        catch (HttpRequestException ex)
        {
            throw new NetworkProbeException(NetworkProbeFailure.Unreachable, "The IP service is unreachable.", ex);
        }
        catch (IOException ex)
        {
            throw new NetworkProbeException(NetworkProbeFailure.Unreachable, "The IP response stream was interrupted.", ex);
        }
        catch (JsonException ex)
        {
            throw new NetworkProbeException(NetworkProbeFailure.InvalidResponse, "The IP service returned invalid JSON.", ex);
        }
    }

    public bool IsSystemProxyEnabled() => _readProxy();
    private static bool ReadEffectiveProxy() => UsesProxy(HttpClient.DefaultProxy, new Uri(LocationEndpoint));

    internal static bool UsesProxy(IWebProxy proxy, Uri destination)
    {
        ArgumentNullException.ThrowIfNull(proxy);
        ArgumentNullException.ThrowIfNull(destination);
        if (proxy.IsBypassed(destination)) return false;
        // Windows' HttpWindowsProxy always returns false from IsBypassed. Its
        // GetProxy result is authoritative: null or the destination means DIRECT.
        var endpoint = proxy.GetProxy(destination);
        return endpoint is not null && endpoint != destination;
    }

    private static HttpRequestMessage CreateRequest(HttpMethod method, string endpoint)
    {
        var request = new HttpRequestMessage(method, endpoint);
        request.Headers.UserAgent.ParseAdd("SkyBridgeCompass/1.0");
        request.Headers.CacheControl = new CacheControlHeaderValue { NoCache = true, NoStore = true };
        return request;
    }

    private static NetworkProbeException InvalidResponse() =>
        new(NetworkProbeFailure.InvalidResponse, "The IP service returned an invalid location response.");

    private static string? ReadString(JsonElement root, string property)
    {
        if (!root.TryGetProperty(property, out var value) || value.ValueKind == JsonValueKind.Null) return null;
        if (value.ValueKind != JsonValueKind.String) throw InvalidResponse();
        var text = value.GetString()?.Trim();
        if (text is { Length: > 128 } || (text is not null && text.Any(char.IsControl))) throw InvalidResponse();
        return string.IsNullOrEmpty(text) ? null : text;
    }

    public static string FormatBytesPerSecond(double bytesPerSecond)
    {
        if (!double.IsFinite(bytesPerSecond) || bytesPerSecond < 0)
            throw new ArgumentOutOfRangeException(nameof(bytesPerSecond));
        var (divisor, unit) = bytesPerSecond switch
        {
            >= 1_000_000_000 => (1_000_000_000d, "GB/s"),
            >= 1_000_000 => (1_000_000d, "MB/s"),
            >= 1_000 => (1_000d, "KB/s"),
            _ => (1d, "B/s")
        };
        return (bytesPerSecond / divisor).ToString(divisor == 1 ? "0" : "0.0", CultureInfo.InvariantCulture) + " " + unit;
    }
}
