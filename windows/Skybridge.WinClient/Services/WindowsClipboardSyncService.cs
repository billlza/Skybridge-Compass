using System;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

// WindowsClipboardSyncService
//
// Bidirectional OS-clipboard sync for Windows, mirroring the mature macOS
// Sources/SkyBridgeCore/Clipboard/ClipboardSyncService.swift:
//
//   macOS                                  Windows (this file)
//   -----                                  -------------------
//   NSPasteboard.changeCount poll          AddClipboardFormatListener + WM_CLIPBOARDUPDATE
//   change-count dedup                     sequence-number (GetClipboardSequenceNumber) dedup
//   lastContentHash loop suppression       ClipboardLoopGuard (WindowsClipboardSyncCore.cs)
//   AES.GCM.seal envelope                  ClipboardEnvelope (nonce||ct||tag)
//   connection.sendAppMessage(.clipboard)  ISkyBridgeDataPlane.SendAsync(DataPlaneChannel.Clipboard, ...)
//   ingestRemoteContent / applyRemoteContent  OnFrameReceived -> apply to OS clipboard
//
// === Clipboard-monitor approach + trade-off ===
// We use the Win32 path: a *message-only* window (HWND_MESSAGE) that registers via
// AddClipboardFormatListener and receives WM_CLIPBOARDUPDATE. Rationale:
//   * This app is UNPACKAGED (Skybridge.WinClient.csproj: WindowsPackageType=None),
//     so it has no package identity. The simpler WinRT path
//     (Windows.ApplicationModel.DataTransfer.Clipboard.ContentChanged +
//     Clipboard.GetContent()) is reliable only with package identity; unpackaged it
//     is flaky and GetContent() can throw. So we choose Win32 for robustness and
//     keep the WinRT option documented as a future packaged-build optimization.
//   * AddClipboardFormatListener is the modern, event-driven Win32 mechanism — no
//     polling, unlike macOS which is forced to poll changeCount. We still read
//     GetClipboardSequenceNumber() for a cheap dedup pre-filter.
//
// === Threading model ===
// Win32 clipboard APIs (OpenClipboard / GetClipboardData / SetClipboardData) are
// single-threaded-apartment (STA) and must run on the thread that owns the
// message-only window and pumps its messages. We therefore spin up ONE dedicated
// STA background thread that:
//   1. creates the message-only window,
//   2. AddClipboardFormatListener,
//   3. runs a GetMessage/DispatchMessage pump,
//   4. handles WM_CLIPBOARDUPDATE (read clipboard -> codec -> data plane) and a
//      custom WM_APP_APPLY (apply a received item) all on this same STA thread.
// Inbound frames from the data plane arrive on arbitrary threads; we marshal them
// onto the STA thread by PostMessage(WM_APP_APPLY) with a queued item, so all
// clipboard touches stay on the one owning thread. No WinUI DispatcherQueue is
// needed (and the message-only window is independent of the UI window lifetime).

/// <summary>
/// Monitors the Windows OS clipboard for local changes and applies received
/// remote items, exchanging AES-256-GCM envelopes over
/// <see cref="DataPlaneChannel.Clipboard"/>. All crypto / framing / dedup logic
/// lives in <see cref="ClipboardSyncCodec"/> (WindowsClipboardSyncCore.cs); this
/// class owns only the OS integration and lifecycle.
/// </summary>
internal sealed class WindowsClipboardSyncService : IDisposable
{
    private readonly ISkyBridgeDataPlane _dataPlane;
    private readonly ClipboardSyncCodec _codec;
    private readonly bool _syncImages;
    private readonly int _maxContentBytes;

    private readonly object _lifecycleGate = new();
    private bool _started;
    private bool _disposed;

#if WINDOWS
    private Thread? _pumpThread;
    private uint _pumpThreadId;
    private IntPtr _messageWindow;
    private WndProcDelegate? _wndProcKeepAlive; // pin so the delegate isn't GC'd
    private readonly ManualResetEventSlim _pumpReady = new(false);
    private uint _lastSequenceNumber;
    // Items handed to the STA pump for application, keyed by a token PostMessage carries.
    private readonly System.Collections.Concurrent.ConcurrentQueue<ClipboardPayload> _inboundApplyQueue = new();
#endif

