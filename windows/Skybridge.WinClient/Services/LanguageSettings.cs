using System;
using System.IO;
using System.Text.Json;

namespace Skybridge.WinClient.Services;

// =====================================================================================
//  LanguageSettings — the tiny, dependency-free reader/writer for the persisted UI-language
//  choice, used by App startup BEFORE any DI / SettingsService exists.
//
//  SOURCE OF TRUTH: the SAME file the rest of the app already persists settings to —
//  %LOCALAPPDATA%\SkyBridge\settings.json (written by SettingsStore as plaintext JSON). The
//  "Language" field there is the single source of truth, two-way bound from the 语言 dropdown in
//  the Settings ▸ General tab (SettingsCoordinator.Language → SettingsService.Language →
//  SkyBridgeSettings.Language → settings.json). We deliberately do NOT introduce a second store
//  (e.g. Windows.Storage.ApplicationData.LocalSettings): that would duplicate the value the
//  Settings UI already saves and create a divergence risk. Reading the same file means the
//  existing dropdown's persistence "just works" at the next launch.
//
//  Why a standalone helper instead of constructing SettingsService in App.OnLaunched? The language
//  override MUST be applied before MainWindow's XAML realizes (x:Uid snapshots the resolved
//  language on first lookup). At that point the SessionViewModel / SettingsCoordinator graph is not
//  built yet, and standing the whole service up just to read one string would be heavy and would
//  start its debounced-save timer. This reads the one field directly with System.Text.Json — no
//  WinAppSDK runtime dependency, fully unpackaged-safe.
//
//  Stored value convention (matches SkyBridgeSettings.Language defaults / the dropdown Tags):
//    ""  or  "system"  → follow the system display language (NO PrimaryLanguageOverride)
//    "zh-Hans"                                              → 简体中文
//    "ja"                                                   → 日本語
//    "en-US"  (legacy "en" accepted)                        → English
//
//  Get/Set deal in the STORED value; ResolveBcp47Override() maps the stored value to the BCP-47 tag
//  to hand to Microsoft.Windows.Globalization.ApplicationLanguages.PrimaryLanguageOverride (or null
//  for "follow system"). Every method is defensive: any IO/JSON failure → treated as "system".
// =====================================================================================

public static class LanguageSettings
{
    // The four stored values the UI offers. "system" is the sentinel for "follow the OS".
    public const string System = "system";
    public const string SimplifiedChinese = "zh-Hans";
    public const string Japanese = "ja";
    public const string English = "en-US";

    // The single source-of-truth file (same path/name SettingsStore uses).
    private static string SettingsFilePath =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "SkyBridge",
            "settings.json");

    /// <summary>
    /// Read the persisted stored language value (one of "", "system", "zh-Hans", "ja", "en-US").
    /// Returns "system" when the file is missing/empty/corrupt or the field is absent — i.e. the
    /// default "follow the system display language" behavior.
    /// </summary>
    public static string Get()
    {
        try
        {
            var path = SettingsFilePath;
            if (!File.Exists(path))
            {
                return System;
            }

            var bytes = File.ReadAllBytes(path);
            if (bytes.Length == 0)
            {
                return System;
            }

            // Tolerate a UTF-8 BOM (JsonDocument.Parse rejects it): a user editing settings.json in
            // Notepad / a PowerShell `Set-Content -Encoding utf8` can prepend EF BB BF. Strip it.
            var data = (bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF)
                ? new ReadOnlyMemory<byte>(bytes, 3, bytes.Length - 3)
                : new ReadOnlyMemory<byte>(bytes);

            using var doc = JsonDocument.Parse(data);
            if (doc.RootElement.ValueKind == JsonValueKind.Object &&
                doc.RootElement.TryGetProperty("Language", out var languageElement) &&
                languageElement.ValueKind == JsonValueKind.String)
            {
                var value = languageElement.GetString();
                return string.IsNullOrWhiteSpace(value) ? System : value!.Trim();
            }

            return System;
        }
        catch (Exception)
        {
            // Missing file, corrupt JSON, locked file — fall back to "system" (no override).
            return System;
        }
    }

    /// <summary>
    /// Persist the stored language value into settings.json, merging into the existing JSON object so
    /// no other setting is lost. Best-effort: a write/serialize failure is swallowed (the in-memory
    /// PrimaryLanguageOverride still takes effect for this session; only cross-launch persistence is
    /// affected). Normally the Settings UI persists via SettingsService; this exists so a caller that
    /// is OUTSIDE the DI graph can also write the value safely.
    /// </summary>
    public static void Set(string storedValue)
    {
        var normalized = string.IsNullOrWhiteSpace(storedValue) ? System : storedValue.Trim();

        try
        {
            var path = SettingsFilePath;
            var directory = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(directory))
            {
                Directory.CreateDirectory(directory);
            }

            // Merge into the existing object (preserve every other settings field) rather than
            // clobbering the file with a one-key document.
            var root = new System.Collections.Generic.Dictionary<string, JsonElement>(StringComparer.Ordinal);
            if (File.Exists(path))
            {
                var existing = File.ReadAllBytes(path);
                if (existing.Length > 0)
                {
                    try
                    {
                        using var doc = JsonDocument.Parse(existing);
                        if (doc.RootElement.ValueKind == JsonValueKind.Object)
                        {
                            foreach (var property in doc.RootElement.EnumerateObject())
                            {
                                root[property.Name] = property.Value.Clone();
                            }
                        }
                    }
                    catch (Exception)
                    {
                        // Corrupt existing file — start a fresh object rather than fail the write.
                    }
                }
            }

            using var stream = new MemoryStream();
            using (var writer = new Utf8JsonWriter(stream, new JsonWriterOptions { Indented = true }))
            {
                writer.WriteStartObject();
                var wroteLanguage = false;
                foreach (var pair in root)
                {
                    if (string.Equals(pair.Key, "Language", StringComparison.Ordinal))
                    {
                        writer.WriteString("Language", normalized);
                        wroteLanguage = true;
                    }
                    else
                    {
                        writer.WritePropertyName(pair.Key);
                        pair.Value.WriteTo(writer);
                    }
                }

                if (!wroteLanguage)
                {
                    writer.WriteString("Language", normalized);
                }

                writer.WriteEndObject();
            }

            File.WriteAllBytes(path, stream.ToArray());
        }
        catch (Exception)
        {
            // Persistence is best-effort — never crash on a settings write failure.
        }
    }

    /// <summary>
    /// Map the persisted stored value to the BCP-47 tag to pass to
    /// Microsoft.Windows.Globalization.ApplicationLanguages.PrimaryLanguageOverride. Returns null for
    /// "follow the system display language" (caller should then clear the override with String.Empty).
    /// </summary>
    public static string? ResolveBcp47Override()
    {
        return MapStoredValueToBcp47(Get());
    }

    /// <summary>
    /// Pure mapping from a stored value to its BCP-47 override tag (null == follow system). Exposed so
    /// the Settings UI can compute the immediate override to apply on change without re-reading disk.
    /// </summary>
    public static string? MapStoredValueToBcp47(string? storedValue)
    {
        var value = string.IsNullOrWhiteSpace(storedValue) ? System : storedValue!.Trim();

        return value switch
        {
            System => null,            // follow the system display language
            SimplifiedChinese => SimplifiedChinese,
            Japanese => Japanese,
            English => English,
            "en" => English,           // legacy stored value accepted
            _ => value,                // any explicit BCP-47 the user/file carried — honor it verbatim
        };
    }
}
