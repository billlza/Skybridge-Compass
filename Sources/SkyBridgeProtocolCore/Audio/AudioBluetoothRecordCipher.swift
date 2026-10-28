import CryptoKit
import Foundation
import os

struct AudioBluetoothTrafficMaterial: Sendable {
    let context: Data
    let sendKey: SymmetricKey
    let receiveKey: SymmetricKey
}

/// Ordered, direction-bound records for one confirmed CoC. A fresh key pair and owned counters
/// make the implicit GCM nonces unique. This supplies no account or native output permission.
public final class AudioBluetoothRecordCipher: Sendable {
    public static let maximumRecords: UInt64 = 1 << 24
    public static let maximumRecordBytes = 8 + 28 + 8 + AudioStreamingWire.maximumOpusPacketBytes + 16
    private struct State: Sendable {
        var keys: AudioBluetoothTrafficMaterial?
        var nextSend: UInt64 = 1
        var nextReceive: UInt64 = 1
    }
    private let state: OSAllocatedUnfairLock<State>
    private let binding: AudioBluetoothBinding
    private let format: AudioStreamingOpusFormat
    private let buffering: AudioStreamingOpusBuffering
    private let requireCurrent: @Sendable () throws -> Void
    private let closeOwner: @Sendable () -> Void
    private let recordBudget: UInt64

    init(binding: AudioBluetoothBinding, material: AudioBluetoothTrafficMaterial,
         requireCurrent: @escaping @Sendable () throws -> Void, closeOwner: @escaping @Sendable () -> Void,
         recordBudget: UInt64 = maximumRecords) throws {
        guard (1...Self.maximumRecords).contains(recordBudget), let offer = binding.offer.body.opusOfferParameters else {
            throw AudioBluetoothAttachmentError.invalidBinding
        }
        self.binding = binding; self.format = offer.format; self.buffering = offer.buffering; self.requireCurrent = requireCurrent
        self.closeOwner = closeOwner; self.recordBudget = recordBudget
        state = .init(initialState: State(keys: material))
    }

    public func seal(_ message: AudioStreamingMessage) throws -> Data {
        try perform {
            try state.withLock { value in
                guard let material = value.keys else { throw AudioBluetoothAttachmentError.closed }
                guard value.nextSend <= recordBudget else { throw AudioBluetoothAttachmentError.recordLimit }
                try validate(message, sender: binding.role)
                let plaintext = try AudioStreamingWire.encode(message)
                let counter = Self.counterBytes(value.nextSend)
                let box = try AES.GCM.seal(plaintext, using: material.sendKey, nonce: AES.GCM.Nonce(data: nonce(counter)),
                    authenticating: aad(context: material.context, role: binding.role, counter: counter))
                value.nextSend += 1
                return counter + box.ciphertext + box.tag
            }
        }
    }

    public func open(_ record: Data) throws -> AudioStreamingMessage {
        try perform {
            try state.withLock { value in
                guard let material = value.keys else { throw AudioBluetoothAttachmentError.closed }
                guard (52...Self.maximumRecordBytes).contains(record.count) else { throw AudioBluetoothAttachmentError.malformedRecord }
                let counter = Data(record.prefix(8))
                let sequence = counter.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                guard value.nextReceive <= recordBudget, sequence == value.nextReceive else { throw AudioBluetoothAttachmentError.recordOrder }
                let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce(counter)),
                    ciphertext: Data(record.dropFirst(8).dropLast(16)), tag: Data(record.suffix(16)))
                let plaintext = try AES.GCM.open(box, using: material.receiveKey,
                    authenticating: aad(context: material.context, role: binding.role.peer, counter: counter))
                let message = try AudioStreamingWire.decode(plaintext)
                try validate(message, sender: binding.role.peer)
                value.nextReceive += 1
                return message
            }
        }
    }

    public func close() {
        state.withLock { $0.keys = nil }
        closeOwner()
    }

    private func perform<T: Sendable>(_ operation: @Sendable () throws -> T) throws -> T {
        do {
            try requireCurrent()
            let result = try operation()
            try requireCurrent()
            return result
        } catch { close(); throw error }
    }

    private func validate(_ message: AudioStreamingMessage, sender: AudioBluetoothRole) throws {
        guard message.streamID == binding.offer.streamID else { throw AudioBluetoothAttachmentError.invalidBinding }
        let packet = UInt64(format.packetBytes)
        let permitted: Bool
        switch message.body {
        case .opusConfiguration: permitted = sender == .source
        case .opusData(_, let bytes): permitted = sender == .source && UInt64(bytes.count) == packet
        case .opusEnd(_, let count, let total, _): permitted = sender == .source && count > 0 && total / count == packet
        case .accept(let window): permitted = sender == .sink &&
            (packet...(UInt64(buffering.windowPackets) * packet)).contains(UInt64(window)) && UInt64(window) % packet == 0
        case .credit(let retired): permitted = sender == .sink && retired % packet == 0
        case .contentVerified(let total, _): permitted = sender == .sink && total > 0 && total % packet == 0
        case .opusOutputReady: permitted = sender == .sink
        case .playbackComplete(let frames, _): permitted = sender == .sink && frames > 0
        case .stop: permitted = true
        default: permitted = false
        }
        guard permitted else { throw AudioBluetoothAttachmentError.unsupportedMediaRole }
    }

    private static func counterBytes(_ value: UInt64) -> Data {
        Data((0..<8).reversed().map { UInt8((value >> ($0 * 8)) & 255) })
    }
    private func nonce(_ counter: Data) -> Data { Data(repeating: 0, count: 4) + counter }
    private func aad(context: Data, role: AudioBluetoothRole, counter: Data) -> Data {
        Data("SkyBridge-Audio-Bluetooth-Record-v1|".utf8) + context + Data([role.rawValue]) + counter
    }
}
