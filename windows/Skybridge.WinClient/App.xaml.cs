using System;
using Microsoft.UI.Xaml;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient;

public partial class App : Application
{
    private Window? _window;

    public App()
    {
        // ===== Trilingual UI language selection (en-US / zh-Hans / ja) =====
        // The actual override is applied in OnLaunched (NOT here): in the ctor the WinAppSDK runtime
        // isn't bootstrapped yet and PrimaryLanguageOverride crashes (0xc000027b). By default we set
        // NOTHING — the app follows the SYSTEM DISPLAY LANGUAGE (the documented unpackaged behavior).
        // We only call PrimaryLanguageOverride when the user has made an explicit choice, so the
        // system-following default is untouched for users who never pick a language.
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        // Apply the language override HERE, not in the App ctor: in the ctor the WinAppSDK runtime
        // isn't bootstrapped yet and PrimaryLanguageOverride crashes (0xc000027b). By OnLaunched the
        // runtime is up, and this is still BEFORE the MainWindow XAML loads, so x:Uid resources
        // resolve in the chosen language.
        ApplyLanguageOverride();
        _window = new MainWindow();
        _window.Activate();
    }

    // Resolve and apply the persisted UI-language override, if any.
    //
    // Resolution:
    //   1. The user's persisted choice — LanguageSettings reads the "Language" field of the same
    //      %LOCALAPPDATA%\SkyBridge\settings.json the Settings ▸ General 语言 dropdown writes to. It
    //      maps the stored value ("zh-Hans" / "ja" / "en-US") to a BCP-47 tag, or null for "follow
    //      system" ("" / "system").
    //   2. No explicit choice → null → follow the system display language (override cleared).
    //
    // The API is Microsoft.Windows.Globalization.ApplicationLanguages.PrimaryLanguageOverride (the
    // Windows App SDK class — NOT Windows.Globalization, which throws/misbehaves unpackaged). It is
    // supported for unpackaged apps since Windows App SDK 1.6.240701003; this project references
    // WindowsAppSDK 2.2.0, so it is available. The value is persisted by the platform between
    // sessions; setting it here every launch from our own source of truth keeps the two in sync.
    //
    // NOTE: x:Uid strings fully re-resolve to the new language on the NEXT launch. Setting the
    // override before the MainWindow XAML loads (as we do) means a language picked in Settings takes
    // effect on the relaunch after it is saved — the "restart to apply" experience the Settings UI
    // surfaces, which is acceptable (Mac behaves the same).
    private static void ApplyLanguageOverride()
    {
        try
        {
            var language = LanguageSettings.ResolveBcp47Override();

            if (!string.IsNullOrWhiteSpace(language))
            {
                Microsoft.Windows.Globalization.ApplicationLanguages.PrimaryLanguageOverride = language!.Trim();
            }
            else
            {
                // No explicit choice: clear any previously-persisted override so we follow the
                // system display language. Empty string == "use system default".
                Microsoft.Windows.Globalization.ApplicationLanguages.PrimaryLanguageOverride = string.Empty;
            }
        }
        catch (Exception)
        {
            // Never let a localization-setup failure stop the app from launching — fall through to
            // the system display language.
        }
    }
}
