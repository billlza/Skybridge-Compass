namespace Skybridge.WinClient.Services;

public interface IConnectionWorkspaceStateClient
{
    ConnectionWorkspaceStatusPatch BuildInitialStatusPatch();

    ConnectionWorkspaceStatusPatch BuildInputResetPatch(ConnectionWorkspaceResetReason reason);

    ConnectionWorkspaceValidatedState BuildInputInvalidatedState();

    ConnectionWorkspaceValidatedState BuildDiscoveryBrowserValidatedState(
        DiscoveryBrowserSnapshot snapshot);

    ConnectionWorkspaceValidatedState BuildDiscoveryPeerValidatedState(
        DiscoveredPeer peer);

    ConnectionWorkspaceValidatedState BuildPairingValidatedState(
        ConnectionWorkspaceValidatedState currentState,
        PairingMaterial material);

    ConnectionWorkspaceValidatedState BuildPairingInputResetState(
        ConnectionWorkspaceValidatedState currentState);

    ConnectionWorkspaceStatusPatch BuildDiscoveryBrowserResultPatch(
        DiscoveryBrowserAction action,
        DiscoveryBrowserSnapshot snapshot,
        string currentPairingStatus);

    ConnectionWorkspaceStatusPatch BuildManualTargetPreparedPatch(ManualConnectionSnapshot snapshot);

    ConnectionWorkspaceStatusPatch BuildCrossNetworkPreparedPatch(CrossNetworkConnectionSnapshot snapshot);

    ConnectionWorkspaceStatusPatch BuildDiscoveryPeerValidatedPatch(DiscoveredPeer peer);

    ConnectionWorkspaceStatusPatch BuildPairingValidatedPatch(PairingMaterial material);

    ConnectionWorkspacePreflightReadiness BuildPreflightReadiness(
        DiscoveredPeer? discoveredPeer,
        PairingMaterial? pairingMaterial);

    bool CanPreparePreflight(
        DiscoveredPeer? discoveredPeer,
        PairingMaterial? pairingMaterial);

    ConnectionWorkspaceStatusPatch BuildPreflightPreparedPatch(ConnectionPreflightSnapshot snapshot);
}

public sealed class ConnectionWorkspaceStateClient : IConnectionWorkspaceStateClient
{
    public static string DefaultReadyStatus { get; } = "Ready";

    public ConnectionWorkspaceStatusPatch BuildInitialStatusPatch() =>
        new(
            DiscoveryStatus: DefaultReadyStatus,
            DiscoveryBrowserStatus: DefaultReadyStatus,
            ManualConnectionStatus: DefaultReadyStatus,
            CrossNetworkStatus: DefaultReadyStatus,
            PairingStatus: DefaultReadyStatus,
            ConnectionPreflightStatus: DefaultReadyStatus,
            IsDiscoveryScanning: false);

    public ConnectionWorkspaceStatusPatch BuildInputResetPatch(ConnectionWorkspaceResetReason reason) =>
        reason switch
        {
            ConnectionWorkspaceResetReason.DiscoveryInputChanged => new ConnectionWorkspaceStatusPatch(
                DiscoveryStatus: DefaultReadyStatus,
                DiscoveryBrowserStatus: DefaultReadyStatus,
                PairingStatus: DefaultReadyStatus,
                ConnectionPreflightStatus: DefaultReadyStatus,
                IsDiscoveryScanning: false),
            ConnectionWorkspaceResetReason.ManualTargetInputChanged => new ConnectionWorkspaceStatusPatch(
                ManualConnectionStatus: DefaultReadyStatus),
            ConnectionWorkspaceResetReason.CrossNetworkInputChanged => new ConnectionWorkspaceStatusPatch(
                CrossNetworkStatus: DefaultReadyStatus),
            ConnectionWorkspaceResetReason.PairingInputChanged => new ConnectionWorkspaceStatusPatch(
                PairingStatus: DefaultReadyStatus,
                ConnectionPreflightStatus: DefaultReadyStatus),
            ConnectionWorkspaceResetReason.PreflightCleared => new ConnectionWorkspaceStatusPatch(
                ConnectionPreflightStatus: DefaultReadyStatus),
            _ => new ConnectionWorkspaceStatusPatch()
        };

    public ConnectionWorkspaceValidatedState BuildInputInvalidatedState() =>
        new(null, null);

    public ConnectionWorkspaceValidatedState BuildDiscoveryBrowserValidatedState(
        DiscoveryBrowserSnapshot snapshot) =>
        new(
            snapshot.Peers.Count == 1 ? snapshot.Peers[0].Peer : null,
            null);

    public ConnectionWorkspaceValidatedState BuildDiscoveryPeerValidatedState(
        DiscoveredPeer peer) =>
        new(peer, null);

