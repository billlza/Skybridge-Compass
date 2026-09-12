using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Skybridge.WinClient.Services;
using Skybridge.WinClient.Services.FileTransfer;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;

namespace Skybridge.WinClient;

public sealed partial class MainWindow
{
    private bool _connectingFileTransfer;
    private bool _disconnectingFileTransfer;

    private void OnFileTransferDragOver(object sender, DragEventArgs args)
    {
        args.AcceptedOperation = !_hostShutdownInProgress && !ViewModel.IsBusy &&
            args.DataView.Contains(StandardDataFormats.StorageItems) ? DataPackageOperation.Copy : DataPackageOperation.None;
    }

    private async void OnFileTransferDrop(object sender, DragEventArgs args)
    {
        var deferral = args.GetDeferral();
        try
        {
            if (_hostShutdownInProgress || !args.DataView.Contains(StandardDataFormats.StorageItems)) return;
            var items = await args.DataView.GetStorageItemsAsync();
            var hasFolder = items.Any(item => item.IsOfType(StorageItemTypes.Folder));
            if (hasFolder && items.Count != 1) throw new InvalidOperationException(RemoteControlText("FileTransferLiveSelectionLimit"));
            var result = await _fileTransferWorkspace.SendSelectedPathsAsync(items.Select(item => item.Path).ToArray(), hasFolder);
            ViewModel.ApplyLiveFileTransfer(await _fileTransferWorkspace.BuildReadOnlySnapshotAsync(), result.Status);
        }
        catch (Exception failure) { ViewModel.ApplyLiveFileTransfer(await _fileTransferWorkspace.BuildReadOnlySnapshotAsync(), failure.Message); }
        finally { deferral.Complete(); }
    }

