using System.Net.Sockets;
using Windows.Media.Playback;

namespace Skybridge.WinClient.Services.RemoteControl;

internal sealed record RemoteControlViewerOutcome(Exception? Failure, IReadOnlyList<Exception> CleanupFailures);

/// <summary>Owns the viewer's one carrier, authenticated keys and Windows media source.</summary>
internal sealed class WindowsRemoteControlViewer : IAsyncDisposable
{
    private readonly TcpProductControlTransport _transport;
    private readonly WindowsRemoteVideoPlayer _video = new();
    private readonly RemoteControlViewerSession _session;
    private readonly CancellationTokenSource _lifetime;
    private readonly object _lifetimeGate = new();
    private bool _lifetimeDisposed;

    private WindowsRemoteControlViewer(TcpProductControlTransport transport, ProductSessionKeys keys,
        RemoteControlSecurityIdentity localIdentity, CancellationToken cancellationToken)
    {
        _transport = transport;
        _lifetime = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        _session = new(transport, keys, localIdentity, _video.ReceiveAsync, access => AccessChanged?.Invoke(access));
        Completion = ObserveAsync(_session.RunAsync(_lifetime.Token));
    }

    internal event Action<RemoteControlAccess>? AccessChanged;
    internal RemoteControlAccess? Access => _session.Access;
    internal Task<MediaPlayer> Player => _video.Available;
    internal Task<RemoteControlAccess> Ready => _session.Ready;
    internal (int Width, int Height) VideoDimensions => _video.Dimensions;
    internal Task<RemoteControlViewerOutcome> Completion { get; }

    internal static async Task<WindowsRemoteControlViewer> ConnectAsync(ProductPeerAuthentication authentication, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(authentication);
        using var authority = authentication;
        var endpoint = authority.Endpoint;
        if (endpoint.Service != SkyBridgeProtocolConstants.RemoteDesktopDnsSdService || string.IsNullOrWhiteSpace(endpoint.HostName) || endpoint.Port == 0)
            throw new InvalidDataException("Remote viewing requires a resolved remote-desktop service endpoint.");
        using var connectDeadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        connectDeadline.CancelAfter(TimeSpan.FromSeconds(10));
        var client = new TcpClient();
        TcpProductControlTransport? transport = null;
        try
        {
            try { await client.ConnectAsync(endpoint.HostName, endpoint.Port, connectDeadline.Token).ConfigureAwait(false); }
            catch (OperationCanceledException failure) when (connectDeadline.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
            { throw new TimeoutException("The selected remote desktop host did not accept a TCP connection within 10 seconds.", failure); }
            transport = new(client, RemoteControlWire.MaximumOutboundFrameBytes, RemoteControlWire.MaximumOutboundFrameBytes);
            using var authenticated = await new ProductHandshakeCore(authority.Crypto).StartInitiatorAsync(transport, authority.Peer, cancellationToken).ConfigureAwait(false);
            var viewer = new WindowsRemoteControlViewer(transport, authenticated.Keys, authority.LocalIdentity, cancellationToken);
            transport = null;
            return viewer;
        }
        catch (Exception failure)
        {
            if (transport is not null)
            {
                try { await transport.DisposeAsync().ConfigureAwait(false); }
                catch (Exception cleanup) { throw new AggregateException("Viewer connection and carrier cleanup failed.", failure, cleanup); }
            }
            else { client.Dispose(); }
            throw;
        }
    }

    internal Task SendInputAsync<T>(string type, T payload, RemoteControlAccess access, CancellationToken cancellationToken) =>
        _session.SendInputAsync(type, payload, access, cancellationToken);

    private async Task<RemoteControlViewerOutcome> ObserveAsync(Task receiver)
    {
        Exception? failure = null;
        var cleanupFailures = new List<Exception>();
        try
        {
            if (await Task.WhenAny(receiver, _video.Failure).ConfigureAwait(false) == _video.Failure)
                throw await _video.Failure.ConfigureAwait(false);
            await receiver.ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (_lifetime.IsCancellationRequested) { }
        catch (Exception error) { failure = error; }
        try { RequestStop(); } catch (Exception error) { cleanupFailures.Add(error); }
        try { _transport.Close(); } catch (Exception error) { cleanupFailures.Add(error); }
        try { await receiver.ConfigureAwait(false); }
        catch (OperationCanceledException) when (_lifetime.IsCancellationRequested) { }
        catch (Exception error)
        {
            if (!ReferenceEquals(error, failure))
                failure = failure is null ? error : new AggregateException("Video playback and its carrier both failed.", failure, error);
        }
        try { _session.Dispose(); } catch (Exception error) { cleanupFailures.Add(error); }
        try { await _transport.DisposeAsync().ConfigureAwait(false); } catch (Exception error) { cleanupFailures.Add(error); }
        lock (_lifetimeGate) { _lifetime.Dispose(); _lifetimeDisposed = true; }
        return new(failure, cleanupFailures);
    }

    public async ValueTask DisposeAsync()
    {
        // Cancellation and TCP close are idempotent; every caller joins the same cleanup result.
        var failures = new List<Exception>();
        try { RequestStop(); } catch (Exception error) { failures.Add(error); }
        try { _transport.Close(); } catch (Exception error) { failures.Add(error); }
        var outcome = await Completion.ConfigureAwait(false);
        failures.AddRange(outcome.CleanupFailures);
        // The presentation owner detaches MediaPlayerElement before retiring this player.
        try { await _video.DisposeAsync().ConfigureAwait(false); } catch (Exception error) { failures.Add(error); }
        if (failures.Count > 0)
            throw new AggregateException("Viewer resources could not be fully released.", failures);
    }

    private void RequestStop()
    {
        lock (_lifetimeGate) { if (!_lifetimeDisposed) _lifetime.Cancel(); }
    }
}
