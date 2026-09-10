using System;
using System.Collections.Generic;

namespace Skybridge.WinClient.Services;

public enum ProductSessionActionKind
{
    FileTransfer,
    RemoteDesktop
}

public enum ProductSessionActionDisabledReason
{
    MissingResolvedRoute,
    MissingEstablishedProductControlSession,
    ProductControlSessionNotEstablished,
    ProductControlSessionExpired,
    PeerDeviceIdMismatch,
    PeerFingerprintMismatch,
    UnsupportedRouteProvenance,
    MissingAuthenticatedRouteBinding,
    AuthenticatedRouteBindingExpired,
    MissingValidatedDiscoveryCandidate
}

public sealed record EstablishedProductControlSessionSnapshot(
    string SessionId,
    string RemoteDeviceId,
    string RemotePublicKeyFingerprint,
    string SecureSessionState,
    DateTimeOffset ExpiresAtUtc)
{
    public IReadOnlyList<AuthenticatedProductRouteBinding> AuthenticatedRouteBindings { get; init; } =
        Array.Empty<AuthenticatedProductRouteBinding>();
}

public sealed record AuthenticatedProductRouteBinding(
    ProductSessionActionKind Kind,
    string Service,
    string HostName,
    ushort Port,
    string InstanceName,
    string EndpointProvenance,
    DateTimeOffset ExpiresAtUtc);

public sealed record ProductSessionActionTarget(
    ProductSessionActionKind Kind,
    DiscoveryPeerEndpoint? Endpoint,
    bool Enabled,
    ProductSessionActionDisabledReason? DisabledReason,
    string? SessionId,
    string Detail);

public static class ProductSessionActionTargetProjection
{
    private const string EstablishedState = "Established";
    private const string ResolvedDnsSdEndpointProvenance = "resolved-dns-sd-endpoint";

    public static IReadOnlyList<ProductSessionActionTarget> Project(
        DiscoveryBrowserPeerCandidate candidate,
        EstablishedProductControlSessionSnapshot? session,
        DateTimeOffset nowUtc)
    {
        ArgumentNullException.ThrowIfNull(candidate);

        return
        [
            ProjectFileTransfer(candidate, session, nowUtc),
            ProjectRemoteDesktop(candidate, session, nowUtc)
        ];
    }

    public static ProductSessionActionTarget ProjectFileTransfer(
        DiscoveryBrowserPeerCandidate candidate,
        EstablishedProductControlSessionSnapshot? session,
        DateTimeOffset nowUtc)
    {
        ArgumentNullException.ThrowIfNull(candidate);
        return ProjectSingle(
            ProductSessionActionKind.FileTransfer,
            candidate,
            candidate.Routes.FileTransfer,
            session,
            nowUtc);
    }

    public static ProductSessionActionTarget ProjectRemoteDesktop(
        DiscoveryBrowserPeerCandidate candidate,
        EstablishedProductControlSessionSnapshot? session,
        DateTimeOffset nowUtc)
    {
        ArgumentNullException.ThrowIfNull(candidate);
        return ProjectSingle(
            ProductSessionActionKind.RemoteDesktop,
            candidate,
            candidate.Routes.RemoteDesktop,
            session,
            nowUtc);
    }

