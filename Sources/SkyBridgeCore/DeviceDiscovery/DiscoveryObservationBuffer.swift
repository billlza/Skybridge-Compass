import Foundation

/// One bounded latest-value table for a scan. Leases reject resolved results
/// from an older scan or an older observation of the same Bonjour service.
struct DiscoveryObservationBuffer {
    enum Key: Hashable, Sendable {
        case bonjour(instance: String, serviceType: String, domain: String)
        case usb(identifier: String)
    }

    struct Lease: Equatable, Sendable {
        let generation: UUID
        let key: Key
        let revision: UUID
    }

    enum Admission: Equatable {
        case accepted(Lease)
        case staleScan
        case capacityExceeded(limit: Int)
    }

    struct Update: Sendable {
        let lease: Lease
        let device: DiscoveredDevice
    }

    private struct Entry {
        let lease: Lease
        var device: DiscoveredDevice?
        var pending = false
    }

    let capacity: Int
    private var generation: UUID?
    private var entries: [Key: Entry] = [:]

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    var currentGeneration: UUID? { generation }
    var hasPendingUpdates: Bool { entries.values.contains(where: \.pending) }
    var count: Int { entries.count }

    mutating func start() -> UUID {
        let generation = UUID()
        self.generation = generation
        entries.removeAll(keepingCapacity: true)
        return generation
    }

    mutating func stop() {
        generation = nil
        entries.removeAll(keepingCapacity: true)
    }

    func isCurrent(generation: UUID) -> Bool { self.generation == generation }

    func isCurrent(_ lease: Lease) -> Bool {
        isCurrent(generation: lease.generation) && entries[lease.key]?.lease == lease
    }

    mutating func begin(key: Key, generation: UUID) -> Admission {
        guard isCurrent(generation: generation) else { return .staleScan }
        guard entries[key] != nil || entries.count < capacity else {
            return .capacityExceeded(limit: capacity)
        }
        let lease = Lease(generation: generation, key: key, revision: UUID())
        entries[key] = Entry(lease: lease, device: entries[key]?.device)
        return .accepted(lease)
    }

    @discardableResult
    mutating func enqueue(_ device: DiscoveredDevice, lease: Lease) -> Bool {
        guard isCurrent(lease) else { return false }
        entries[lease.key] = Entry(lease: lease, device: device, pending: true)
        return true
    }

    mutating func takePending() -> [Update] {
        var updates: [Update] = []
        for key in Array(entries.keys) {
            guard var entry = entries[key], entry.pending, let device = entry.device else { continue }
            updates.append(Update(lease: entry.lease, device: device))
            entry.pending = false
            entries[key] = entry
        }
        return updates
    }

    mutating func remove(key: Key) { entries.removeValue(forKey: key) }

    mutating func remove(where predicate: (DiscoveredDevice) -> Bool) {
        entries = entries.filter { _, entry in
            guard let device = entry.device else { return true }
            return !predicate(device)
        }
    }
}
