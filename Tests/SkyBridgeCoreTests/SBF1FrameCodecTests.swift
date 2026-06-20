import Testing
import Foundation
@testable import SkyBridgeCore

//
//  SBF1FrameCodecTests.swift
//
//  Offline, CI-safe golden-vector + round-trip tests for the Apple-side SBF1
//  data-plane codec. The byte vectors are pinned against
//  core/skybridge-core/src/frame.rs so the Apple peer and the Windows/Rust
//  peer agree byte-for-byte on the wire. No network, no WebRTC, no DataChannel.
//

@Suite("SBF1 Frame Codec")
struct SBF1FrameCodecTests {

    /// GOLDEN VECTOR — the exact 20 header bytes for a channel-3 (clipboard),
    /// version-1, endOfMessage-flagged frame, as defined by frame.rs:
    ///   "SBF1"            = 53 42 46 31
    ///   version 1         = 01
    ///   channel clipboard = 03
    ///   flags 0x0002 (BE) = 00 02   (END_OF_MESSAGE)
    ///   sequence 7 (u64 BE) = 00 00 00 00 00 00 00 07
    ///   payloadLen 5 (u32 BE) = 00 00 00 05
    ///   payload "hello"   = 68 65 6C 6C 6F
    @Test("encodes the exact frame.rs golden bytes for a clipboard frame")
    func goldenClipboardFrameMatchesFrameRs() throws {
        let frame = SBF1Frame(
            channel: .clipboard,
            sequence: 7,
            flags: .endOfMessage,
            payload: Data("hello".utf8)
        )

        let encoded = SBF1Frame.encode(frame)

        let expected: [UInt8] = [
            0x53, 0x42, 0x46, 0x31,                         // "SBF1"
            0x01,                                           // version
            0x03,                                           // channel = clipboard
            0x00, 0x02,                                     // flags = END_OF_MESSAGE
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07, // sequence = 7
            0x00, 0x00, 0x00, 0x05,                         // payloadLen = 5
            0x68, 0x65, 0x6C, 0x6C, 0x6F                    // "hello"
        ]

        #expect([UInt8](encoded) == expected)
        // Pin the header prefix the design calls out explicitly.
        #expect(Array(encoded.prefix(8)) == [0x53, 0x42, 0x46, 0x31, 0x01, 0x03, 0x00, 0x02])
        #expect(encoded.count == SBF1Frame.headerLength + 5)
    }

