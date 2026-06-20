//
//  WebRTCSBF1DataPlane.swift
//  SkyBridgeCore
//
//  Apple-side SBF1 data-plane codec + answerer state for cross-platform
//  (Windows ⇄ macOS/iOS) interop over a raw WebRTC DataChannel.
//
//  SCOPE / SAFETY (read before editing):
//  - This file is ADDITIVE and MODE-GATED. Nothing here runs unless the
//    SBF1 interop gate is explicitly enabled (env SKYBRIDGE_SBF1_INTEROP=1).
//    The Apple↔Apple P2P / PQC / rekey-election / SBWC path is BYTE-FOR-BYTE
//    untouched — see CrossNetworkConnectionManager.startWebRTCInboundHandshakeAndControlLoop.
//  - The frame format mirrors core/skybridge-core/src/frame.rs EXACTLY:
//    20-byte big-endian header
//      "SBF1" (4) | version=1 (1) | channel (1) | flags-u16 (2)
//      | sequence-u64 (8) | payloadLen-u32 (4) | payload (payloadLen)
//  - SBF1 magic (53 42 46 31) is distinct from the SBWC envelope magic
//    (53 42 57 43); decode() rejects anything that is not an SBF1 frame, so a
//    stray SBWC frame can never cross-contaminate the interop path.
//
//  The codec (encode/decode/SBF1Frame/SBF1Channel/SBF1Flags) is pure, Sendable
//  and statics-only. Per-session reassembly + outbound sequence counters live in
//  SBF1ChannelState, which the @MainActor manager owns one-per-session.
//

import Foundation

// MARK: - Channel

/// The SBF1 logical channel (header byte 5). Mirrors `SkyBridgeChannel`
/// channel-code mapping in core/skybridge-core/src/frame.rs / transport.rs.
public enum SBF1Channel: UInt8, Sendable, CaseIterable, Hashable {
    case control = 1
    case file = 2
    case clipboard = 3
    case telemetry = 4
    case realtime = 5
}

// MARK: - Flags

/// The SBF1 frame flags (header bytes 6..8, big-endian u16). Mirrors
/// `FrameFlags` in frame.rs. Only the two known bits are valid; any other bit
/// set is rejected by `SBF1Frame.decode`, matching the Rust `UnknownFlags`.
public struct SBF1Flags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    /// SBP2 fixed-size padding was applied to the payload (0x0001).
    public static let sbp2Padded = SBF1Flags(rawValue: 0x0001)
    /// This frame completes a logical message (0x0002).
    public static let endOfMessage = SBF1Flags(rawValue: 0x0002)

    /// The union of every bit this implementation understands. Mirrors
    /// `FrameFlags::KNOWN_MASK`.
    static let knownMask: UInt16 = sbp2Padded.rawValue | endOfMessage.rawValue
}

// MARK: - Frame

/// A decoded SBF1 frame. `payload` is the raw (possibly SBP2-padded) frame
/// body — SBP2 unwrap is deliberately NOT performed here; it is the
/// application's responsibility, matching the Rust `decode_frame` /
/// `decode_frame_payload` split.
public struct SBF1Frame: Sendable, Equatable {
    public let channel: SBF1Channel
    public let sequence: UInt64
    public let flags: SBF1Flags
    public let payload: Data

    public init(channel: SBF1Channel, sequence: UInt64, flags: SBF1Flags, payload: Data) {
        self.channel = channel
        self.sequence = sequence
        self.flags = flags
        self.payload = payload
    }

    // MARK: Constants (mirror frame.rs)

    /// "SBF1" — the frame magic (53 42 46 31).
    static let magic: [UInt8] = [0x53, 0x42, 0x46, 0x31]
    /// The only supported version byte.
    static let version: UInt8 = 1
    /// Fixed header length in bytes.
    public static let headerLength = 20
    /// Hard payload cap (64 MiB), matching the Windows helper's refuse-threshold.
    /// A bogus/hostile length above this is rejected rather than allocated.
    public static let maxPayloadBytes = 64 * 1024 * 1024

    // MARK: Errors

    public enum DecodeError: Error, Equatable {
        case frameTooShort
        case badMagic
        case unsupportedVersion(UInt8)
        case unknownChannel(UInt8)
        case unknownFlags(UInt16)
        case payloadTooLarge(UInt32)
        case truncatedPayload(expected: Int, actual: Int)
    }

    // MARK: Encode

