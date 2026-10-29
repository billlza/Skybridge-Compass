import Foundation

/// The authenticated MAIN/USB carrier. This is not an SBWC packet or a second
/// encryption protocol: the connection seals this envelope with its current keys.
public enum AudioStreamingLANEnvelope {
    public static let headerBytes = 13
    public static let maximumBytes = headerBytes + AudioStreamingWire.maximumMessageBytes
    private static let prefix: [UInt8] = [0x53, 0x42, 0x45, 0x31, 2] // SBE1, audio

    public static func encode(_ message: AudioStreamingMessage) throws -> Data {
        var result = Data(prefix)
        result.append(contentsOf: repeatElement(UInt8(0), count: 8))
        result.append(try AudioStreamingWire.encode(message))
        return result
    }

    /// Returns nil only for another carrier. Once kind 2 is identified, malformed
    /// data is an error; it must never fall through to the legacy JSON decoder.
    public static func decodeIfPresent(_ data: Data) throws -> AudioStreamingMessage? {
        guard data.prefix(prefix.count).elementsEqual(prefix) else { return nil }
        guard data.count <= maximumBytes else { throw AudioStreamingWireError.oversized }
        guard data.count >= headerBytes,
              data.dropFirst(prefix.count).prefix(8).allSatisfy({ $0 == 0 }) else {
            throw AudioStreamingWireError.malformed
        }
        return try AudioStreamingWire.decode(Data(data.dropFirst(headerBytes)))
    }
}