    private static ProductSessionActionTarget ProjectSingle(
        ProductSessionActionKind kind,
        DiscoveryBrowserPeerCandidate candidate,
        DiscoveryPeerEndpoint? endpoint,
        EstablishedProductControlSessionSnapshot? session,
        DateTimeOffset nowUtc)
    {
        if (endpoint is null)
        {
            return Disabled(
                kind,
                endpoint,
                ProductSessionActionDisabledReason.MissingResolvedRoute,
                "No resolved DNS-SD endpoint was available for this action; TXT port hints are diagnostic only.");
        }

        if (!string.Equals(endpoint.Provenance, ResolvedDnsSdEndpointProvenance, StringComparison.Ordinal))
        {
            return Disabled(
                kind,
                endpoint,
                ProductSessionActionDisabledReason.UnsupportedRouteProvenance,
                "Only host/port values produced by DNS-SD resolve can become product action targets.");
        }

        if (session is null)
        {
            return Disabled(
                kind,
                endpoint,
                ProductSessionActionDisabledReason.MissingEstablishedProductControlSession,
                "Discovery found a route, but product actions require an established product-control secure session.");
        }

        if (string.IsNullOrWhiteSpace(session.SessionId)
            || !string.Equals(session.SecureSessionState.Trim(), EstablishedState, StringComparison.Ordinal))
        {
            return Disabled(
                kind,
                endpoint,
                ProductSessionActionDisabledReason.ProductControlSessionNotEstablished,
                "The product-control session is not established.");
        }

        if (session.ExpiresAtUtc <= nowUtc)
        {
            return Disabled(
                kind,
                endpoint,
                ProductSessionActionDisabledReason.ProductControlSessionExpired,
                "The product-control session is stale and must be re-established.");
        }

        if (!SameIdentity(session.RemoteDeviceId, candidate.Peer.DeviceId))
        {
            return Disabled(
                kind,
                endpoint,
                ProductSessionActionDisabledReason.PeerDeviceIdMismatch,
                "The product-control session peer does not match the discovered peer.");
        }

        if (!SameFingerprint(session.RemotePublicKeyFingerprint, candidate.Peer.PublicKeyFingerprint))
        {
            return Disabled(
                kind,
                endpoint,
                ProductSessionActionDisabledReason.PeerFingerprintMismatch,
                "The product-control session fingerprint does not match the discovery fingerprint.");
        }

        var binding = FindAuthenticatedBinding(kind, endpoint, session.AuthenticatedRouteBindings);
        if (binding is null)
        {
            return Disabled(
                kind,
                endpoint,
                ProductSessionActionDisabledReason.MissingAuthenticatedRouteBinding,
                "The product-control secure session has not authenticated this resolved DNS-SD route.");
        }

        if (binding.ExpiresAtUtc <= nowUtc)
        {
            return Disabled(
                kind,
                endpoint,
                ProductSessionActionDisabledReason.AuthenticatedRouteBindingExpired,
                "The authenticated product route binding is stale and must be refreshed.");
        }

        return new ProductSessionActionTarget(
            kind,
            endpoint,
            Enabled: true,
            DisabledReason: null,
            SessionId: session.SessionId.Trim(),
            Detail: $"authenticated-route-binding; endpoint={endpoint.HostName}:{endpoint.Port}; route={endpoint.Provenance}");
    }

    private static ProductSessionActionTarget Disabled(
        ProductSessionActionKind kind,
        DiscoveryPeerEndpoint? endpoint,
        ProductSessionActionDisabledReason reason,
        string detail) =>
        new(
            kind,
            endpoint,
            Enabled: false,
            DisabledReason: reason,
            SessionId: null,
            Detail: detail);

    private static bool SameIdentity(string lhs, string rhs) =>
        !string.IsNullOrWhiteSpace(lhs)
        && !string.IsNullOrWhiteSpace(rhs)
        && string.Equals(lhs.Trim(), rhs.Trim(), StringComparison.Ordinal);

    private static bool SameFingerprint(string lhs, string rhs)
    {
        var left = lhs.Trim();
        var right = rhs.Trim();
        return IsCanonicalFingerprint(left)
            && IsCanonicalFingerprint(right)
            && string.Equals(left, right, StringComparison.Ordinal);
    }

    private static AuthenticatedProductRouteBinding? FindAuthenticatedBinding(
        ProductSessionActionKind kind,
        DiscoveryPeerEndpoint endpoint,
        IReadOnlyList<AuthenticatedProductRouteBinding> bindings)
    {
        foreach (var binding in bindings)
        {
            if (binding.Kind == kind
                && string.Equals(binding.Service.Trim(), endpoint.Service, StringComparison.Ordinal)
                && string.Equals(binding.HostName.Trim(), endpoint.HostName, StringComparison.Ordinal)
                && binding.Port == endpoint.Port
                && string.Equals(binding.InstanceName.Trim(), endpoint.InstanceName, StringComparison.Ordinal)
                && string.Equals(binding.EndpointProvenance.Trim(), endpoint.Provenance, StringComparison.Ordinal))
            {
                return binding;
            }
        }

        return null;
    }

    private static bool IsCanonicalFingerprint(string value)
    {
        if (value.Length != 64)
        {
            return false;
        }

        foreach (var c in value)
        {
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')))
            {
                return false;
            }
        }

        return true;
    }
}
