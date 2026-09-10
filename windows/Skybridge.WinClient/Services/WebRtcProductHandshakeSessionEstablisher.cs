using System;
using System.Threading;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

public sealed class WebRtcProductHandshakeSessionEstablisher :
    IWebRtcProductSecureSessionEstablisher,
    IDisposable
{
    private readonly WebRtcProductHandshakeDriver _handshakeDriver;
    private readonly IDisposable? _cryptoProviderOwner;
    private bool _disposed;

    public WebRtcProductHandshakeSessionEstablisher(
        WebRtcProductHandshakeDriver handshakeDriver,
        IDisposable? cryptoProviderOwner = null)
    {
        _handshakeDriver = handshakeDriver ?? throw new ArgumentNullException(nameof(handshakeDriver));
        _cryptoProviderOwner = cryptoProviderOwner;
    }

    public Task<LiveWebRtcProductControlContext> EstablishAsync(
        LiveWebRtcProductControlContext transportContext,
        CancellationToken cancellationToken = default)
    {
        if (_disposed)
        {
            throw new ObjectDisposedException(nameof(WebRtcProductHandshakeSessionEstablisher));
        }

        ArgumentNullException.ThrowIfNull(transportContext);
        if (transportContext.SecureSessionState != WebRtcProductControlSecureSessionState.TransportOnly)
        {
            throw new InvalidOperationException(
                "WebRTC product-control secure session establishment requires a TransportOnly context.");
        }

        return transportContext.Role switch
        {
            "offer" => _handshakeDriver.StartInitiatorAsync(transportContext, cancellationToken),
            "answer" => _handshakeDriver.StartResponderAsync(transportContext, cancellationToken),
            _ => throw new InvalidOperationException(
                "WebRTC product-control secure session establishment requires role 'offer' or 'answer'.")
        };
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _cryptoProviderOwner?.Dispose();
        _disposed = true;
    }
}
