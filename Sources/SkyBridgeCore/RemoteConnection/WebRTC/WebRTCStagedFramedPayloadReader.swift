import Foundation
import SkyBridgeProtocolCore

/// One fully retained WebRTC control-channel frame and the route established
/// before its declared payload-sized allocation.
struct WebRTCStagedFramedPayload: Sendable, Equatable {
    let payload: Data
    let route: BoundSessionWebRTCFrameRouteV1
}

/// Reads the existing four-byte length framing with a fixed 19-byte admission
/// scratch. A BSC1 payload cannot cause a declared-size allocation until its
/// exact kind, cap, outer length, and initial SBWC fields have been validated.
struct WebRTCStagedFramedPayloadReader {
    typealias ReadChunk = @Sendable (_ maximumByteCount: Int) async throws -> Data

    private let readChunk: ReadChunk

    init(readChunk: @escaping ReadChunk) {
        self.readChunk = readChunk
    }

    func next() async throws -> WebRTCStagedFramedPayload {
        let encodedLength = try await readExactly(4)
        let declaredPayloadByteCount = Int(readUInt32(encodedLength))
        guard WebRTCFramedPayloadPolicy.isValidPayloadByteCount(declaredPayloadByteCount) else {
            throw BoundSessionWebRTCCarrierErrorV1.invalidOuterPayloadByteCount(
                declaredPayloadByteCount
            )
        }

        let prefixByteCount = min(
            BoundSessionWebRTCCarrierPolicyV1.stagedPrefixByteCount,
            declaredPayloadByteCount
        )
        let stagedPrefix = try await readExactly(prefixByteCount)
        let route = try BoundSessionWebRTCCarrierPolicyV1.classifyStagedPrefix(
            declaredPayloadByteCount: declaredPayloadByteCount,
            stagedPrefix: stagedPrefix
        )

        var payload = Data()
        payload.reserveCapacity(declaredPayloadByteCount)
        payload.append(stagedPrefix)
        if prefixByteCount < declaredPayloadByteCount {
            payload.append(
                try await readExactly(declaredPayloadByteCount - prefixByteCount)
            )
        }
        return WebRTCStagedFramedPayload(payload: payload, route: route)
    }

    private func readExactly(_ byteCount: Int) async throws -> Data {
        guard byteCount > 0 else {
            throw WebRTCStagedFramedPayloadReaderError.invalidReadByteCount(byteCount)
        }
        var bytes = Data()
        bytes.reserveCapacity(byteCount)
        while bytes.count < byteCount {
            try Task.checkCancellation()
            let remainingByteCount = byteCount - bytes.count
            let chunk = try await readChunk(min(65_536, remainingByteCount))
            guard !chunk.isEmpty else {
                throw WebRTCStagedFramedPayloadReaderError.emptyChunk
            }
            guard chunk.count <= remainingByteCount else {
                throw WebRTCStagedFramedPayloadReaderError.readExceededRequestedByteCount(
                    requested: remainingByteCount,
                    actual: chunk.count
                )
            }
            bytes.append(chunk)
        }
        try Task.checkCancellation()
        return bytes
    }

    private func readUInt32(_ data: Data) -> UInt32 {
        (UInt32(data[data.startIndex]) << 24)
            | (UInt32(data[data.startIndex + 1]) << 16)
            | (UInt32(data[data.startIndex + 2]) << 8)
            | UInt32(data[data.startIndex + 3])
    }
}

enum WebRTCStagedFramedPayloadReaderError: Error, Sendable, Equatable, LocalizedError {
    case invalidReadByteCount(Int)
    case emptyChunk
    case readExceededRequestedByteCount(requested: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .invalidReadByteCount(let actual):
            "invalid staged frame read byte count: \(actual)"
        case .emptyChunk:
            "staged frame source returned an empty chunk"
        case .readExceededRequestedByteCount(let requested, let actual):
            "staged frame source exceeded requested bytes: requested \(requested), got \(actual)"
        }
    }
}
