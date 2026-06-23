using System;
using System.Diagnostics;

namespace Skybridge.WinClient.Services;

// =====================================================================================
//  WindowsRuntimeLog — the process-wide diagnostics sink whose MINIMUM LEVEL is live and
//  settable from the Advanced > 调试 settings (详细日志 + 日志级别). Before this existed the
//  Windows client had no logger at all (grep-confirmed: no ILogger / Trace sink), so the
//  Advanced logging toggles had nothing to drive. This is a small, real, dependency-free
//  sink built on System.Diagnostics.Trace — every emit below the current MinimumLevel is
//  dropped, so flipping 日志级别 / 详细日志 changes what actually gets written, live.
//
//  It is deliberately tiny and static: the SettingsCoordinator's logger effect hook sets
//  MinimumLevel (and the verbose flag forces it down to Trace), and any subsystem that wants
//  to emit calls WindowsRuntimeLog.Write(level, ...). No fabricated effect: the level gate is
//  observable — Trace listeners (DefaultTraceListener / the debugger output window / any
//  attached listener) receive exactly the lines at-or-above the live threshold.
// =====================================================================================

public enum WindowsLogLevel
{
    Trace = 0,
    Debug = 1,
    Info = 2,
    Warning = 3,
    Error = 4,
    None = 5
}

public static class WindowsRuntimeLog
{
    private static readonly object Sync = new();
    private static volatile WindowsLogLevel _minimumLevel = WindowsLogLevel.Info;

    /// <summary>
    /// The live minimum level. Emits strictly below this are dropped. Default "Info" matches the
    /// SkyBridgeSettings.LogLevel default. Setting it takes effect immediately for every later
    /// Write — that is the observable behavior the 日志级别 dropdown / 详细日志 toggle produce.
    /// </summary>
    public static WindowsLogLevel MinimumLevel
    {
        get => _minimumLevel;
        set => _minimumLevel = value;
    }

    /// <summary>
    /// Apply the settings-level pair: the 日志级别 dropdown string ("Trace"/"Debug"/"Info"/
    /// "Warning"/"Error"/"None") sets the floor; 详细日志 (verbose) forces it down to Trace so the
    /// most detailed lines flow regardless of the dropdown. Unknown level strings keep the prior
    /// floor (defensive — never silently widen logging on a typo).
    /// </summary>
    public static void Apply(string? logLevel, bool verbose)
    {
        if (verbose)
        {
            MinimumLevel = WindowsLogLevel.Trace;
            return;
        }

        MinimumLevel = ParseLevel(logLevel, MinimumLevel);
    }

    public static WindowsLogLevel ParseLevel(string? value, WindowsLogLevel fallback) =>
        (value ?? string.Empty).Trim().ToLowerInvariant() switch
        {
            "trace" or "verbose" => WindowsLogLevel.Trace,
            "debug" => WindowsLogLevel.Debug,
            "info" or "information" => WindowsLogLevel.Info,
            "warn" or "warning" => WindowsLogLevel.Warning,
            "error" => WindowsLogLevel.Error,
            "none" or "off" => WindowsLogLevel.None,
            _ => fallback
        };

    /// <summary>
    /// Emit one line if its level is at-or-above the live minimum. Routed through
    /// System.Diagnostics.Trace so any attached listener (the debugger output, a file listener,
    /// the default OutputDebugString sink) receives it. Never throws.
    /// </summary>
    public static void Write(WindowsLogLevel level, string category, string message)
    {
        if (level < _minimumLevel || level == WindowsLogLevel.None)
        {
            return;
        }

        try
        {
            lock (Sync)
            {
                Trace.WriteLine($"[{DateTimeOffset.Now:HH:mm:ss}] [{level}] [{category}] {message}");
            }
        }
        catch (Exception)
        {
            // A logging sink must never crash the caller; drop on any listener failure.
        }
    }
}
