using System;
using System.Threading;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

public enum WebRtcProductControlSecureSessionState
{
    TransportOnly,
    Established
}

public sealed record LiveWebRtcProductControlContext(
    IWebRtcProductControlPlane ControlPlane,
    string PeerDeviceId,
    string PeerPublicKeyFingerprint,
    string Role,
    string TransportProfile,
    string DataChannelLabel,
    string AdapterBinding,
    string LocalEndpoint,
    string RemoteEndpoint,
    string SelectedCandidatePair,
    int LateRemoteIceCandidateRelayCount,
    string TransportBindingDigestHex,
    ulong TimestampWindowMs,
    WebRtcProductControlSecureSessionState SecureSessionState,
    string LocalDeviceId = "",
    string LocalPublicKeyFingerprint = "",
    WebRtcProductSessionIncarnation? SessionIncarnation = null);

/// <summary>
/// Opaque exact-owner lease returned by a product-control runtime consumer start.
/// The matching stop operation must present the same lease.
/// </summary>
public readonly record struct WebRtcProductControlRuntimeLease
{
    internal WebRtcProductControlRuntimeLease(Guid ownerId)
    {
        OwnerId = ownerId;
    }

    public Guid OwnerId { get; }

    internal static WebRtcProductControlRuntimeLease Create() => new(Guid.NewGuid());

    public void RequireValid()
    {
        if (OwnerId == Guid.Empty)
        {
            throw new InvalidOperationException(
                "WebRTC product-control runtime lease owner must not be empty.");
        }
    }
}

/// <summary>
/// Opaque incarnation of one installed product secure session. It prevents a
/// stale context for logical session A from reading or clearing replacement B.
/// </summary>
public readonly record struct WebRtcProductSessionIncarnation
{
    internal WebRtcProductSessionIncarnation(Guid ownerId)
    {
        OwnerId = ownerId;
    }

    public Guid OwnerId { get; }

    internal static WebRtcProductSessionIncarnation Create() => new(Guid.NewGuid());

    public void RequireValid()
    {
        if (OwnerId == Guid.Empty)
        {
            throw new InvalidOperationException(
                "WebRTC product secure-session incarnation owner must not be empty.");
        }
    }
}

public interface IWebRtcAppSessionKeyProvider
{
    WebRtcAppSecureSessionKeys RequireEstablishedKeys(LiveWebRtcProductControlContext context);
}

public sealed class WebRtcAppSessionKeysUnavailableException : InvalidOperationException
{
    public WebRtcAppSessionKeysUnavailableException(string message)
        : base(message)
    {
    }
}

public sealed class UnavailableWebRtcAppSessionKeyProvider : IWebRtcAppSessionKeyProvider
{
    public WebRtcAppSecureSessionKeys RequireEstablishedKeys(LiveWebRtcProductControlContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        throw new WebRtcAppSessionKeysUnavailableException(
            "WebRTC product-control secure session keys are not established. "
            + "Run the Mac-compatible MessageA/MessageB/FIN1 handshake before sending SBWC business payloads.");
    }
}

public interface IWebRtcProductControlRuntimeConsumer
{
    /// <summary>
    /// Starts one consumer incarnation and transfers ownership to the caller only
    /// by returning a valid lease.
    /// </summary>
    /// <remarks>
    /// If start throws or is cancelled, the implementation must undo every
    /// unpublished side effect because the caller has no lease with which to stop it.
    /// </remarks>
    Task<WebRtcProductControlRuntimeLease> StartAsync(
        LiveWebRtcProductControlContext context,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Stops only the consumer incarnation identified by <paramref name="lease"/>.
    /// </summary>
    /// <remarks>
    /// A stale or foreign lease must not clear a replacement incarnation. Repeating
    /// stop for the same lease after its incarnation is gone must be harmless.
    /// </remarks>
    Task StopAsync(
        WebRtcProductControlRuntimeLease lease,
        CancellationToken cancellationToken = default);
}

/// <summary>
/// Exact-lease authority boundary used by the product-control engine to prove
/// that a completed runtime start established the authenticated product session,
/// rather than merely opening the raw WebRTC transport.
/// </summary>
internal interface IWebRtcProductControlEstablishedSessionAuthority
{
    LiveWebRtcProductControlContext RequireEstablishedContext(
        WebRtcProductControlRuntimeLease lease);
}
