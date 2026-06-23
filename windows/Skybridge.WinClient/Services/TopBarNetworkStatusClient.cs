using System;
using System.Diagnostics;
using System.Globalization;
using System.Net.Http;
using System.Net.NetworkInformation;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32;

namespace Skybridge.WinClient.Services;

// =====================================================================================
//  TopBarNetworkStatusClient — Windows port of the macOS
//  Sources/SkyBridgeCore/Network/TopBarNetworkStatusService.swift sampler surface.
//
//  It provides the three REAL top-bar network probes the Mac top bar shows, using only
//  in-framework Windows/.NET APIs (no third-party deps):
//
//    NET SPEED  : System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces()
//                 → sum BytesReceived/BytesSent (GetIPv4Statistics/GetIPStatistics) across
//                 UP, non-loopback, non-tunnel interfaces. The CLIENT only reads the raw
//                 cumulative counters; the COORDINATOR keeps the baseline and computes the
//                 delta ÷ elapsed seconds (exactly the Mac's previousCounters/elapsed math,
//                 ported off the getifaddrs/if_data ifi_ibytes/ifi_obytes sum). Formatting
//                 is base-1000 (GB/s ≥ 1e9, MB/s ≥ 1e6, KB/s ≥ 1e3, else B/s), mirroring the
//                 Mac formatBytesPerSecond, e.g. "↓ 24.0 KB/s · ↑ 6.1 KB/s".
//
//    LATENCY    : a static cached HttpClient HEAD request (mirrors WeatherClient's single
//                 cached HttpClient pattern) to the same fast endpoint the Mac uses
//                 (https://skybridge-compass.vercel.app); elapsed measured with Stopwatch.
//                 On any failure → null, which the coordinator renders as the honest "— ms"
//                 placeholder (never a fabricated RTT).
//
//    IP + PROXY : HTTP GET https://ipapi.co/json/ (the exact Mac locationURL) → parse
//                 {ip, city, country_code}; the Windows system proxy is detected by reading
//                 HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ProxyEnable
//                 via Microsoft.Win32.Registry (in-framework; 1 = proxy on). The coordinator
//                 formats "City · 代理" / "City · 直连" matching the Mac. On failure →
//                 honest "IP · 不可用".
//
//  Every method is try/catch → result-or-null; NOTHING throws into the UI. The client is a
//  pure data seam (no timers, no observable surface) — the TopBarNetworkCoordinator owns the
//  periodic loop, the baseline state, and the formatting, exactly the way the Mac service's
//  start()/sampleSpeed()/refreshLatency()/refreshLocation() loop does.
// =====================================================================================

public interface ITopBarNetworkStatusClient
{
    /// <summary>
    /// Snapshot of the cumulative inbound/outbound byte counters summed across all UP,
    /// non-loopback, non-tunnel interfaces, captured at <see cref="NetworkCounterSample.SampledAt"/>.
    /// Returns null if the counters cannot be read (the coordinator then keeps the last
    /// baseline and shows the loading placeholder).
    /// </summary>
    NetworkCounterSample? SampleInterfaceCounters();

    /// <summary>
    /// Measures round-trip latency to the fast endpoint via a HEAD request. Returns the
    /// elapsed milliseconds (≥ 1), or null on any network/timeout failure.
    /// </summary>
    Task<int?> MeasureLatencyMillisecondsAsync(CancellationToken cancellationToken = default);

    /// <summary>
    /// Fetches the public IP / city / country-code from ipapi.co and reads the Windows
    /// system-proxy flag. Returns null on failure (coordinator shows "IP · 不可用").
    /// </summary>
    Task<NetworkLocationSample?> ResolveLocationAsync(CancellationToken cancellationToken = default);

    /// <summary>
    /// Reads the Windows system-proxy enabled flag in isolation (HKCU ProxyEnable == 1).
    /// Always returns a bool (false on any failure) — used for the icon color even when the
    /// IP lookup itself fails.
    /// </summary>
    bool IsSystemProxyEnabled();
}

// Cumulative byte counters at a point in time (the coordinator differences two of these).
public readonly record struct NetworkCounterSample(ulong BytesReceived, ulong BytesSent, DateTimeOffset SampledAt);

