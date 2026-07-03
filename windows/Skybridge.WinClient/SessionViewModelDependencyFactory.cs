using Skybridge.WinClient.ViewModels;

namespace Skybridge.WinClient;

internal static class SessionViewModelDependencyFactory
{
    public static SessionViewModelDependencies CreateConfigured() =>
        WindowsNativeRuntimeDependencyFactory.CreateFromEnvironment();

    public static SessionViewModelDependencies CreateDefault() =>
        WindowsNativeRuntimeDependencyFactory.CreateFromEnvironment();
}
