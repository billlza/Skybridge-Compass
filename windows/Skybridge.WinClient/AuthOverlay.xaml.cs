using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Skybridge.WinClient.ViewModels;
using Windows.UI;

namespace Skybridge.WinClient;

// =====================================================================================
//  AuthOverlay — code-behind for the in-window Mac LOGIN. This replaces the crashing
//  SignInDialog ContentDialog: it is a plain UserControl layer in MainWindow, so there is
//  no XamlRoot, no single-dialog rule, and no async-void ShowAsync teardown.
//
//  • The 4 method tabs are a radio-like selection driven here (SelectedAuthMethod): tapping
//    one paints its accent ring and swaps the visible form. No data binding needed for the
//    picker — it is local UI state.
//  • EMAIL is fully functional: the 邮箱登录 button calls ViewModel.SignInWithEmailAsync,
//    which runs the REAL Supabase email/password sign-in through the coordinator. The busy
//    spinner + inline error mirror the VM's IsAuthBusy / AuthErrorMessage (subscribed below).
//  • Microsoft remains disabled until Windows owns state, PKCE, callback validation, and
//    Supabase session installation as one closed flow.
//  • Nebula and Phone remain explicitly unavailable until Windows owns a complete OAuth/OTP
//    callback, verification, and session-install path. Neither entry point fakes success.
//  • Guest mode just dismisses the overlay (the shell already runs signed-out).
//
//  The password is read ONLY from PasswordInput.Password (user input) — never defaulted.
// =====================================================================================

public sealed partial class AuthOverlay : UserControl
{
    private static readonly SolidColorBrush SelectedTabRing = new(Color.FromArgb(0xFF, 0x30, 0x72, 0xEF));
    private static readonly SolidColorBrush UnselectedTabRing = new(Color.FromArgb(0x33, 0xFF, 0xFF, 0xFF));

    private SessionViewModel? _viewModel;
    private string _selectedMethod = "email";

    public AuthOverlay()
    {
        InitializeComponent();
        DataContextChanged += OnDataContextChanged;
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        // Default to the Email tab (the fully-functional path), matching the Mac default-
        // selected-first behavior where email is the in-app credential flow.
        SelectMethod("email");
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        if (_viewModel is not null)
        {
            _viewModel.PropertyChanged -= OnViewModelPropertyChanged;
        }
    }

    private void OnDataContextChanged(FrameworkElement sender, DataContextChangedEventArgs args)
    {
        if (_viewModel is not null)
        {
            _viewModel.PropertyChanged -= OnViewModelPropertyChanged;
        }

        _viewModel = args.NewValue as SessionViewModel;
        if (_viewModel is not null)
        {
            _viewModel.PropertyChanged += OnViewModelPropertyChanged;
            SyncFromViewModel();
        }
    }

    private void OnViewModelPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(SessionViewModel.IsAuthBusy)
            or nameof(SessionViewModel.AuthErrorMessage)
            or nameof(SessionViewModel.HasAuthError)
            or nameof(SessionViewModel.ShowAuthOverlay))
        {
            SyncFromViewModel();
        }
    }

    // Reflect the VM's auth state into the busy spinner + inline error banner. Also clears the
    // password whenever the overlay is (re)shown so a stale secret never lingers in the box.
    private void SyncFromViewModel()
    {
        if (_viewModel is null)
        {
            return;
        }

        var busy = _viewModel.IsAuthBusy;
        SignInSpinner.IsActive = busy;
        SignInSpinner.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
        SignInGlyph.Visibility = busy ? Visibility.Collapsed : Visibility.Visible;
        EmailSignInButton.IsEnabled = !busy;

        var hasError = _viewModel.HasAuthError;
        ErrorBanner.Visibility = hasError ? Visibility.Visible : Visibility.Collapsed;
        ErrorText.Text = _viewModel.AuthErrorMessage ?? string.Empty;

        if (!_viewModel.ShowAuthOverlay)
        {
            // Overlay just hid (e.g. successful sign-in): wipe the password box.
            PasswordInput.Password = string.Empty;
        }
    }

    // ---- Method-tab selection -------------------------------------------------------

    private void OnTabTapped(object sender, TappedRoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string method })
        {
            SelectMethod(method);
        }
    }

    private void OnSelectEmail(object sender, RoutedEventArgs e) => SelectMethod("email");

    private void SelectMethod(string method)
    {
        _selectedMethod = method;

        PaintTab(MicrosoftTab, method == "microsoft");
        PaintTab(NebulaTab, method == "nebula");
        PaintTab(PhoneTab, method == "phone");
        PaintTab(EmailTab, method == "email");

        MicrosoftForm.Visibility = method == "microsoft" ? Visibility.Visible : Visibility.Collapsed;
        NebulaForm.Visibility = method == "nebula" ? Visibility.Visible : Visibility.Collapsed;
        PhoneForm.Visibility = method == "phone" ? Visibility.Visible : Visibility.Collapsed;
        EmailForm.Visibility = method == "email" ? Visibility.Visible : Visibility.Collapsed;
    }

    private static void PaintTab(Border tab, bool selected)
    {
        tab.BorderBrush = selected ? SelectedTabRing : UnselectedTabRing;
        tab.BorderThickness = new Thickness(selected ? 1.5 : 1.0);
    }

    // ---- Email sign-in (fully functional, real Supabase) ----------------------------

    private async void OnEmailSignIn(object sender, RoutedEventArgs e)
    {
        if (_viewModel is null)
        {
            return;
        }

        var email = EmailInput.Text?.Trim() ?? string.Empty;
        // Password read verbatim from user input — never defaulted or hardcoded.
        var password = PasswordInput.Password ?? string.Empty;

        // The VM owns the busy/error state + typed coordinator failures.
        await _viewModel.SignInWithEmailAsync(email, password);
    }

    // ---- Email-form register hint (hosted; inert for now) ---------------------------

    private void OnRegisterHint(object sender, RoutedEventArgs e)
    {
        // Registration is a hosted Supabase flow; surface it as a non-destructive hint in the
        // inline error banner rather than faking an in-app sign-up.
        ErrorBanner.Visibility = Visibility.Visible;
        ErrorText.Text = "注册请使用网页端完成，随后可在此用邮箱密码登录。";
    }

    // ---- Phone OTP (honest: not wired on Windows) -----------------------------------

    private void OnPhoneGetCode(object sender, RoutedEventArgs e)
    {
        // No Windows phone-OTP backend; don't pretend a code was sent.
        PhoneHint.Text = "手机验证码登录暂未在 Windows 端开放，请暂用邮箱登录。";
    }

    private void OnForgotPassword(object sender, RoutedEventArgs e)
    {
        // /auth/v1/recover is a POST API, not a hosted GET page. Do not launch a dead URL or put
        // credentials in a query string. A real implementation must call the typed auth client.
        ErrorBanner.Visibility = Visibility.Visible;
        ErrorText.Text = "密码恢复尚未在 Windows 端接通，请先在其他已验证客户端完成重置。";
    }

    // ---- Guest mode -----------------------------------------------------------------

    private void OnGuestMode(object sender, RoutedEventArgs e) => _viewModel?.EnterGuestMode();
}
