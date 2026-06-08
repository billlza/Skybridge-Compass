using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;

namespace Skybridge.WinClient.ViewModels;

internal static class WorkspaceCollectionProjector
{
    public static void Replace<TSource, TItem>(
        ObservableCollection<TItem> target,
        IEnumerable<TSource> source,
        Func<TSource, TItem> map)
    {
        target.Clear();
        foreach (var item in source)
        {
            target.Add(map(item));
        }
    }
}
