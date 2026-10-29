import Foundation
import XCTest
@testable import SkyBridgeProtocolCore

/// Public synthetic material shared byte-for-byte with Kotlin and the independent Python oracle.
struct BluetoothAudioFixture: Decodable, Sendable {
    struct Record: Decodable, Sendable { let plaintext, record: String }
    let offer, route, sendKey, receiveKey, transcriptHash, sourceNonce, sinkNonce: String
    let hello, challenge, finish, ready: String
    let sourceRecords, sinkRecords: [Record]
    let suite: UInt16

    static func load() throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf:
            XCTUnwrap(Bundle.module.url(forResource: "audio-bluetooth-channel-v1", withExtension: "json"))))
    }
    func bytes(_ text: String) throws -> Data {
        let chars = Array(text)
        return try Data(stride(from: 0, to: chars.count, by: 2).map {
            try XCTUnwrap(UInt8(String(chars[$0...($0 + 1)]), radix: 16))
        })
    }
    func binding(_ role: AudioBluetoothRole) throws -> AudioBluetoothBinding {
        let offer = try AudioStreamingWire.decode(bytes(offer)), route = try AudioStreamingWire.decode(bytes(route))
        var negotiation = AudioBluetoothNegotiation(role: role, streamID: offer.streamID)
        if role == .source {
            try negotiation.prepareSend(offer); try negotiation.commitSend(offer); try negotiation.receive(route)
        } else {
            try negotiation.receive(offer); try negotiation.prepareSend(route); try negotiation.commitSend(route)
        }
        return try negotiation.takeBinding()
    }
    func secret(_ role: AudioBluetoothRole) throws -> AudioBluetoothAttachmentSecret {
        try .init(binding: binding(role), sendKey: bytes(role == .source ? sendKey : receiveKey),
            receiveKey: bytes(role == .source ? receiveKey : sendKey), transcriptHash: bytes(transcriptHash), suite: suite)
    }
    func attachment(_ role: AudioBluetoothRole, current: @escaping @Sendable () throws -> Void = {},
                    now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) throws -> AudioBluetoothAttachment {
        try .init(binding: binding(role), secret: secret(role), requireParentCurrent: current, now: now)
    }
    func packet() throws -> AudioStreamingMessage {
        try AudioStreamingWire.decode(bytes(sourceRecords[1].plaintext))
    }
}
