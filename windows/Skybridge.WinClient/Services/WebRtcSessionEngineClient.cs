using System;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

public sealed class WebRtcSessionEngineClient : IEngineClient, IDisposable
{
    private readonly IEngineClient _innerEngine;
    private readonly IWebRtcHelperLaunchClient _helperLaunchClient;
    private readonly WebRtcSessionEngineOptions _options;
    private readonly SemaphoreSlim _mutex = new(1, 1);

    private EngineConnectionState _state = EngineConnectionState.Disconnected;
    private WebRtcHelperSession? _helperSession;
    private SkyBridgeDataPlaneClient? _dataPlane;
    private WindowsClipboardSyncService? _clipboardSync;
    private bool _disposed;

    public WebRtcSessionEngineClient(
        IEngineClient innerEngine,
        IWebRtcHelperLaunchClient helperLaunchClient,
        WebRtcSessionEngineOptions options)
    {
        _innerEngine = innerEngine ?? throw new ArgumentNullException(nameof(innerEngine));
        _helperLaunchClient = helperLaunchClient ?? throw new ArgumentNullException(nameof(helperLaunchClient));
        _options = options ?? throw new ArgumentNullException(nameof(options));
    }

    public EngineConnectionState State => _state;

    public event EventHandler<EngineConnectionState>? ConnectionStateChanged;

    public async Task ConnectAsync(ConnectionLaunchRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        request.Plan.ValidateForLaunch(request.PairingMaterial);
        ValidateWebRtcSessionLaunch(request);

        await _mutex.WaitAsync().ConfigureAwait(false);
        try
        {
            ThrowIfDisposed();
            if (_state != EngineConnectionState.Disconnected)
            {
                return;
            }

            SetState(EngineConnectionState.Connecting);
            try
            {
                await _innerEngine.ConnectAsync(request).ConfigureAwait(false);
                _helperSession = await _helperLaunchClient
                    .LaunchSessionAsync(new WebRtcHelperSessionRequest(
                        _options.AsAnswerer,
                        _options.PreferredIpcPort))
                    .ConfigureAwait(false);

                _dataPlane = new SkyBridgeDataPlaneClient(
                    _helperSession.IpcPort,
                    ipcToken: _helperSession.IpcToken,
                    autoReconnect: false);
                await _dataPlane.StartAsync().ConfigureAwait(false);

                if (_options.StartClipboardSync)
                {
                    _clipboardSync = WindowsClipboardSyncHook.StartForSession(
                        _dataPlane,
                        request.PairingMaterial.SharedPairingSecret!,
                        FormatHex(request.Plan.TransportBindingDigest),
                        _options.SyncClipboardImages);
                }

                SetState(EngineConnectionState.Connected);
            }
            catch
            {
                await DisposeLiveSessionAsync().ConfigureAwait(false);
                await DisconnectInnerIfNeededAsync().ConfigureAwait(false);
                SetState(EngineConnectionState.Disconnected);
                throw;
            }
        }
        finally
        {
            _mutex.Release();
        }
    }

    public async Task DisconnectAsync()
    {
        await _mutex.WaitAsync().ConfigureAwait(false);
        try
        {
            ThrowIfDisposed();
            if (_state == EngineConnectionState.Disconnected)
            {
                return;
            }

            SetState(EngineConnectionState.ShuttingDown);
            await DisposeLiveSessionAsync().ConfigureAwait(false);
            await _innerEngine.DisconnectAsync().ConfigureAwait(false);
            SetState(EngineConnectionState.Disconnected);
        }
        finally
        {
            _mutex.Release();
        }
    }

    public async Task SendHeartbeatAsync()
    {
        await _mutex.WaitAsync().ConfigureAwait(false);
        try
        {
            ThrowIfDisposed();
            if (_state != EngineConnectionState.Connected)
            {
                throw new InvalidOperationException("Cannot send heartbeat when the WebRTC session engine is not connected.");
            }

            if (_dataPlane is null || !_dataPlane.IsConnected)
            {
                throw new InvalidOperationException("Cannot send heartbeat because the WebRTC data plane is not connected.");
            }

            await _innerEngine.SendHeartbeatAsync().ConfigureAwait(false);
        }
        finally
        {
            _mutex.Release();
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        DisposeLiveSessionAsync().AsTask().GetAwaiter().GetResult();
        if (_innerEngine is IDisposable disposable)
        {
            disposable.Dispose();
        }

        _mutex.Dispose();
        _disposed = true;
        GC.SuppressFinalize(this);
    }

    private void ValidateWebRtcSessionLaunch(ConnectionLaunchRequest request)
    {
        if (request.Plan.AdapterKind != ConnectionLaunchAdapterKind.WebRtcDataChannel)
        {
            throw new InvalidOperationException("WebRTC session engine requires a WebRtcDataChannel adapter.");
        }

        if (request.Plan.TransportKind != CoreTransportKind.WebRtcDataChannel
            || request.Plan.TransportAudit != CoreTransportAuditCode.WebRtcInterop)
        {
            throw new InvalidOperationException("WebRTC session engine requires a Core WebRtcInterop transport plan.");
        }

        if (!request.Plan.IsLiveAdapterReady)
        {
            throw new InvalidOperationException("WebRTC session engine requires a live verified WebRTC adapter before launch.");
        }

        if (_options.StartClipboardSync
            && string.IsNullOrWhiteSpace(request.PairingMaterial.SharedPairingSecret))
        {
            throw new InvalidOperationException("Clipboard sync requires non-public shared pairing secret material; the current pairing envelope only provides peer public-key material.");
        }
    }

    private async ValueTask DisposeLiveSessionAsync()
    {
        _clipboardSync?.Dispose();
        _clipboardSync = null;

        if (_dataPlane is not null)
        {
            await _dataPlane.DisposeAsync().ConfigureAwait(false);
            _dataPlane = null;
        }

        if (_helperSession is not null)
        {
            await _helperSession.DisposeAsync().ConfigureAwait(false);
            _helperSession = null;
        }
    }

    private async Task DisconnectInnerIfNeededAsync()
    {
        if (_innerEngine.State != EngineConnectionState.Disconnected)
        {
            await _innerEngine.DisconnectAsync().ConfigureAwait(false);
        }
    }

    private void ThrowIfDisposed()
    {
        if (_disposed)
        {
            throw new ObjectDisposedException(nameof(WebRtcSessionEngineClient));
        }
    }

    private void SetState(EngineConnectionState state)
    {
        if (_state == state)
        {
            return;
        }

        _state = state;
        ConnectionStateChanged?.Invoke(this, state);
    }

    private static string FormatHex(byte[] bytes)
    {
        var builder = new StringBuilder(bytes.Length * 2);
        foreach (var value in bytes)
        {
            builder.Append(value.ToString("x2"));
        }

        return builder.ToString();
    }
}

public sealed class WebRtcSessionEngineOptions
{
    public WebRtcSessionEngineOptions(
        bool asAnswerer,
        int preferredIpcPort,
        bool startClipboardSync,
        bool syncClipboardImages)
    {
        if (preferredIpcPort is < 0 or > 65535)
        {
            throw new InvalidOperationException("WebRTC session engine IPC port must be 0..65535.");
        }

        AsAnswerer = asAnswerer;
        PreferredIpcPort = preferredIpcPort;
        StartClipboardSync = startClipboardSync;
        SyncClipboardImages = syncClipboardImages;
    }

    public bool AsAnswerer { get; }

    public int PreferredIpcPort { get; }

    public bool StartClipboardSync { get; }

    public bool SyncClipboardImages { get; }
}
