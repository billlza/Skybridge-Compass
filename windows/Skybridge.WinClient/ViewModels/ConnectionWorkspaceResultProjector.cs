using System;
using System.Collections.ObjectModel;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

internal sealed class ConnectionWorkspaceResultProjector
{
    private readonly IConnectionWorkspaceStateClient _connectionWorkspaceStateClient;
    private readonly ConnectionWorkspaceInputCoordinator _connectionInputCoordinator;
    private readonly WorkspaceStatusPatchApplier _statusPatchApplier;
    private readonly WorkspaceCountNotifier _countNotifier;
    private readonly ObservableCollection<DiscoveredPeerView> _discoveredPeers;
    private readonly ObservableCollection<DiscoveryBrowserFactView> _discoveryBrowserFacts;
    private readonly ObservableCollection<ManualConnectionFactView> _manualConnectionFacts;
    private readonly ObservableCollection<CrossNetworkConnectionFactView> _crossNetworkConnectionFacts;
    private readonly ObservableCollection<PairingFactView> _pairingFacts;
    private readonly ObservableCollection<ConnectionPreflightFactView> _connectionPreflightFacts;

    public ConnectionWorkspaceResultProjector(
        IConnectionWorkspaceStateClient connectionWorkspaceStateClient,
        ConnectionWorkspaceInputCoordinator connectionInputCoordinator,
        WorkspaceStatusPatchApplier statusPatchApplier,
        WorkspaceCountNotifier countNotifier,
        ObservableCollection<DiscoveredPeerView> discoveredPeers,
        ObservableCollection<DiscoveryBrowserFactView> discoveryBrowserFacts,
        ObservableCollection<ManualConnectionFactView> manualConnectionFacts,
        ObservableCollection<CrossNetworkConnectionFactView> crossNetworkConnectionFacts,
        ObservableCollection<PairingFactView> pairingFacts,
        ObservableCollection<ConnectionPreflightFactView> connectionPreflightFacts)
    {
        _connectionWorkspaceStateClient = connectionWorkspaceStateClient;
        _connectionInputCoordinator = connectionInputCoordinator;
        _statusPatchApplier = statusPatchApplier;
        _countNotifier = countNotifier;
        _discoveredPeers = discoveredPeers;
        _discoveryBrowserFacts = discoveryBrowserFacts;
        _manualConnectionFacts = manualConnectionFacts;
        _crossNetworkConnectionFacts = crossNetworkConnectionFacts;
        _pairingFacts = pairingFacts;
        _connectionPreflightFacts = connectionPreflightFacts;
    }

    public void ApplyDiscoveryBrowserResult(
        DiscoveryBrowserAction action,
        DiscoveryBrowserSnapshot snapshot,
        string currentPairingStatus)
    {
        WorkspaceCollectionProjector.Replace(
            _discoveryBrowserFacts,
            snapshot.Facts,
            DiscoveryBrowserFactView.FromFact);

        if (action != DiscoveryBrowserAction.Stop)
        {
            _connectionInputCoordinator.ApplyValidatedState(
                _connectionWorkspaceStateClient.BuildDiscoveryBrowserValidatedState(snapshot));
            WorkspaceCollectionProjector.Replace(
                _discoveredPeers,
                snapshot.Peers,
                DiscoveredPeerView.FromCandidate);

            _connectionInputCoordinator.ClearPairingAndPreflight();
            _countNotifier.DiscoveredPeersChanged();
        }

        _countNotifier.DiscoveryBrowserFactsChanged();
        _statusPatchApplier.Apply(
            _connectionWorkspaceStateClient.BuildDiscoveryBrowserResultPatch(
                action,
                snapshot,
                currentPairingStatus));
    }

    public void ApplyManualTargetPrepared(
        ManualConnectionSnapshot snapshot,
        Action<string> setDiscoveryService)
    {
        WorkspaceCollectionProjector.Replace(
            _manualConnectionFacts,
            snapshot.Facts,
            ManualConnectionFactView.FromFact);

        _connectionInputCoordinator.ApplyInputInvalidation();
        _countNotifier.ManualConnectionFactsChanged();
        setDiscoveryService(snapshot.Target.Service);
        _statusPatchApplier.Apply(
            _connectionWorkspaceStateClient.BuildManualTargetPreparedPatch(snapshot));
    }

    public void ApplyCrossNetworkPrepared(
        CrossNetworkConnectionSnapshot snapshot,
        Action<string> setGeneratedCode)
    {
        WorkspaceCollectionProjector.Replace(
            _crossNetworkConnectionFacts,
            snapshot.Facts,
            CrossNetworkConnectionFactView.FromFact);

        if (!string.IsNullOrWhiteSpace(snapshot.GeneratedCode))
        {
            setGeneratedCode(snapshot.GeneratedCode);
        }

        _connectionInputCoordinator.ApplyInputInvalidation();
        _countNotifier.CrossNetworkConnectionFactsChanged();
        _statusPatchApplier.Apply(
            _connectionWorkspaceStateClient.BuildCrossNetworkPreparedPatch(snapshot));
    }

    public void ApplyDiscoveryPeerValidated(
        DiscoveredPeer peer,
        DiscoveryBrowserPeerCandidate candidate)
    {
        _connectionInputCoordinator.ApplyValidatedState(
            _connectionWorkspaceStateClient.BuildDiscoveryPeerValidatedState(peer));
        WorkspaceCollectionProjector.Replace(
            _discoveredPeers,
            new[] { candidate },
            DiscoveredPeerView.FromCandidate);
        _connectionInputCoordinator.ClearPairingAndPreflight();
        _countNotifier.DiscoveredPeersChanged();
        _statusPatchApplier.Apply(
            _connectionWorkspaceStateClient.BuildDiscoveryPeerValidatedPatch(peer));
    }

    public void ApplyPairingValidated(PairingMaterialSnapshot snapshot)
    {
        var material = snapshot.Material;
        _connectionInputCoordinator.ApplyValidatedState(
            _connectionWorkspaceStateClient.BuildPairingValidatedState(
                _connectionInputCoordinator.ValidatedState,
                material));
        _connectionInputCoordinator.ClearConnectionPreflight();
        WorkspaceCollectionProjector.Replace(_pairingFacts, snapshot.Facts, PairingFactView.FromFact);

        _countNotifier.PairingFactsChanged();
        _statusPatchApplier.Apply(
            _connectionWorkspaceStateClient.BuildPairingValidatedPatch(material));
    }

    public void ApplyPreflightPrepared(ConnectionPreflightSnapshot snapshot)
    {
        WorkspaceCollectionProjector.Replace(
            _connectionPreflightFacts,
            snapshot.Facts,
            ConnectionPreflightFactView.FromFact);

        _countNotifier.ConnectionPreflightFactsChanged();
        _statusPatchApplier.Apply(
            _connectionWorkspaceStateClient.BuildPreflightPreparedPatch(snapshot));
    }
}