    public ConnectionWorkspaceValidatedState BuildPairingValidatedState(
        ConnectionWorkspaceValidatedState currentState,
        PairingMaterial material) =>
        new(currentState.DiscoveredPeer, material);

    public ConnectionWorkspaceValidatedState BuildPairingInputResetState(
        ConnectionWorkspaceValidatedState currentState) =>
        new(currentState.DiscoveredPeer, null);

    public ConnectionWorkspaceStatusPatch BuildDiscoveryBrowserResultPatch(
        DiscoveryBrowserAction action,
        DiscoveryBrowserSnapshot snapshot,
        string currentPairingStatus) =>
        new(
            DiscoveryStatus: action == DiscoveryBrowserAction.Stop
                ? "Discovery stopped"
                : snapshot.Peers.Count == 0
                    ? "No Core-validated peers"
                    : $"Validated {snapshot.Peers.Count} peer(s)",
            DiscoveryBrowserStatus: snapshot.IsScanning
                ? $"Scanning {snapshot.CapturedAt:HH:mm:ss} UTC"
                : $"Stopped {snapshot.CapturedAt:HH:mm:ss} UTC",
            PairingStatus: action == DiscoveryBrowserAction.Stop ? currentPairingStatus : DefaultReadyStatus,
            IsDiscoveryScanning: snapshot.IsScanning,
            StatusMessage: "Discovery browser snapshot updated");

    public ConnectionWorkspaceStatusPatch BuildManualTargetPreparedPatch(ManualConnectionSnapshot snapshot) =>
        new(
            DiscoveryStatus: "Manual target prepared",
            ManualConnectionStatus: $"Prepared {snapshot.Target.Host}:{snapshot.Target.Port}",
            PairingStatus: DefaultReadyStatus,
            StatusMessage: "Manual connection target prepared");

    public ConnectionWorkspaceStatusPatch BuildCrossNetworkPreparedPatch(CrossNetworkConnectionSnapshot snapshot) =>
        new(
            DiscoveryStatus: "Cross-network envelope prepared",
            CrossNetworkStatus: snapshot.Status,
            PairingStatus: DefaultReadyStatus,
            StatusMessage: "Cross-network connection snapshot updated");

    public ConnectionWorkspaceStatusPatch BuildDiscoveryPeerValidatedPatch(DiscoveredPeer peer) =>
        new(
            DiscoveryStatus: $"Validated {peer.DeviceId}",
            PairingStatus: DefaultReadyStatus,
            StatusMessage: "Discovery advertisement validated");

    public ConnectionWorkspaceStatusPatch BuildPairingValidatedPatch(PairingMaterial material) =>
        new(
            PairingStatus: $"Validated {material.DeviceId}",
            StatusMessage: "Pairing code validated");

    public ConnectionWorkspacePreflightReadiness BuildPreflightReadiness(
        DiscoveredPeer? discoveredPeer,
        PairingMaterial? pairingMaterial)
    {
        if (discoveredPeer is null)
        {
            return new(false, "Parse a Core-validated discovery TXT record before connection preflight.");
        }

        if (pairingMaterial is null)
        {
            return new(false, "Validate pairing material before connection preflight.");
        }

        return new(true, "");
    }

    public bool CanPreparePreflight(
        DiscoveredPeer? discoveredPeer,
        PairingMaterial? pairingMaterial) =>
        BuildPreflightReadiness(discoveredPeer, pairingMaterial).IsReady;

    public ConnectionWorkspaceStatusPatch BuildPreflightPreparedPatch(ConnectionPreflightSnapshot snapshot) =>
        new(
            ConnectionPreflightStatus: $"Prepared {snapshot.CapturedAt:HH:mm:ss} UTC",
            StatusMessage: "Connection preflight prepared");
}

public enum ConnectionWorkspaceResetReason
{
    DiscoveryInputChanged,
    ManualTargetInputChanged,
    CrossNetworkInputChanged,
    PairingInputChanged,
    PreflightCleared
}

public sealed record ConnectionWorkspaceStatusPatch(
    string? DiscoveryStatus = null,
    string? DiscoveryBrowserStatus = null,
    string? ManualConnectionStatus = null,
    string? CrossNetworkStatus = null,
    string? PairingStatus = null,
    string? ConnectionPreflightStatus = null,
    string? StatusMessage = null,
    bool? IsDiscoveryScanning = null);

public sealed record ConnectionWorkspacePreflightReadiness(
    bool IsReady,
    string ErrorMessage);

public sealed record ConnectionWorkspaceValidatedState(
    DiscoveredPeer? DiscoveredPeer,
    PairingMaterial? PairingMaterial);
