using System;
using System.Collections.Generic;
using System.Text;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

public interface IDiscoveryBrowserClient
{
    DiscoveryBrowserInputPolicy BuildInputPolicy();

    DiscoveryBrowserPeerCandidate BuildPeerCandidate(DiscoveredPeer peer);

    string BuildPendingStatus(DiscoveryBrowserAction action);

    Task<DiscoveryBrowserSnapshot> BuildReadOnlySnapshotAsync(DiscoveryBrowserRequest request);

    bool TryPublish(
        DiscoveryBrowserSnapshot snapshot,
        Action<DiscoveryBrowserSnapshot> publish);
}

public interface IWindowsDnsSdBrowseClient
{
    Task<WindowsDnsSdBrowseSnapshot> BrowseAsync(
        WindowsDnsSdBrowseRequest request,
        CancellationToken cancellationToken = default);
}

public sealed class WindowsDiscoveryBrowserClient : IDiscoveryBrowserClient
{
    private static readonly IReadOnlyList<string> DefaultQueryOrder =
        SkyBridgeProtocolConstants.WindowsDnsSdQueryOrder;
    private const int ExtendedSearchDurationSeconds = 15;
    private readonly IDiscoveryClient _discoveryClient;
    private readonly IWindowsDnsSdBrowseClient _dnsSdBrowseClient;
    private readonly object _operationGate = new();
    private ActiveDiscoveryBrowserOperation? _activeOperation;
    private DiscoveryBrowserOperationOwner? _publicationOwner;
    private long _nextGeneration;

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
        if (request.Action == DiscoveryBrowserAction.Stop)
        {
            var stop = BeginStopOperation();
            stop.Target?.Cancel();
            if (stop.Target is not null)
            {
                await stop.Target.Completion.ConfigureAwait(false);
            }

            return (await BuildSnapshotCoreAsync(request, CancellationToken.None).ConfigureAwait(false)) with
            {
                OperationOwner = stop.Owner
            };
        }