// Resolved public-network location + the system-proxy state at resolution time.
public readonly record struct NetworkLocationSample(
    string? PublicIpAddress,
    string? City,
    string? CountryCode,
    bool IsSystemProxyEnabled);

public sealed class TopBarNetworkStatusClient : ITopBarNetworkStatusClient
{
    // One cached client for the whole app (idiomatic; mirrors WeatherClient.HttpClient).
    // 6 s ceiling guards the per-request timeouts so a hung socket can't wedge the loop.
    private static readonly HttpClient HttpClient = CreateHttpClient();

    private static readonly TimeSpan LatencyTimeout = TimeSpan.FromSeconds(5);

    private static readonly TimeSpan LocationTimeout = TimeSpan.FromSeconds(6);

    // Same endpoints as the Mac TopBarNetworkStatusService (latencyURL / locationURL).
    private const string LatencyEndpoint = "https://www.gstatic.com/generate_204";

    private const string LocationEndpoint = "https://ipwho.is/";

    private static HttpClient CreateHttpClient()
    {
        var client = new HttpClient
        {
            Timeout = TimeSpan.FromSeconds(6)
        };
        // ipapi.co rejects empty/unknown user-agents with 403; a curl-style agent is served
        // the JSON body (same trick WeatherClient uses for wttr.in).
        client.DefaultRequestHeaders.UserAgent.ParseAdd("curl/8.4.0");
        return client;
    }

    // ---- Net speed: cumulative interface byte counters --------------------------------

    public NetworkCounterSample? SampleInterfaceCounters()
    {
        try
        {
            ulong bytesIn = 0;
            ulong bytesOut = 0;

            foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
            {
                // Mirror the Mac filter: UP, non-loopback, non-tunnel. (The Mac walks
                // getifaddrs with IFF_UP set and IFF_LOOPBACK clear; we additionally skip
                // Tunnel adapters so a VPN's virtual NIC doesn't double-count the physical
                // traffic it encapsulates.)
                if (nic.OperationalStatus != OperationalStatus.Up)
                {
                    continue;
                }

                if (nic.NetworkInterfaceType is NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel)
                {
                    continue;
                }

                // Prefer the IPv4 statistics (BytesReceived/BytesSent are cumulative octet
                // counts, matching ifi_ibytes/ifi_obytes); fall back to the combined IP
                // statistics on adapters that don't expose the IPv4-specific view.
                // GetIPv4Statistics() returns IPv4InterfaceStatistics and GetIPStatistics()
                // returns IPInterfaceStatistics — two unrelated types (no common base), so read
                // the cumulative octet counts in each branch rather than sharing a variable.
                long received;
                long sent;
                try
                {
                    var s = nic.GetIPv4Statistics();
                    received = s.BytesReceived;
                    sent = s.BytesSent;
                }
                catch (NetworkInformationException)
                {
                    var s = nic.GetIPStatistics();
                    received = s.BytesReceived;
                    sent = s.BytesSent;
                }

                // The .NET counters are signed longs; clamp negatives (counter glitch) to 0.
                bytesIn += received > 0 ? (ulong)received : 0;
                bytesOut += sent > 0 ? (ulong)sent : 0;
            }

            return new NetworkCounterSample(bytesIn, bytesOut, DateTimeOffset.UtcNow);
        }
        catch (Exception)
        {
            // No adapters readable / WMI hiccup — the coordinator keeps its last baseline.
            return null;
        }
    }

    // ---- Latency: cached-HttpClient HEAD + Stopwatch ----------------------------------

    public async Task<int?> MeasureLatencyMillisecondsAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            cts.CancelAfter(LatencyTimeout);

