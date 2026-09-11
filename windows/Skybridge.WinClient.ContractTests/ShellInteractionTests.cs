using Skybridge.WinClient.Services;

internal static class ShellInteractionTests
{
    internal static readonly (string Name, Func<Task> Run)[] Cases =
    [
        ("notification center opens the real surface and bounds unread history", NotificationsAsync),
        ("transfer notifications distinguish repeated files and do not replay after clear", TransfersAsync),
        ("appearance menu and settings share persisted theme ownership", AppearanceAsync),
        ("legacy dark setting survives migration and invalid backgrounds are rejected", MigrationAsync)
    ];

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static Task NotificationsAsync()
    {
        int opened = 0;
        var center = new WorkspaceNotificationCenter(() => opened++);
        for (int i = 0; i < 125; i++) center.Add("Event " + i, "Actual event detail", "\uE73E");
        Check(center.Items.Count == 100 && center.UnreadCount == 100 && center.Items[0].Title == "Event 124", "History must retain only the newest bounded events.");
        center.OpenNotifications();
        Check(opened == 1 && center.UnreadCount == 100, "Opening intent must not claim items were read before the popup is visible.");
        center.SetOpen(true);
        center.Add("Visible event", "Detail", "\uE73E");
        Check(center.UnreadCount == 0, "Visible notifications should be read.");
        center.SetOpen(false);
        center.Add("New event", "Detail", "\uE73E");
        Check(center.UnreadCount == 1, "New event must restore the badge.");
        center.Clear();
        Check(center.IsEmpty && center.UnreadCount == 0, "Clear must update list and badge together.");
        var failure = new WorkspaceNotificationCenter(() => throw new InvalidOperationException("surface failed"));
        try { failure.OpenNotifications(); throw new Exception("A failed popup was reported as opened."); }
        catch (InvalidOperationException error) { Check(error.Message == "surface failed", "Original popup error was lost."); }
        return Task.CompletedTask;
    }

    private static Task TransfersAsync()
    {
        var center = new WorkspaceNotificationCenter(() => { });
        var sent = new FileTransferHistoryItem("same.txt", "Sent", "hash", "verified");
        var sameFileAgain = new FileTransferHistoryItem("same.txt", "Sent", "hash", "verified");
        center.ObserveTransfers([sent], key => key, enabled: true);
        center.ObserveTransfers([sent], key => key, enabled: true);
        Check(center.Items.Count == 1, "Progress snapshots replayed a terminal event.");
        center.Clear();
        center.ObserveTransfers([sent], key => key, enabled: true);
        Check(center.Items.Count == 0, "Cleared history was replayed.");
        center.ObserveTransfers([sameFileAgain, sent], key => key, enabled: true);
        Check(center.Items.Count == 1, "A second real transfer of identical bytes must notify.");
        var failed = new FileTransferHistoryItem("other.txt", "Failed", "", "Connection closed");
        center.ObserveTransfers([failed, sameFileAgain, sent], key => key, enabled: false);
        center.ObserveTransfers([failed, sameFileAgain, sent], key => key, enabled: true);
        Check(center.Items.Count == 1, "Re-enabling notifications must not replay muted events.");
        var nextFailure = new FileTransferHistoryItem("other.txt", "Failed", "", "Connection closed");
        center.ObserveTransfers([nextFailure], key => key, enabled: true);
        Check(center.Items[0].Title == "NotificationsTransferFailed" && center.Items[0].Detail.Contains("Connection closed"), "Real transfer failure was not retained.");
        return Task.CompletedTask;
    }

    private static async Task AppearanceAsync()
    {
        string directory = Path.Combine(Path.GetTempPath(), "skybridge-shell-contract-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            var store = new SettingsStore(directory);
            using (var settings = new SettingsService(store))
            {
                int menus = 0;
                var preference = new SettingsThemePreferenceClient(settings);
                var client = new TopBarStatusClient(new WorkspaceNotificationCenter(() => { }), preference, () => menus++);
                settings.AppearanceMode = "system";
                await client.BuildThemeActionAsync();
                Check(menus == 1 && settings.AppearanceMode == "system", "Opening the menu must not cycle or mutate the theme.");
                settings.AppearanceMode = "light";
                settings.BackgroundTheme = "aurora";
                Check(preference.CurrentStatus == TopBarStatusClient.LightThemeStatus, "Top bar and settings disagreed about appearance.");
                Check(store.Save(settings.Snapshot).Succeeded, "Settings were not saved.");
            }
            using var restored = new SettingsService(store);
            Check(restored.AppearanceMode == "light" && restored.BackgroundTheme == "aurora", "Appearance did not survive relaunch.");
        }
        finally { Directory.Delete(directory, recursive: true); }
    }

    private static Task MigrationAsync()
    {
        string directory = Path.Combine(Path.GetTempPath(), "skybridge-shell-migration-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            var store = new SettingsStore(directory);
            Check(store.Save(new SkyBridgeSettings { UseDarkMode = false }).Succeeded, "Legacy settings setup failed.");
            using var service = new SettingsService(store);
            Check(service.AppearanceMode == "light" && service.BackgroundTheme == "weather", "Legacy explicit appearance or weather changed on upgrade.");
            Check(!store.Save(new SkyBridgeSettings { AppearanceMode = "unknown" }).Succeeded, "Invalid appearance was accepted.");
            Check(!store.Save(new SkyBridgeSettings { BackgroundTheme = "custom" }).Succeeded, "Custom mode without an image was accepted.");
            Check(!store.Save(new SkyBridgeSettings { BackgroundTheme = "unknown" }).Succeeded, "Invalid background was accepted.");
        }
        finally { Directory.Delete(directory, recursive: true); }
        return Task.CompletedTask;
    }
}
