using Skybridge.WinClient.ViewModels;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient;

internal static class SessionViewModelDependencyFactory
{
    public static SessionViewModelDependencies CreateConfigured(IFileTransferWorkspaceClient? fileTransferClient = null) =>
        WindowsNativeRuntimeDependencyFactory.CreateFromEnvironment(fileTransferClient);

    public static SessionViewModelDependencies CreateDefault() =>
        WindowsNativeRuntimeDependencyFactory.CreateFromEnvironment();
}
