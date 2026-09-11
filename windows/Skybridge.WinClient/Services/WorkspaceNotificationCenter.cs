using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Globalization;
using System.Linq;

namespace Skybridge.WinClient.Services;

public sealed record WorkspaceNotification(string Title, string Detail, string Glyph, DateTimeOffset CreatedAt, bool IsTransfer)
{
    public string TimeText => CreatedAt.ToLocalTime().ToString("t", CultureInfo.CurrentCulture);
}

// Owned by the application window. All producers dispatch onto that window's UI
// thread, so the list, badge and popup share one ordered event history.
public sealed class WorkspaceNotificationCenter : ITopBarNotificationCenterClient, INotifyPropertyChanged
{
    public const int Capacity = 100;
    private readonly Action _open;
    private readonly ObservableCollection<WorkspaceNotification> _items = [];
    private HashSet<FileTransferHistoryItem> _observedTransfers = new(ReferenceEqualityComparer.Instance);
    private int _unreadCount;
    private bool _isOpen;

    public WorkspaceNotificationCenter(Action open)
    {
        _open = open ?? throw new ArgumentNullException(nameof(open));
        Items = new(_items);
    }

    public ReadOnlyObservableCollection<WorkspaceNotification> Items { get; }
    public int UnreadCount => _unreadCount;
    public bool IsEmpty => _items.Count == 0;
    public string CurrentStatus => _unreadCount.ToString(CultureInfo.InvariantCulture);
    public event PropertyChangedEventHandler? PropertyChanged;
    public event Action<WorkspaceNotification>? NotificationAdded;

    public bool CanOpenNotifications() => true;
    public TopBarWorkspaceActionResult OpenNotifications()
    {
        _open();
        return new(CurrentStatus, "Notification center opened");
    }

    public void SetOpen(bool open)
    {
        _isOpen = open;
        if (open) _unreadCount = 0;
        Notify();
    }

    public void Clear()
    {
        _items.Clear();
        _unreadCount = 0;
        // Retain the bounded transfer observation set: clearing the center must
        // not replay completed transfers on the next progress snapshot.
        Notify();
    }

    public void Add(string title, string detail, string glyph, bool isTransfer = false)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(title);
        var item = new WorkspaceNotification(title, detail, glyph, DateTimeOffset.UtcNow, isTransfer);
        _items.Insert(0, item);
        if (_items.Count > Capacity) _items.RemoveAt(_items.Count - 1);
        if (!_isOpen) _unreadCount = Math.Min(Capacity, _unreadCount + 1);
        Notify();
        NotificationAdded?.Invoke(item);
    }

    public void ObserveTransfers(IReadOnlyList<FileTransferHistoryItem> history, Func<string, string> text, bool enabled)
    {
        ArgumentNullException.ThrowIfNull(history);
        // Each history entry is immutable and retained across progress snapshots.
        // Reference identity distinguishes two real transfers of identical files.
        var current = new HashSet<FileTransferHistoryItem>(history.Take(Capacity), ReferenceEqualityComparer.Instance);
        foreach (var item in history.Take(Capacity).Reverse())
        {
            if (_observedTransfers.Contains(item) || !enabled) continue;
            var key = item.Result switch
            {
                "Sent" => "NotificationsTransferSent",
                "Received" => "NotificationsTransferReceived",
                "Failed" => "NotificationsTransferFailed",
                _ => throw new InvalidOperationException("Unknown terminal file-transfer notification state.")
            };
            Add(text(key), item.Name + "\n" + item.Detail, item.Result == "Failed" ? "\uEA39" : "\uE73E", isTransfer: true);
        }
        _observedTransfers = current;
    }

    private void Notify()
    {
        PropertyChanged?.Invoke(this, new(nameof(UnreadCount)));
        PropertyChanged?.Invoke(this, new(nameof(IsEmpty)));
    }
}
