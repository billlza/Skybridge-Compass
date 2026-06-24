using System;
using System.IO;
using Microsoft.UI.Xaml;

namespace Skybridge.WinClient;

public partial class App : Application
{
    private Window? _window;

    public App()
    {
        // ===== Trilingual UI language selection (en-US / zh-Hans / ja) =====
        // MUST run before InitializeComponent / any UI is realized: the Resource Management System
        // snapshots the resolved language when XAML x:Uid lookups first run, so the override has to
        // be in place first. By default we set NOTHING — the app follows the SYSTEM DISPLAY LANGUAGE
        // (the documented unpackaged behavior). We only call PrimaryLanguageOverride when an explicit
        // choice exists, so the system-following default is untouched for users who never pick a
        // language.
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

    // Resolve and apply the UI language override, if any.
    //
    // Resolution order:
    //   1. TEST HOOK (see below): C:\sb\force-lang.txt — first line is a BCP-47 tag.
    //   2. (future) a persisted user setting from the Settings UI — left as the documented seam.
    //   3. nothing -> follow the system display language (no override call).
    //
    // The API is Microsoft.Windows.Globalization.ApplicationLanguages.PrimaryLanguageOverride
    // (the Windows App SDK class — NOT Windows.Globalization, which throws/misbehaves unpackaged).
    // It is supported for unpackaged apps since Windows App SDK 1.6.240701003; this project
    // references WindowsAppSDK 2.2.0, so it is available. The value is persisted by the platform
    // between sessions; setting it here every launch from our own source of truth is fine.
    //
    // NOTE: x:Uid strings fully re-resolve to the new language on the NEXT launch. Setting the
    // override before InitializeComponent (as we do) means a freshly written force-lang.txt takes
    // effect on the relaunch after it is written — exactly the test loop the box needs.
    private static void ApplyLanguageOverride()
    {
        try
        {
            var language = ResolveForcedTestLanguage();
            // (future) ?? ResolvePersistedSettingLanguage();

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

    // ===== TEMP TEST HOOK — REMOVE BEFORE SHIP =====
    // Reads C:\sb\force-lang.txt and returns its first non-empty line as a BCP-47 language tag
    // (e.g. "zh-Hans", "ja", "en-US"). Lets the box switch UI language + screenshot WITHOUT
    // changing the system display language. Delete the file (or this method) to fall back to the
    // system language. Any read failure / missing file => null (no override).
    private static string? ResolveForcedTestLanguage()
    {
        try
        {
            const string path = @"C:\sb\force-lang.txt";
            if (!File.Exists(path))
            {
                return null;
            }

            foreach (var raw in File.ReadAllLines(path))
            {
                var line = raw.Trim();
                if (line.Length > 0 && !line.StartsWith("#", StringComparison.Ordinal))
                {
                    return line;
                }
            }

            return null;
        }
        catch (Exception)
        {
            return null;
        }
    }
}
