import Foundation

enum TrustedDevicePersistence {
    private static let trustedDevicesLegacyKey = "TrustedDevices"
    private static let trustRecordsLegacyKey = "SkyBridge.TrustedDeviceRecords"
    private static let catalogStore = CodablePersistenceStore<Catalog>(
        location: .protectedApplicationSupport(
            path: "Security/trusted-device-catalog.json"
        )
    )

    struct Catalog: Codable, Sendable {
        var deviceIDs: [String]
        var records: [TrustedDeviceRecord]

        func normalized() -> Catalog {
            let normalizedIDs = Array(
                Set(
                    deviceIDs
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                )
            ).sorted()

            var recordByID: [String: TrustedDeviceRecord] = [:]
            for record in records {
                let id = record.deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty else { continue }
                recordByID[id] = TrustedDeviceRecord(
                    deviceId: id,
                    trustedDate: record.trustedDate,
                    deviceName: record.deviceName
                )
            }

            for id in normalizedIDs where recordByID[id] == nil {
                recordByID[id] = TrustedDeviceRecord(deviceId: id)
            }

            let normalizedRecords = normalizedIDs.compactMap { recordByID[$0] }
            return Catalog(deviceIDs: normalizedIDs, records: normalizedRecords)
        }
    }

    static func loadDetailedState(defaults: UserDefaults = .standard) -> (deviceIDs: [String], records: [String: TrustedDeviceRecord]) {
        if let catalog = catalogStore.load()?.normalized() {
            return (
                catalog.deviceIDs,
                Dictionary(uniqueKeysWithValues: catalog.records.map { ($0.deviceId, $0) })
            )
        }

        let migrated = migrateLegacyState(defaults: defaults).normalized()
        if !migrated.deviceIDs.isEmpty || defaults.object(forKey: trustRecordsLegacyKey) != nil {
            saveDetailedState(deviceIDs: migrated.deviceIDs, records: Dictionary(uniqueKeysWithValues: migrated.records.map { ($0.deviceId, $0) }), defaults: defaults)
        }

        return (
            migrated.deviceIDs,
            Dictionary(uniqueKeysWithValues: migrated.records.map { ($0.deviceId, $0) })
        )
    }

    static func loadDeviceIDs(defaults: UserDefaults = .standard) -> [String] {
        loadDetailedState(defaults: defaults).deviceIDs
    }

    static func saveDeviceIDs<S: Sequence>(_ deviceIDs: S, defaults: UserDefaults = .standard) where S.Element == String {
        let existing = loadDetailedState(defaults: defaults)
        let trimmedIDs = Array(
            Set(
                deviceIDs
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        ).sorted()
        let filteredRecords = existing.records.filter { trimmedIDs.contains($0.key) }
        saveDetailedState(deviceIDs: trimmedIDs, records: filteredRecords, defaults: defaults)
    }

    static func saveDetailedState(
        deviceIDs: [String],
        records: [String: TrustedDeviceRecord],
        defaults: UserDefaults = .standard
    ) {
        let normalizedIDs = Array(
            Set(
                deviceIDs
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        ).sorted()
        var normalizedRecords: [TrustedDeviceRecord] = []
        normalizedRecords.reserveCapacity(normalizedIDs.count)
        for id in normalizedIDs {
            if let record = records[id] {
                normalizedRecords.append(
                    TrustedDeviceRecord(
                        deviceId: id,
                        trustedDate: record.trustedDate,
                        deviceName: record.deviceName
                    )
                )
            } else {
                normalizedRecords.append(TrustedDeviceRecord(deviceId: id))
            }
        }

        try? catalogStore.save(Catalog(deviceIDs: normalizedIDs, records: normalizedRecords).normalized())
        defaults.removeObject(forKey: trustedDevicesLegacyKey)
        defaults.removeObject(forKey: trustRecordsLegacyKey)
    }

    private static func migrateLegacyState(defaults: UserDefaults) -> Catalog {
        var ids = Set<String>()

        if let json = defaults.data(forKey: trustedDevicesLegacyKey),
           let set = try? JSONDecoder().decode(Set<String>.self, from: json) {
            ids.formUnion(set)
        }

        if let array = defaults.stringArray(forKey: trustedDevicesLegacyKey) {
            ids.formUnion(array)
        }

        let records: [TrustedDeviceRecord]
        if let data = defaults.data(forKey: trustRecordsLegacyKey) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            records = (try? decoder.decode([TrustedDeviceRecord].self, from: data)) ?? []
        } else {
            records = []
        }

        return Catalog(deviceIDs: Array(ids), records: records)
    }
}