    /// Serializes a frame to its exact on-wire bytes. Pure & Sendable.
    public static func encode(_ frame: SBF1Frame) -> Data {
        var out = Data(capacity: headerLength + frame.payload.count)
        out.append(contentsOf: magic)                                  // 0..4   "SBF1"
        out.append(version)                                            // 4      version
        out.append(frame.channel.rawValue)                            // 5      channel
        appendBigEndian(&out, UInt16: frame.flags.rawValue)            // 6..8   flags
        appendBigEndian(&out, UInt64: frame.sequence)                 // 8..16  sequence
        appendBigEndian(&out, UInt32: UInt32(truncatingIfNeeded: frame.payload.count)) // 16..20 payloadLen
        out.append(frame.payload)                                      // 20..   payload
        return out
    }

    // MARK: Decode

    /// Parses one SBF1 frame from `encoded`. Validates magic, version, channel,
    /// flags, and that the declared payload length is present. Rejects anything
    /// that is not a well-formed SBF1 frame — including a stray SBWC envelope
    /// (different magic). Trailing bytes beyond the declared payload are ignored,
    /// matching `decode_frame` (one DataChannel message == one frame).
    public static func decode(_ encoded: Data) throws -> SBF1Frame {
        guard encoded.count >= headerLength else {
            throw DecodeError.frameTooShort
        }
        // Index into a contiguous base-0 view regardless of the source Data slice.
        let bytes = [UInt8](encoded)

        guard Array(bytes[0..<4]) == magic else {
            throw DecodeError.badMagic
        }
        let ver = bytes[4]
        guard ver == version else {
            throw DecodeError.unsupportedVersion(ver)
        }
        guard let channel = SBF1Channel(rawValue: bytes[5]) else {
            throw DecodeError.unknownChannel(bytes[5])
        }
        let flagBits = readBigEndianUInt16(bytes, at: 6)
        guard flagBits & ~SBF1Flags.knownMask == 0 else {
            throw DecodeError.unknownFlags(flagBits)
        }
        let sequence = readBigEndianUInt64(bytes, at: 8)
        let payloadLen32 = readBigEndianUInt32(bytes, at: 16)
        guard payloadLen32 <= UInt32(maxPayloadBytes) else {
            throw DecodeError.payloadTooLarge(payloadLen32)
        }
        let payloadLen = Int(payloadLen32)
        let actual = bytes.count - headerLength
        guard payloadLen <= actual else {
            throw DecodeError.truncatedPayload(expected: payloadLen, actual: actual)
        }
        let payload = Data(bytes[headerLength..<(headerLength + payloadLen)])
        return SBF1Frame(channel: channel, sequence: sequence, flags: SBF1Flags(rawValue: flagBits), payload: payload)
    }

    // MARK: Big-endian helpers

    private static func appendBigEndian(_ data: inout Data, UInt16 value: UInt16) {
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    private static func appendBigEndian(_ data: inout Data, UInt32 value: UInt32) {
        data.append(UInt8(truncatingIfNeeded: value >> 24))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    private static func appendBigEndian(_ data: inout Data, UInt64 value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    private static func readBigEndianUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private static func readBigEndianUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    private static func readBigEndianUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 {
            value = (value << 8) | UInt64(bytes[offset + i])
        }
        return value
    }
}

// MARK: - Per-session channel state (reassembly + outbound sequence)

/// Per-session SBF1 plumbing: outbound per-channel monotonic sequence counters
/// and inbound per-channel reassembly buffers. Logically owned by the
/// @MainActor manager (one instance per interop session); not itself Sendable.
final class SBF1ChannelState {
    /// Next outbound sequence number to stamp, per channel. Mirrors the Rust
    /// per-channel `sequence` counters (each channel counts independently).
    private var outboundSequence: [SBF1Channel: UInt64] = [:]

    /// Accumulated inbound payload bytes per channel, awaiting `endOfMessage`.
    private var inboundReassembly: [SBF1Channel: Data] = [:]

    init() {}

    /// Returns the next outbound sequence number for `channel` and advances it.
    func nextOutboundSequence(for channel: SBF1Channel) -> UInt64 {
        let current = outboundSequence[channel] ?? 0
        outboundSequence[channel] = current &+ 1
        return current
    }

    /// Feeds one inbound frame into per-channel reassembly. Returns the fully
    /// reassembled logical-message payload once `endOfMessage` is observed,
    /// otherwise `nil` (more fragments expected). Honors the 64 MiB cap across
    /// the accumulated message, dropping (and resetting) a channel that exceeds it.
    func accumulate(_ frame: SBF1Frame) -> Data? {
        var buffer = inboundReassembly[frame.channel] ?? Data()
        buffer.append(frame.payload)
        if buffer.count > SBF1Frame.maxPayloadBytes {
            // Fail closed: discard the over-cap partial message for this channel.
            inboundReassembly[frame.channel] = nil
            return nil
        }
        if frame.flags.contains(.endOfMessage) {
            inboundReassembly[frame.channel] = nil
            return buffer
        }
        inboundReassembly[frame.channel] = buffer
        return nil
    }
}
