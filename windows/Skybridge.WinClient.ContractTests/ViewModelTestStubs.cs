using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

internal sealed class WorkspaceViewStateBuilder
{
    public DiscoveryBrowserRequest BuildDiscoveryBrowserRequest(
        DiscoveryBrowserAction action,
        string discoveryService,
        string discoveryTxtRecord,
        string discoverySearchText,
        bool isDiscoveryCompatibilityModeEnabled,
        int extendedSearchCountdown) =>
        new(
            action,
            discoveryService,
            discoveryTxtRecord,
            discoverySearchText,
            isDiscoveryCompatibilityModeEnabled,
            extendedSearchCountdown);
}

internal sealed class ConnectionWorkspaceResultProjector
{
    public void ApplyDiscoveryBrowserResult(
        DiscoveryBrowserAction action,
        DiscoveryBrowserSnapshot snapshot,
        string currentPairingStatus)
    {
        _ = action;
        ArgumentNullException.ThrowIfNull(snapshot);
        ArgumentNullException.ThrowIfNull(currentPairingStatus);
    }
}
