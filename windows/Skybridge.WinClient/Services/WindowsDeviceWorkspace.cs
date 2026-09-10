using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.Versioning;
using System.Threading;
using System.Threading.Tasks;

using Skybridge.WinClient.Services.RemoteControl;

namespace Skybridge.WinClient.Services;

/// <summary>Application owner of the existing device identity and native feature sessions.</summary>
[SupportedOSPlatform("windows10.0.19041")]
internal sealed class WindowsDeviceWorkspace : IAsyncDisposable
{
    private readonly string _stateDirectory;
    private readonly string _displayName;
    private readonly SemaphoreSlim _operations = new(1, 1);
    private readonly SemaphoreSlim _controlOperations = new(1, 1);
    private readonly Dictionary<string, LanProductControlSession> _controlSessions = new(StringComparer.Ordinal);
    private readonly object _stateGate = new();
    private RemoteControlIdentityStore? _identity;
    private WindowsRemoteControlHost? _host;
    private Action<WindowsRemoteControlHostStatus>? _hostStatusHandler;
    private CancellationTokenSource? _hostCancellation;
    private Task _hostObservation = Task.CompletedTask;
    private long _generation;
    private volatile bool _disposed;

    public bool HasHost
    {
        get { lock (_stateGate) return _host is not null; }
    }

    public long CurrentGeneration => Interlocked.Read(ref _generation);

    public WindowsDeviceWorkspace()
        : this(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SkyBridge", "remote-control"), Environment.MachineName)
    {
    }

    internal WindowsDeviceWorkspace(string stateDirectory, string displayName)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(stateDirectory);
        ArgumentException.ThrowIfNullOrWhiteSpace(displayName);
        _stateDirectory = stateDirectory;
        _displayName = displayName;
    }

    public event Action<RemoteControlHostWorkspaceStatus>? StatusChanged;

    internal Task<ProductPeerAuthentication> PrepareViewerAuthenticationAsync(DiscoveryBrowserPeerCandidate candidate,
        RemoteControlViewerAccount account, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(candidate);
        ArgumentNullException.ThrowIfNull(account);
        var endpoint = candidate.Routes.RemoteDesktop
            ?? throw new InvalidOperationException("The selected device has no resolved remote-desktop route.");
        return PreparePeerAuthenticationAsync(candidate, account, endpoint, cancellationToken);
    }

    internal Task<ProductPeerAuthentication> PrepareControlAuthenticationAsync(DiscoveryBrowserPeerCandidate candidate,
        RemoteControlViewerAccount account, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(candidate);
        ArgumentNullException.ThrowIfNull(account);
        var endpoint = candidate.Routes.Control
            ?? throw new InvalidOperationException("The selected device has no resolved product-control route.");
        return PreparePeerAuthenticationAsync(candidate, account, endpoint, cancellationToken);
    }

