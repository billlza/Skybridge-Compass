using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

internal sealed class WorkspaceActionSurfaceLoader
{
    private readonly IWorkspaceActionCatalogClient _actionCatalogClient;
    private readonly WorkspaceActionSurfaceTargets _surfaceTargets;
    private readonly WorkspaceCommandRegistry _commandRegistry;

    public WorkspaceActionSurfaceLoader(
        IWorkspaceActionCatalogClient actionCatalogClient,
        WorkspaceActionSurfaceTargets surfaceTargets,
        WorkspaceCommandRegistry commandRegistry)
    {
        _actionCatalogClient = actionCatalogClient;
        _surfaceTargets = surfaceTargets;
        _commandRegistry = commandRegistry;
    }

    public void LoadInitialSurfaces(WorkspaceActionRenderContext renderContext)
    {
        foreach (var surface in _actionCatalogClient.BuildInitialSurfaces())
        {
            LoadSurface(surface, renderContext);
        }
    }

    public void RefreshDynamicSurfaces(WorkspaceActionRenderContext renderContext)
    {
        foreach (var surface in _actionCatalogClient.BuildDynamicRefreshSurfaces())
        {
            LoadSurface(surface, renderContext);
        }
    }

    public void LoadSurface(
        WorkspaceActionSurface surface,
        WorkspaceActionRenderContext renderContext)
    {
        var snapshot = _actionCatalogClient.BuildResolvedSnapshot(
            new WorkspaceActionCatalogRequest(surface),
            renderContext.Gates,
            renderContext.Details);
        var target = _surfaceTargets.Resolve(surface);

        WorkspaceCollectionProjector.Replace(
            target,
            snapshot.Actions,
            action => WorkspaceActionItemView.FromItem(
                action,
                _commandRegistry.Resolve(action.CommandId)));
    }
}
