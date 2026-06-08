using System;
using System.Threading.Tasks;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

internal sealed class SystemMonitorWorkspaceActions
{
    private readonly WorkspaceBusyCoordinator _busyCoordinator;
    private readonly ISystemMonitorWorkspaceClient _systemMonitorClient;
    private readonly Action<string> _setSystemMonitorStatus;
    private readonly Action<string> _setStatusMessage;

    public SystemMonitorWorkspaceActions(
        WorkspaceBusyCoordinator busyCoordinator,
        ISystemMonitorWorkspaceClient systemMonitorClient,
        Action<string> setSystemMonitorStatus,
        Action<string> setStatusMessage)
    {
        _busyCoordinator = busyCoordinator ?? throw new ArgumentNullException(nameof(busyCoordinator));
        _systemMonitorClient = systemMonitorClient ?? throw new ArgumentNullException(nameof(systemMonitorClient));
        _setSystemMonitorStatus = setSystemMonitorStatus ?? throw new ArgumentNullException(nameof(setSystemMonitorStatus));
        _setStatusMessage = setStatusMessage ?? throw new ArgumentNullException(nameof(setStatusMessage));
    }

    public Task StartMonitoringAsync() =>
        RunAsync(
            _systemMonitorClient.BuildStartMonitoringPendingStatus,
            _systemMonitorClient.BuildStartMonitoringActionAsync);

    public Task StopMonitoringAsync() =>
        RunAsync(
            _systemMonitorClient.BuildStopMonitoringPendingStatus,
            _systemMonitorClient.BuildStopMonitoringActionAsync);

    public Task EnableAdvancedMonitoringAsync() =>
        RunAsync(
            _systemMonitorClient.BuildAdvancedMonitoringPendingStatus,
            _systemMonitorClient.BuildAdvancedMonitoringActionAsync);

    private Task RunAsync(
        Func<string> buildPendingStatus,
        Func<Task<SystemMonitorWorkspaceActionResult>> buildActionAsync) =>
        _busyCoordinator.RunAsync(
            WorkspaceErrorScope.SystemMonitor,
            async () =>
            {
                _setSystemMonitorStatus(buildPendingStatus());
                var result = await buildActionAsync();
                _setSystemMonitorStatus(result.Status);
                _setStatusMessage(result.Message);
            });
}
