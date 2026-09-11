using Skybridge.WinClient.ViewModels;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient;

internal static class SessionViewModelDependencyFactory
{
    public static SessionViewModelDependencies CreateConfigured(
        IFileTransferWorkspaceClient fileTransferClient,
        ITopBarNotificationCenterClient notifications,
        SettingsService settings,
        System.Action openThemePicker) =>
        CreateConfigured(fileTransferClient,
            new TopBarStatusClient(notifications, new SettingsThemePreferenceClient(settings), openThemePicker), settings);

    public static SessionViewModelDependencies CreateConfigured(IFileTransferWorkspaceClient? fileTransferClient = null, ITopBarStatusClient? topBarStatusClient = null, SettingsService? settingsService = null) =>
        WindowsNativeRuntimeDependencyFactory.CreateFromEnvironment(fileTransferClient, topBarStatusClient, settingsService);

    public static SessionViewModelDependencies CreateDefault() =>
        WindowsNativeRuntimeDependencyFactory.CreateFromEnvironment();
}
