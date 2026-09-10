using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

public interface IWebRtcSessionDataPlaneProvider
{
    LiveWebRtcSessionContext RequireLiveSession(ConnectionLaunchRequest request);
}

public sealed record LiveWebRtcSessionContext(
    ISkyBridgeDataPlane DataPlane,
    string PeerDeviceId,
    string PeerPublicKeyFingerprint,
    string SessionIdHex,
    string AdapterBinding,
    string LocalEndpoint,
    string RemoteEndpoint,
    string SelectedCandidatePair,
    ulong TimestampWindowMs,
    IReadOnlyList<ChannelMapping> ChannelMappings);

/// <summary>
/// Opaque exact-owner lease returned by a WebRTC session runtime consumer start.
/// The matching stop operation must present the same lease.
/// </summary>
public readonly record struct WebRtcSessionRuntimeLease
{
    internal WebRtcSessionRuntimeLease(Guid ownerId)
    {
        OwnerId = ownerId;
    }

    public Guid OwnerId { get; }

    internal static WebRtcSessionRuntimeLease Create() => new(Guid.NewGuid());

    public void RequireValid()
    {
        if (OwnerId == Guid.Empty)
        {
            throw new InvalidOperationException(
                "WebRTC session runtime lease owner must not be empty.");
        }
    }
}

public interface IWebRtcSessionRuntimeConsumer
{
    /// <summary>
    /// Starts one consumer incarnation and transfers ownership to the caller only
    /// by returning a valid lease.
    /// </summary>
    /// <remarks>
    /// If start throws or is cancelled, the implementation must undo every
    /// unpublished side effect because the caller has no lease with which to stop it.
    /// </remarks>
    Task<WebRtcSessionRuntimeLease> StartAsync(
        LiveWebRtcSessionContext session,
        ConnectionLaunchRequest request,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Stops only the consumer incarnation identified by <paramref name="lease"/>.
    /// </summary>
    /// <remarks>
    /// A stale or foreign lease must not clear a replacement incarnation. Repeating
    /// stop for the same lease after its incarnation is gone must be harmless.
    /// </remarks>
    Task StopAsync(
        WebRtcSessionRuntimeLease lease,
        CancellationToken cancellationToken = default);
}
