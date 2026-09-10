using System.Collections.Specialized;
using System.Net;
using Skybridge.WinClient.Services.RemoteControl;
using Skybridge.WinClient.ViewModels;

internal static class RemoteControlNetworkSelectionTests
{
    internal static IReadOnlyList<(string Name, Func<Task> Run)> Cases { get; } =
    [
        ("host network refresh preserves the collection selected item and unchanged rows", UnchangedSnapshot),
        ("host network reorder retains selection through synchronous binding writeback", ReorderWriteback),
        ("host network insertion and removal preserve the surviving selected route", InsertAndRemove),
        ("host network rename preserves the route and updates its visible name", RenameSelectedRoute),
        ("host network removal clears selection until a unique route remains", RemovedSelection),
        ("host network choices require explicit selection when more than one exists", AmbiguousChoices),
        ("host network address changes invalidate the prior route", ChangedRoute),
        ("host network empty snapshots discard removed selection without replacing collection", EmptySnapshot),
        ("host network rejects a missing snapshot without changing selection", MissingSnapshot)
    ];

    private static RemoteControlNetworkInterface Network(string id, string address, uint index, string? name = null) =>
        new(id, name ?? id, IPAddress.Parse(address), index);

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static Task UnchangedSnapshot()
    {
        var selection = new RemoteControlNetworkSelection();
        var ethernet = Network("ethernet", "192.0.2.10", 3);
        var collection = selection.Items;
        selection.Apply([ethernet]);
        Require(ReferenceEquals(selection.Selected, ethernet), "The only network was not selected on first preparation.");
        var mutations = 0;
        selection.Items.CollectionChanged += (_, _) => mutations++;
        selection.Apply([Network("ethernet", "192.0.2.10", 3)]);
        selection.Apply([Network("ethernet", "192.0.2.10", 3)]);
        Require(ReferenceEquals(collection, selection.Items) && ReferenceEquals(selection.Items[0], ethernet) &&
            ReferenceEquals(selection.Selected, ethernet) && mutations == 0,
            "An unchanged post-import network snapshot replaced ItemsSource or raised a row reset that could clear selection.");
        return Task.CompletedTask;
    }

    private static Task ReorderWriteback()
    {
        var selection = new RemoteControlNetworkSelection();
        var first = Network("first", "192.0.2.10", 3);
        var second = Network("second", "192.0.2.20", 4);
        selection.Apply([first, second]);
        selection.Select(first);
        using var binding = new SelectionWriteback(selection);
        selection.Apply([Network("second", "192.0.2.20", 4), Network("first", "192.0.2.10", 3)]);
        Require(binding.NullWrites > 0, "The regression did not exercise a selected row's synchronous null writeback.");
        Require(ReferenceEquals(selection.Selected, first) && ReferenceEquals(selection.Items[0], second) &&
            ReferenceEquals(selection.Items[1], first), "Reordering lost the selected route or changed surviving item identities.");
        return Task.CompletedTask;
    }

    private static Task InsertAndRemove()
    {
        var selection = new RemoteControlNetworkSelection();
        var ethernet = Network("ethernet", "192.0.2.10", 3);
        selection.Apply([ethernet]);
        using var binding = new SelectionWriteback(selection);
        selection.Apply([Network("other", "192.0.2.20", 4), Network("ethernet", "192.0.2.10", 3)]);
        Require(ReferenceEquals(selection.Selected, ethernet) && ReferenceEquals(selection.Items[1], ethernet),
            "Inserting an earlier row replaced the selected network.");
        selection.Apply([Network("ethernet", "192.0.2.10", 3)]);
        Require(ReferenceEquals(selection.Selected, ethernet) && ReferenceEquals(selection.Items[0], ethernet),
            "Removing an unrelated row discarded a surviving network selection.");
        return Task.CompletedTask;
    }

    private static Task RenameSelectedRoute()
    {
        var selection = new RemoteControlNetworkSelection();
        var ethernet = Network("ethernet", "192.0.2.10", 3, "Ethernet");
        selection.Apply([ethernet, Network("other", "192.0.2.20", 4)]);
        selection.Select(ethernet);
        using var binding = new SelectionWriteback(selection);
        var renamed = Network("ethernet", "192.0.2.10", 3, "Office Ethernet");
        selection.Apply([renamed, Network("other", "192.0.2.20", 4)]);
        Require(binding.NullWrites > 0 && ReferenceEquals(selection.Selected, renamed) &&
            selection.Selected.DisplayName.Contains("Office Ethernet", StringComparison.Ordinal),
            "A friendly-name change invalidated the route or left the old name on screen.");
        return Task.CompletedTask;
    }

