using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Serialization;

[JsonConverter(typeof(JsonStringEnumConverter<DesktopViewerInputEventKind>))]
internal enum DesktopViewerInputEventKind { MouseDown, MouseUp, MouseWheel, KeyDown, KeyUp, TextChanged, ClickTarget }

internal sealed record DesktopViewerInputEvent(
    long Sequence, DateTimeOffset TimeUtc, DesktopViewerInputEventKind Kind, string Target,
    string? Key, string? Modifiers, int? X, int? Y, string? Button, int? WheelDelta, int? TextLength);

/// <summary>Bounded observations from the owned window, never an input producer.</summary>
internal sealed class DesktopViewerInputReceipt
{
    internal const int MaximumEvents = 256;
    private readonly string _path;
    private readonly Queue<DesktopViewerInputEvent> _events = new(MaximumEvents);
    private readonly DateTimeOffset _started = DateTimeOffset.UtcNow;
    private long _eventCount;
    internal int TextChanges { get; private set; }
    internal int ClickTargetClicks { get; private set; }

    internal DesktopViewerInputReceipt(string evidence) => _path = Path.Combine(evidence, "viewer-input.json");

    internal void Key(DesktopViewerInputEventKind kind, KeyEventArgs args) =>
        Record(kind, "textBox", key: args.KeyCode.ToString(), modifiers: args.Modifiers.ToString());

    internal void Mouse(DesktopViewerInputEventKind kind, string target, MouseEventArgs args) =>
        Record(kind, target, x: args.X, y: args.Y, button: args.Button.ToString(), wheelDelta: args.Delta);

    internal void Text(int length)
    {
        TextChanges++;
        Record(DesktopViewerInputEventKind.TextChanged, "textBox", textLength: length);
    }

    internal void Click()
    {
        ClickTargetClicks++;
        Record(DesktopViewerInputEventKind.ClickTarget, "clickTarget");
    }

    private void Record(DesktopViewerInputEventKind kind, string target, string? key = null,
        string? modifiers = null, int? x = null, int? y = null, string? button = null, int? wheelDelta = null, int? textLength = null)
    {
        if (_events.Count == MaximumEvents) _events.Dequeue();
        _events.Enqueue(new(++_eventCount, DateTimeOffset.UtcNow, kind, target, key, modifiers, x, y, button, wheelDelta, textLength));
    }

    internal void Write(Form window, TextBox textBox, Button clickTarget, string status, string? reason,
        int mouseDown, int mouseUp, int keyDown, int keyUp, Exception? failure)
    {
        using var process = Process.GetCurrentProcess();
        var receipt = new
        {
            SchemaVersion = 1, Profile = "desktop-viewer-input", Status = status, CompletionReason = reason,
            WindowReady = window.IsHandleCreated, SelfInjectedInput = false, AssertionsPerformed = false,
            ProcessId = process.Id, SessionId = process.SessionId, WindowHandle = window.Handle.ToInt64(), WindowTitle = window.Text,
            StartedAtUtc = _started, UpdatedAtUtc = DateTimeOffset.UtcNow, DeadlineUtc = _started.AddMinutes(20),
            CoordinateSpace = "physical-screen-pixels", ScreenBounds = Bounds(Screen.FromHandle(window.Handle).Bounds),
            WindowBounds = Bounds(window.Bounds), TextBoxBounds = Bounds(textBox.RectangleToScreen(textBox.ClientRectangle)),
            ClickTargetBounds = Bounds(clickTarget.RectangleToScreen(clickTarget.ClientRectangle)),
            TextObserved = textBox.Text, MouseDownEvents = mouseDown, MouseUpEvents = mouseUp, KeyDownEvents = keyDown, KeyUpEvents = keyUp,
            TextChanges, ClickTargetClicks, TotalEvents = _eventCount, RecentEventLimit = MaximumEvents,
            EventsOmitted = _eventCount - _events.Count, RecentEvents = _events.ToArray(), Error = failure?.ToString()
        };
        var temporary = _path + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(receipt, new JsonSerializerOptions { WriteIndented = true }));
        File.Move(temporary, _path, true);
    }

    private static DesktopViewerBounds Bounds(Rectangle rectangle) => new(rectangle.X, rectangle.Y, rectangle.Width, rectangle.Height);
    private sealed record DesktopViewerBounds(int X, int Y, int Width, int Height);
}
