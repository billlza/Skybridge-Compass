using System;

namespace Skybridge.WinClient.Services;

public enum ProductControlSessionSnapshotUnavailableReason
{
    NotWired,
    NoEstablishedSession
}

public sealed record ProductControlSessionSnapshotResult(
    EstablishedProductControlSessionSnapshot? Session,
    ProductControlSessionSnapshotUnavailableReason? UnavailableReason,
    string Detail);

public interface IProductControlSessionSnapshotClient
{
    ProductControlSessionSnapshotResult Capture(
        DiscoveryBrowserPeerCandidate candidate,
        DateTimeOffset nowUtc);
}

public sealed class UnavailableProductControlSessionSnapshotClient : IProductControlSessionSnapshotClient
{
    public ProductControlSessionSnapshotResult Capture(
        DiscoveryBrowserPeerCandidate candidate,
        DateTimeOffset nowUtc)
    {
        ArgumentNullException.ThrowIfNull(candidate);
        return new(
            null,
            ProductControlSessionSnapshotUnavailableReason.NotWired,
            "WinClient has no established product-control session authority wired for discovered product actions.");
    }
}

public interface IProductSessionActionGateClient
{
    ProductSessionActionGateResult EvaluateFileTransfer(
        DiscoveryBrowserPeerCandidate? candidate,
        DateTimeOffset nowUtc);

    ProductSessionActionGateResult EvaluateRemoteDesktop(
        DiscoveryBrowserPeerCandidate? candidate,
        DateTimeOffset nowUtc);
}

public sealed class ProductSessionActionGateClient : IProductSessionActionGateClient
{
    private readonly IProductControlSessionSnapshotClient _snapshotClient;

    public ProductSessionActionGateClient()
        : this(new UnavailableProductControlSessionSnapshotClient())
    {
    }

    public ProductSessionActionGateClient(IProductControlSessionSnapshotClient snapshotClient)
    {
        _snapshotClient = snapshotClient ?? throw new ArgumentNullException(nameof(snapshotClient));
    }

    public ProductSessionActionGateResult EvaluateFileTransfer(
        DiscoveryBrowserPeerCandidate? candidate,
        DateTimeOffset nowUtc) =>
        Evaluate(ProductSessionActionKind.FileTransfer, candidate, nowUtc);

    public ProductSessionActionGateResult EvaluateRemoteDesktop(
        DiscoveryBrowserPeerCandidate? candidate,
        DateTimeOffset nowUtc) =>
        Evaluate(ProductSessionActionKind.RemoteDesktop, candidate, nowUtc);

    private ProductSessionActionGateResult Evaluate(
        ProductSessionActionKind kind,
        DiscoveryBrowserPeerCandidate? candidate,
        DateTimeOffset nowUtc)
    {
        if (candidate is null)
        {
            return ProductSessionActionGateResult.Blocked(
                kind,
                ProductSessionActionDisabledReason.MissingValidatedDiscoveryCandidate,
                "Select exactly one Core-validated discovered peer before using a discovered product action.");
        }

        var snapshot = _snapshotClient.Capture(candidate, nowUtc);
        var target = kind switch
        {
            ProductSessionActionKind.FileTransfer =>
                ProductSessionActionTargetProjection.ProjectFileTransfer(candidate, snapshot.Session, nowUtc),
            ProductSessionActionKind.RemoteDesktop =>
                ProductSessionActionTargetProjection.ProjectRemoteDesktop(candidate, snapshot.Session, nowUtc),
            _ => throw new ArgumentOutOfRangeException(nameof(kind), kind, "Unknown product action kind.")
        };

        if (target.Enabled)
        {
            return new(target.Kind, true, null, target, target.Detail);
        }

        var detail = string.IsNullOrWhiteSpace(snapshot.Detail)
            ? target.Detail
            : $"{target.Detail} {snapshot.Detail}";
        return new(
            target.Kind,
            false,
            target.DisabledReason,
            target,
            detail);
    }
}

public sealed record ProductSessionActionGateResult(
    ProductSessionActionKind Kind,
    bool IsReady,
    ProductSessionActionDisabledReason? DisabledReason,
    ProductSessionActionTarget? Target,
    string Detail)
{
    public static ProductSessionActionGateResult Blocked(
        ProductSessionActionKind kind,
        ProductSessionActionDisabledReason reason,
        string detail) =>
        new(kind, false, reason, null, detail);
}