    private static Task RemovedSelection()
    {
        var selection = new RemoteControlNetworkSelection();
        var removed = Network("removed", "192.0.2.10", 3);
        var remaining = Network("remaining", "192.0.2.20", 4);
        selection.Apply([removed, remaining]);
        selection.Select(removed);
        using var binding = new SelectionWriteback(selection);
        selection.Apply([Network("remaining", "192.0.2.20", 4), Network("third", "192.0.2.30", 5)]);
        Require(selection.Selected is null, "Removing the selected network silently chose a different route among multiple candidates.");
        selection.Apply([Network("remaining", "192.0.2.20", 4)]);
        Require(ReferenceEquals(selection.Selected, remaining), "The unique remaining network was not selected using its preserved row.");
        return Task.CompletedTask;
    }

    private static Task AmbiguousChoices()
    {
        var selection = new RemoteControlNetworkSelection();
        var first = Network("first", "192.0.2.10", 3);
        selection.Apply([first, Network("second", "192.0.2.20", 4)]);
        Require(selection.Selected is null, "Initial preparation guessed a route when multiple networks existed.");
        selection.Select(Network("first", "192.0.2.10", 3));
        Require(ReferenceEquals(selection.Selected, first), "Selection was not normalized to an actual collection item.");
        selection.Select(Network("not-present", "192.0.2.99", 9));
        Require(selection.Selected is null, "An out-of-collection route was accepted as a usable selection.");
        return Task.CompletedTask;
    }

    private static Task ChangedRoute()
    {
        var selection = new RemoteControlNetworkSelection();
        var old = Network("ethernet", "192.0.2.10", 3);
        selection.Apply([old, Network("other", "192.0.2.20", 4)]);
        selection.Select(old);
        using var binding = new SelectionWriteback(selection);
        selection.Apply([Network("ethernet", "192.0.2.11", 3), Network("other", "192.0.2.20", 4)]);
        Require(selection.Selected is null, "An address change kept a stale route selected.");
        selection.Select(selection.Items[0]);
        selection.Apply([Network("ethernet", "192.0.2.11", 8), Network("other", "192.0.2.20", 4)]);
        Require(selection.Selected is null, "An interface-index change kept a stale DNS-SD routing scope selected.");
        return Task.CompletedTask;
    }

    private static Task EmptySnapshot()
    {
        var selection = new RemoteControlNetworkSelection();
        var collection = selection.Items;
        var old = Network("ethernet", "192.0.2.10", 3);
        selection.Apply([old]);
        using var binding = new SelectionWriteback(selection);
        selection.Apply([]);
        selection.Select(old);
        Require(selection.Items.Count == 0 && selection.Selected is null && ReferenceEquals(collection, selection.Items),
            "Empty discovery retained a removed selection or replaced the observable collection.");
        selection.Apply([Network("ethernet", "192.0.2.10", 3)]);
        Require(ReferenceEquals(selection.Selected, selection.Items[0]), "A returning unique network was not selected.");
        return Task.CompletedTask;
    }

    private static Task MissingSnapshot()
    {
        var selection = new RemoteControlNetworkSelection();
        var existing = Network("ethernet", "192.0.2.10", 3);
        selection.Apply([existing]);
        try
        {
            selection.Apply(null!);
            throw new InvalidOperationException("A missing network snapshot was accepted.");
        }
        catch (ArgumentNullException)
        {
            Require(ReferenceEquals(selection.Selected, existing) && ReferenceEquals(selection.Items[0], existing),
                "An invalid snapshot changed the last valid network selection.");
        }
        return Task.CompletedTask;
    }

    private sealed class SelectionWriteback : IDisposable
    {
        private readonly RemoteControlNetworkSelection _selection;
        internal int NullWrites { get; private set; }

        internal SelectionWriteback(RemoteControlNetworkSelection selection)
        {
            _selection = selection;
            _selection.Items.CollectionChanged += OnItemsChanged;
        }

        private void OnItemsChanged(object? sender, NotifyCollectionChangedEventArgs args)
        {
            Require(args.Action != NotifyCollectionChangedAction.Reset, "Network projection reset every bound row.");
            if (_selection.Selected is { } selected && !_selection.Items.Any(item => ReferenceEquals(item, selected)))
            {
                // This is the synchronous TwoWay write observed from the real
                // ComboBox when its selected row is temporarily removed/replaced.
                NullWrites++;
                _selection.Select(null);
            }
        }

        public void Dispose() => _selection.Items.CollectionChanged -= OnItemsChanged;
    }
}
