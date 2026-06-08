using System;
using System.Threading.Tasks;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

internal sealed class DiscoveryBrowserActions
{
    private readonly DiscoveryBrowserInputPolicy _inputPolicy;
    private readonly WorkspaceBusyCoordinator _busyCoordinator;
    private readonly IDiscoveryBrowserClient _discoveryBrowserClient;
    private readonly WorkspaceViewStateBuilder _viewStateBuilder;
    private readonly ConnectionWorkspaceResultProjector _connectionResultProjector;
    private readonly Func<string> _getDiscoveryService;
    private readonly Func<string> _getDiscoveryTxtRecord;
    private readonly Func<string> _getDiscoverySearchText;
    private readonly Func<bool> _getIsDiscoveryCompatibilityModeEnabled;
    private readonly Func<int> _getExtendedSearchCountdown;
    private readonly Func<string> _getPairingStatus;
    private readonly Action<int> _setExtendedSearchCountdown;
    private readonly Action<string> _setDiscoveryBrowserStatus;

    public DiscoveryBrowserActions(
        DiscoveryBrowserInputPolicy inputPolicy,
        WorkspaceBusyCoordinator busyCoordinator,
        IDiscoveryBrowserClient discoveryBrowserClient,
        WorkspaceViewStateBuilder viewStateBuilder,
        ConnectionWorkspaceResultProjector connectionResultProjector,
        Func<string> getDiscoveryService,
        Func<string> getDiscoveryTxtRecord,
        Func<string> getDiscoverySearchText,
        Func<bool> getIsDiscoveryCompatibilityModeEnabled,
        Func<int> getExtendedSearchCountdown,
        Func<string> getPairingStatus,
        Action<int> setExtendedSearchCountdown,
        Action<string> setDiscoveryBrowserStatus)
    {
        _inputPolicy = inputPolicy;
        _busyCoordinator = busyCoordinator;
        _discoveryBrowserClient = discoveryBrowserClient;
        _viewStateBuilder = viewStateBuilder;
        _connectionResultProjector = connectionResultProjector;
        _getDiscoveryService = getDiscoveryService;
        _getDiscoveryTxtRecord = getDiscoveryTxtRecord;
        _getDiscoverySearchText = getDiscoverySearchText;
        _getIsDiscoveryCompatibilityModeEnabled = getIsDiscoveryCompatibilityModeEnabled;
        _getExtendedSearchCountdown = getExtendedSearchCountdown;
        _getPairingStatus = getPairingStatus;
        _setExtendedSearchCountdown = setExtendedSearchCountdown;
        _setDiscoveryBrowserStatus = setDiscoveryBrowserStatus;
    }

    public Task StartAsync() =>
        RunAsync(DiscoveryBrowserAction.Start);

    public Task StopAsync() =>
        RunAsync(DiscoveryBrowserAction.Stop);

    public Task RefreshAsync() =>
        RunAsync(DiscoveryBrowserAction.Refresh);

    public Task RunExtendedSearchAsync()
    {
        _setExtendedSearchCountdown(_inputPolicy.ExtendedSearchSeconds);
        return RunAsync(DiscoveryBrowserAction.ExtendedSearch);
    }

    private Task RunAsync(DiscoveryBrowserAction action) =>
        _busyCoordinator.RunAsync(WorkspaceErrorScope.DeviceDiscovery, async () =>
        {
            _setDiscoveryBrowserStatus(_discoveryBrowserClient.BuildPendingStatus(action));
            var snapshot = await _discoveryBrowserClient.BuildReadOnlySnapshotAsync(
                _viewStateBuilder.BuildDiscoveryBrowserRequest(
                    action,
                    _getDiscoveryService(),
                    _getDiscoveryTxtRecord(),
                    _getDiscoverySearchText(),
                    _getIsDiscoveryCompatibilityModeEnabled(),
                    _getExtendedSearchCountdown()));

            _connectionResultProjector.ApplyDiscoveryBrowserResult(
                action,
                snapshot,
                _getPairingStatus());
        });
}
