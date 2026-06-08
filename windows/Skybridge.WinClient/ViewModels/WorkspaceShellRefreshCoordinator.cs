using System;
using System.Collections.Generic;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

internal sealed class WorkspaceShellRefreshCoordinator
{
    private readonly WorkspaceCommandRegistry _commandRegistry;
    private readonly WorkspaceActionSurfaceLoader _actionSurfaceLoader;
    private readonly WorkspaceActionRenderContextBuilder _renderContextBuilder;
    private readonly DashboardMetricsUpdater _dashboardMetricsUpdater;
    private readonly TopBarStatusUpdater _topBarStatusUpdater;
    private readonly Func<DashboardMetricsRequest> _buildDashboardMetricsRequest;
    private readonly Func<WorkspaceActionRenderState> _buildActionRenderState;
    private readonly Action<string> _notifyPropertyChanged;
    private readonly IReadOnlyList<string> _selectedFeaturePropertyNames;
    private readonly string _connectionStatusPropertyName;

    public WorkspaceShellRefreshCoordinator(
        WorkspaceCommandRegistry commandRegistry,
        WorkspaceActionSurfaceLoader actionSurfaceLoader,
        WorkspaceActionRenderContextBuilder renderContextBuilder,
        DashboardMetricsUpdater dashboardMetricsUpdater,
        TopBarStatusUpdater topBarStatusUpdater,
        Func<DashboardMetricsRequest> buildDashboardMetricsRequest,
        Func<WorkspaceActionRenderState> buildActionRenderState,
        Action<string> notifyPropertyChanged,
        IReadOnlyList<string> selectedFeaturePropertyNames,
        string connectionStatusPropertyName)
    {
        _commandRegistry = commandRegistry;
        _actionSurfaceLoader = actionSurfaceLoader;
        _renderContextBuilder = renderContextBuilder;
        _dashboardMetricsUpdater = dashboardMetricsUpdater;
        _topBarStatusUpdater = topBarStatusUpdater;
        _buildDashboardMetricsRequest = buildDashboardMetricsRequest;
        _buildActionRenderState = buildActionRenderState;
        _notifyPropertyChanged = notifyPropertyChanged;
        _selectedFeaturePropertyNames = selectedFeaturePropertyNames;
        _connectionStatusPropertyName = connectionStatusPropertyName;
    }

    public void RefreshCommandStates()
    {
        _commandRegistry.RefreshAll();
        RefreshDynamicWorkspaceActionStates();
    }

    public void ApplyWorkspaceInputChange(Action? resetInput = null)
    {
        resetInput?.Invoke();
        RefreshCommandStates();
    }

    public void RefreshSelectedFeatureState()
    {
        foreach (var propertyName in _selectedFeaturePropertyNames)
        {
            _notifyPropertyChanged(propertyName);
        }

        RefreshTopBarStatus();
        RefreshCommandStates();
    }

    public void RefreshConnectionState()
    {
        _notifyPropertyChanged(_connectionStatusPropertyName);
        RefreshShellRuntimeState();
    }

    public void RefreshShellRuntimeState()
    {
        RefreshDashboardMetrics();
        RefreshTopBarStatus();
        RefreshCommandStates();
    }

    public void LoadWorkspaceActions()
    {
        _actionSurfaceLoader.LoadInitialSurfaces(
            _renderContextBuilder.BuildContext(_buildActionRenderState()));
    }

    public void RefreshTopBarStatus()
    {
        var renderState = _buildActionRenderState();
        _topBarStatusUpdater.Refresh(
            _renderContextBuilder.BuildTopBarStatusRequest(renderState),
            _renderContextBuilder.BuildGateSnapshot(renderState));
    }

    public void RefreshDashboardMetrics()
    {
        _dashboardMetricsUpdater.Refresh(_buildDashboardMetricsRequest());
    }

    private void RefreshDynamicWorkspaceActionStates()
    {
        _actionSurfaceLoader.RefreshDynamicSurfaces(
            _renderContextBuilder.BuildContext(_buildActionRenderState()));
    }
}
