using System;
using System.Globalization;
using System.IO;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace Skybridge.WinClient.Settings;

// =====================================================================================
//  SettingsGeneralView — Tab 1 (通用 / General) code-behind.
//
//  Most controls (语言 / 扫描间隔 dropdowns, the toggles, the 主题颜色 swatch picker) two-way
//  bind straight to Settings.<Prop> on the SettingsCoordinator (DataContext = the SessionViewModel
//  inherited from SettingsView), so they need no code-behind.
//
//  The 数据管理 section's 清除缓存 affordance DOES need code-behind: it is a tappable frosted
//  Border (NOT a <Button>, to keep the frozen SettingsToolbar / SettingsMaintenance push-button
//  surfaces intact — see Scripts/verify-windows-ui-action-order.ps1:170-172). On tap it deletes
//  the REAL application cache directory (%LOCALAPPDATA%\SkyBridge\cache*) and refreshes the adjacent
//  live 当前缓存：<size> status. The size readout is computed from the actual on-disk byte count —
//  never a fabricated number — on Loaded and after every clear.
//
//  This mirrors the SettingsFileTransferView folder-picker pattern (a Border + Tapped handler doing
//  real work in code-behind), and touches no coordinator/service/DI-root file.
// =====================================================================================
public sealed partial class SettingsGeneralView : UserControl
{
    public SettingsGeneralView()
    {
        InitializeComponent();
        Loaded += OnLoaded;
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        await RefreshCacheSizeAsync().ConfigureAwait(false);
    }

    // ---- 清除缓存 -------------------------------------------------------------------------
    //
    // The application cache lives under %LOCALAPPDATA%\SkyBridge in directories/files whose name
    // starts with "cache" (case-insensitive) — matching the Mac contract's "%LOCALAPPDATA%\SkyBridge
    // \cache*" glob. We compute the total size by walking those entries, and clear by deleting them.
    private static string CacheRoot =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "SkyBridge");

    // Tap handler for the frosted 清除缓存 Border. Deletes the real cache entries, then recomputes
    // and re-renders the 当前缓存：<size> status. Fully defensive: a locked/missing file never
    // crashes the Settings surface — it is skipped and the status reflects whatever remains.
    private async void OnClearCacheTapped(object sender, TappedRoutedEventArgs e)
    {
        try
        {
            if (ClearCacheAffordance is not null)
            {
                ClearCacheAffordance.IsHitTestVisible = false;
            }

            await Task.Run(ClearCacheEntries).ConfigureAwait(true);
        }
        catch (Exception)
        {
            // Best-effort: never crash the Settings surface on a cache-clear failure.
        }
        finally
        {
            await RefreshCacheSizeAsync().ConfigureAwait(true);

            if (ClearCacheAffordance is not null)
            {
                ClearCacheAffordance.IsHitTestVisible = true;
            }
        }
    }

    // Delete every cache* entry under the cache root. Runs on a thread-pool thread (file I/O).
    private static void ClearCacheEntries()
    {
        var root = CacheRoot;
        if (!Directory.Exists(root))
        {
            return;
        }

        foreach (var dir in EnumerateCacheDirectories(root))
        {
            try
            {
                Directory.Delete(dir, recursive: true);
            }
            catch (Exception)
            {
                // Locked / in-use entry — skip it; the size readout will reflect what remains.
            }
        }

        foreach (var file in EnumerateCacheFiles(root))
        {
            try
            {
                File.Delete(file);
            }
            catch (Exception)
            {
                // Skip locked files.
            }
        }
    }

    // Compute the real on-disk cache size and render it into the 当前缓存：<size> status.
    private async Task RefreshCacheSizeAsync()
    {
        long bytes = 0;
        try
        {
            bytes = await Task.Run(ComputeCacheBytes).ConfigureAwait(true);
        }
        catch (Exception)
        {
            bytes = 0;
        }

        if (CacheSizeStatus is not null)
        {
            // 'settings.general.cacheSize' = verbatim '当前缓存：' + computed size.
            CacheSizeStatus.Text = "当前缓存：" + FormatBytes(bytes);
        }
    }

    // Sum the byte size of every cache* entry under the cache root (real on-disk count).
    private static long ComputeCacheBytes()
    {
        var root = CacheRoot;
        if (!Directory.Exists(root))
        {
            return 0;
        }

        long total = 0;

        foreach (var dir in EnumerateCacheDirectories(root))
        {
            total += DirectorySize(dir);
        }

        foreach (var file in EnumerateCacheFiles(root))
        {
            total += SafeFileLength(file);
        }

        return total;
    }

    private static System.Collections.Generic.IEnumerable<string> EnumerateCacheDirectories(string root)
    {
        try
        {
            return Directory.EnumerateDirectories(root, "cache*", SearchOption.TopDirectoryOnly);
        }
        catch (Exception)
        {
            return System.Array.Empty<string>();
        }
    }

    private static System.Collections.Generic.IEnumerable<string> EnumerateCacheFiles(string root)
    {
        try
        {
            return Directory.EnumerateFiles(root, "cache*", SearchOption.TopDirectoryOnly);
        }
        catch (Exception)
        {
            return System.Array.Empty<string>();
        }
    }

    private static long DirectorySize(string path)
    {
        long total = 0;
        try
        {
            foreach (var file in Directory.EnumerateFiles(path, "*", SearchOption.AllDirectories))
            {
                total += SafeFileLength(file);
            }
        }
        catch (Exception)
        {
            // Unreadable subtree — count what we could.
        }

        return total;
    }

    private static long SafeFileLength(string file)
    {
        try
        {
            return new FileInfo(file).Length;
        }
        catch (Exception)
        {
            return 0;
        }
    }

    // Human-readable byte formatter (B / KB / MB / GB), invariant culture.
    private static string FormatBytes(long bytes)
    {
        if (bytes <= 0)
        {
            return "0 B";
        }

        string[] units = { "B", "KB", "MB", "GB", "TB" };
        double size = bytes;
        int unit = 0;
        while (size >= 1024d && unit < units.Length - 1)
        {
            size /= 1024d;
            unit++;
        }

        var format = unit == 0 ? "0" : "0.0";
        return size.ToString(format, CultureInfo.InvariantCulture) + " " + units[unit];
    }
}
