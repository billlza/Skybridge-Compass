using System;
using System.Collections.Generic;
using System.Globalization;
using Microsoft.UI.Xaml.Data;

namespace Skybridge.WinClient.Converters;

/// <summary>
/// Localizes the per-page status line (the "Ready" text on each workspace page) at the
/// BINDING layer only  -- without ever touching the backing string the providers emit.
///
/// WHY a binding-layer converter and NOT a localized backing field:
///   The 7 workspace providers set their initial status to the canonical English literal
///   <c>"Ready"</c> (e.g. <c>_discoveryStatus = "Ready"</c>, <c>DefaultInitialStatus = "Ready"</c>),
///   and two CI gates assert that exact literal  -- Scripts/verify-windows-startup-state.ps1
///   (e.g. <c>AssertEqual("Ready", state.DiscoveryStatus, ...)</c>) and
///   Scripts/verify-windows-ui-parity.ps1 (the source-literal block
///   <c>_discoveryStatus = "Ready"</c> ... <c>_settingsStatus = "Ready"</c>). Changing the
///   field/value would break both gates. So the canonical English string stays the source of
///   truth and we translate ONLY what the user sees.
///
/// Behaviour:
///   - A KNOWN canonical English status (Ready / Idle / Preview ready / Intent ready /
///     No Core-validated peers / Discovery stopped) is mapped to its localized form for the
///     current UI language.
///   - Any UNKNOWN / dynamic string (honest live messages such as
///     "Prepared 192.168.0.10:11550", "Scanning 12:03:44 UTC", "Validated 3 peer(s)") passes
///     through VERBATIM  -- we never swallow a real status message into a generic localized one.
///   - null / empty passes through unchanged.
///
/// Language resolution mirrors App.xaml.cs's source of truth:
///   1. Microsoft.Windows.Globalization.ApplicationLanguages.PrimaryLanguageOverride (the
///      explicit choice the app applies on launch), when non-empty.
///   2. otherwise the current UI culture (system display language).
/// The resolved tag is folded to one of: "zh" (zh-Hans*), "ja", or "en" (default).
///
/// Value resolution is resw-FIRST, dictionary-FALLBACK (reliability over elegance):
///   We first try the indexed resources.pri via
///   Microsoft.Windows.ApplicationModel.Resources.ResourceManager (the WinAppSDK MRT Core
///   manager that works unpackaged  -- the same resource system x:Uid uses), reading the
///   Status.* key under a ResourceContext pinned to the resolved language. If that lookup
///   throws or returns nothing (e.g. an unpackaged path quirk), we fall back to a small
///   in-code trilingual table so a value is ALWAYS produced. The resw values and the table
///   are kept identical, so either path renders the same text.
/// </summary>
public sealed class StatusKeyToLocalizedConverter : IValueConverter
{
    // Canonical English status string -> Status.* resw key (also the in-code table key below).
    private static readonly Dictionary<string, string> CanonicalToResourceKey =
        new(StringComparer.Ordinal)
        {
            ["Ready"] = "Status.Ready",
            ["Idle"] = "Status.Idle",
            ["Preview ready"] = "Status.PreviewReady",
            ["Intent ready"] = "Status.IntentReady",
            ["No Core-validated peers"] = "Status.NoCoreValidatedPeers",
            ["Discovery stopped"] = "Status.DiscoveryStopped",
        };

    // In-code trilingual fallback, keyed by resource key then language fold ("en"/"zh"/"ja").
    // Mirrors Strings/{en-US,zh-Hans,ja}/Resources.resw Status.* values exactly.
    private static readonly Dictionary<string, Dictionary<string, string>> FallbackTable =
        new(StringComparer.Ordinal)
        {
            ["Status.Ready"] = new() { ["en"] = "Ready", ["zh"] = "就绪", ["ja"] = "準備完了" },
            ["Status.Idle"] = new() { ["en"] = "Idle", ["zh"] = "空闲", ["ja"] = "アイドル" },
            ["Status.PreviewReady"] = new() { ["en"] = "Preview ready", ["zh"] = "预览就绪", ["ja"] = "プレビュー準備完了" },
            ["Status.IntentReady"] = new() { ["en"] = "Intent ready", ["zh"] = "操作就绪", ["ja"] = "操作準備完了" },
            ["Status.NoCoreValidatedPeers"] = new() { ["en"] = "No Core-validated peers", ["zh"] = "未发现经核心校验的设备", ["ja"] = "コア検証済みのピアがありません" },
            ["Status.DiscoveryStopped"] = new() { ["en"] = "Discovery stopped", ["zh"] = "已停止发现", ["ja"] = "検出を停止しました" },
        };

