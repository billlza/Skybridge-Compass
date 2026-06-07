using System;
using System.Collections.Generic;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

public interface IDiscoveryBrowserClient
{
    DiscoveryBrowserInputPolicy BuildInputPolicy();

    Task<DiscoveryBrowserSnapshot> BuildReadOnlySnapshotAsync(DiscoveryBrowserRequest request);
}

public sealed class WindowsDiscoveryBrowserClient : IDiscoveryBrowserClient
{
    private static readonly string[] DefaultQueryOrder = { "_skybridge._udp", "_skybridge._tcp" };
    private const int ExtendedSearchDurationSeconds = 15;
    private readonly IDiscoveryClient _discoveryClient;

    public static DiscoveryBrowserInputPolicy DefaultInputPolicy { get; } =
        new(ExtendedSearchDurationSeconds, DefaultQueryOrder);

    public WindowsDiscoveryBrowserClient(IDiscoveryClient discoveryClient)
    {
        _discoveryClient = discoveryClient ?? throw new ArgumentNullException(nameof(discoveryClient));
    }

    public DiscoveryBrowserInputPolicy BuildInputPolicy() => DefaultInputPolicy;

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
            return new DiscoveryBrowserSnapshot(DateTimeOffset.UtcNow, false, Array.Empty<DiscoveredPeer>(), facts);
        }

        var peers = new List<DiscoveredPeer>();
        if (string.IsNullOrWhiteSpace(request.TxtRecord))
        {
            facts.Add(new DiscoveryBrowserFact(
                "Native browse",
                "pending",
                "No TXT record supplied; live DnsServiceBrowse resolution must feed CoreDiscoveryClient once wired."));
            return new DiscoveryBrowserSnapshot(DateTimeOffset.UtcNow, true, peers, facts);
        }

        var service = string.IsNullOrWhiteSpace(request.Service)
            ? DefaultQueryOrder[0]
            : request.Service.Trim();
        var peer = await _discoveryClient.ParseAdvertisementAsync(service, request.TxtRecord);
        if (MatchesSearch(peer, request.SearchText))
        {
            peers.Add(peer);
        }

        facts.Add(new DiscoveryBrowserFact(
            "Core TXT parse",
            peer.DeviceId,
            "Candidate came from CoreDiscoveryClient; pubKeyFP remains fingerprint-only until pairing material is validated."));

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
    IReadOnlyList<DiscoveredPeer> Peers,
    IReadOnlyList<DiscoveryBrowserFact> Facts);

public sealed record DiscoveryBrowserInputPolicy(
    int ExtendedSearchSeconds,
    IReadOnlyList<string> ServiceQueryOrder);

public sealed record DiscoveryBrowserFact(
    string Label,
    string Value,
    string Detail);
