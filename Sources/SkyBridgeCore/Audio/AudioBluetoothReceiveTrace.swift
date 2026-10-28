#if os(macOS)
import Foundation

/// Local qualification evidence only. The session owns this bounded ring; it never stores
/// media, peer identifiers or error descriptions and never participates in flow control.
struct AudioBluetoothReceiveTrace {
    enum Kind: String {
        case readBegin, received, reduceBegin, reduceEnd, output
        case creditQueued, creditWriteBegin, creditWriteEnd, terminal
    }
    struct Event {
        let elapsed: Duration
        let kind: Kind
        let value: UInt64
        let auxiliary: UInt64
        let queued: Int

        var diagnostic: String {
            let parts = elapsed.components
            let milliseconds = Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
            return "ms=\(milliseconds) kind=\(kind.rawValue) value=\(value) auxiliary=\(auxiliary) queued=\(queued)"
        }
    }
    static let capacity = 512
    private let began: ContinuousClock.Instant
    private var ring: [Event] = []
    private var next = 0

    init(now: ContinuousClock.Instant = .now) {
        began = now
        ring.reserveCapacity(Self.capacity)
    }

    mutating func record(_ kind: Kind, value: UInt64 = 0, auxiliary: UInt64 = 0,
                         queued: Int = 0, now: ContinuousClock.Instant = .now) {
        let event = Event(elapsed: began.duration(to: now), kind: kind,
                          value: value, auxiliary: auxiliary, queued: queued)
        if ring.count < Self.capacity { ring.append(event) }
        else { ring[next] = event }
        next = (next + 1) % Self.capacity
    }

    var events: [Event] {
        guard ring.count == Self.capacity, next != 0 else { return ring }
        return Array(ring[next...]) + Array(ring[..<next])
    }
}
#endif
