namespace Skybridge.WinClient.Services.RemoteControl;

internal static class WindowsH264AccessUnit
{
    internal readonly record struct Nal(int Offset, int Length, int Type);

    public static byte[] Prepare(byte[] encoded, ReadOnlySpan<byte> sequenceHeader, out bool isKeyFrame)
    {
        ArgumentNullException.ThrowIfNull(encoded);
        var units = Parse(encoded);
        isKeyFrame = units.Any(unit => unit.Type == 5);
        if (!units.Any(unit => unit.Type is 1 or 5))
            throw Invalid("The H.264 access unit has no picture slice.");
        if (!isKeyFrame) return encoded;
        var firstSlice = units.First(unit => unit.Type is 1 or 5).Offset;
        var hasSps = units.Any(unit => unit.Type == 7 && unit.Offset < firstSlice);
        var hasPps = units.Any(unit => unit.Type == 8 && unit.Offset < firstSlice);
        if (hasSps && hasPps) return encoded;
        var headers = Parse(sequenceHeader);
        var required = headers.Where(unit => (unit.Type == 7 && !hasSps) || (unit.Type == 8 && !hasPps)).ToArray();
        if ((!hasSps && !required.Any(unit => unit.Type == 7)) || (!hasPps && !required.Any(unit => unit.Type == 8)))
            throw Invalid("An H.264 IDR frame is missing its SPS/PPS decoder configuration.");
        var prefixLength = required.Sum(unit => 4 + unit.Length);
        var result = new byte[checked(prefixLength + encoded.Length)];
        var position = 0;
        foreach (var unit in required)
        {
            result[position + 3] = 1;
            sequenceHeader.Slice(unit.Offset, unit.Length).CopyTo(result.AsSpan(position + 4));
            position += 4 + unit.Length;
        }
        encoded.AsSpan().CopyTo(result.AsSpan(position));
        return result;
    }

    internal static IReadOnlyList<Nal> Parse(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length is < 4 or > 32 * 1024 * 1024)
            throw Invalid("H.264 Annex-B bytes are empty or exceed the frame budget.");
        var units = new List<Nal>();
        var position = 0;
        while (position < bytes.Length)
        {
            var prefix = PrefixLength(bytes, position);
            if (prefix == 0) throw Invalid("H.264 data is not a complete Annex-B access unit.");
            var start = position + prefix;
            var end = start;
            while (end < bytes.Length && PrefixLength(bytes, end) == 0) end++;
            var payloadEnd = end;
            while (payloadEnd > start && bytes[payloadEnd - 1] == 0) payloadEnd--;
            if (payloadEnd == start || (bytes[start] & 0x80) != 0)
                throw Invalid("H.264 contains an empty or invalid NAL unit.");
            var type = bytes[start] & 0x1f;
            if (type is < 1 or > 23) throw Invalid("H.264 contains an unsupported NAL unit type.");
            units.Add(new(start, payloadEnd - start, type));
            if (units.Count > 2048) throw Invalid("H.264 access unit exceeds the NAL count budget.");
            position = end;
        }
        return units;
    }

    private static int PrefixLength(ReadOnlySpan<byte> bytes, int index)
    {
        if (index + 2 >= bytes.Length || bytes[index] != 0 || bytes[index + 1] != 0) return 0;
        if (bytes[index + 2] == 1) return 3;
        return index + 3 < bytes.Length && bytes[index + 2] == 0 && bytes[index + 3] == 1 ? 4 : 0;
    }
    private static WindowsDesktopException Invalid(string message) => new(WindowsDesktopFailure.EncodingFailed, message);
}