    @Test("round-trips channel, sequence, flags, and payload for every channel")
    func roundTripPreservesAllFields() throws {
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x10])
        for channel in SBF1Channel.allCases {
            let frame = SBF1Frame(
                channel: channel,
                sequence: 0xABCD_1234_5678_9F01,
                flags: [.sbp2Padded, .endOfMessage],
                payload: payload
            )
            let decoded = try SBF1Frame.decode(SBF1Frame.encode(frame))
            #expect(decoded == frame)
            #expect(decoded.channel == channel)
            #expect(decoded.sequence == 0xABCD_1234_5678_9F01)
            #expect(decoded.flags.contains(.sbp2Padded))
            #expect(decoded.flags.contains(.endOfMessage))
            #expect(decoded.payload == payload)
        }
    }

    @Test("round-trips an empty payload")
    func roundTripEmptyPayload() throws {
        let frame = SBF1Frame(channel: .control, sequence: 0, flags: [], payload: Data())
        let decoded = try SBF1Frame.decode(SBF1Frame.encode(frame))
        #expect(decoded == frame)
        #expect(decoded.payload.isEmpty)
    }

    @Test("decode rejects a frame that is shorter than the header")
    func decodeRejectsTooShort() {
        #expect(throws: SBF1Frame.DecodeError.frameTooShort) {
            _ = try SBF1Frame.decode(Data([0x53, 0x42, 0x46]))
        }
    }

    @Test("decode rejects bad magic (e.g. an SBWC envelope cannot cross-contaminate)")
    func decodeRejectsBadMagic() {
        // "SBWC" (53 42 57 43) + a full 20-byte header's worth of bytes.
        var sbwcLike = Data([0x53, 0x42, 0x57, 0x43, 0x01, 0x03, 0x00, 0x02])
        sbwcLike.append(Data(repeating: 0, count: SBF1Frame.headerLength - sbwcLike.count))
        #expect(throws: SBF1Frame.DecodeError.badMagic) {
            _ = try SBF1Frame.decode(sbwcLike)
        }
    }

    @Test("decode rejects an unsupported version")
    func decodeRejectsUnsupportedVersion() {
        var bytes = [UInt8](SBF1Frame.encode(
            SBF1Frame(channel: .control, sequence: 0, flags: [], payload: Data())
        ))
        bytes[4] = 2
        #expect(throws: SBF1Frame.DecodeError.unsupportedVersion(2)) {
            _ = try SBF1Frame.decode(Data(bytes))
        }
    }

    @Test("decode rejects an unknown channel code")
    func decodeRejectsUnknownChannel() {
        var bytes = [UInt8](SBF1Frame.encode(
            SBF1Frame(channel: .control, sequence: 0, flags: [], payload: Data())
        ))
        bytes[5] = 99
        #expect(throws: SBF1Frame.DecodeError.unknownChannel(99)) {
            _ = try SBF1Frame.decode(Data(bytes))
        }
    }

    @Test("decode rejects unknown flag bits")
    func decodeRejectsUnknownFlags() {
        var bytes = [UInt8](SBF1Frame.encode(
            SBF1Frame(channel: .realtime, sequence: 9, flags: [], payload: Data("abc".utf8))
        ))
        bytes[6] = 0x80
        bytes[7] = 0x00
        #expect(throws: SBF1Frame.DecodeError.unknownFlags(0x8000)) {
            _ = try SBF1Frame.decode(Data(bytes))
        }
    }

    @Test("decode rejects a truncated payload")
    func decodeRejectsTruncatedPayload() {
        var bytes = [UInt8](SBF1Frame.encode(
            SBF1Frame(channel: .file, sequence: 1, flags: [], payload: Data("abc".utf8))
        ))
        // Drop two payload bytes: declares 3, only 1 present.
        bytes.removeLast(2)
        #expect(throws: SBF1Frame.DecodeError.truncatedPayload(expected: 3, actual: 1)) {
            _ = try SBF1Frame.decode(Data(bytes))
        }
    }

    // MARK: - Per-channel reassembly + sequence

    @Test("reassembly returns nil until endOfMessage, then the full payload")
    func reassemblyAccumulatesAcrossFragments() {
        let state = SBF1ChannelState()
        let first = SBF1Frame(channel: .clipboard, sequence: 0, flags: [], payload: Data("Hello, ".utf8))
        let second = SBF1Frame(channel: .clipboard, sequence: 1, flags: .endOfMessage, payload: Data("world".utf8))

        #expect(state.accumulate(first) == nil)
        let reassembled = state.accumulate(second)
        #expect(reassembled == Data("Hello, world".utf8))
    }

    @Test("reassembly is independent per channel")
    func reassemblyIsPerChannel() {
        let state = SBF1ChannelState()
        #expect(state.accumulate(
            SBF1Frame(channel: .control, sequence: 0, flags: [], payload: Data("A".utf8))
        ) == nil)
        #expect(state.accumulate(
            SBF1Frame(channel: .clipboard, sequence: 0, flags: .endOfMessage, payload: Data("Z".utf8))
        ) == Data("Z".utf8))
        // Control still pending; completing it yields only its own bytes.
        #expect(state.accumulate(
            SBF1Frame(channel: .control, sequence: 1, flags: .endOfMessage, payload: Data("B".utf8))
        ) == Data("AB".utf8))
    }

    @Test("outbound sequence counts independently per channel from zero")
    func outboundSequenceIsPerChannel() {
        let state = SBF1ChannelState()
        #expect(state.nextOutboundSequence(for: .control) == 0)
        #expect(state.nextOutboundSequence(for: .control) == 1)
        #expect(state.nextOutboundSequence(for: .clipboard) == 0)
        #expect(state.nextOutboundSequence(for: .control) == 2)
        #expect(state.nextOutboundSequence(for: .clipboard) == 1)
    }
}
