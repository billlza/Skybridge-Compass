using System;
using System.Collections.Generic;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

public interface IDiscoveryBrowserClient
{
    DiscoveryBrowserInputPolicy BuildInputPolicy();

    DiscoveryBrowserPeerCandidate BuildPeerCandidate(DiscoveredPeer peer);

    string BuildPendingStatus(DiscoveryBrowserAction action);

    Task<DiscoveryBrowserSnapshot> BuildReadOnlySnapshotAsync(DiscoveryBrowserRequest request);
}

public interface IWindowsDnsSdBrowseClient
{
    Task<WindowsDnsSdBrowseSnapshot> BrowseAsync(WindowsDnsSdBrowseRequest request);
}

public sealed class WindowsDiscoveryBrowserClient : IDiscoveryBrowserClient
{
    private static readonly string[] DefaultQueryOrder = { "_skybridge._udp", "_skybridge._tcp" };
    private const int ExtendedSearchDurationSeconds = 15;
    private readonly IDiscoveryClient _discoveryClient;
    private readonly IWindowsDnsSdBrowseClient _dnsSdBrowseClient;

    public static DiscoveryBrowserInputPolicy DefaultInputPolicy { get; } =
        new(ExtendedSearchDurationSeconds, DefaultQueryOrder);

    public WindowsDiscoveryBrowserClient(IDiscoveryClient discoveryClient)
        : this(discoveryClient, new PendingWindowsDnsSdBrowseClient())
    {
    }

    public WindowsDiscoveryBrowserClient(
        IDiscoveryClient discoveryClient,
        IWindowsDnsSdBrowseClient dnsSdBrowseClient)
    {
        _discoveryClient = discoveryClient ?? throw new ArgumentNullException(nameof(discoveryClient));
        _dnsSdBrowseClient = dnsSdBrowseClient ?? throw new ArgumentNullException(nameof(dnsSdBrowseClient));
    }

    public DiscoveryBrowserInputPolicy BuildInputPolicy() => DefaultInputPolicy;

    public DiscoveryBrowserPeerCandidate BuildPeerCandidate(DiscoveredPeer peer) =>
        BuildDefaultPeerCandidate(peer);

    public string BuildPendingStatus(DiscoveryBrowserAction action) =>
        BuildDefaultPendingStatus(action);

    public static string BuildDefaultPendingStatus(DiscoveryBrowserAction action) =>
        action == DiscoveryBrowserAction.Stop ? "Stopping..." : "Scanning...";

    public static DiscoveryBrowserPeerCandidate BuildDefaultPeerCandidate(DiscoveredPeer peer)
    {
        ArgumentNullException.ThrowIfNull(peer);

        return new DiscoveryBrowserPeerCandidate(
            peer,
            FormatCapabilities(peer.Capabilities),
            "pubKeyFP fingerprint only; pairing must provide the peer public key.");
    }

    public async Task<DiscoveryBrowserSnapshot> BuildReadOnlySnapshotAsync(DiscoveryBrowserRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        var facts = new List<DiscoveryBrowserFact>
        {
            new("Backend", "Win32 DNS-SD boundary", "Use windns.h DnsServiceBrowse/DnsServiceRegister for the live adapter; WinRT DnssdServiceWatcher stays avoided because Microsoft marks it unsupported."),
            new("Query order", string.Join(", ", DefaultQueryOrder), "Preserves mac/iOS _skybridge._udp primary and _skybridge._tcp fallback service names."),
            new("Action", request.Action.ToString(), request.Action == DiscoveryBrowserAction.Stop ? "Stop only changes browser state; cached peers remain visible." : "Read-only snapshot; no network connection attempt is started."),
            new("Compatibility mode", request.CompatibilityMode ? "enabled" : "disabled", "Extended provider sweep is a browser hint only; it does not weaken pairing or transport policy.")
        };

        if (request.Action == DiscoveryBrowserAction.ExtendedSearch)
        {
            facts.Add(new DiscoveryBrowserFact(
                "Extended search",
                $"{request.ExtendedSearchSeconds}s",
                "Matches the mac compatibility/extended-search control shape while native providers are pending."));
        }

        if (!string.IsNullOrWhiteSpace(request.SearchText))
        {
            facts.Add(new DiscoveryBrowserFact(
                "Search",
                request.SearchText.Trim(),
                "Filters the Core-validated candidate list by name, device ID, platform, service, or capabilities."));
        }

        if (request.Action == DiscoveryBrowserAction.Stop)
        {
            return new DiscoveryBrowserSnapshot(DateTimeOffset.UtcNow, false, Array.Empty<DiscoveryBrowserPeerCandidate>(), facts);
        }

        var records = new List<WindowsDnsSdResolvedTxtRecord>();
        if (string.IsNullOrWhiteSpace(request.TxtRecord))
        {
            var browseSnapshot = await _dnsSdBrowseClient.BrowseAsync(
                new WindowsDnsSdBrowseRequest(
                    DefaultQueryOrder,
                    request.Action,
                    request.CompatibilityMode,
                    request.ExtendedSearchSeconds));
            facts.AddRange(browseSnapshot.Facts);
            records.AddRange(browseSnapshot.Records);
        }
        else
        {
            var service = string.IsNullOrWhiteSpace(request.Service)
                ? DefaultQueryOrder[0]
                : request.Service.Trim();
            records.Add(new WindowsDnsSdResolvedTxtRecord(
                service,
                request.TxtRecord,
                "manual TXT input",
                "",
                0));
        }

        var peers = new List<DiscoveryBrowserPeerCandidate>();
        foreach (var record in records)
        {
            var peer = await _discoveryClient.ParseAdvertisementAsync(record.Service, record.TxtRecord);
            if (MatchesSearch(peer, request.SearchText))
            {
                peers.Add(BuildPeerCandidate(peer));
            }

            facts.Add(new DiscoveryBrowserFact(
                "Core TXT parse",
                peer.DeviceId,
                $"Candidate came from {FormatRecordSource(record)}; pubKeyFP remains fingerprint-only until pairing material is validated."));
        }

        return new DiscoveryBrowserSnapshot(DateTimeOffset.UtcNow, true, peers, facts);
    }

