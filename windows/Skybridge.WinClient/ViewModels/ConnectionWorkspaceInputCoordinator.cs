using System.Collections.ObjectModel;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

internal sealed class ConnectionWorkspaceInputCoordinator
{
    private readonly IConnectionWorkspaceStateClient _connectionWorkspaceStateClient;
    private readonly WorkspaceStatusPatchApplier _statusPatchApplier;
    private readonly WorkspaceCountNotifier _countNotifier;
    private readonly ObservableCollection<DiscoveredPeerView> _discoveredPeers;
    private readonly ObservableCollection<DiscoveryBrowserFactView> _discoveryBrowserFacts;
    private readonly ObservableCollection<ManualConnectionFactView> _manualConnectionFacts;
    private readonly ObservableCollection<PairingFactView> _pairingFacts;
    private readonly ObservableCollection<ConnectionPreflightFactView> _connectionPreflightFacts;

    public ConnectionWorkspaceInputCoordinator(
        IConnectionWorkspaceStateClient connectionWorkspaceStateClient,
        WorkspaceStatusPatchApplier statusPatchApplier,
        WorkspaceCountNotifier countNotifier,
        ObservableCollection<DiscoveredPeerView> discoveredPeers,
        ObservableCollection<DiscoveryBrowserFactView> discoveryBrowserFacts,
        ObservableCollection<ManualConnectionFactView> manualConnectionFacts,
        ObservableCollection<PairingFactView> pairingFacts,
        ObservableCollection<ConnectionPreflightFactView> connectionPreflightFacts)
    {
        _connectionWorkspaceStateClient = connectionWorkspaceStateClient;
        _statusPatchApplier = statusPatchApplier;
        _countNotifier = countNotifier;
        _discoveredPeers = discoveredPeers;
        _discoveryBrowserFacts = discoveryBrowserFacts;
        _manualConnectionFacts = manualConnectionFacts;
        _pairingFacts = pairingFacts;
        _connectionPreflightFacts = connectionPreflightFacts;
        ValidatedState = _connectionWorkspaceStateClient.BuildInputInvalidatedState();
    }

    public ConnectionWorkspaceValidatedState ValidatedState { get; private set; }

    public void ApplyValidatedState(ConnectionWorkspaceValidatedState state)
    {
        ValidatedState = state;
    }

    public void ApplyInputInvalidation()
    {
        ApplyValidatedState(_connectionWorkspaceStateClient.BuildInputInvalidatedState());
        ClearPairingAndPreflight();
    }

    public void ClearPairingAndPreflight()
    {
        _pairingFacts.Clear();
        ClearConnectionPreflight();
        _countNotifier.PairingFactsChanged();
    }

    public void InvalidatePairingAndPreflight()
    {
        ApplyValidatedState(_connectionWorkspaceStateClient.BuildInputInvalidatedState());
        _discoveredPeers.Clear();
        _discoveryBrowserFacts.Clear();
        ClearPairingAndPreflight();
        _statusPatchApplier.Apply(
            _connectionWorkspaceStateClient.BuildInputResetPatch(
                ConnectionWorkspaceResetReason.DiscoveryInputChanged));
        _countNotifier.DiscoveredPeersChanged();
        _countNotifier.DiscoveryBrowserFactsChanged();
    }

    public void ResetManualConnectionInput()
    {
        _manualConnectionFacts.Clear();
        _statusPatchApplier.Apply(
            _connectionWorkspaceStateClient.BuildInputResetPatch(
                ConnectionWorkspaceResetReason.ManualTargetInputChanged));
        _countNotifier.ManualConnectionFactsChanged();
    }

    public void ResetCrossNetworkInput()
    {
        _statusPatchApplier.Apply(
            _connectionWorkspaceStateClient.BuildInputResetPatch(
                ConnectionWorkspaceResetReason.CrossNetworkInputChanged));
    }

    public void ResetPairingInput()
    {
        ApplyValidatedState(
            _connectionWorkspaceStateClient.BuildPairingInputResetState(ValidatedState));
        ClearPairingAndPreflight();
        _statusPatchApplier.Apply(
            _connectionWorkspaceStateClient.BuildInputResetPatch(
                ConnectionWorkspaceResetReason.PairingInputChanged));
    }

    public void ClearConnectionPreflight()
    {
        _connectionPreflightFacts.Clear();
        _statusPatchApplier.Apply(
            _connectionWorkspaceStateClient.BuildInputResetPatch(
                ConnectionWorkspaceResetReason.PreflightCleared));
        _countNotifier.ConnectionPreflightFactsChanged();
    }
}
