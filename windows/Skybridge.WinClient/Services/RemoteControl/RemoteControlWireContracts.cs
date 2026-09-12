using System.Buffers.Binary;
using System.Net;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Skybridge.WinClient.Services.RemoteControl;

internal sealed record RemoteControlMessage(
    [property: JsonPropertyName("type"), JsonRequired] string Type,
    [property: JsonPropertyName("payload"), JsonRequired] byte[] Payload,
    Guid? InputControlLease = null);

internal sealed record RemoteControlAccess(int Version, ulong Revision, string Role, Guid? Lease)
{
    internal const int CurrentVersion = 1;
    internal bool AllowsInput => Role == "controller";

    internal void Validate()
    {
        if (Version != CurrentVersion || Revision is 0 or > long.MaxValue ||
            Role is not ("controller" or "observer") ||
            (Role == "controller" && (Lease is null || Lease == Guid.Empty)) ||
            (Role == "observer" && Lease is not null))
            throw new InvalidDataException("Invalid remote input grant.");
    }
}

internal sealed record RemoteStreamTransaction(
    [property: JsonPropertyName("id")] Guid Id);

internal sealed record RemoteMediaEndpoint(
    [property: JsonPropertyName("host")] string Host,
    [property: JsonPropertyName("port")] int Port);

internal sealed record RemoteControlViewerAccount(string AccountDisplayName, string NebulaId);

internal sealed record RemoteControlSecurityIdentity(string AccountDisplayName, string NebulaId, string DeviceId, string DeviceName)
{
    internal void Validate()
    {
        foreach (var (value, maximum) in new[] { (AccountDisplayName, 320), (NebulaId, 256), (DeviceId, 256), (DeviceName, 128) })
            if (string.IsNullOrWhiteSpace(value) || value.Any(char.IsControl) || System.Text.Encoding.UTF8.GetByteCount(value) > maximum)
                throw new InvalidDataException("The current account and device must provide complete, bounded remote-control identity metadata.");
    }
}

internal sealed record RemoteStreamConfiguration
{
    public int? Width { get; init; }
    public int? Height { get; init; }
    public string? PreferredCodec { get; init; }
    public string[] SupportedVideoFormats { get; init; } = [];
    public string? QualityPreset { get; init; }
    public int? VideoCompressionLevel { get; init; }
    public bool? AdaptiveResolutionEnabled { get; init; }
    [JsonRequired] public int TargetFrameRate { get; init; }
    [JsonRequired] public int KeyFrameInterval { get; init; }
    public bool LowLatencyMode { get; init; }
    public bool EnableHardwareAcceleration { get; init; }
    public bool EnableAppleSiliconOptimization { get; init; }
    public bool ClipboardSyncEnabled { get; init; }
    public bool? DamageTrackingEnabled { get; init; }
    public bool? SeparateCursorChannelEnabled { get; init; }
    public bool? InteractionOverlayChannelEnabled { get; init; }
    public string? RefreshStrategy { get; init; }
    public string? ScreenFrameTransport { get; init; }
    public bool? AudioRedirectionEnabled { get; init; }
    public string? AudioTransport { get; init; }
    public string? AudioMode { get; init; }
    public string? MediaSessionId { get; init; }
    public RemoteMediaEndpoint? MediaAudioEndpoint { get; init; }
    public bool? CompatibilityAudioFallbackEnabled { get; init; }
    public int? AudioSampleRate { get; init; }
    public int? AudioChannelCount { get; init; }
    public string? MediaFallbackPolicy { get; init; }
    public ulong? StreamRefreshToken { get; init; }
    public int? FramePresentationAckVersion { get; init; }
    public int? RemoteControlAccessVersion { get; init; }
    public RemoteControlSecurityIdentity? RemoteControlSecurityIdentity { get; init; }
    [JsonPropertyName("captureDisplayID")] public uint? CaptureDisplayId { get; init; }
    [JsonRequired] public RemoteStreamTransaction StreamConfigurationTransaction { get; init; } = new(Guid.Empty);
    [JsonRequired] public double SentAt { get; init; }
    public bool IsStop => TargetFrameRate <= 0 || ScreenFrameTransport == "stopped" || RefreshStrategy == "stop";

