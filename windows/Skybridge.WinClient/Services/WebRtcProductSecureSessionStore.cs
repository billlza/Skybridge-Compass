using System;
using System.IO;

namespace Skybridge.WinClient.Services;

/// <summary>
/// Stores product-control SBWC keys only after the Mac-compatible handshake driver
/// has verified MessageA/MessageB/FIN1. The store never derives keys itself and
/// never upgrades raw TransportOnly evidence to Established without explicit keys.
/// </summary>
public sealed class WebRtcProductSecureSessionStore : IWebRtcAppSessionKeyProvider
{
    private readonly object _gate = new();
    private EstablishedSession? _established;

    public LiveWebRtcProductControlContext InstallEstablishedSession(
        LiveWebRtcProductControlContext transportContext,
        WebRtcAppSecureSessionKeys keys,
        ushort suiteWireId)
    {
        ArgumentNullException.ThrowIfNull(transportContext);
        ArgumentNullException.ThrowIfNull(keys);
        WebRtcProductHandshakeCodec.RequireKnownSuite(suiteWireId);
        ValidateRoleBinding(transportContext, keys);

        if (transportContext.SecureSessionState != WebRtcProductControlSecureSessionState.TransportOnly)
        {
            throw new InvalidOperationException(
                "WebRTC product secure session installation requires a TransportOnly product-control context.");
        }

        var establishedContext = transportContext with
        {
            SecureSessionState = WebRtcProductControlSecureSessionState.Established
        };
        var session = new EstablishedSession(
            establishedContext.PeerDeviceId,
            establishedContext.PeerPublicKeyFingerprint,
            establishedContext.AdapterBinding,
            establishedContext.TransportBindingDigestHex,
            suiteWireId,
            keys.Clone());

        lock (_gate)
        {
            _established?.Dispose();
            _established = session;
        }

        return establishedContext;
    }

    public WebRtcAppSecureSessionKeys RequireEstablishedKeys(LiveWebRtcProductControlContext context)
    {
        return RequireEstablishedSession(context).Keys.Clone();
    }

    public WebRtcAppSecureSessionKeys RequireEstablishedKeys(
        LiveWebRtcProductControlContext context,
        ushort suiteWireId,
        WebRtcAppSecureRole role)
    {
        WebRtcProductHandshakeCodec.RequireKnownSuite(suiteWireId);
        var session = RequireEstablishedSession(context);
        if (session.SuiteWireId != suiteWireId)
        {
            throw new WebRtcAppSessionKeysUnavailableException(
                "WebRTC product-control secure session suite does not match the requested suite.");
        }

        if (session.Keys.Role != role)
        {
            throw new WebRtcAppSessionKeysUnavailableException(
                "WebRTC product-control secure session role does not match the requested role.");
        }

        return session.Keys.Clone();
    }

    private EstablishedSession RequireEstablishedSession(LiveWebRtcProductControlContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        if (context.SecureSessionState != WebRtcProductControlSecureSessionState.Established)
        {
            throw new WebRtcAppSessionKeysUnavailableException(
                "WebRTC product-control context is not Established; refusing to expose SBWC session keys.");
        }

        EstablishedSession? session;
        lock (_gate)
        {
            session = _established;
        }

        if (session is null)
        {
            throw new WebRtcAppSessionKeysUnavailableException(
                "WebRTC product-control secure session keys are not installed.");
        }

        if (!session.Matches(context))
        {
            throw new WebRtcAppSessionKeysUnavailableException(
                "WebRTC product-control secure session keys do not match the requested peer or transport binding.");
        }

        return session;
    }

    public void Clear(LiveWebRtcProductControlContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        lock (_gate)
        {
            if (_established is not null && _established.Matches(context))
            {
                _established.Dispose();
                _established = null;
            }
        }
    }

    public void ClearAll()
    {
        lock (_gate)
        {
            _established?.Dispose();
            _established = null;
        }
    }

    private sealed record EstablishedSession(
        string PeerDeviceId,
        string PeerPublicKeyFingerprint,
        string AdapterBinding,
        string TransportBindingDigestHex,
        ushort SuiteWireId,
        WebRtcAppSecureSessionKeys Keys) : IDisposable
    {
        public void Dispose() => Keys.Dispose();

        public bool Matches(LiveWebRtcProductControlContext context)
        {
            if (string.IsNullOrWhiteSpace(Keys.SessionId))
            {
                throw new InvalidDataException("Installed WebRTC product secure session has an empty session id.");
            }

            return string.Equals(PeerDeviceId, context.PeerDeviceId, StringComparison.Ordinal) &&
                string.Equals(PeerPublicKeyFingerprint, context.PeerPublicKeyFingerprint, StringComparison.Ordinal) &&
                string.Equals(AdapterBinding, context.AdapterBinding, StringComparison.Ordinal) &&
                string.Equals(TransportBindingDigestHex, context.TransportBindingDigestHex, StringComparison.Ordinal);
        }
    }

    private static void ValidateRoleBinding(
        LiveWebRtcProductControlContext transportContext,
        WebRtcAppSecureSessionKeys keys)
    {
        var expectedRole = transportContext.Role switch
        {
            "offer" => WebRtcAppSecureRole.Initiator,
            "answer" => WebRtcAppSecureRole.Responder,
            _ => throw new InvalidDataException(
                $"Unsupported WebRTC product-control role '{transportContext.Role}' for secure session installation.")
        };

        if (keys.Role != expectedRole)
        {
            throw new InvalidOperationException(
                "WebRTC product secure session role does not match the product-control transport role.");
        }
    }
}