            // GET (not HEAD): the msftconnecttest endpoint returns 405 to HEAD, so use a GET of
            // the tiny (~14-byte) connecttest.txt. With ResponseHeadersRead we still time only the
            // round trip to the first response, never the (trivial) body read.
            using var request = new HttpRequestMessage(HttpMethod.Get, LatencyEndpoint);
            var stopwatch = Stopwatch.StartNew();
            using var response = await HttpClient
                .SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cts.Token)
                .ConfigureAwait(false);

            stopwatch.Stop();

            // Accept any HTTP response (2xx–5xx) as a successful round trip — we are timing
            // reachability, not asserting a 200 (the Mac accepts 200..<600 likewise).
            return Math.Max(1, (int)stopwatch.Elapsed.TotalMilliseconds);
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or OperationCanceledException)
        {
            // Network/timeout — honest null → "— ms".
            return null;
        }
        catch (Exception)
        {
            return null;
        }
    }

    // ---- IP + proxy: ipapi.co GET + HKCU ProxyEnable ----------------------------------

    public async Task<NetworkLocationSample?> ResolveLocationAsync(CancellationToken cancellationToken = default)
    {
        // Always resolve the proxy state (it's local + cheap) so the icon color is correct
        // even when the IP lookup itself fails below.
        var proxyEnabled = IsSystemProxyEnabled();

        try
        {
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            cts.CancelAfter(LocationTimeout);

            using var response = await HttpClient
                .GetAsync(LocationEndpoint, HttpCompletionOption.ResponseHeadersRead, cts.Token)
                .ConfigureAwait(false);

            if (!response.IsSuccessStatusCode)
            {
                return null;
            }

            await using var stream = await response.Content
                .ReadAsStreamAsync(cts.Token)
                .ConfigureAwait(false);
            using var document = await JsonDocument
                .ParseAsync(stream, cancellationToken: cts.Token)
                .ConfigureAwait(false);

            var root = document.RootElement;
            var ip = ReadString(root, "ip");
            if (string.IsNullOrWhiteSpace(ip))
            {
                // No usable IP → treat as failure (coordinator shows "IP · 不可用").
                return null;
            }

            return new NetworkLocationSample(
                ip,
                ReadString(root, "city"),
                ReadString(root, "country_code"),
                proxyEnabled);
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or JsonException or OperationCanceledException)
        {
            return null;
        }
        catch (Exception)
        {
            return null;
        }
    }

    public bool IsSystemProxyEnabled()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Internet Settings");
            if (key is null)
            {
                return false;
            }

            // ProxyEnable is a DWORD: 1 = a manual proxy is configured + on. (This mirrors
            // the Mac's SCDynamicStoreCopyProxies HTTP/HTTPS/SOCKS enable check — both report
            // "is the OS routing through a configured proxy".)
            var value = key.GetValue("ProxyEnable");
            return value is int enabled && enabled != 0;
        }
        catch (Exception)
        {
            // Registry hive unavailable / access denied — assume direct (false), never throw.
            return false;
        }
    }

    private static string? ReadString(JsonElement root, string property)
    {
        if (root.TryGetProperty(property, out var element) && element.ValueKind == JsonValueKind.String)
        {
            var raw = element.GetString();
            return string.IsNullOrWhiteSpace(raw) ? null : raw.Trim();
        }

        return null;
    }

    // ---- Base-1000 byte/sec formatting (mirrors the Mac formatBytesPerSecond) ---------

    // Exposed as a static helper so the coordinator formats with the exact same thresholds
    // (and the unit tests, if any, can assert it directly). Base 1000: GB/s ≥ 1e9, MB/s ≥ 1e6,
    // KB/s ≥ 1e3, else B/s. One decimal place for the scaled units, integer for B/s.
    public static string FormatBytesPerSecond(double bytesPerSecond)
    {
        if (double.IsNaN(bytesPerSecond) || bytesPerSecond < 0)
        {
            bytesPerSecond = 0;
        }

        if (bytesPerSecond >= 1_000_000_000d)
        {
            return string.Format(CultureInfo.InvariantCulture, "{0:0.0} GB/s", bytesPerSecond / 1_000_000_000d);
        }

        if (bytesPerSecond >= 1_000_000d)
        {
            return string.Format(CultureInfo.InvariantCulture, "{0:0.0} MB/s", bytesPerSecond / 1_000_000d);
        }

        if (bytesPerSecond >= 1_000d)
        {
            return string.Format(CultureInfo.InvariantCulture, "{0:0.0} KB/s", bytesPerSecond / 1_000d);
        }

        return string.Format(CultureInfo.InvariantCulture, "{0:0} B/s", bytesPerSecond);
    }
}
