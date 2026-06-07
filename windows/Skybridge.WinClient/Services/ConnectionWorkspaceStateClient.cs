namespace Skybridge.WinClient.Services;

public interface IConnectionWorkspaceStateClient
{
    ConnectionWorkspaceStatusPatch BuildInputResetPatch(ConnectionWorkspaceResetReason reason);

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
    private const string Ready = "Ready";

    public ConnectionWorkspaceStatusPatch BuildInputResetPatch(ConnectionWorkspaceResetReason reason) =>
        reason switch
        {
            ConnectionWorkspaceResetReason.DiscoveryInputChanged => new ConnectionWorkspaceStatusPatch(
                DiscoveryStatus: Ready,
                DiscoveryBrowserStatus: Ready,
                PairingStatus: Ready,
                ConnectionPreflightStatus: Ready,
                IsDiscoveryScanning: false),
            ConnectionWorkspaceResetReason.ManualTargetInputChanged => new ConnectionWorkspaceStatusPatch(
                ManualConnectionStatus: Ready),
            ConnectionWorkspaceResetReason.CrossNetworkInputChanged => new ConnectionWorkspaceStatusPatch(
                CrossNetworkStatus: Ready),
            ConnectionWorkspaceResetReason.PairingInputChanged => new ConnectionWorkspaceStatusPatch(
                PairingStatus: Ready,
                ConnectionPreflightStatus: Ready),
            ConnectionWorkspaceResetReason.PreflightCleared => new ConnectionWorkspaceStatusPatch(
                ConnectionPreflightStatus: Ready),
            _ => new ConnectionWorkspaceStatusPatch()
        };

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
            PairingStatus: action == DiscoveryBrowserAction.Stop ? currentPairingStatus : Ready,
            IsDiscoveryScanning: snapshot.IsScanning,
            StatusMessage: "Discovery browser snapshot updated");

    public ConnectionWorkspaceStatusPatch BuildManualTargetPreparedPatch(ManualConnectionSnapshot snapshot) =>
        new(
            DiscoveryStatus: "Manual target prepared",
            ManualConnectionStatus: $"Prepared {snapshot.Target.Host}:{snapshot.Target.Port}",
            PairingStatus: Ready,
            StatusMessage: "Manual connection target prepared");

    public ConnectionWorkspaceStatusPatch BuildCrossNetworkPreparedPatch(CrossNetworkConnectionSnapshot snapshot) =>
        new(
            DiscoveryStatus: "Cross-network envelope prepared",
            CrossNetworkStatus: snapshot.Status,
            PairingStatus: Ready,
            StatusMessage: "Cross-network connection snapshot updated");

    public ConnectionWorkspaceStatusPatch BuildDiscoveryPeerValidatedPatch(DiscoveredPeer peer) =>
        new(
            DiscoveryStatus: $"Validated {peer.DeviceId}",
            PairingStatus: Ready,
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