    internal async Task<LanProductControlSession> ConnectControlAsync(DiscoveryBrowserPeerCandidate candidate,
        RemoteControlViewerAccount account, ushort localFileTransferPort, CancellationToken cancellationToken)
    {
        await _controlOperations.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            var deviceId = RemoteControlHandshakeBinding.CanonicalDeviceId(candidate.Peer.DeviceId);
            foreach (var stale in _controlSessions.Where(entry => !entry.Value.IsReady).ToArray())
            {
                await stale.Value.DisposeAsync().ConfigureAwait(false);
                lock (_stateGate) _controlSessions.Remove(stale.Key);
            }
            if (_controlSessions.TryGetValue(deviceId, out var existing))
            {
                // Reuse only if the currently selected identity and both routes still
                // belong to this exact session. Route changes require an explicit disconnect.
                existing.RequireFileTransferRoute(candidate);
                return existing;
            }
            if (_controlSessions.Count >= 8) throw new InvalidOperationException("Eight device sessions are already open. Disconnect before adding another.");
            var authority = await PrepareControlAuthenticationAsync(candidate, account, cancellationToken).ConfigureAwait(false);
            var session = await LanProductControlSession.ConnectAsync(authority, localFileTransferPort, cancellationToken).ConfigureAwait(false);
            lock (_stateGate) _controlSessions.Add(deviceId, session);
            return session;
        }
        finally { _controlOperations.Release(); }
    }

    internal LanProductControlSession RequireIncomingControlSession(string deviceId)
    {
        lock (_stateGate)
        {
            if (_disposed || !_controlSessions.TryGetValue(RemoteControlHandshakeBinding.CanonicalDeviceId(deviceId), out var session) || !session.IsReady)
                throw new InvalidDataException("This sender does not have an established device session.");
            return session;
        }
    }

    internal async Task DisconnectControlSessionsAsync()
    {
        await _controlOperations.WaitAsync().ConfigureAwait(false);
        try
        {
            var failures = new List<Exception>();
            foreach (var entry in _controlSessions.ToArray())
            {
                try
                {
                    await entry.Value.DisposeAsync().ConfigureAwait(false);
                    lock (_stateGate) _controlSessions.Remove(entry.Key);
                }
                catch (Exception failure) { failures.Add(failure); }
            }
            if (failures.Count > 0) throw new AggregateException("Device sessions could not be fully released.", failures);
        }
        finally { _controlOperations.Release(); }
    }

    private async Task<ProductPeerAuthentication> PreparePeerAuthenticationAsync(DiscoveryBrowserPeerCandidate candidate,
        RemoteControlViewerAccount account, DiscoveryPeerEndpoint endpoint, CancellationToken cancellationToken)
    {
        WebRtcProductPqcHandshakeCryptoProvider crypto;
        RemoteControlSecurityIdentity localIdentity;
        RemoteControlPairingMaterial localPairing;
        await _operations.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            _identity ??= await RemoteControlIdentityStore.LoadOrCreateAsync(_stateDirectory, _displayName, cancellationToken).ConfigureAwait(false);
            localIdentity = new(account.AccountDisplayName, account.NebulaId, _identity.PublicMaterial.DeviceId, _identity.PublicMaterial.DeviceName);
            localIdentity.Validate();
            localPairing = _identity.PublicMaterial;
            crypto = _identity.CreateInitiatorCryptoProvider(candidate.Peer.DeviceId, candidate.Peer.PublicKeyFingerprint);
        }
        finally { _operations.Release(); }
        return new(endpoint, new ProductHandshakePeerContext(RemoteControlHandshakeBinding.CanonicalDeviceId(candidate.Peer.DeviceId),
            candidate.Peer.PublicKeyFingerprint), crypto, localIdentity, localPairing);
    }

    public async Task<RemoteControlHostPreparation> PrepareAsync(CancellationToken cancellationToken = default)
    {
        await _operations.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            _identity ??= await RemoteControlIdentityStore.LoadOrCreateAsync(_stateDirectory, _displayName, cancellationToken).ConfigureAwait(false);
            return await BuildPreparationAsync(_identity, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _operations.Release();
        }
    }

    public async Task<RemoteControlHostPreparation> ImportTrustedPeerAsync(RemoteControlPairingMaterial material, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(material);
        await _operations.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (_host is not null)
            {
                throw new InvalidOperationException("Stop remote control before changing the trusted controller list.");
            }

            _identity ??= await RemoteControlIdentityStore.LoadOrCreateAsync(_stateDirectory, _displayName, cancellationToken).ConfigureAwait(false);
            // Complete fallible network discovery before committing authority. A
            // later adapter failure must not report an already trusted peer as unimported.
            var preparation = await BuildPreparationAsync(_identity, cancellationToken).ConfigureAwait(false);
            await _identity.ImportTrustedPeerAsync(material, cancellationToken).ConfigureAwait(false);
            return preparation with { TrustedDeviceNames = _identity.TrustedMaterials.Select(peer => peer.DeviceName).ToArray() };
        }
        finally
        {
            _operations.Release();
        }
    }

    public async Task StartAsync(RemoteControlNetworkInterface selectedInterface, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(selectedInterface);
        await _operations.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (_host is not null)
            {
                throw new InvalidOperationException("Remote control already owns a host. Stop it before starting another.");
            }

            var identity = _identity ?? throw new InvalidOperationException("Remote-control identity has not been prepared.");
            if (identity.TrustedMaterials.Count == 0)
            {
                throw new InvalidOperationException("Import a trusted controller before enabling remote control.");
            }

            var networks = await Task.Run(ReadNetworkInterfaces, cancellationToken).ConfigureAwait(false);
            if (!networks.Contains(selectedInterface))
            {
                throw new InvalidOperationException("The selected network is no longer available. Refresh and select the connected network again.");
            }

            var host = new WindowsRemoteControlHost(identity);
            var generation = Interlocked.Increment(ref _generation);
            Action<WindowsRemoteControlHostStatus> handler = status =>
            {
                lock (_stateGate)
                {
                    if (!ReferenceEquals(_host, host)) return;
                }

                StatusChanged?.Invoke(new RemoteControlHostWorkspaceStatus(generation, status));
            };
            CancellationTokenSource hostCancellation;
            lock (_stateGate)
            {
                hostCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                _hostCancellation = hostCancellation;
                _host = host;
                _hostStatusHandler = handler;
            }

            host.StatusChanged += handler;
            try
            {
                await host.StartAsync(selectedInterface.Address, selectedInterface.InterfaceIndex, hostCancellation.Token).ConfigureAwait(false);
                _hostObservation = ObserveHostCompletionAsync(host, generation, hostCancellation.Token);
            }
            catch (Exception startError)
            {
                try
                {
                    await ReleaseHostAsync(host).ConfigureAwait(false);
                }
                catch (Exception cleanupError)
                {
                    throw new AggregateException("Remote-control start and cleanup failed.", startError, cleanupError);
                }

                throw;
            }
        }
        finally
        {
            _operations.Release();
        }
    }

    public async Task StopAsync(CancellationToken cancellationToken = default)
    {
        lock (_stateGate)
        {
            _hostCancellation?.Cancel();
        }

        await _operations.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_host is { } host)
            {
                await host.StopAsync().ConfigureAwait(false);
                await ReleaseHostAsync(host).ConfigureAwait(false);
            }
        }
        finally
        {
            _operations.Release();
        }
    }

    public Task ApproveSessionAsync(Guid sessionId, bool allowInput, CancellationToken cancellationToken = default) =>
        RunHostOperationAsync(host => host.ApproveSessionAsync(sessionId, allowInput, cancellationToken), cancellationToken);

    public Task TransferInputAsync(Guid sessionId, CancellationToken cancellationToken = default) =>
        RunHostOperationAsync(host => host.TransferInputAsync(sessionId, cancellationToken), cancellationToken);

    public Task DisconnectSessionAsync(Guid sessionId, CancellationToken cancellationToken = default) =>
        RunHostOperationAsync(host =>
        {
            host.DisconnectSession(sessionId);
            return Task.CompletedTask;
        }, cancellationToken);

    private async Task RunHostOperationAsync(Func<WindowsRemoteControlHost, Task> operation, CancellationToken cancellationToken)
    {
        await _operations.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            var host = _host ?? throw new InvalidOperationException("Remote access is not enabled.");
            await operation(host).ConfigureAwait(false);
        }
        finally { _operations.Release(); }
    }

    public async ValueTask DisposeAsync()
    {
        _disposed = true;
        await DisconnectControlSessionsAsync().ConfigureAwait(false);
        await StopAsync().ConfigureAwait(false);
        await _operations.WaitAsync().ConfigureAwait(false);
        try
        {
            _identity?.Dispose();
            _identity = null;
        }
        finally
        {
            _operations.Release();
        }
    }

    private async Task ReleaseHostAsync(WindowsRemoteControlHost host)
    {
        await host.DisposeAsync().ConfigureAwait(false);
        await _hostObservation.ConfigureAwait(false);
        lock (_stateGate)
        {
            if (!ReferenceEquals(_host, host)) return;
            host.StatusChanged -= _hostStatusHandler;
            _hostStatusHandler = null;
            _host = null;
            Interlocked.Increment(ref _generation);
            _hostObservation = Task.CompletedTask;
            _hostCancellation?.Dispose();
            _hostCancellation = null;
        }
    }

    private async Task ObserveHostCompletionAsync(WindowsRemoteControlHost host, long generation, CancellationToken cancellationToken)
    {
        try
        {
            await host.Completion.ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            // An explicit stop cancels the listener and all session consumers.
        }
        catch (Exception error)
        {
            lock (_stateGate)
            {
                if (!ReferenceEquals(_host, host)) return;
            }

            WindowsRuntimeLog.Write(WindowsLogLevel.Error, "RemoteControlHost", error.Message);
            StatusChanged?.Invoke(new RemoteControlHostWorkspaceStatus(generation,
                host.CurrentStatus with { State = WindowsRemoteControlHostState.Failed, Message = error.Message }));
        }
    }

    private static async Task<RemoteControlHostPreparation> BuildPreparationAsync(RemoteControlIdentityStore identity, CancellationToken cancellationToken)
    {
        var networks = await Task.Run(ReadNetworkInterfaces, cancellationToken).ConfigureAwait(false);
        return new RemoteControlHostPreparation(
            identity.PublicMaterial.ToJson(),
            identity.PublicMaterial.DeviceName,
            identity.PublicMaterial.ProtocolPublicKeyFingerprint,
            identity.TrustedMaterials.Select(material => material.DeviceName).ToArray(),
            networks);
    }

    private static IReadOnlyList<RemoteControlNetworkInterface> ReadNetworkInterfaces()
    {
        var choices = new List<RemoteControlNetworkInterface>();
        foreach (var network in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (network.OperationalStatus != OperationalStatus.Up ||
                network.NetworkInterfaceType is NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel ||
                !network.Supports(NetworkInterfaceComponent.IPv4))
            {
                continue;
            }

            var properties = network.GetIPProperties();
            var ipv4 = properties.GetIPv4Properties() ?? throw new InvalidOperationException("An active IPv4 network has no interface properties.");
            foreach (var unicast in properties.UnicastAddresses)
            {
                if (unicast.Address.AddressFamily != AddressFamily.InterNetwork ||
                    IPAddress.IsLoopback(unicast.Address) || unicast.Address.Equals(IPAddress.Any))
                {
                    continue;
                }

                choices.Add(new RemoteControlNetworkInterface(network.Id, network.Name, unicast.Address, checked((uint)ipv4.Index)));
            }
        }

        return choices.OrderBy(choice => choice.Name, StringComparer.CurrentCulture).ThenBy(choice => choice.Address.ToString(), StringComparer.Ordinal).ToArray();
    }
}