    public void Validate(IPAddress authenticatedPeer, string authenticatedSessionId)
    {
        if (StreamConfigurationTransaction is null || StreamConfigurationTransaction.Id == Guid.Empty ||
            !double.IsFinite(SentAt) || SentAt <= 0)
        {
            throw new InvalidDataException("A stream configuration requires a transaction and finite send time.");
        }
        if (TargetFrameRate < 0) throw new InvalidDataException("Negative frame rates are invalid.");
        if (RemoteControlAccessVersion is not null and not RemoteControlAccess.CurrentVersion)
            throw new NotSupportedException("Unknown remote-control access version.");
        if (IsStop) return;
        if (TargetFrameRate is < 1 or > 120 || KeyFrameInterval is < 1 or > 600)
            throw new InvalidDataException("Frame rate or keyframe interval is outside the supported range.");
        if ((Width is null) != (Height is null) || Width is < 2 or > 8192 || Height is < 2 or > 8192)
            throw new InvalidDataException("Capture dimensions must be a complete, bounded pair.");
        if (Width.HasValue && (long)Width.Value * Height!.Value > 16_777_216)
            throw new InvalidDataException("Requested capture exceeds the pixel budget.");
        if (ScreenFrameTransport != "sbrf-v1" || !SupportedVideoFormats.Contains("h264", StringComparer.OrdinalIgnoreCase))
            throw new NotSupportedException("This host requires SBRF with H.264 in the supported video formats.");
        if (CaptureDisplayId.HasValue)
            throw new NotSupportedException("Apple display identifiers cannot select a Windows display.");
        if (ClipboardSyncEnabled || SeparateCursorChannelEnabled == true || InteractionOverlayChannelEnabled == true)
            throw new NotSupportedException("This host includes the pointer in video and does not expose clipboard or separate overlay channels.");
        if (FramePresentationAckVersion is not null and not 1)
            throw new NotSupportedException("Unknown frame presentation acknowledgement version.");
        if (CompatibilityAudioFallbackEnabled == true)
            throw new NotSupportedException("Legacy audio fallback is not supported by this host.");
        if (AudioRedirectionEnabled == true)
        {
            if (AudioTransport != "pqc-media-v1" || MediaSessionId != authenticatedSessionId ||
                AudioSampleRate != 48_000 || AudioChannelCount != 2 ||
                AudioMode is not ("low-latency" or "high-fidelity"))
                throw new InvalidDataException("Audio must use this authenticated session's 48 kHz stereo media transport.");
            if (MediaAudioEndpoint is null || MediaAudioEndpoint.Port is < 1 or > 65535 ||
                !IPAddress.TryParse(MediaAudioEndpoint.Host, out var address) ||
                !(address.MapToIPv6().Equals(authenticatedPeer.MapToIPv6()) ||
                  (authenticatedPeer.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork && address.Equals(IPAddress.Any)) ||
                  (authenticatedPeer.AddressFamily == System.Net.Sockets.AddressFamily.InterNetworkV6 && address.Equals(IPAddress.IPv6Any))))
                throw new InvalidDataException("The audio destination must be the authenticated control peer.");
        }
        else if (MediaAudioEndpoint is not null || AudioTransport is not (null or "disabled"))
        {
            throw new InvalidDataException("Disabled audio must not advertise a live media destination.");
        }
    }
}

internal sealed record RemoteStreamRejection(RemoteStreamTransaction Transaction, string Code, string Message);

internal sealed record RemoteStreamAcknowledgement(
    double AcceptedAt, RemoteStreamTransaction Transaction, ulong? StreamRefreshToken,
    bool AudioEndpointPresent, string? ScreenFrameTransport, int? FramePresentationAckVersion,
    RemoteControlAccess? ControlAccess = null);
internal sealed record RemotePointerEvent(
    [property: JsonRequired] string Type, [property: JsonRequired] double X,
    [property: JsonRequired] double Y, [property: JsonRequired] double Timestamp, int? ClickCount);
internal sealed record RemoteKeyEvent([property: JsonRequired] string Type,
    [property: JsonRequired] int KeyCode, [property: JsonRequired] double Timestamp);
internal sealed record RemoteFrameAcknowledgement(int Version, ulong SequenceNumber, RemoteStreamTransaction StreamTransaction);
internal sealed record RemoteH264ScreenFrame(byte[] Bytes, int Width, int Height, ulong TimestampMicroseconds,
    ulong Sequence, bool IsKeyFrame);