    private static bool MatchesSearch(DiscoveredPeer peer, string searchText)
    {
        if (string.IsNullOrWhiteSpace(searchText))
        {
            return true;
        }

        var needle = searchText.Trim();
        return Contains(peer.DeviceId, needle)
            || Contains(peer.DisplayName, needle)
            || Contains(peer.PlatformLabel, needle)
            || Contains(peer.ServiceKind.ToString(), needle)
            || Contains(peer.CapabilityTokens, needle);
    }

    private static bool Contains(string value, string needle) =>
        value.Contains(needle, StringComparison.OrdinalIgnoreCase);

    private static string FormatRecordSource(WindowsDnsSdResolvedTxtRecord record)
    {
        if (string.IsNullOrWhiteSpace(record.InstanceName))
        {
            return record.Service;
        }

        return string.IsNullOrWhiteSpace(record.HostName)
            ? $"{record.InstanceName} via {record.Service}"
            : $"{record.InstanceName} at {record.HostName}:{record.Port} via {record.Service}";
    }

    private static string FormatCapabilities(PeerCapabilities capabilities)
    {
        var values = new List<string>();
        if (capabilities.SupportsAppleNative)
        {
            values.Add("apple-native");
        }

        if (capabilities.SupportsMsQuic)
        {
            values.Add("msquic");
        }

        if (capabilities.SupportsSkyBridgeIceMsQuic)
        {
            values.Add("ice-msquic");
        }

        if (capabilities.SupportsWebRtcDataChannel)
        {
            values.Add("webrtc");
        }

        if (capabilities.SupportsTcpFallback)
        {
            values.Add("tcp");
        }

        if (capabilities.SupportsRelay)
        {
            values.Add("relay");
        }

        return values.Count == 0 ? "none" : string.Join(", ", values);
    }
}

public sealed class PendingWindowsDnsSdBrowseClient : IWindowsDnsSdBrowseClient
{
    public Task<WindowsDnsSdBrowseSnapshot> BrowseAsync(WindowsDnsSdBrowseRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);

        IReadOnlyList<DiscoveryBrowserFact> facts =
        [
            new(
                "Native browse",
                "pending",
                "No TXT record supplied; live DnsServiceBrowse/DnsServiceResolve resolution must feed CoreDiscoveryClient once wired.")
        ];

        return Task.FromResult(new WindowsDnsSdBrowseSnapshot(Array.Empty<WindowsDnsSdResolvedTxtRecord>(), facts));
    }
}

public sealed record DiscoveryBrowserRequest(
    DiscoveryBrowserAction Action,
    string Service,
    string TxtRecord,
    string SearchText,
    bool CompatibilityMode,
    int ExtendedSearchSeconds);

public enum DiscoveryBrowserAction
{
    Start,
    Stop,
    Refresh,
    ExtendedSearch
}

public sealed record DiscoveryBrowserSnapshot(
    DateTimeOffset CapturedAt,
    bool IsScanning,
    IReadOnlyList<DiscoveryBrowserPeerCandidate> Peers,
    IReadOnlyList<DiscoveryBrowserFact> Facts);

public sealed record DiscoveryBrowserInputPolicy(
    int ExtendedSearchSeconds,
    IReadOnlyList<string> ServiceQueryOrder);

public sealed record DiscoveryBrowserPeerCandidate(
    DiscoveredPeer Peer,
    string CapabilitiesSummary,
    string TrustSummary);

public sealed record DiscoveryBrowserFact(
    string Label,
    string Value,
    string Detail);

public sealed record WindowsDnsSdBrowseRequest(
    IReadOnlyList<string> QueryOrder,
    DiscoveryBrowserAction Action,
    bool CompatibilityMode,
    int ExtendedSearchSeconds);

public sealed record WindowsDnsSdBrowseSnapshot(
    IReadOnlyList<WindowsDnsSdResolvedTxtRecord> Records,
    IReadOnlyList<DiscoveryBrowserFact> Facts);

public sealed record WindowsDnsSdResolvedTxtRecord(
    string Service,
    string TxtRecord,
    string InstanceName,
    string HostName,
    ushort Port);
