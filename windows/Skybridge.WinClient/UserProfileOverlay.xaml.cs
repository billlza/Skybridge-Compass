using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Skybridge.WinClient.ViewModels;
using Windows.ApplicationModel.DataTransfer;

namespace Skybridge.WinClient;

// =====================================================================================
//  UserProfileOverlay — code-behind for the in-window Mac "用户资料" modal.
//
//  • Close X and tap-outside (backdrop) both hide the overlay via the VM
//    (ViewModel.HideProfileOverlay). A tap on the card itself is marked handled so it does
//    NOT bubble to the backdrop.
//  • 复制 copies the 星云ID / 邮箱 to the system clipboard via a DataPackage (the WinUI
//    equivalent of the Mac NSPasteboard copy).
//  • 编辑 / 绑定 are rendered for parity; the live profile-update write is not yet wired on
//    the Windows client (the Mac calls SupabaseService.updateUserProfile). Rather than fake a
//    save, these surface a clear inline hint — honest, no silent no-op.
// =====================================================================================

public sealed partial class UserProfileOverlay : UserControl
{
    public UserProfileOverlay()
    {
        InitializeComponent();
    }

    private SessionViewModel? ViewModel => DataContext as SessionViewModel;

    private void OnClose(object sender, RoutedEventArgs e) => ViewModel?.HideProfileOverlay();

    private void OnBackdropTapped(object sender, TappedRoutedEventArgs e) =>
        ViewModel?.HideProfileOverlay();

    // Swallow taps on the card so they don't bubble up to the backdrop (which would close).
    private void OnCardTapped(object sender, TappedRoutedEventArgs e) => e.Handled = true;

    private void OnCopyNebulaId(object sender, RoutedEventArgs e) =>
        CopyToClipboard(ViewModel?.NebulaId);

    private void OnCopyEmail(object sender, RoutedEventArgs e) =>
        CopyToClipboard(ViewModel?.Email);

    private static void CopyToClipboard(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return;
        }

        var package = new DataPackage { RequestedOperation = DataPackageOperation.Copy };
        package.SetText(value);
        Clipboard.SetContent(package);
    }

    // 编辑 / 绑定 — render-only for now (the live update write is not wired on Windows). Show
    // an honest hint instead of pretending the change was saved.
    private void OnEditHint(object sender, RoutedEventArgs e) =>
        ShowHint("资料编辑将在后续版本开放，当前请在 Mac/iOS 端修改资料。");

    private void OnBindHint(object sender, RoutedEventArgs e) =>
        ShowHint("绑定功能将在后续版本开放，当前请在 Mac/iOS 端绑定邮箱或手机号。");

    // 退出登录 — clears the persisted session (coordinator SignOutAsync → SessionStore.Clear,
    // IsSignedIn=false) and dismisses the overlay; the account block returns to "Sign in".
    private void OnSignOut(object sender, RoutedEventArgs e)
    {
        var vm = ViewModel;
        vm?.HideProfileOverlay();
        if (vm?.SignOutCommand?.CanExecute(null) == true)
        {
            vm.SignOutCommand.Execute(null);
        }
    }

    private void ShowHint(string message)
    {
        ActionHint.Text = message;
        ActionHint.Visibility = Visibility.Visible;
    }
}
