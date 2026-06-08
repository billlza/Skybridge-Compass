using System;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

internal sealed class TopBarStatusUpdater
{
    private readonly ITopBarStatusClient _topBarStatusClient;
    private readonly WorkspaceActionSurfaceLoader _actionSurfaceLoader;
    private readonly Action<string> _setConnectionStatus;
    private readonly Action<string> _setDiagnosticsStatus;
    private readonly Action<string> _setNotificationsStatus;
    private readonly Action<string> _setThemeStatus;

    public TopBarStatusUpdater(
        ITopBarStatusClient topBarStatusClient,
        WorkspaceActionSurfaceLoader actionSurfaceLoader,
        Action<string> setConnectionStatus,
        Action<string> setDiagnosticsStatus,
        Action<string> setNotificationsStatus,
        Action<string> setThemeStatus)
    {
        _topBarStatusClient = topBarStatusClient;
        _actionSurfaceLoader = actionSurfaceLoader;
        _setConnectionStatus = setConnectionStatus;
        _setDiagnosticsStatus = setDiagnosticsStatus;
        _setNotificationsStatus = setNotificationsStatus;
        _setThemeStatus = setThemeStatus;
    }

    public WorkspaceActionDetailSnapshot BuildActionDetails(TopBarStatusRequest request) =>
        _topBarStatusClient.BuildStatusUpdate(request).ActionDetails;

    public void Refresh(
        TopBarStatusRequest request,
        WorkspaceActionGateSnapshot gates)
    {
        var update = _topBarStatusClient.BuildStatusUpdate(request);

        _setConnectionStatus(update.ResolvedStatus.ConnectionStatus);
        _setDiagnosticsStatus(update.ResolvedStatus.DiagnosticsStatus);
        _setNotificationsStatus(update.ResolvedStatus.NotificationsStatus);
        _setThemeStatus(update.ResolvedStatus.ThemeStatus);
        _actionSurfaceLoader.LoadSurface(
            WorkspaceActionSurface.TopBarActions,
            new WorkspaceActionRenderContext(gates, update.ActionDetails));
    }
}