    /// <param name="dataPlane">The shared data plane; clipboard rides channel Clipboard.</param>
    /// <param name="keyProvider">
    /// Session-key injection point. Pass the real handshake-derived key provider once
    /// it is wired; for bring-up pass <see cref="DerivedDevelopmentKeyProvider"/>.
    /// </param>
    /// <param name="syncImages">Whether to read/apply PNG images (default true, matches macOS).</param>
    /// <param name="maxContentBytes">Skip items larger than this (default 10 MiB, matches macOS).</param>
    public WindowsClipboardSyncService(
        ISkyBridgeDataPlane dataPlane,
        IClipboardSessionKeyProvider keyProvider,
        bool syncImages = true,
        int maxContentBytes = 10 * 1024 * 1024)
    {
        _dataPlane = dataPlane ?? throw new ArgumentNullException(nameof(dataPlane));
        _codec = new ClipboardSyncCodec(keyProvider ?? throw new ArgumentNullException(nameof(keyProvider)));
        _syncImages = syncImages;
        _maxContentBytes = maxContentBytes;
    }

    /// <summary>Start monitoring the OS clipboard and subscribe to inbound clipboard frames.</summary>
    public void Start()
    {
        lock (_lifecycleGate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (_started)
            {
                return;
            }

            _dataPlane.FrameReceived += OnFrameReceived;
            StartMonitor();
            _started = true;
        }
    }

    /// <summary>Stop monitoring and unsubscribe. Safe to call when not started.</summary>
    public void Stop()
    {
        lock (_lifecycleGate)
        {
            if (!_started)
            {
                return;
            }

            _dataPlane.FrameReceived -= OnFrameReceived;
            StopMonitor();
            _codec.Guard.Reset();
            _started = false;
        }
    }

    public void Dispose()
    {
        lock (_lifecycleGate)
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
        }

        Stop();
#if WINDOWS
        _pumpReady.Dispose();
#endif
    }

    // === Inbound: data plane -> OS clipboard ===

    private void OnFrameReceived(DataPlaneChannel channel, byte[] frame)
    {
        if (channel != DataPlaneChannel.Clipboard)
        {
            return; // not ours
        }

        ClipboardPayload? payload;
        try
        {
            payload = _codec.TryDecodeInbound(frame);
        }
        catch (Exception)
        {
            // Bad tag / malformed envelope / unknown kind — drop silently (fail closed).
            return;
        }

        if (payload is not { } item)
        {
            return; // duplicate / our own echo — suppressed by the loop guard
        }

        // Mark applied BEFORE touching the OS clipboard so the WM_CLIPBOARDUPDATE
        // that the apply causes is recognised as our echo and not re-broadcast.
        _codec.MarkInboundApplied(item);
        ApplyToOsClipboard(item);
    }

    // === Outbound: local OS clipboard change -> data plane ===

    /// <summary>
    /// Called on the STA pump thread when the local clipboard changed. Reads the
    /// item, runs it through the codec (dedup + seal), and sends it. Exposed
    /// internal so the monitor and tests can drive it; never throws to the pump.
    /// </summary>
    private void HandleLocalClipboardChanged()
    {
        ClipboardPayload? read;
        try
        {
            read = ReadOsClipboard();
        }
        catch (Exception)
        {
            return;
        }

        if (read is not { } payload)
        {
            return; // nothing syncable on the clipboard
        }

        byte[]? envelope;
        try
        {
            envelope = _codec.TryBuildOutboundEnvelope(payload);
        }
        catch (Exception)
        {
            return; // e.g. no session key yet -> fail closed, don't crash the pump
        }

        if (envelope is null)
        {
            return; // duplicate / echo of an applied item
        }

        if (!_dataPlane.IsConnected)
        {
            return; // nothing to send to yet; next change will resync
        }

        // Fire-and-forget; the data plane owns ordering on the Clipboard channel.
        _ = SendEnvelopeAsync(envelope);
    }

    private async Task SendEnvelopeAsync(byte[] envelope)
    {
        try
        {
            await _dataPlane.SendAsync(DataPlaneChannel.Clipboard, envelope).ConfigureAwait(false);
        }
        catch (Exception)
        {
            // Transient send failure; a later change re-syncs. Don't surface to the pump.
        }
    }

