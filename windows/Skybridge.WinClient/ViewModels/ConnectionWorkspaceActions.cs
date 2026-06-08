using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

internal sealed class ConnectionWorkspaceActions
{
    private readonly WorkspaceBusyCoordinator _busyCoordinator;
    private readonly IManualConnectionClient _manualConnectionClient;
    private readonly IDiscoveryClient _discoveryClient;
    private readonly IDiscoveryBrowserClient _discoveryBrowserClient;
    private readonly IPairingMaterialClient _pairingMaterialClient;
    private readonly IConnectionPreflightClient _connectionPreflightClient;
    private readonly IConnectionWorkspaceStateClient _connectionWorkspaceStateClient;
    private readonly WorkspaceViewStateBuilder _viewStateBuilder;
    private readonly ConnectionWorkspaceInputCoordinator _connectionInputCoordinator;
    private readonly ConnectionWorkspaceResultProjector _connectionResultProjector;
    private readonly IList<DiscoveredPeerView> _discoveredPeers;
    private readonly Func<string> _getManualConnectionHost;
    private readonly Func<string> _getManualConnectionPort;
    private readonly Func<string> _getManualConnectionCode;
    private readonly Func<string> _getDiscoveryService;
    private readonly Func<string> _getDiscoveryTxtRecord;
    private readonly Func<string> _getPairingConnectionCode;
    private readonly Action<string> _setManualConnectionStatus;
    private readonly Action<string> _setDiscoveryStatus;
    private readonly Action<string> _setPairingStatus;
    private readonly Action<string> _setConnectionPreflightStatus;
    private readonly Action<string> _setDiscoveryService;

    public ConnectionWorkspaceActions(
        WorkspaceBusyCoordinator busyCoordinator,
        IManualConnectionClient manualConnectionClient,
        IDiscoveryClient discoveryClient,
        IDiscoveryBrowserClient discoveryBrowserClient,
        IPairingMaterialClient pairingMaterialClient,
        IConnectionPreflightClient connectionPreflightClient,
        IConnectionWorkspaceStateClient connectionWorkspaceStateClient,
        WorkspaceViewStateBuilder viewStateBuilder,
        ConnectionWorkspaceInputCoordinator connectionInputCoordinator,
        ConnectionWorkspaceResultProjector connectionResultProjector,
        IList<DiscoveredPeerView> discoveredPeers,
        Func<string> getManualConnectionHost,
        Func<string> getManualConnectionPort,
        Func<string> getManualConnectionCode,
        Func<string> getDiscoveryService,
        Func<string> getDiscoveryTxtRecord,
        Func<string> getPairingConnectionCode,
        Action<string> setManualConnectionStatus,
        Action<string> setDiscoveryStatus,
        Action<string> setPairingStatus,
        Action<string> setConnectionPreflightStatus,
        Action<string> setDiscoveryService)
    {
        _busyCoordinator = busyCoordinator;
        _manualConnectionClient = manualConnectionClient;
        _discoveryClient = discoveryClient;
        _discoveryBrowserClient = discoveryBrowserClient;
        _pairingMaterialClient = pairingMaterialClient;
        _connectionPreflightClient = connectionPreflightClient;
        _connectionWorkspaceStateClient = connectionWorkspaceStateClient;
        _viewStateBuilder = viewStateBuilder;
        _connectionInputCoordinator = connectionInputCoordinator;
        _connectionResultProjector = connectionResultProjector;
        _discoveredPeers = discoveredPeers;
        _getManualConnectionHost = getManualConnectionHost;
        _getManualConnectionPort = getManualConnectionPort;
        _getManualConnectionCode = getManualConnectionCode;
        _getDiscoveryService = getDiscoveryService;
        _getDiscoveryTxtRecord = getDiscoveryTxtRecord;
        _getPairingConnectionCode = getPairingConnectionCode;
        _setManualConnectionStatus = setManualConnectionStatus;
        _setDiscoveryStatus = setDiscoveryStatus;
        _setPairingStatus = setPairingStatus;
        _setConnectionPreflightStatus = setConnectionPreflightStatus;
        _setDiscoveryService = setDiscoveryService;
    }

    public Task PrepareManualConnectionAsync() =>
        RunAsync(async () =>
        {
            _setManualConnectionStatus(_manualConnectionClient.BuildPendingStatus());
            var snapshot = await _manualConnectionClient.BuildReadOnlySnapshotAsync(
                _viewStateBuilder.BuildManualConnectionRequest(
                    _getManualConnectionHost(),
                    _getManualConnectionPort(),
                    _getManualConnectionCode()));
            _connectionResultProjector.ApplyManualTargetPrepared(
                snapshot,
                _setDiscoveryService);
        });

    public Task ParseAdvertisementAsync() =>
        RunAsync(async () =>
        {
            _setDiscoveryStatus(_discoveryClient.BuildPendingStatus());
            var peer = await _discoveryClient.ParseAdvertisementAsync(
                _getDiscoveryService(),
                _getDiscoveryTxtRecord());
            _connectionResultProjector.ApplyDiscoveryPeerValidated(
                peer,
                _discoveryBrowserClient.BuildPeerCandidate(peer));
        });

    public Task ValidatePairingCodeAsync() =>
        RunAsync(async () =>
        {
            _setPairingStatus(_pairingMaterialClient.BuildPendingStatus());
            var expectedFingerprint = _discoveredPeers.Count == 1
                ? _discoveredPeers[0].PublicKeyFingerprint
                : null;
            var snapshot = await _pairingMaterialClient.BuildReadOnlySnapshotAsync(
                _getPairingConnectionCode(),
                expectedFingerprint);
            _connectionResultProjector.ApplyPairingValidated(snapshot);
        });

    public Task PrepareConnectionAsync() =>
        RunAsync(async () =>
        {
            var discoveredPeer = _connectionInputCoordinator.ValidatedState.DiscoveredPeer;
            var pairingMaterial = _connectionInputCoordinator.ValidatedState.PairingMaterial;
            var readiness = _connectionWorkspaceStateClient.BuildPreflightReadiness(
                discoveredPeer,
                pairingMaterial);
            if (!readiness.IsReady)
            {
                throw new InvalidOperationException(readiness.ErrorMessage);
            }

            _setConnectionPreflightStatus(_connectionPreflightClient.BuildPendingStatus());
            var snapshot = await _connectionPreflightClient.BuildReadOnlySnapshotAsync(
                discoveredPeer!,
                pairingMaterial!);
            _connectionResultProjector.ApplyPreflightPrepared(snapshot);
        });

    private Task RunAsync(Func<Task> action) =>
        _busyCoordinator.RunAsync(WorkspaceErrorScope.DeviceDiscovery, action);
}
