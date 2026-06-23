using System;
using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Data;

namespace Skybridge.WinClient.ViewModels;

/// <summary>
/// Maps an integer collection count to a <see cref="Visibility"/> so the dashboard
/// summary panels can show a populated list OR an honest empty-state placeholder,
/// the way the Mac dashboard panels swap between their row lists and
/// <c>EmptyStateView</c>.
///
/// The bound source is one of the reliable count properties on
/// <see cref="SessionViewModel"/> (<c>DiscoveredPeerCount</c>,
/// <c>RemoteDesktopSessionCount</c>, <c>SystemMonitorMetricCount</c>), each of which
/// raises a property-change notification via <see cref="WorkspaceCountNotifier"/>
/// whenever its backing <see cref="System.Collections.ObjectModel.ObservableCollection{T}"/>
/// is replaced/refreshed — so this converter re-runs on real data changes.
///
/// Behaviour (no allocation, no fake data — purely a view-state switch):
///   • default               → Visible when count &gt; 0  (the list has rows)
///   • ConverterParameter="Empty" → Visible when count == 0 (show the empty state)
/// Any non-int input is treated as 0 (so a missing/zero count shows the empty state).
/// </summary>
public sealed class CountToVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var count = value switch
        {
            int i => i,
            null => 0,
            _ => int.TryParse(value.ToString(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsed) ? parsed : 0
        };

        var wantEmpty = parameter is string mode &&
            string.Equals(mode, "Empty", StringComparison.OrdinalIgnoreCase);

        var hasItems = count > 0;
        var visible = wantEmpty ? !hasItems : hasItems;
        return visible ? Visibility.Visible : Visibility.Collapsed;
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language)
    {
        throw new NotSupportedException();
    }
}
