import Foundation

struct TransferDeviceCacheEnvelope<Value: Codable & Sendable>: Codable, Sendable {
    let schemaVersion: Int
    let payload: Value
}

enum DeviceConnectionRepositoryError: Error, CustomNSError, Sendable {
    case unsupportedSchema
    case invalidEntry
    case capacityExceeded
    case invalidLegacyPayload

    static let errorDomain = "com.skybridge.filetransfer.device-cache"

    var errorCode: Int {
        switch self {
        case .unsupportedSchema: return 1
        case .invalidEntry: return 2
        case .capacityExceeded: return 3
        case .invalidLegacyPayload: return 4
        }
    }

    var errorUserInfo: [String: Any] { [:] }
}

enum DeviceConnectionPersistenceOperation: String, Sendable {
    case load
    case upsert
    case remove
    case updateStatus = "update_status"
    case updateStatistics = "update_statistics"
    case clear
}

public struct DeviceConnectionPersistenceFailure: Equatable, Sendable {
    public let operation: String
    public let domain: String
    public let code: Int

    init(operation: DeviceConnectionPersistenceOperation, error: Error) {
        let nsError = error as NSError
        self.operation = operation.rawValue
        self.domain = nsError.domain
        self.code = nsError.code
    }
}

struct DeviceConnectionSnapshot: Sendable {
    let devices: [String: DeviceInfo]
    let generation: UInt64
}

actor LegacyDeviceConnectionDefaultsStore {
    private let defaults: UserDefaults

    init(suiteName: String?) {
        if let suiteName {
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                preconditionFailure("Unable to create isolated legacy defaults suite")
            }
            self.defaults = defaults
        } else {
            self.defaults = .standard
        }
    }

    func data(forKey key: String) -> Data? {
        defaults.data(forKey: key)
    }

    func removeObject(forKey key: String) {
        defaults.removeObject(forKey: key)
    }
}