internal static class RemoteControlWire
{
    public const int MaximumInboundFrameBytes = 65_536;
    public const int MaximumOutboundFrameBytes = 8_000_000;
    internal static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = false,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        MaxDepth = 16,
        AllowDuplicateProperties = false
    };

    public static T Decode<T>(ReadOnlyMemory<byte> bytes) where T : class =>
        JsonSerializer.Deserialize<T>(bytes.Span, JsonOptions)
            ?? throw new InvalidDataException("The remote-control payload cannot be null.");

    public static byte[] EncodeMessage<T>(string type, T payload, Guid? inputControlLease = null) =>
        JsonSerializer.SerializeToUtf8Bytes(
            new RemoteControlMessage(type, JsonSerializer.SerializeToUtf8Bytes(payload, JsonOptions), inputControlLease), JsonOptions);

    public static RemoteH264ScreenFrame DecodeH264Frame(ReadOnlySpan<byte> bytes)
    {
        const int headerLength = 36;
        if (bytes.Length <= headerLength || bytes.Length > MaximumOutboundFrameBytes ||
            BinaryPrimitives.ReadUInt32BigEndian(bytes) != 0x53425246 || bytes[4] != 2 || bytes[5] != 2)
            throw new InvalidDataException("The viewer requires a bounded SBRF v2 H.264 frame.");
        var flags = BinaryPrimitives.ReadUInt16BigEndian(bytes[6..]);
        var width = BinaryPrimitives.ReadUInt32BigEndian(bytes[8..]);
        var height = BinaryPrimitives.ReadUInt32BigEndian(bytes[12..]);
        var timestamp = BinaryPrimitives.ReadUInt64BigEndian(bytes[16..]);
        var sequence = BinaryPrimitives.ReadUInt64BigEndian(bytes[24..]);
        var length = BinaryPrimitives.ReadUInt32BigEndian(bytes[32..]);
        if ((flags & ~1) != 0 || width is < 2 or > 8192 || height is < 2 or > 8192 ||
            (ulong)width * height > 16_777_216 || timestamp == 0 || sequence == 0 || length != bytes.Length - headerLength)
            throw new InvalidDataException("The SBRF frame has invalid dimensions, ordering, flags or payload length.");
        var payload = bytes[headerLength..];
        var units = WindowsH264AccessUnit.Parse(payload);
        var keyFrame = units.Any(unit => unit.Type == 5);
        if (!units.Any(unit => unit.Type is 1 or 5) || keyFrame != ((flags & 1) != 0))
            throw new InvalidDataException("The SBRF keyframe flag must match the H.264 picture slices.");
        return new(payload.ToArray(), (int)width, (int)height, timestamp, sequence, keyFrame);
    }

    public static byte[] EncodeH264Frame(
        ReadOnlySpan<byte> annexB, int width, int height, double timestampUnixSeconds, bool keyFrame, ulong sequence)
    {
        const int headerLength = 36;
        if (annexB.IsEmpty || annexB.Length > MaximumOutboundFrameBytes - 128 ||
            width is < 2 or > 8192 || height is < 2 or > 8192 ||
            !double.IsFinite(timestampUnixSeconds) || timestampUnixSeconds <= 0 ||
            timestampUnixSeconds > ulong.MaxValue / 1_000_000d)
            throw new InvalidDataException("The H.264 frame is outside the wire limits.");
        var result = new byte[headerLength + annexB.Length];
        var header = result.AsSpan(0, headerLength);
        BinaryPrimitives.WriteUInt32BigEndian(header, 0x53425246);
        header[4] = 2;
        header[5] = 2;
        BinaryPrimitives.WriteUInt16BigEndian(header[6..], keyFrame ? (ushort)1 : (ushort)0);
        BinaryPrimitives.WriteUInt32BigEndian(header[8..], checked((uint)width));
        BinaryPrimitives.WriteUInt32BigEndian(header[12..], checked((uint)height));
        BinaryPrimitives.WriteUInt64BigEndian(header[16..], checked((ulong)(timestampUnixSeconds * 1_000_000)));
        BinaryPrimitives.WriteUInt64BigEndian(header[24..], sequence);
        BinaryPrimitives.WriteUInt32BigEndian(header[32..], checked((uint)annexB.Length));
        annexB.CopyTo(result.AsSpan(headerLength));
        return result;
    }
}
