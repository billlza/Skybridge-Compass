using System;

namespace Skybridge.WinClient.ViewModels;

internal sealed class WorkspaceDeferredRefreshAction
{
    private Action? _refresh;

    public void Attach(Action refresh)
    {
        _refresh = refresh ?? throw new ArgumentNullException(nameof(refresh));
    }

    public void Invoke()
    {
        if (_refresh is null)
        {
            throw new InvalidOperationException("Workspace refresh action was invoked before it was attached.");
        }

        _refresh();
    }
}
