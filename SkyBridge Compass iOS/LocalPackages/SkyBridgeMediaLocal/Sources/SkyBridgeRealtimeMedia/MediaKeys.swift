import CryptoKit
import Foundation

public enum SkyBridgeMediaKeyDirection: String, Sendable {
    case send
    case receive
}

public enum SkyBridgeMediaEndpointRole: String, Sendable {
    case initiator
    case responder
}

public enum SkyBridgeMediaWireDirection: UInt8, Sendable {
    case initiatorToResponder = 1
    case responderToInitiator = 2
}

public struct SkyBridgeMediaDirectionKeys: Sendable {
    public let key: SymmetricKey
    public let nonceSalt: Data
    public let epoch: UInt32
    public let wireDirection: SkyBridgeMediaWireDirection
    public let transcriptPrefix: UInt64

    public init(
        key: SymmetricKey,
        nonceSalt: Data,
        epoch: UInt32,
        wireDirection: SkyBridgeMediaWireDirection,
        transcriptPrefix: UInt64
    ) {
        precondition(nonceSalt.count == 4, "SBMA v1 nonce salt must be 4 bytes")
        self.key = key
        self.nonceSalt = nonceSalt
        self.epoch = epoch
        self.wireDirection = wireDirection
        self.transcriptPrefix = transcriptPrefix
    }
}

public struct SkyBridgeMediaKeyMaterial: Sendable {
    public let send: SkyBridgeMediaDirectionKeys
    public let receive: SkyBridgeMediaDirectionKeys

    public init(send: SkyBridgeMediaDirectionKeys, receive: SkyBridgeMediaDirectionKeys) {
        self.send = send
        self.receive = receive
    }

    public static func derive(
        sendSecret: Data,
        receiveSecret: Data,
        sessionId: String,
        transcriptHash: Data = Data(),
        epoch: UInt32 = 0,
        localRole: SkyBridgeMediaEndpointRole = .initiator
    ) -> SkyBridgeMediaKeyMaterial {
        let sendDirection: SkyBridgeMediaWireDirection
        let receiveDirection: SkyBridgeMediaWireDirection
        switch localRole {
        case .initiator:
            sendDirection = .initiatorToResponder
            receiveDirection = .responderToInitiator
        case .responder:
            sendDirection = .responderToInitiator
            receiveDirection = .initiatorToResponder
        }
        let transcriptPrefix = transcriptPrefix(transcriptHash)
        return SkyBridgeMediaKeyMaterial(
            send: deriveDirection(
                baseKey: sendSecret,
                sessionId: sessionId,
                transcriptHash: transcriptHash,
                epoch: epoch,
                wireDirection: sendDirection,
                transcriptPrefix: transcriptPrefix
            ),
            receive: deriveDirection(
                baseKey: receiveSecret,
                sessionId: sessionId,
                transcriptHash: transcriptHash,
                epoch: epoch,
                wireDirection: receiveDirection,
                transcriptPrefix: transcriptPrefix
            )
        )
    }

    private static func deriveDirection(
        baseKey: Data,
        sessionId: String,
        transcriptHash: Data,
        epoch: UInt32,
        wireDirection: SkyBridgeMediaWireDirection,
        transcriptPrefix: UInt64
    ) -> SkyBridgeMediaDirectionKeys {
        var info = Data("skybridge-media-v1".utf8)
        info.append(0)
        info.append(Data(sessionId.utf8))
        info.append(0)
        info.append(wireDirection.rawValue)
        info.append(0)
        info.append(contentsOf: [
            UInt8((epoch >> 24) & 0xff),
            UInt8((epoch >> 16) & 0xff),
            UInt8((epoch >> 8) & 0xff),
            UInt8(epoch & 0xff)
        ])
        let output = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: baseKey),
            salt: transcriptHash,
            info: info,
            outputByteCount: 36
        )
        let material = output.withUnsafeBytes { Data($0) }
        return SkyBridgeMediaDirectionKeys(
            key: SymmetricKey(data: material.prefix(32)),
            nonceSalt: Data(material.suffix(4)),
            epoch: epoch,
            wireDirection: wireDirection,
            transcriptPrefix: transcriptPrefix
        )
    }

    private static func transcriptPrefix(_ transcriptHash: Data) -> UInt64 {
        var input = Data("SkyBridge-Media-Transcript-v1|".utf8)
        input.append(transcriptHash)
        return SHA256.hash(data: input).prefix(8).reduce(UInt64(0)) { partial, byte in
            (partial << 8) | UInt64(byte)
        }
    }
}
