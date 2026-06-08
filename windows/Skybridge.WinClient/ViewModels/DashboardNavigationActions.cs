using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

internal sealed class DashboardNavigationActions
{
    private readonly Func<IReadOnlyList<FeatureEntry>> _getNavigationItems;
    private readonly Action<FeatureEntry> _selectFeature;

    public DashboardNavigationActions(
        Func<IReadOnlyList<FeatureEntry>> getNavigationItems,
        Action<FeatureEntry> selectFeature)
    {
        _getNavigationItems = getNavigationItems;
        _selectFeature = selectFeature;
    }

    public Task SelectDeviceDiscoveryAsync() =>
        SelectAsync(FeatureEntryId.DeviceDiscovery);

    public Task SelectFileTransferAsync() =>
        SelectAsync(FeatureEntryId.FileTransfer);

    public Task SelectSystemMonitorAsync() =>
        SelectAsync(FeatureEntryId.SystemMonitor);

    public Task SelectSettingsAsync() =>
        SelectAsync(FeatureEntryId.Settings);

    private Task SelectAsync(FeatureEntryId featureId)
    {
        _selectFeature(ResolveFeature(featureId));

        return Task.CompletedTask;
    }

    private FeatureEntry ResolveFeature(FeatureEntryId featureId)
    {
        foreach (var item in _getNavigationItems())
        {
            if (item.Id == featureId)
            {
                return item;
            }
        }

        throw new InvalidOperationException($"Dashboard navigation target is not registered: {featureId}.");
    }
}
