using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;

namespace Skybridge.WinClient.ViewModels;

internal static class WorkspaceCollectionProjector
{
    // In-place differential projection.
    //
    // The previous implementation did `target.Clear(); foreach(...) target.Add(...)`. The
    // Clear() raises an ObservableCollection Reset, which tears down and rebuilds EVERY bound
    // ItemsControl container. Because all dashboard/feature panels share one MainWindow
    // ScrollViewer > StackPanel, that Reset reads as a whole-window flicker on every refresh —
    // and the engine drives refreshes periodically (see FfiEngineClient ~1s heartbeat path).
    //
    // Instead we diff the mapped source against the existing target in place:
    //   • Equal slots are LEFT UNTOUCHED — no change event, so no container rebuild.
    //   • Changed slots emit a single granular Replace.
    //   • Extra source items Add; surplus target items Remove from the tail.
    // An unchanged refresh therefore produces ZERO collection mutations (no Reset, ever), so the
    // bound UI does not re-render at all. This requires the projected TItem to have VALUE
    // equality (every *View type the projector maps to is a `record`, so this holds).
    public static void Replace<TSource, TItem>(
        ObservableCollection<TItem> target,
        IEnumerable<TSource> source,
        Func<TSource, TItem> map)
    {
        var mapped = source.Select(map).ToList();

        for (var i = 0; i < mapped.Count; i++)
        {
            if (i < target.Count)
            {
                // Only assign when the value actually differs. Equal records skip the indexer
                // set entirely, so no Replace event fires and the container is preserved.
                if (!EqualityComparer<TItem>.Default.Equals(target[i], mapped[i]))
                {
                    target[i] = mapped[i];
                }
            }
            else
            {
                target.Add(mapped[i]);
            }
        }

        // Trim any surplus tail rows the new source no longer carries.
        while (target.Count > mapped.Count)
        {
            target.RemoveAt(target.Count - 1);
        }
    }
}