        var operation = BeginBrowseOperation();
        try
        {
            return (await BuildSnapshotCoreAsync(request, operation.CancellationToken).ConfigureAwait(false)) with
            {
                OperationOwner = operation.Owner
            };
        }
        finally
        {
            CompleteBrowseOperation(operation);
        }
    }

    public bool TryPublish(
        DiscoveryBrowserSnapshot snapshot,
        Action<DiscoveryBrowserSnapshot> publish)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        ArgumentNullException.ThrowIfNull(publish);
        if (snapshot.OperationOwner is null)
        {
            throw new InvalidOperationException(
                "Discovery browser publication requires an operation owner.");
        }

        lock (_operationGate)
        {
            if (_publicationOwner != snapshot.OperationOwner)
            {
                return false;
            }

            publish(snapshot);
            return true;
        }
    }

    private async Task<DiscoveryBrowserSnapshot> BuildSnapshotCoreAsync(
        DiscoveryBrowserRequest request,
        CancellationToken cancellationToken)
    {
        var capturedAt = DateTimeOffset.UtcNow;
        var facts = new List<DiscoveryBrowserFact>
        {
            new("Backend", "Win32 DNS-SD boundary", "Use windns.h DnsServiceBrowse/DnsServiceRegister for the live adapter; WinRT DnssdServiceWatcher stays avoided because Microsoft marks it unsupported."),
            new("Query order", string.Join(", ", DefaultQueryOrder), "Browses both control services, then canonical file/remote services, followed by legacy input-only aliases."),
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
            return new DiscoveryBrowserSnapshot(capturedAt, false, Array.Empty<DiscoveryBrowserPeerCandidate>(), facts);
        }

        var records = new List<WindowsDnsSdResolvedTxtRecord>();
        if (string.IsNullOrWhiteSpace(request.TxtRecord))
        {
            var browseSnapshot = await _dnsSdBrowseClient.BrowseAsync(
                new WindowsDnsSdBrowseRequest(
                    DefaultQueryOrder,
                    request.Action,
                    request.CompatibilityMode,
                    request.ExtendedSearchSeconds),
                cancellationToken).ConfigureAwait(false);
            facts.AddRange(browseSnapshot.Facts);
            records.AddRange(browseSnapshot.Records);
            if (cancellationToken.IsCancellationRequested)
            {
                facts.Add(new DiscoveryBrowserFact(
                    "Native browse",
                    "cancelled",
                    "The exact DNS-SD browse owner completed its native callback barrier after cancellation; its stale result will not be published."));
                return new DiscoveryBrowserSnapshot(
                    capturedAt,
                    false,
                    Array.Empty<DiscoveryBrowserPeerCandidate>(),
                    facts);
            }
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
            DiscoveredPeer peer;
            try
            {
                peer = await _discoveryClient.ParseAdvertisementAsync(record.Service, record.TxtRecord);
            }
            catch (Exception ex) when (ex is ArgumentException or InvalidOperationException)
            {
                facts.Add(new DiscoveryBrowserFact(
                    "Core TXT parse",
                    "rejected",
                    $"Candidate from {FormatRecordSource(record)} failed Core validation: {ex.GetType().Name}."));
                continue;
            }

            peer = WithResolvedDisplayName(peer, record);
            var routes = DiscoveryPeerRoutes.FromResolvedTxtRecord(record);
            var candidate = BuildPeerCandidate(peer) with { Routes = routes };
            var projectedCandidate = candidate with
            {
                ProductActionTargets = ProductSessionActionTargetProjection.Project(candidate, null, capturedAt)
            };
            if (MatchesSearch(peer, request.SearchText))
            {
                peers.Add(projectedCandidate);
            }

            facts.Add(new DiscoveryBrowserFact(
                "Core TXT parse",
                peer.DeviceId,
                $"Candidate came from {FormatRecordSource(record)}; pubKeyFP remains fingerprint-only until pairing material is validated."));
            if (routes.HasAny)
            {
                facts.Add(new DiscoveryBrowserFact(
                    "Resolved route",
                    peer.DeviceId,
                    routes.Summary));
                facts.Add(new DiscoveryBrowserFact(
                    "Product action gate",
                    peer.DeviceId,
                    FormatProductActionGate(projectedCandidate.ProductActionTargets)));
            }
        }

        // Native browse/resolve owners have completed and released their callback
        // leases before this snapshot returns. The UI must not advertise a live scan.
        return new DiscoveryBrowserSnapshot(DateTimeOffset.UtcNow, false, peers, facts);
    }

    private static DiscoveredPeer WithResolvedDisplayName(DiscoveredPeer peer, WindowsDnsSdResolvedTxtRecord record)
    {
        // Canonical Apple TXT records deliberately omit a display name. DNS-SD's
        // instance label is presentation data only; it never changes peer identity,
        // fingerprints, resolved routes, or the product-session admission gate.
        if (peer.DisplayName != "Unknown Device") return peer;
        var instance = record.InstanceName.TrimEnd('.');
        var suffix = $".{record.Service}.local";
        if (!instance.EndsWith(suffix, StringComparison.OrdinalIgnoreCase)) return peer;
        var name = instance[..^suffix.Length];
        if (string.IsNullOrWhiteSpace(name) || Encoding.UTF8.GetByteCount(name) > 63 || name.Any(char.IsControl))
            return peer;
        return peer with { DisplayName = name };
    }

    private ActiveDiscoveryBrowserOperation BeginBrowseOperation()
    {
        ActiveDiscoveryBrowserOperation? previous;
        ActiveDiscoveryBrowserOperation current;
        lock (_operationGate)
        {
            current = new ActiveDiscoveryBrowserOperation(CreateOwnerLocked());
            previous = _activeOperation;
            _activeOperation = current;
            _publicationOwner = current.Owner;
        }

        previous?.Cancel();
        return current;
    }

    private StopDiscoveryBrowserOperation BeginStopOperation()
    {
        lock (_operationGate)
        {
            var owner = CreateOwnerLocked();
            _publicationOwner = owner;
            return new StopDiscoveryBrowserOperation(owner, _activeOperation);
        }
    }

    private void CompleteBrowseOperation(ActiveDiscoveryBrowserOperation operation)
    {
        lock (_operationGate)
        {
            if (ReferenceEquals(_activeOperation, operation))
            {
                _activeOperation = null;
            }
        }

        operation.Complete();
    }

    private DiscoveryBrowserOperationOwner CreateOwnerLocked()
    {
        _nextGeneration = checked(_nextGeneration + 1);
        return new DiscoveryBrowserOperationOwner(_nextGeneration, Guid.NewGuid());
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

    private static string FormatProductActionGate(IReadOnlyList<ProductSessionActionTarget> targets)
    {
        var values = new List<string>();
        foreach (var target in targets)
        {
            values.Add(
                target.Enabled
                    ? $"{target.Kind}=enabled"
                    : $"{target.Kind}=disabled:{target.DisabledReason}");
        }

        return values.Count == 0
            ? "No product action targets were projected."
            : string.Join(", ", values);
    }

    private sealed class ActiveDiscoveryBrowserOperation
    {
        private readonly object _gate = new();
        private readonly CancellationTokenSource _cancellation = new();
        private readonly TaskCompletionSource _completion =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        private bool _completed;

        public ActiveDiscoveryBrowserOperation(DiscoveryBrowserOperationOwner owner)
        {
            Owner = owner;
            CancellationToken = _cancellation.Token;
        }

        public DiscoveryBrowserOperationOwner Owner { get; }

        public CancellationToken CancellationToken { get; }

        public Task Completion => _completion.Task;

        public void Cancel()
        {
            lock (_gate)
            {
                if (!_completed)
                {
                    _cancellation.Cancel();
                }
            }
        }

        public void Complete()
        {
            lock (_gate)
            {
                if (_completed)
                {
                    return;
                }

                _completed = true;
                _cancellation.Dispose();
                _completion.TrySetResult();
            }
        }
    }

    private sealed record StopDiscoveryBrowserOperation(
        DiscoveryBrowserOperationOwner Owner,
        ActiveDiscoveryBrowserOperation? Target);
}