actor DeviceConnectionRepository {
    static let schemaVersion = 2
    static let maximumDeviceCount = 512
    static let maximumLegacyPayloadBytes = 2 * 1_024 * 1_024

    private let store: CodablePersistenceStore<TransferDeviceCacheEnvelope<[String: DeviceInfo]>>
    private let legacyStore: LegacyDeviceConnectionDefaultsStore
    private let legacyKey: String
    private var generation: UInt64 = 0

    private struct CanonicalLoad: Sendable {
        var devices: [String: DeviceInfo]
        let migratedLegacy: Bool
    }

    init(
        store: CodablePersistenceStore<TransferDeviceCacheEnvelope<[String: DeviceInfo]>>,
        legacySuiteName: String? = nil,
        legacyKey: String = "SkyBridge.DeviceConnections"
    ) {
        self.store = store
        self.legacyStore = LegacyDeviceConnectionDefaultsStore(suiteName: legacySuiteName)
        self.legacyKey = legacyKey
    }

    static func validateInput(_ device: DeviceInfo) throws {
        try validate(device, key: device.id)
    }

    func load() async throws -> DeviceConnectionSnapshot {
        let store = self.store
        let legacyKey = self.legacyKey
        let legacyData = await legacyStore.data(forKey: legacyKey)
        let canonical = try await CodablePersistenceStoreIOCoordinator.shared.perform(
            identity: store.persistenceIdentity
        ) {
            try Self.loadCanonical(store: store, legacyData: legacyData)
        }
        if canonical.migratedLegacy {
            await legacyStore.removeObject(forKey: legacyKey)
        }
        return snapshot(canonical.devices)
    }

    func upsert(_ device: DeviceInfo) async throws -> DeviceConnectionSnapshot {
        try Self.validate(device, key: device.id)
        return try await mutate { canonical in
            guard canonical[device.id] != nil || canonical.count < Self.maximumDeviceCount else {
                throw DeviceConnectionRepositoryError.capacityExceeded
            }
            canonical[device.id] = device
            return true
        }
    }

    func remove(id: String) async throws -> DeviceConnectionSnapshot {
        try await mutate { canonical in
            canonical.removeValue(forKey: id) != nil
        }
    }

    func updateStatus(id: String, status: ConnectionStatus) async throws -> DeviceConnectionSnapshot {
        try await mutate { canonical in
            guard var device = canonical[id] else { return false }
            device.connectionStatus = status
            if status == .connected {
                device.lastConnected = Date()
            }
            try Self.validate(device, key: id)
            canonical[id] = device
            return true
        }
    }

    func updateStatistics(
        id: String,
        bytesTransferred: Int64,
        speed: Double
    ) async throws -> DeviceConnectionSnapshot {
        guard bytesTransferred >= 0, speed.isFinite, speed >= 0 else {
            throw DeviceConnectionRepositoryError.invalidEntry
        }
        return try await mutate { canonical in
            guard var device = canonical[id] else { return false }
            let nextTransferCount = device.totalTransfers.addingReportingOverflow(1)
            let nextByteCount = device.totalBytesTransferred.addingReportingOverflow(bytesTransferred)
            guard !nextTransferCount.overflow, !nextByteCount.overflow else {
                throw DeviceConnectionRepositoryError.invalidEntry
            }
            device.totalTransfers = nextTransferCount.partialValue
            device.totalBytesTransferred = nextByteCount.partialValue
            let count = Double(device.totalTransfers)
            device.averageSpeed = (device.averageSpeed * (count - 1) + speed) / count
            try Self.validate(device, key: id)
            canonical[id] = device
            return true
        }
    }

    func clear() async throws -> DeviceConnectionSnapshot {
        let store = self.store
        let legacyKey = self.legacyKey
        let devices = try await CodablePersistenceStoreIOCoordinator.shared.perform(
            identity: store.persistenceIdentity
        ) {
            try Self.save([:], store: store)
            return [String: DeviceInfo]()
        }
        await legacyStore.removeObject(forKey: legacyKey)
        return snapshot(devices)
    }

    private func mutate(
        _ mutation: @escaping @Sendable (inout [String: DeviceInfo]) throws -> Bool
    ) async throws -> DeviceConnectionSnapshot {
        let store = self.store
        let legacyKey = self.legacyKey
        let legacyData = await legacyStore.data(forKey: legacyKey)
        let canonical = try await CodablePersistenceStoreIOCoordinator.shared.perform(
            identity: store.persistenceIdentity
        ) {
            var canonical = try Self.loadCanonical(store: store, legacyData: legacyData)
            if try mutation(&canonical.devices) {
                try Self.save(canonical.devices, store: store)
            } else if canonical.migratedLegacy {
                try Self.save(canonical.devices, store: store)
            }
            return canonical
        }
        if canonical.migratedLegacy {
            await legacyStore.removeObject(forKey: legacyKey)
        }
        return snapshot(canonical.devices)
    }

    private func snapshot(_ devices: [String: DeviceInfo]) -> DeviceConnectionSnapshot {
        let nextGeneration = generation.addingReportingOverflow(1)
        precondition(!nextGeneration.overflow, "Device connection repository generation overflow")
        generation = nextGeneration.partialValue
        return DeviceConnectionSnapshot(devices: devices, generation: generation)
    }

    private static func loadCanonical(
        store: CodablePersistenceStore<TransferDeviceCacheEnvelope<[String: DeviceInfo]>>,
        legacyData: Data?
    ) throws -> CanonicalLoad {
        if let envelope = try store.loadOrThrow() {
            return CanonicalLoad(devices: try validate(envelope), migratedLegacy: false)
        }

        guard let legacyData else {
            return CanonicalLoad(devices: [:], migratedLegacy: false)
        }
        guard legacyData.count <= maximumLegacyPayloadBytes else {
            throw CodablePersistenceStoreError.payloadTooLarge(
                actualBytes: legacyData.count,
                maximumBytes: maximumLegacyPayloadBytes
            )
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let migratedDevices: [String: DeviceInfo]
        do {
            let envelope = try decoder.decode(
                TransferDeviceCacheEnvelope<[String: DeviceInfo]>.self,
                from: legacyData
            )
            migratedDevices = try validate(envelope)
        } catch is DecodingError {
            do {
                let legacy = try decoder.decode([String: DeviceInfo].self, from: legacyData)
                try validate(legacy)
                migratedDevices = legacy
            } catch {
                throw DeviceConnectionRepositoryError.invalidLegacyPayload
            }
        }

        try save(migratedDevices, store: store)
        return CanonicalLoad(devices: migratedDevices, migratedLegacy: true)
    }

    private static func save(
        _ devices: [String: DeviceInfo],
        store: CodablePersistenceStore<TransferDeviceCacheEnvelope<[String: DeviceInfo]>>
    ) throws {
        try validate(devices)
        try store.save(
            TransferDeviceCacheEnvelope(schemaVersion: schemaVersion, payload: devices)
        )
    }

    private static func validate(
        _ envelope: TransferDeviceCacheEnvelope<[String: DeviceInfo]>
    ) throws -> [String: DeviceInfo] {
        guard envelope.schemaVersion == schemaVersion else {
            throw DeviceConnectionRepositoryError.unsupportedSchema
        }
        try validate(envelope.payload)
        return envelope.payload
    }

    private static func validate(_ devices: [String: DeviceInfo]) throws {
        guard devices.count <= maximumDeviceCount else {
            throw DeviceConnectionRepositoryError.capacityExceeded
        }
        for (key, device) in devices {
            try validate(device, key: key)
        }
    }

    private static func validate(_ device: DeviceInfo, key: String) throws {
        guard key == device.id,
              (1...512).contains(device.id.utf8.count),
              (1...1_024).contains(device.name.utf8.count),
              (1...256).contains(device.ipAddress.utf8.count),
              (1...65_535).contains(device.port),
              device.lastConnected.timeIntervalSinceReferenceDate.isFinite,
              device.totalTransfers >= 0,
              device.totalBytesTransferred >= 0,
              device.averageSpeed.isFinite,
              device.averageSpeed >= 0 else {
            throw DeviceConnectionRepositoryError.invalidEntry
        }
    }
}