    // Lazily-created MRT Core manager (shared; cheap to reuse). null if construction fails
    // (e.g. resources.pri unreachable)  -- in that case we always use the in-code table.
    private static Microsoft.Windows.ApplicationModel.Resources.ResourceManager? _resourceManager;
    private static bool _resourceManagerTried;

    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var input = value as string;
        if (string.IsNullOrEmpty(input))
        {
            return value ?? string.Empty;
        }

        // Unknown / dynamic status -> pass through untouched (honest live messages survive).
        if (!CanonicalToResourceKey.TryGetValue(input, out var resourceKey))
        {
            return input;
        }

        var lang = ResolveLanguageFold();

        // resw-first: try the indexed resources.pri under the resolved language.
        var fromResw = TryResolveFromResw(resourceKey, lang);
        if (!string.IsNullOrEmpty(fromResw))
        {
            return fromResw!;
        }

        // Dictionary fallback (always yields a value for a known key).
        if (FallbackTable.TryGetValue(resourceKey, out var perLang) &&
            (perLang.TryGetValue(lang, out var localized) || perLang.TryGetValue("en", out localized)))
        {
            return localized;
        }

        // Last resort: the canonical English the caller passed in.
        return input;
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language)
    {
        throw new NotSupportedException();
    }

    // Fold the active UI language to one of "zh" / "ja" / "en".
    private static string ResolveLanguageFold()
    {
        string? tag = null;
        try
        {
            var over = Microsoft.Windows.Globalization.ApplicationLanguages.PrimaryLanguageOverride;
            if (!string.IsNullOrWhiteSpace(over))
            {
                tag = over;
            }
        }
        catch (Exception)
        {
            // Runtime not ready / unsupported  -- fall through to the culture below.
        }

        if (string.IsNullOrWhiteSpace(tag))
        {
            try
            {
                tag = CultureInfo.CurrentUICulture.Name;
            }
            catch (Exception)
            {
                tag = "en";
            }
        }

        tag = (tag ?? "en").Trim().ToLowerInvariant();
        if (tag.StartsWith("zh", StringComparison.Ordinal))
        {
            return "zh";
        }
        if (tag.StartsWith("ja", StringComparison.Ordinal))
        {
            return "ja";
        }
        return "en";
    }

    // Returns the Status.* resw value for the requested language fold, or null on any failure.
    private static string? TryResolveFromResw(string resourceKey, string langFold)
    {
        var manager = GetResourceManager();
        if (manager is null)
        {
            return null;
        }

        try
        {
            var context = manager.CreateResourceContext();
            // Pin the language so the lookup honors the app's chosen UI language rather than
            // only the system default. BCP-47 tags are fine here.
            var bcp47 = langFold switch
            {
                "zh" => "zh-Hans",
                "ja" => "ja",
                _ => "en-US",
            };
            context.QualifierValues["Language"] = bcp47;

            // resw keys live under the "Resources" subtree; "Status.Ready" maps to
            // Resources/Status.Ready in the indexed map.
            var candidate = manager.MainResourceMap.TryGetValue("Resources/" + resourceKey, context);
            var text = candidate?.ValueAsString;
            return string.IsNullOrEmpty(text) ? null : text;
        }
        catch (Exception)
        {
            return null;
        }
    }

    private static Microsoft.Windows.ApplicationModel.Resources.ResourceManager? GetResourceManager()
    {
        if (_resourceManagerTried)
        {
            return _resourceManager;
        }

        _resourceManagerTried = true;
        try
        {
            _resourceManager = new Microsoft.Windows.ApplicationModel.Resources.ResourceManager();
        }
        catch (Exception)
        {
            _resourceManager = null;
        }
        return _resourceManager;
    }
}
