import Foundation

/// USB link profile 2. RFC 1662 octet transparency/FCS-32, with an explicit
/// SkyBridge record header (not PPP). Framing confers no freshness or identity.
/// An epoch-negotiating owner must admit both nonces before feeding DATA to Yamux.
public enum USBLinkWire {
    public static let version: UInt8 = 2
    public static let nonceBytes = 32, headerBytes = 72, maximumBodyBytes = 16 * 1024
    public static let maximumRecordBytes = headerBytes + maximumBodyBytes + 4
    public static let maximumEncodedBytes = maximumRecordBytes * 2 + 2
    public static let maximumStartupDiscards = 8
    private static let flag: UInt8 = 0x7e, escape: UInt8 = 0x7d
    private static let magic: [UInt8] = [0x53, 0x42, 0x55, 0x4c]

    public enum Kind: UInt8, Sendable { case offer, select, accept, ready, data, close }
    public enum Failure: Error, Equatable, Sendable {
        case nonce, header, body, checksum, escape, capacity, truncated, recoveryBudget, state
    }
    public enum Mode: Sendable { case strict, startup }
    public enum Event: Sendable {
        case record(Record)
        /// Encoded bytes between flags, excluding the delimiter itself.
        case discarded(reason: Failure, encodedBodyBytes: Int)
    }
    /// Public random correlation value, never a peer identity or authentication key.
    public struct Nonce: Hashable, Sendable {
        public let bytes: Data
        public init(_ bytes: Data) throws {
            guard bytes.count == nonceBytes, bytes.contains(where: { $0 != 0 }) else { throw Failure.nonce }
            self.bytes = Data(bytes)
        }
    }
    public struct Record: Sendable {
        public let kind: Kind
        public let sender: Nonce
        public let recipient: Nonce?
        public let body: Data
        public init(kind: Kind, sender: Nonce, recipient: Nonce?, body: Data = Data()) throws {
            guard (kind == .offer) == (recipient == nil), sender != recipient else { throw Failure.header }
            guard kind == .data ? (1...maximumBodyBytes).contains(body.count) : body.isEmpty else { throw Failure.body }
            self.kind = kind; self.sender = sender; self.recipient = recipient; self.body = Data(body)
        }
    }
    private static let crcTable: [UInt32] = (0..<256).map { index in
        var word = UInt32(index)
        for _ in 0..<8 { word = (word >> 1) ^ (word & 1 == 1 ? 0xedb88320 : 0) }
        return word
    }
    private static func crc32(_ bytes: some Sequence<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in bytes { crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 255)] }
        return crc ^ 0xffffffff
    }
    /// Complete record before escaping, including the little-endian FCS-32.
    public static func encodeRaw(_ record: Record) -> Data {
        var raw = Data(magic + [version, record.kind.rawValue])
        raw.append(record.sender.bytes)
        raw.append(record.recipient?.bytes ?? Data(count: nonceBytes))
        raw.append(contentsOf: [UInt8(record.body.count >> 8), UInt8(record.body.count & 255)])
        raw.append(record.body)
        let crc = crc32(raw)
        for shift in stride(from: 0, to: 32, by: 8) { raw.append(UInt8(truncatingIfNeeded: crc >> shift)) }
        return raw
    }
    public static func encode(_ record: Record) -> Data {
        let raw = encodeRaw(record)
        var encoded = Data([flag]); encoded.reserveCapacity(raw.count * 2 + 2)
        for byte in raw {
            if byte == flag || byte == escape { encoded.append(contentsOf: [escape, byte ^ 0x20]) }
            else { encoded.append(byte) }
        }
        encoded.append(flag)
        return encoded
    }
    public static func decodeRaw(_ input: Data) throws -> Record {
        guard input.count >= headerBytes + 4 else { throw Failure.truncated }
        guard input.count <= maximumRecordBytes else { throw Failure.capacity }
        let raw = Array(input)
        guard Array(raw.prefix(4)) == magic, raw[4] == version, let kind = Kind(rawValue: raw[5]) else { throw Failure.header }
        let length = (Int(raw[70]) << 8) | Int(raw[71])
        guard length <= maximumBodyBytes, raw.count == headerBytes + length + 4 else { throw Failure.body }
        let received = (0..<4).reduce(UInt32(0)) { $0 | (UInt32(raw[raw.count - 4 + $1]) << (8 * $1)) }
        guard received == crc32(raw.dropLast(4)) else { throw Failure.checksum }
        let sender = try Nonce(Data(raw[6..<38]))
        let recipientBytes = Data(raw[38..<70])
        let recipient = recipientBytes.allSatisfy { $0 == 0 } ? nil : try Nonce(recipientBytes)
        return try Record(kind: kind, sender: sender, recipient: recipient, body: Data(raw[headerBytes..<(headerBytes + length)]))
    }
    /// Single reader. Startup mode explicitly reports up to eight bounded old
    /// damaged records; incompatible headers/nonces remain fatal. seal() restores
    /// strict decoding irreversibly at a record boundary. The epoch owner must
    /// call it only after a fresh exchange: this parser grants no freshness or
    /// identity. The owner bounds total startup time/bytes/records and treats
    /// physical EOF as carrier loss, never successful file/audio completion.
    public struct Decoder: Sendable {
        private var storage: [UInt8] = []
        private var aligned = false, escaped = false
        private var mode: Mode
        private var encodedBodyBytes = 0
        private var pendingDiscard: Failure?
        private var terminal: Failure?
        public private(set) var discardedRecords = 0
        public private(set) var prefixDiscardedBytes = 0
        public var bufferedBytes: Int { storage.count }
        public var isAtRecordBoundary: Bool {
            aligned && storage.isEmpty && !escaped && encodedBodyBytes == 0 && pendingDiscard == nil && terminal == nil
        }
        public init(mode: Mode = .strict) { self.mode = mode; storage.reserveCapacity(maximumRecordBytes) }
        public mutating func seal() throws {
            if let terminal { throw terminal }
            guard isAtRecordBoundary else { terminal = .state; throw Failure.state }
            mode = .strict
        }
        private mutating func endRecord() throws -> Event {
            let event: Event
            do {
                if let pendingDiscard { throw pendingDiscard }
                guard !escaped else { throw Failure.escape }
                event = .record(try decodeRaw(Data(storage)))
            } catch let failure as Failure {
                guard mode == .startup, [Failure.truncated, .body, .checksum, .escape].contains(failure) else { throw failure }
                guard discardedRecords < maximumStartupDiscards else { throw Failure.recoveryBudget }
                discardedRecords += 1
                event = .discarded(reason: failure, encodedBodyBytes: encodedBodyBytes)
            }
            storage.removeAll(keepingCapacity: true)
            encodedBodyBytes = 0; escaped = false; pendingDiscard = nil
            return event
        }
        public mutating func accept(_ byte: UInt8) throws -> Event? {
            if let terminal { throw terminal }
            do {
                if !aligned {
                    if byte == flag { aligned = true }
                    else {
                        guard prefixDiscardedBytes < maximumEncodedBytes - 1 else { throw Failure.capacity }
                        prefixDiscardedBytes += 1
                    }
                    return nil
                }
                if byte == flag {
                    guard encodedBodyBytes > 0 else { return nil }
                    return try endRecord()
                }
                guard encodedBodyBytes < maximumEncodedBytes - 2 else { throw Failure.capacity }
                encodedBodyBytes += 1
                if pendingDiscard != nil { return nil }
                if !escaped && byte == escape { escaped = true; return nil }
                let decoded = escaped ? byte ^ 0x20 : byte
                if escaped && decoded != flag && decoded != escape {
                    guard mode == .startup else { throw Failure.escape }
                    pendingDiscard = .escape; storage.removeAll(keepingCapacity: true); escaped = false
                    return nil
                }
                escaped = false
                guard storage.count < maximumRecordBytes else { throw Failure.capacity }
                storage.append(decoded)
                return nil
            } catch let error as Failure {
                terminal = error
                throw error
            }
        }
    }
}
