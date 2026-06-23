using System;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Skybridge.WinClient.Services;

// =====================================================================================
//  SettingsStore — at-rest persistence of the Windows Settings page. Writes the typed
//  SkyBridgeSettings model as plaintext JSON to %LOCALAPPDATA%\SkyBridge\settings.json
//  (the same directory the SessionStore uses for session.bin).
//
//  This is modeled BYTE-FOR-BYTE on SessionStore.cs's defensive style, with ONE difference:
//  settings are NOT secrets, so there is NO DPAPI. ProtectedData would only make the file
//  impossible to inspect/diff and add a crypto failure mode for no security benefit. Plain
//  System.Text.Json (JsonIgnoreCondition.WhenWritingNull) is used, exactly like SessionStore's
//  JsonOptions.
//
//  Every method is defensive, matching SessionStore:
//    • Load()  — returns a fresh-default SkyBridgeSettings on ANY failure (missing file, empty
//                file, corrupt JSON, schema drift, foreign blob). A bad file never crashes the
//                app; it just behaves as "first run" and the defaults materialize.
//    • Save()  — best-effort; swallows write/serialize failures. A failed write must never break
//                an otherwise-good in-memory settings change — the user simply won't be remembered
//                across launches.
//    • Reset() — deletes the file (the next Save re-creates it). Reverting the in-memory model to
//                defaults is the SettingsService's job; this only clears the on-disk copy.
//
//  Schema versioning: SkyBridgeSettings carries SchemaVersion (starts at 1). A loaded file whose
//  SchemaVersion does not match the current version is treated as foreign → defaults (clean
//  migration boundary for the future).
// =====================================================================================

public sealed class SettingsStore
{
    // The schema version this build writes/expects. Bump when the model changes in a
    // non-backward-compatible way; a mismatch on Load() falls back to defaults.
    public const int CurrentSchemaVersion = 1;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        WriteIndented = true
    };

    private readonly string _directory;
    private readonly string _filePath;

    public SettingsStore()
    {
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        _directory = Path.Combine(localAppData, "SkyBridge");
        _filePath = Path.Combine(_directory, "settings.json");
    }

    /// <summary>Absolute path to the on-disk settings file (for diagnostics / Export defaults).</summary>
    public string FilePath => _filePath;

    public void Save(SkyBridgeSettings settings)
    {
        if (settings is null)
        {
            return;
        }

        try
        {
            Directory.CreateDirectory(_directory);

            var json = JsonSerializer.SerializeToUtf8Bytes(settings, JsonOptions);
            File.WriteAllBytes(_filePath, json);
        }
        catch (Exception)
        {
            // Persistence is best-effort: a failed write must not break an otherwise-good
            // in-memory settings change. The user simply won't be remembered across launches.
        }
    }

    public SkyBridgeSettings Load()
    {
        try
        {
            if (!File.Exists(_filePath))
            {
                return new SkyBridgeSettings();
            }

            var bytes = File.ReadAllBytes(_filePath);
            if (bytes.Length == 0)
            {
                return new SkyBridgeSettings();
            }

            var loaded = JsonSerializer.Deserialize<SkyBridgeSettings>(bytes, JsonOptions);
            if (loaded is null)
            {
                return new SkyBridgeSettings();
            }

            // Schema drift / foreign blob — treat as first run rather than honoring stale shapes.
            if (loaded.SchemaVersion != CurrentSchemaVersion)
            {
                return new SkyBridgeSettings();
            }

            return loaded;
        }
        catch (Exception)
        {
            // Corrupt JSON, schema drift, partial write — treat as "no persisted settings" and
            // return a fresh-default model rather than crashing.
            return new SkyBridgeSettings();
        }
    }

    public void Reset()
    {
        try
        {
            if (File.Exists(_filePath))
            {
                File.Delete(_filePath);
            }
        }
        catch (Exception)
        {
            // Nothing actionable if the delete fails; the next Save overwrites it anyway.
        }
    }

    /// <summary>
    /// Serialize the given settings to an arbitrary path (the user-chosen Export target). Throws
    /// on failure so the caller can surface a status — Export is an explicit user action, unlike
    /// the silent best-effort Save.
    /// </summary>
    public void ExportTo(string path, SkyBridgeSettings settings)
    {
        var json = JsonSerializer.SerializeToUtf8Bytes(settings, JsonOptions);
        File.WriteAllBytes(path, json);
    }

    /// <summary>
    /// Deserialize settings from an arbitrary path (the user-chosen Import source). Returns null
    /// if the file is missing/empty/corrupt/foreign-schema so the caller can leave the current
    /// settings untouched and report the failure honestly.
    /// </summary>
    public SkyBridgeSettings? ImportFrom(string path)
    {
        try
        {
            if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
            {
                return null;
            }

            var bytes = File.ReadAllBytes(path);
            if (bytes.Length == 0)
            {
                return null;
            }

            var loaded = JsonSerializer.Deserialize<SkyBridgeSettings>(bytes, JsonOptions);
            if (loaded is null || loaded.SchemaVersion != CurrentSchemaVersion)
            {
                return null;
            }

            return loaded;
        }
        catch (Exception)
        {
            return null;
        }
    }
}
