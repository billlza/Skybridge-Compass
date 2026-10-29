import Foundation

enum AudioBluetoothHandshakeWire {
    static let maximumBytes = 120
    static func packet(kind: UInt8, streamID: UUID, body: Data) -> Data {
        var wire = Data([0x53, 0x42, 0x41, 0x42, 1, kind, 0, 0])
        var tuple = streamID.uuid
        withUnsafeBytes(of: &tuple) { wire.append(contentsOf: $0) }
        wire.append(body)
        return wire
    }
    static func body(_ packet: Data, kind: UInt8, streamID: UUID, size: Int) throws -> Data {
        let header = self.packet(kind: kind, streamID: streamID, body: Data())
        guard packet.count == 24 + size, packet.count <= maximumBytes,
              packet.prefix(24) == header else { throw AudioBluetoothAttachmentError.unexpectedMessage }
        return Data(packet.dropFirst(24))
    }
}

/// Single serial owner, intentionally not Sendable. Native adapters hold this inside their own
/// actor/worker and acknowledge writes only after actual completion. No account/output grant.
public final class AudioBluetoothHandshake {
    public static let maximumFrameBytes = 120
    private enum Phase { case fresh, sendHello, waitChallenge, sendChallenge, waitFinish,
        sendFinish, waitReady, sendReady, established, transferred, failed }
    private let owner: AudioBluetoothAttachment
    private let secret: AudioBluetoothAttachmentSecret
    private let localNonce: Data
    private let sourceNonce: Data
    private var sinkNonce: Data?
    private var phase = Phase.fresh
    private var pending: Data?
    public var role: AudioBluetoothRole { owner.binding.role }
    private var streamID: UUID { owner.binding.offer.streamID }

    init(owner: AudioBluetoothAttachment, secret: AudioBluetoothAttachmentSecret, localNonce: Data, sourceNonce: Data) {
        self.owner = owner; self.secret = secret; self.localNonce = localNonce; self.sourceNonce = sourceNonce
        if owner.binding.role == .sink { sinkNonce = localNonce }
    }

    public func initialFrame() throws -> Data {
        try transition {
            guard phase == .fresh else { throw AudioBluetoothAttachmentError.alreadyIssued }
            if role == .source { return stage(.sendHello, kind: 1, body: sourceNonce + (try secret.helloProof(sourceNonce))) }
            return stage(.sendChallenge, kind: 2, body: sourceNonce + localNonce +
                (try secret.confirmation(role: .sink, sourceNonce: sourceNonce, sinkNonce: localNonce)))
        }
    }

    public func didSend(_ frame: Data) throws {
        try transition {
            guard pending == frame else { throw AudioBluetoothAttachmentError.unexpectedMessage }
            switch phase {
            case .sendHello: phase = .waitChallenge
            case .sendChallenge: phase = .waitFinish
            case .sendFinish: phase = .waitReady
            case .sendReady: phase = .established
            default: throw AudioBluetoothAttachmentError.unexpectedMessage
            }
            pending = nil
        }
    }

    /// nil has one meaning: the source verified the final sink Ready.
    public func receive(_ frame: Data) throws -> Data? {
        try transition {
            switch phase {
            case .waitChallenge:
                let body = try AudioBluetoothHandshakeWire.body(frame, kind: 2, streamID: streamID, size: 96)
                guard body.prefix(32) == sourceNonce else { throw AudioBluetoothAttachmentError.invalidNonce }
                let sink = Data(body.dropFirst(32).prefix(32))
                try secret.verify(Data(body.suffix(32)), role: .sink, sourceNonce: sourceNonce, sinkNonce: sink)
                sinkNonce = sink
                return stage(.sendFinish, kind: 3, body: sourceNonce + sink +
                    (try secret.confirmation(role: .source, sourceNonce: sourceNonce, sinkNonce: sink)))
            case .waitFinish:
                guard let sinkNonce else { throw AudioBluetoothAttachmentError.notReady }
                try secret.verify(proofBody(frame, kind: 3, sink: sinkNonce), role: .source, sourceNonce: sourceNonce, sinkNonce: sinkNonce)
                return stage(.sendReady, kind: 4, body: sourceNonce + sinkNonce + (try secret.readyProof(source: sourceNonce, sink: sinkNonce)))
            case .waitReady:
                guard let sinkNonce else { throw AudioBluetoothAttachmentError.notReady }
                try secret.verifyReady(proofBody(frame, kind: 4, sink: sinkNonce), source: sourceNonce, sink: sinkNonce)
                phase = .established
                return nil
            default: throw AudioBluetoothAttachmentError.unexpectedMessage
            }
        }
    }

    public func takeRecordCipher() throws -> AudioBluetoothRecordCipher {
        guard phase == .established, let sinkNonce else { throw AudioBluetoothAttachmentError.notReady }
        do {
            try owner.requireHandshakeCurrent()
            let material = try secret.traffic(role: role, source: sourceNonce, sink: sinkNonce)
            try owner.commitHandshake(); try owner.requireEstablishedCurrent()
            let cipher = try AudioBluetoothRecordCipher(binding: owner.binding, material: material,
                requireCurrent: { [owner] in try owner.requireEstablishedCurrent() }, closeOwner: { [owner] in owner.close() })
            phase = .transferred
            return cipher
        } catch { phase = .failed; owner.close(); throw error }
    }

    private func proofBody(_ frame: Data, kind: UInt8, sink: Data) throws -> Data {
        let body = try AudioBluetoothHandshakeWire.body(frame, kind: kind, streamID: streamID, size: 96)
        guard body.prefix(32) == sourceNonce, body.dropFirst(32).prefix(32) == sink else { throw AudioBluetoothAttachmentError.invalidNonce }
        return Data(body.suffix(32))
    }
    private func stage(_ next: Phase, kind: UInt8, body: Data) -> Data {
        let frame = AudioBluetoothHandshakeWire.packet(kind: kind, streamID: streamID, body: body)
        phase = next; pending = frame
        return frame
    }
    private func transition<T>(_ action: () throws -> T) throws -> T {
        do {
            try owner.requireHandshakeCurrent()
            let value = try action()
            try owner.requireHandshakeCurrent()
            return value
        } catch { phase = .failed; pending = nil; owner.close(); throw error }
    }
}
