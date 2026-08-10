import Foundation

/// Canonical JSON encoder for cross-network file-transfer wire messages.
///
/// A fresh encoder is used for every call so mutable formatter state is never
/// shared across concurrent send paths. Sorted keys make the representation
/// deterministic, while unescaped slashes preserve the canonical Apple/Android
/// interoperability bytes without changing JSON decoding compatibility.
public enum CrossNetworkFileTransferWireEncoder {
    public static func encode(
        _ message: CrossNetworkFileTransferMessage
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(message)
    }
}