public sealed class PendingWindowsDnsSdBrowseClient : IWindowsDnsSdBrowseClient
{
    public Task<WindowsDnsSdBrowseSnapshot> BrowseAsync(
        WindowsDnsSdBrowseRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        _ = cancellationToken;

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
    IReadOnlyList<DiscoveryBrowserFact> Facts)
{
    public DiscoveryBrowserOperationOwner? OperationOwner { get; init; }
}

/// <summary>
/// Identifies one discovery command generation. Instances are issued only by
/// <see cref="WindowsDiscoveryBrowserClient"/> and are used to reject stale publication.
/// </summary>
public sealed record DiscoveryBrowserOperationOwner
{
    internal DiscoveryBrowserOperationOwner(long generation, Guid leaseId)
    {
        Generation = generation;
        LeaseId = leaseId;
    }

    public long Generation { get; }

    public Guid LeaseId { get; }
}

public sealed record DiscoveryBrowserInputPolicy(
    int ExtendedSearchSeconds,
    IReadOnlyList<string> ServiceQueryOrder);

public sealed record DiscoveryBrowserPeerCandidate(
    DiscoveredPeer Peer,
    string CapabilitiesSummary,
    string TrustSummary)
{
    public DiscoveryPeerRoutes Routes { get; init; } = DiscoveryPeerRoutes.Empty;

    public IReadOnlyList<ProductSessionActionTarget> ProductActionTargets { get; init; } =
        Array.Empty<ProductSessionActionTarget>();
}

// The DNS-SD half of these records. The declarations and their pure members live in
// DiscoveryPeerRoutes.cs so preflight and the transport adapters can carry a peer's routes
// without pulling in this file's browse machinery, codec, and protocol tables.
public sealed partial record DiscoveryPeerRoutes
{
    internal static DiscoveryBrowserPeerCandidate JoinFileTransferServices(DiscoveryBrowserPeerCandidate filePeer,
        IEnumerable<DiscoveryBrowserPeerCandidate> peers)
    {
        var fileRoute = filePeer.Routes.FileTransfer
            ?? throw new InvalidOperationException("The selected device has no resolved file-transfer service.");
        var identity = ProductDeviceIdentity.CanonicalDeviceId(filePeer.Peer.DeviceId);
        var controls = peers.Where(peer => peer.Peer.PublicKeyFingerprint == filePeer.Peer.PublicKeyFingerprint &&
                ProductDeviceIdentity.CanonicalDeviceId(peer.Peer.DeviceId) == identity)
            .Select(peer => peer.Routes.Control)
            .OfType<DiscoveryPeerEndpoint>()
            .Where(route => route.Service == SkyBridgeProtocolConstants.TcpControlDnsSdService &&
                route.Provenance == "resolved-dns-sd-endpoint" &&
                string.Equals(route.HostName.TrimEnd('.'), fileRoute.HostName.TrimEnd('.'), StringComparison.OrdinalIgnoreCase))
            .Distinct().ToArray();
        if (controls.Length != 1)
            throw new InvalidDataException("The selected file service requires one matching resolved LAN control service. Refresh device discovery.");
        return filePeer with { Routes = filePeer.Routes with { Control = controls[0] } };
    }