#if !WINDOWS
    // -----------------------------------------------------------------------
    // Non-Windows compile target (e.g. the net10.0 smoke project, were it ever to
    // include this file). The OS-integration members are stubs; the testable
    // pipeline lives entirely in WindowsClipboardSyncCore.cs and does not need them.
    // -----------------------------------------------------------------------
    private void StartMonitor() { }
    private void StopMonitor() { }
    private ClipboardPayload? ReadOsClipboard() => null;
    private void ApplyToOsClipboard(ClipboardPayload payload) { _ = payload; }
#else
    // -----------------------------------------------------------------------
    // Win32 message-only-window monitor + clipboard read/write (STA pump thread).
    // -----------------------------------------------------------------------

    private const int WM_DESTROY = 0x0002;
    private const int WM_CLIPBOARDUPDATE = 0x031D;
    private const int WM_APP_APPLY = 0x8001;         // WM_APP + 1: apply a queued inbound item
    private const int WM_APP_QUIT = 0x8002;          // WM_APP + 2: tear down the pump
    private static readonly IntPtr HWND_MESSAGE = new(-3);

    private const uint CF_UNICODETEXT = 13;
    // Registered clipboard format name for PNG; matches what browsers/apps use.
    private const string PngFormatName = "PNG";
    private uint _cfPng;

    private void StartMonitor()
    {
        _pumpReady.Reset();
        _pumpThread = new Thread(PumpThreadMain)
        {
            IsBackground = true,
            Name = "SkyBridge.ClipboardMonitor",
        };
        _pumpThread.SetApartmentState(ApartmentState.STA);
        _pumpThread.Start();
        // Wait briefly for the window + listener to come up so an immediate Stop() is ordered.
        _pumpReady.Wait(TimeSpan.FromSeconds(5));
    }

    private void StopMonitor()
    {
        var threadId = _pumpThreadId;
        if (threadId != 0)
        {
            // Ask the pump to quit on its own thread, then join.
            PostThreadMessage(threadId, WM_APP_QUIT, IntPtr.Zero, IntPtr.Zero);
        }

        _pumpThread?.Join(TimeSpan.FromSeconds(5));
        _pumpThread = null;
        _pumpThreadId = 0;
    }

    private void PumpThreadMain()
    {
        _pumpThreadId = GetCurrentThreadId();
        _cfPng = RegisterClipboardFormat(PngFormatName);

        _wndProcKeepAlive = WndProc;
        var wndProcPtr = Marshal.GetFunctionPointerForDelegate(_wndProcKeepAlive);

        var className = "SkyBridgeClipboardMonitor_" + Guid.NewGuid().ToString("N");
        var wc = new WNDCLASS
        {
            lpfnWndProc = wndProcPtr,
            hInstance = GetModuleHandle(null),
            lpszClassName = className,
        };

        var atom = RegisterClass(ref wc);
        if (atom == 0)
        {
            _pumpReady.Set();
            return;
        }

        _messageWindow = CreateWindowEx(
            0, className, string.Empty, 0, 0, 0, 0, 0,
            HWND_MESSAGE, IntPtr.Zero, wc.hInstance, IntPtr.Zero);

        if (_messageWindow == IntPtr.Zero)
        {
            _pumpReady.Set();
            return;
        }

        AddClipboardFormatListener(_messageWindow);
        _lastSequenceNumber = GetClipboardSequenceNumber();
        _pumpReady.Set();

        // Classic Win32 message loop.
        while (GetMessage(out var msg, IntPtr.Zero, 0, 0) > 0)
        {
            if (msg.message == WM_APP_QUIT)
            {
                break;
            }

            if (msg.message == WM_APP_APPLY && msg.hwnd == IntPtr.Zero)
            {
                DrainInboundApplyQueue();
                continue;
            }

            TranslateMessage(ref msg);
            DispatchMessage(ref msg);
        }

        // Teardown on the owning thread.
        if (_messageWindow != IntPtr.Zero)
        {
            RemoveClipboardFormatListener(_messageWindow);
            DestroyWindow(_messageWindow);
            _messageWindow = IntPtr.Zero;
        }

        UnregisterClass(className, wc.hInstance);
    }

    private IntPtr WndProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        switch (msg)
        {
            case WM_CLIPBOARDUPDATE:
                OnClipboardUpdate();
                return IntPtr.Zero;

            case WM_APP_APPLY:
                DrainInboundApplyQueue();
                return IntPtr.Zero;

            case WM_DESTROY:
                return IntPtr.Zero;
        }

        return DefWindowProc(hWnd, msg, wParam, lParam);
    }

    private void OnClipboardUpdate()
    {
        // Cheap sequence-number dedup pre-filter (mirrors macOS changeCount guard).
        var seq = GetClipboardSequenceNumber();
        if (seq == _lastSequenceNumber)
        {
            return;
        }

        _lastSequenceNumber = seq;
        HandleLocalClipboardChanged();
    }

    private void DrainInboundApplyQueue()
    {
        while (_inboundApplyQueue.TryDequeue(out var item))
        {
            WriteOsClipboard(item);
            // Keep our sequence baseline current so the resulting WM_CLIPBOARDUPDATE
            // is also filtered by the loop guard (which already marked it applied).
            _lastSequenceNumber = GetClipboardSequenceNumber();
        }
    }

    // Inbound items arrive off-thread; queue + post to the STA pump.
    private void ApplyToOsClipboard(ClipboardPayload payload)
    {
        _inboundApplyQueue.Enqueue(payload);
        var threadId = _pumpThreadId;
        if (threadId != 0)
        {
            PostThreadMessage(threadId, WM_APP_APPLY, IntPtr.Zero, IntPtr.Zero);
        }
    }

    // --- OS clipboard read (STA pump thread) ---

    private ClipboardPayload? ReadOsClipboard()
    {
        if (!OpenClipboard(_messageWindow))
        {
            return null;
        }

        try
        {
            // Prefer text (matches macOS readLocalClipboard ordering).
            if (IsClipboardFormatAvailable(CF_UNICODETEXT))
            {
                var text = ReadUnicodeText();
                if (text is { Length: > 0 })
                {
                    var payload = ClipboardPayload.Text(text);
                    if (payload.Content.Length <= _maxContentBytes)
                    {
                        return payload;
                    }
                }
            }

            if (_syncImages && _cfPng != 0 && IsClipboardFormatAvailable(_cfPng))
            {
                var png = ReadFormatBytes(_cfPng);
                if (png is { Length: > 0 } && png.Length <= _maxContentBytes)
                {
                    return ClipboardPayload.ImagePng(png);
                }
            }

            return null;
        }
        finally
        {
            CloseClipboard();
        }
    }

    private static string? ReadUnicodeText()
    {
        var handle = GetClipboardData(CF_UNICODETEXT);
        if (handle == IntPtr.Zero)
        {
            return null;
        }

        var ptr = GlobalLock(handle);
        if (ptr == IntPtr.Zero)
        {
            return null;
        }

        try
        {
            return Marshal.PtrToStringUni(ptr);
        }
        finally
        {
            GlobalUnlock(handle);
        }
    }

    private static byte[]? ReadFormatBytes(uint format)
    {
        var handle = GetClipboardData(format);
        if (handle == IntPtr.Zero)
        {
            return null;
        }

        var size = (int)GlobalSize(handle);
        if (size <= 0)
        {
            return null;
        }

        var ptr = GlobalLock(handle);
        if (ptr == IntPtr.Zero)
        {
            return null;
        }

        try
        {
            var bytes = new byte[size];
            Marshal.Copy(ptr, bytes, 0, size);
            return bytes;
        }
        finally
        {
            GlobalUnlock(handle);
        }
    }

    // --- OS clipboard write (STA pump thread) ---

    private void WriteOsClipboard(ClipboardPayload payload)
    {
        if (!OpenClipboard(_messageWindow))
        {
            return;
        }

        try
        {
            EmptyClipboard();
            switch (payload.Kind)
            {
                case ClipboardItemKind.Text:
                    WriteUnicodeText(payload.AsText());
                    break;

                case ClipboardItemKind.ImagePng:
                    if (_cfPng != 0)
                    {
                        WriteFormatBytes(_cfPng, payload.Content);
                    }

                    break;
            }
        }
        finally
        {
            CloseClipboard();
        }
    }

    private static void WriteUnicodeText(string text)
    {
        // CF_UNICODETEXT wants a null-terminated UTF-16 buffer in GMEM_MOVEABLE memory.
        var chars = text.Length + 1;
        var bytes = chars * sizeof(char);
        var hGlobal = GlobalAlloc(GMEM_MOVEABLE, (UIntPtr)bytes);
        if (hGlobal == IntPtr.Zero)
        {
            return;
        }

        var ptr = GlobalLock(hGlobal);
        if (ptr == IntPtr.Zero)
        {
            GlobalFree(hGlobal);
            return;
        }

        try
        {
            Marshal.Copy(text.ToCharArray(), 0, ptr, text.Length);
            Marshal.WriteInt16(ptr, text.Length * sizeof(char), 0); // null terminator
        }
        finally
        {
            GlobalUnlock(hGlobal);
        }

        if (SetClipboardData(CF_UNICODETEXT, hGlobal) == IntPtr.Zero)
        {
            GlobalFree(hGlobal); // ownership not transferred on failure
        }
    }

    private static void WriteFormatBytes(uint format, ReadOnlyMemory<byte> bytes)
    {
        var hGlobal = GlobalAlloc(GMEM_MOVEABLE, (UIntPtr)bytes.Length);
        if (hGlobal == IntPtr.Zero)
        {
            return;
        }

        var ptr = GlobalLock(hGlobal);
        if (ptr == IntPtr.Zero)
        {
            GlobalFree(hGlobal);
            return;
        }

        try
        {
            // Marshal.Copy needs a byte[]; .ToArray() avoids the unsafe pointer path
            // (the project does not enable AllowUnsafeBlocks).
            var buffer = bytes.ToArray();
            Marshal.Copy(buffer, 0, ptr, buffer.Length);
        }
        finally
        {
            GlobalUnlock(hGlobal);
        }

        if (SetClipboardData(format, hGlobal) == IntPtr.Zero)
        {
            GlobalFree(hGlobal);
        }
    }

    // --- P/Invoke ---

    private const uint GMEM_MOVEABLE = 0x0002;

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate IntPtr WndProcDelegate(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct WNDCLASS
    {
        public uint style;
        public IntPtr lpfnWndProc;
        public int cbClsExtra;
        public int cbWndExtra;
        public IntPtr hInstance;
        public IntPtr hIcon;
        public IntPtr hCursor;
        public IntPtr hbrBackground;
        [MarshalAs(UnmanagedType.LPWStr)] public string? lpszMenuName;
        [MarshalAs(UnmanagedType.LPWStr)] public string lpszClassName;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MSG
    {
        public IntPtr hwnd;
        public uint message;
        public IntPtr wParam;
        public IntPtr lParam;
        public uint time;
        public int ptX;
        public int ptY;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern ushort RegisterClass(ref WNDCLASS lpWndClass);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool UnregisterClass(string lpClassName, IntPtr hInstance);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateWindowEx(
        uint dwExStyle, string lpClassName, string lpWindowName, uint dwStyle,
        int x, int y, int nWidth, int nHeight,
        IntPtr hWndParent, IntPtr hMenu, IntPtr hInstance, IntPtr lpParam);

    [DllImport("user32.dll")]
    private static extern bool DestroyWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern IntPtr DefWindowProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern int GetMessage(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax);

    [DllImport("user32.dll")]
    private static extern bool TranslateMessage(ref MSG lpMsg);

    [DllImport("user32.dll")]
    private static extern IntPtr DispatchMessage(ref MSG lpMsg);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool PostThreadMessage(uint idThread, uint Msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool AddClipboardFormatListener(IntPtr hwnd);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RemoveClipboardFormatListener(IntPtr hwnd);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool OpenClipboard(IntPtr hWndNewOwner);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool CloseClipboard();

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool EmptyClipboard();

    [DllImport("user32.dll")]
    private static extern bool IsClipboardFormatAvailable(uint format);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr GetClipboardData(uint uFormat);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetClipboardData(uint uFormat, IntPtr hMem);

    [DllImport("user32.dll")]
    private static extern uint GetClipboardSequenceNumber();

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern uint RegisterClipboardFormat(string lpszFormat);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr GetModuleHandle(string? lpModuleName);

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GlobalAlloc(uint uFlags, UIntPtr dwBytes);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GlobalFree(IntPtr hMem);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GlobalLock(IntPtr hMem);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GlobalUnlock(IntPtr hMem);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern UIntPtr GlobalSize(IntPtr hMem);
#endif
}
