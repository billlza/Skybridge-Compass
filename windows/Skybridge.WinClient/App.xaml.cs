using System;
using System.Diagnostics;
using System.IO;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Skybridge.WinClient.Services;
using Skybridge.WinClient.ViewModels;

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
        InstallFailureDiagnostics();
    }

    // ===== Process-level failure diagnostics =====
    //
    // Three sinks, deliberately with three different policies:
    //
    //   1. AsyncRelayCommand.UnhandledErrorSink — every workspace command runs through
    //      `async void ICommand.Execute`, so an exception escaping it has no caller and
    //      terminates the process. The adapter now catches and reports here instead.
    //      Scoped work is already caught by WorkspaceBusyCoordinator and patched onto the
    //      owning WorkspaceErrorScope, so anything reaching this sink is a real defect in
    //      an unscoped path — recorded at Error, never swallowed silently.
    //
    //   2. UnobservedTaskException — a faulted fire-and-forget task nobody awaited. Marking
    //      it observed is safe and standard (since .NET 4.5 it does not tear down the
    //      process anyway); the value here is that it stops being invisible.
    //
    //   3. Application.UnhandledException — intentionally NOT marked Handled. If a failure
    //      reaches this far, process state is unknown and continuing would be guesswork.
    //      What this hook buys is a written record before the process goes down, which is
    //      exactly what was missing when a crash left nothing behind to diagnose.
    private void InstallFailureDiagnostics()
    {
        InstallTraceFileListener();

        AsyncRelayCommand.UnhandledErrorSink = static ex =>
            WindowsRuntimeLog.Write(
                WindowsLogLevel.Error,
                "command",
                $"Unhandled exception escaped a workspace command: {ex}");

        TaskScheduler.UnobservedTaskException += static (_, args) =>
        {
            WindowsRuntimeLog.Write(
                WindowsLogLevel.Error,
                "task",
                $"Unobserved task exception: {args.Exception}");
            args.SetObserved();
        };

        UnhandledException += static (_, args) =>
            WindowsRuntimeLog.Write(
                WindowsLogLevel.Error,
                "app",
                $"Unhandled exception, process terminating: {args.Message} {args.Exception}");
    }

    // Give WindowsRuntimeLog somewhere to land. Trace's default listener only forwards to
    // OutputDebugString, so every line the app writes — including the GPU backdrop reporting
    // why it fell back to a flat clear — was visible to an attached debugger and to nobody
    // else. That is the reason a silent visual failure could not be diagnosed from a running
    // build. The file sits beside settings.json under %LOCALAPPDATA%\SkyBridge so it is easy
    // to ask a user for, and is opened shared-read so it can be tailed while the app runs.
    private static void InstallTraceFileListener()
    {
        try
        {
            var directory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "SkyBridge",
                "logs");
            Directory.CreateDirectory(directory);

            var stream = new FileStream(
                Path.Combine(directory, "skybridge-win.log"),
                FileMode.Append,
                FileAccess.Write,
                FileShare.ReadWrite);

            Trace.Listeners.Add(new TextWriterTraceListener(stream) { Name = "skybridge-file" });
            Trace.AutoFlush = true;

            WindowsRuntimeLog.Write(
                WindowsLogLevel.Info,
                "app",
                $"Launched. Log file at {directory}.");
        }
        catch (Exception)
        {
            // Diagnostics must never be the reason the app fails to start. Without the file
            // listener the app behaves exactly as it did before; it is just harder to debug.
        }
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
    // WindowsAppSDK 2.4.0, so it is available. The value is persisted by the platform between
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