    public static DiscoveryPeerRoutes FromResolvedTxtRecord(WindowsDnsSdResolvedTxtRecord record)
    {
        var endpoint = DiscoveryPeerEndpoint.FromResolvedTxtRecord(record);
        if (endpoint is null)
        {
            return Empty;
        }

        return endpoint.Service switch
        {
            SkyBridgeProtocolConstants.QuicControlDnsSdService => Empty with { Control = endpoint },
            SkyBridgeProtocolConstants.TcpControlDnsSdService => Empty with { Control = endpoint },
            SkyBridgeProtocolConstants.FileTransferDnsSdService => Empty with { FileTransfer = endpoint },
            SkyBridgeProtocolConstants.RemoteDesktopDnsSdService => Empty with { RemoteDesktop = endpoint },
            _ => Empty
        };
    }
}

public sealed partial record DiscoveryPeerEndpoint
{
    public static DiscoveryPeerEndpoint? FromResolvedTxtRecord(WindowsDnsSdResolvedTxtRecord record)
    {
        if (string.IsNullOrWhiteSpace(record.HostName) || record.Port == 0)
        {
            return null;
        }

        var sourceService = record.Service.Trim();
        if (!SkyBridgeProtocolConstants.TryCanonicalizeDnsSdServiceType(
            sourceService,
            out var canonicalService))
        {
            return null;
        }

        var hostName = record.HostName.Trim();
        var instanceName = SkyBridgeProtocolConstants.CanonicalizeDnsSdInstanceName(
            record.InstanceName,
            sourceService,
            canonicalService);
        if (!IsSafeEndpointField(canonicalService, maxLength: 64, allowEmpty: false, allowWhitespace: false)
            || !IsSafeEndpointField(hostName, maxLength: 253, allowEmpty: false, allowWhitespace: false)
            || !IsSafeEndpointField(instanceName, maxLength: 255, allowEmpty: true, allowWhitespace: true))
        {
            return null;
        }

        return new DiscoveryPeerEndpoint(
            canonicalService,
            hostName,
            record.Port,
            instanceName,
            "resolved-dns-sd-endpoint");
    }

    private static bool IsSafeEndpointField(
        string value,
        int maxLength,
        bool allowEmpty,
        bool allowWhitespace)
    {
        if (value.Length == 0)
        {
            return allowEmpty;
        }

        if (value.Length > maxLength)
        {
            return false;
        }

        foreach (var c in value)
        {
            if (char.IsControl(c)
                || (!allowWhitespace && char.IsWhiteSpace(c))
                || c is '/' or '\\' or ';' or '=')
            {
                return false;
            }
        }

        return true;
    }
}

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
