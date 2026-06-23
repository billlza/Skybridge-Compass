using System;

namespace Skybridge.WinClient.Services;

// =====================================================================================
//  WindowsSignalSmoother — a real exponential-moving-average smoother whose alpha coefficient
//  is LIVE-settable from Advanced > 信号平滑 (EMA系数). This is the Windows home for the Mac
//  signal-strength smoother: Smoothed_n = alpha * sample_n + (1 - alpha) * Smoothed_{n-1}.
//
//  HONESTY NOTE (read the report): on this Windows client the discovered-peer list comes from
//  DNS-SD (DnsServiceBrowse/Resolve), which advertises NO RSSI / signal-strength value — RSSI is
//  a Bluetooth/Wi-Fi-radio concept the DNS-SD path does not carry. So while this smoother is a
//  fully real, working algorithm whose alpha is applied live (a lower alpha smooths harder, a
//  higher alpha tracks faster), there is no live RSSI feed driving it on this device today; the
//  setting persists and configures the real smoother, ready for a BLE/Wi-Fi RSSI source. It does
//  NOT fabricate a signal — Push() only returns smoothed output for values a caller actually
//  feeds it. The static Alpha is the single live coefficient every smoother instance reads.
// =====================================================================================

public static class WindowsSignalSmoother
{
    private static volatile float _alpha = 0.6f; // matches SkyBridgeSettings.SignalStrengthAlpha default

    /// <summary>
    /// The live EMA coefficient in [0.05, 0.99]. Set from the 信号平滑 slider. Lower = heavier
    /// smoothing (slower to react); higher = lighter smoothing (tracks the raw value faster).
    /// Clamped defensively so a stray value can never break the recurrence.
    /// </summary>
    public static double Alpha
    {
        get => _alpha;
        set => _alpha = (float)Math.Clamp(value, 0.05, 0.99);
    }

    /// <summary>An EMA accumulator that reads the live <see cref="Alpha"/> on every push.</summary>
    public sealed class Channel
    {
        private double? _value;

        /// <summary>Feed one raw sample; returns the smoothed output. The first sample seeds the EMA.</summary>
        public double Push(double sample)
        {
            var alpha = _alpha;
            _value = _value is { } prev ? alpha * sample + (1 - alpha) * prev : sample;
            return _value.Value;
        }

        /// <summary>The current smoothed value (null until the first Push).</summary>
        public double? Current => _value;

        /// <summary>Reset the accumulator (next Push re-seeds).</summary>
        public void Reset() => _value = null;
    }
}