    private async void OnFileTransferAccountChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs args)
    {
        if (args.PropertyName == nameof(ViewModel.IsSignedIn) && !ViewModel.IsSignedIn && !_hostShutdownInProgress)
            await DisconnectFileTransferAsync();
    }

    private async void OnFileTransferDisconnectClicked(object sender, RoutedEventArgs args) => await DisconnectFileTransferAsync();

    private async Task DisconnectFileTransferAsync()
    {
        if (_disconnectingFileTransfer) return;
        _disconnectingFileTransfer = true;
        FileTransferDisconnectButton.IsEnabled = false;
        try { await _fileTransferWorkspace.DisconnectAsync(); }
        catch (Exception failure) { ViewModel.ApplyLiveFileTransfer(await _fileTransferWorkspace.BuildReadOnlySnapshotAsync(), failure.Message); }
        finally { _disconnectingFileTransfer = false; if (!_hostShutdownInProgress) FileTransferDisconnectButton.IsEnabled = true; }
    }

    private void OnFileTransferChanged(FileTransferWorkspaceSnapshot snapshot, string status)
    {
        if (!DispatcherQueue.TryEnqueue(() =>
        {
            if (!_hostShutdownComplete)
            {
                ViewModel.ApplyLiveFileTransfer(snapshot, status);
                _notifications.ObserveTransfers(snapshot.History, RemoteControlText, ViewModel.Settings.ShowFileTransferNotifications);
            }
        }) && !_hostShutdownComplete)
            throw new InvalidOperationException("The transfer state could not be presented in the application window.");
    }

    private async void OnFileTransferConnectClicked(object sender, RoutedEventArgs args)
    {
        if (_connectingFileTransfer || _hostShutdownInProgress) return;
        _connectingFileTransfer = true;
        FileTransferConnectButton.IsEnabled = false;
        try { await _fileTransferWorkspace.ConnectSelectedPeerAsync(); }
        catch (Exception failure)
        {
            ViewModel.ApplyLiveFileTransfer(await _fileTransferWorkspace.BuildReadOnlySnapshotAsync(), failure.Message);
        }
        finally { _connectingFileTransfer = false; if (!_hostShutdownInProgress) FileTransferConnectButton.IsEnabled = true; }
    }

    private sealed class NativeFileTransferSelection(MainWindow window) : IFileTransferSelectionClient
    {
        private readonly SemaphoreSlim _dialogs = new(1, 1);
        private readonly WindowsDiscoveryBrowserClient _peerDiscovery =
            WindowsNativeRuntimeDependencyFactory.CreateFeaturePeerDiscoveryClient();
        private readonly Microsoft.UI.Dispatching.DispatcherQueue _dispatcher = window.DispatcherQueue;
        public string DestinationDirectory => Environment.ExpandEnvironmentVariables(window.ViewModel.Settings.DefaultTransferPath);

        public async Task<IReadOnlyList<string>> SelectPathsAsync(bool folder, CancellationToken cancellationToken)
        {
            if (folder)
            {
                var picker = new Microsoft.Windows.Storage.Pickers.FolderPicker(window.AppWindow.Id);
                var selected = await picker.PickSingleFolderAsync().AsTask(cancellationToken);
                return selected is null ? [] : [selected.Path];
            }
            var files = new Microsoft.Windows.Storage.Pickers.FileOpenPicker(window.AppWindow.Id);
            var selection = await files.PickMultipleFilesAsync().AsTask(cancellationToken);
            return selection.Select(file => file.Path).ToArray();
        }

        public async Task<DiscoveryBrowserPeerCandidate?> SelectPeerAsync(CancellationToken cancellationToken)
        {
            // File operations own their discovery result. The UI refresh command may
            // legitimately skip while busy, and its filtered cache is not a lookup result.
            var snapshot = await _peerDiscovery.BuildReadOnlySnapshotAsync(new(
                DiscoveryBrowserAction.Refresh, SkyBridgeProtocolConstants.TcpControlDnsSdService,
                "", "", false, WindowsDiscoveryBrowserClient.DefaultInputPolicy.ExtendedSearchSeconds), cancellationToken);
            var candidates = snapshot.Peers.ToArray();
            var files = candidates.Where(peer => peer.Routes.FileTransfer is not null)
                .DistinctBy(peer => (peer.Peer.DeviceId, peer.Peer.PublicKeyFingerprint, peer.Routes.FileTransfer)).ToArray();
            if (files.Length == 0) throw new InvalidOperationException(window.RemoteControlText("FileTransferLiveNoPeers"));
            var picker = new ComboBox { MinWidth = 380, ItemsSource = files.Select(peer => new PeerChoice(peer, peer.Peer.DisplayName)).ToArray(),
                DisplayMemberPath = nameof(PeerChoice.Name), PlaceholderText = window.RemoteControlText("FileTransferLiveChoosePeer") };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(picker, "Skybridge.FileTransfer.Peer");
            var dialog = new ContentDialog {
                XamlRoot = window.RootShell.XamlRoot, Title = window.RemoteControlText("FileTransferLiveChoosePeer"), Content = picker,
                PrimaryButtonText = window.RemoteControlText("FileTransferLiveConnect"), CloseButtonText = window.RemoteControlText("FileTransferLiveCancel"),
                IsPrimaryButtonEnabled = false
            };
            picker.SelectionChanged += (_, _) => dialog.IsPrimaryButtonEnabled = picker.SelectedItem is PeerChoice;
            var result = await ShowAsync(dialog, cancellationToken);
            if (result != ContentDialogResult.Primary) return null;
            var selected = (picker.SelectedItem as PeerChoice)?.Candidate ?? throw new InvalidOperationException("No transfer peer was selected.");
            return DiscoveryPeerRoutes.JoinFileTransferServices(selected, candidates);
        }

        public async Task<bool> ApproveIncomingAsync(ClassicFileMetadata metadata, string destinationDirectory, CancellationToken cancellationToken)
        {
            var completion = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            if (!_dispatcher.TryEnqueue(async () =>
            {
                try
                {
                    var dialog = new ContentDialog {
                        XamlRoot = window.RootShell.XamlRoot, Title = window.RemoteControlText("FileTransferLiveIncoming"),
                        Content = new TextBlock { Text = $"{metadata.SenderDeviceName}\n{metadata.FileName}\n{metadata.FileSize:N0} B\n{destinationDirectory}", TextWrapping = TextWrapping.Wrap },
                        PrimaryButtonText = window.RemoteControlText("FileTransferLiveAccept"), CloseButtonText = window.RemoteControlText("FileTransferLiveDecline")
                    };
                    completion.TrySetResult(await ShowAsync(dialog, cancellationToken) == ContentDialogResult.Primary);
                }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { completion.TrySetCanceled(cancellationToken); }
                catch (Exception failure) { completion.TrySetException(failure); }
            })) throw new InvalidOperationException("The incoming transfer approval could not be displayed.");
            return await completion.Task.ConfigureAwait(false);
        }

        private async Task<ContentDialogResult> ShowAsync(ContentDialog dialog, CancellationToken cancellationToken)
        {
            await _dialogs.WaitAsync(cancellationToken);
            try
            {
                cancellationToken.ThrowIfCancellationRequested();
                var operation = dialog.ShowAsync().AsTask();
                var dispatchFailure = new TaskCompletionSource<Exception>(TaskCreationOptions.RunContinuationsAsynchronously);
                using var registration = cancellationToken.Register(() =>
                {
                    if (operation.IsCompleted) return;
                    try
                    {
                        // A managed callback is required here. Passing the projected
                        // WinRT dialog.Hide method group directly asks CsWinRT to query
                        // the dialog itself for the dispatcher delegate interface.
                        if (!_dispatcher.TryEnqueue(() =>
                        {
                            try { if (!operation.IsCompleted) dialog.Hide(); }
                            catch (Exception failure) { dispatchFailure.TrySetResult(failure); }
                        }))
                            dispatchFailure.TrySetResult(new InvalidOperationException("The dialog's UI dispatcher is no longer available."));
                    }
                    catch (Exception failure) { dispatchFailure.TrySetResult(failure); }
                });
                var completed = await Task.WhenAny(operation, dispatchFailure.Task);
                if (completed == dispatchFailure.Task || dispatchFailure.Task.IsCompleted)
                    throw new InvalidOperationException("The file-transfer dialog could not be cancelled on its UI thread.", await dispatchFailure.Task);
                var result = await operation;
                cancellationToken.ThrowIfCancellationRequested();
                return result;
            }
            finally { _dialogs.Release(); }
        }

        private sealed record PeerChoice(DiscoveryBrowserPeerCandidate Candidate, string Name);
    }
}
