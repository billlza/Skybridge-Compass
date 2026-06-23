using System;
using System.ComponentModel;
using System.Diagnostics;
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
//  • Apple / Nebula open the system browser to the Supabase OAuth authorize URL (the same
//    GoTrue project + client-safe key the rest of the app uses); Phone routes to email
//    (no Windows phone-OTP path) — none of these fake a signed-in success.
//  • Guest mode just dismisses the overlay (the shell already runs signed-out).
//
//  The password is read ONLY from PasswordInput.Password (user input) — never defaulted.
// =====================================================================================

public sealed partial class AuthOverlay : UserControl
{
    // Supabase GoTrue project + client-safe publishable key (the SAME values the
    // SupabaseAuthClient bundles). Used only to build the browser OAuth authorize URL for the
    // Apple / Nebula providers — no secret is involved (publishable/anon key only).
    private const string SupabaseBaseUrl = "https://hloqytmhjludmuhwyyzb.supabase.co";
    private const string OAuthRedirect = "skybridge://auth/callback";

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

        PaintTab(AppleTab, method == "apple");
        PaintTab(NebulaTab, method == "nebula");
        PaintTab(PhoneTab, method == "phone");
        PaintTab(EmailTab, method == "email");

        AppleForm.Visibility = method == "apple" ? Visibility.Visible : Visibility.Collapsed;
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

        // The VM owns the busy/error state + the real coordinator call; it never throws.
        await _viewModel.SignInWithEmailAsync(email, password);
    }

    // ---- Apple / Nebula browser OAuth ----------------------------------------------

    private void OnAppleContinue(object sender, RoutedEventArgs e) =>
        OpenOAuthInBrowser("apple", AppleHint);

    private void OnNebulaBrowserLogin(object sender, RoutedEventArgs e) =>
        OpenOAuthInBrowser("nebula", null);

    private void OnForgotPassword(object sender, RoutedEventArgs e)
    {
        // Supabase password-recovery is a hosted flow; open it in the browser. If the email
        // box already has an address, pass it through so the page can prefill.
        var email = EmailInput.Text?.Trim() ?? string.Empty;
        var url = $"{SupabaseBaseUrl}/auth/v1/recover";
        if (!string.IsNullOrWhiteSpace(email))
        {
            url += $"?email={Uri.EscapeDataString(email)}";
        }

        TryOpenBrowser(url, null);
    }

    // Opens the GoTrue OAuth authorize URL for the given provider in the system browser. The
    // redirect is the app's custom scheme (skybridge://) — the same callback contract the Mac
    // uses; if no browser can be launched we surface a clear "暂用邮箱登录" hint rather than
    // pretending success.
    private void OpenOAuthInBrowser(string provider, TextBlock? hintTarget)
    {
        var url =
            $"{SupabaseBaseUrl}/auth/v1/authorize" +
            $"?provider={Uri.EscapeDataString(provider)}" +
            $"&redirect_to={Uri.EscapeDataString(OAuthRedirect)}";

        TryOpenBrowser(url, hintTarget);
    }

    private static void TryOpenBrowser(string url, TextBlock? hintTarget)
    {
        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = url,
                UseShellExecute = true
            });
        }
        catch (Exception)
        {
            // Could not launch a browser: be honest, don't fake a login.
            if (hintTarget is not null)
            {
                hintTarget.Text = "无法打开浏览器，请暂用邮箱登录。";
            }
        }
    }

    // ---- Guest mode -----------------------------------------------------------------

    private void OnGuestMode(object sender, RoutedEventArgs e) => _viewModel?.EnterGuestMode();
}
