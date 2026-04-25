import Foundation

@available(macOS 14.0, iOS 17.0, *)
public struct TrustRecordDisplayGroup: Identifiable, Sendable, Equatable {
    public let id: String
    public let primaryRecord: TrustRecord
    public let relatedRecords: [TrustRecord]
    public let displayRecord: TrustRecord

    public init(
        id: String,
        primaryRecord: TrustRecord,
        relatedRecords: [TrustRecord],
        displayRecord: TrustRecord
    ) {
        self.id = id
        self.primaryRecord = primaryRecord
        self.relatedRecords = relatedRecords
        self.displayRecord = displayRecord
    }
}

@available(macOS 14.0, iOS 17.0, *)
public enum ApplePeerDeviceMetadataNormalizer {
    public struct Presentation: Sendable, Equatable {
        public let modelName: String?
        public let chip: String?
        public let platform: String?
        public let osVersion: String?

        public init(
            modelName: String?,
            chip: String?,
            platform: String?,
            osVersion: String?
        ) {
            self.modelName = modelName
            self.chip = chip
            self.platform = platform
            self.osVersion = osVersion
        }
    }

    public static func normalize(
        modelName: String?,
        chip: String?,
        platform: String?,
        osVersion: String?
    ) -> Presentation {
        let trimmedModel = trim(modelName)
        let trimmedChip = trim(chip)
        let trimmedPlatform = normalizedPlatformName(trim(platform))
        let trimmedOSVersion = trim(osVersion)

        guard let trimmedModel else {
            return Presentation(
                modelName: nil,
                chip: normalizedFallbackChip(from: trimmedChip),
                platform: trimmedPlatform,
                osVersion: trimmedOSVersion
            )
        }

        let resolved = resolvedPresentation(forModelIdentifier: trimmedModel)
        let effectiveModel = resolved?.modelName ?? trimmedModel
        let effectiveChip: String? = {
            if let trimmedChip, !isGenericChipName(trimmedChip) {
                return trimmedChip
            }
            if let resolved {
                return resolved.chip
            }
            return normalizedFallbackChip(from: trimmedChip)
        }()

        return Presentation(
            modelName: effectiveModel,
            chip: effectiveChip,
            platform: trimmedPlatform,
            osVersion: trimmedOSVersion
        )
    }

    private static func trim(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return raw
    }

    private static func normalizedFallbackChip(from chip: String?) -> String? {
        guard let chip else { return nil }
        if isGenericChipName(chip) {
            return "Apple SoC"
        }
        return chip
    }

    private static func normalizedPlatformName(_ platform: String?) -> String? {
        guard let platform else { return nil }

        switch platform.lowercased() {
        case "ios", "iphoneos":
            return "iOS"
        case "ipados", "ipad os":
            return "iPadOS"
        case "macos", "osx", "mac os":
            return "macOS"
        case "tvos":
            return "tvOS"
        case "watchos":
            return "watchOS"
        case "visionos":
            return "visionOS"
        default:
            return platform
        }
    }

    public static func mergedPresentation(
        preferred: Presentation?,
        fallback: Presentation?
    ) -> Presentation {
        normalize(
            modelName: preferred?.modelName ?? fallback?.modelName,
            chip: preferred?.chip ?? fallback?.chip,
            platform: preferred?.platform ?? fallback?.platform,
            osVersion: preferred?.osVersion ?? fallback?.osVersion
        )
    }

    public static func mergedPresentations(
        _ presentations: [Presentation]
    ) -> Presentation? {
        let candidates = presentations.filter {
            $0.modelName != nil || $0.chip != nil || $0.platform != nil || $0.osVersion != nil
        }
        guard !candidates.isEmpty else { return nil }

        var modelName: String?
        var chip: String?
        var platform: String?
        var osVersion: String?

        for candidate in candidates {
            modelName = preferredModelName(existing: modelName, candidate: candidate.modelName)
            chip = preferredChip(existing: chip, candidate: candidate.chip)
            platform = preferredPlatform(existing: platform, candidate: candidate.platform)
            osVersion = preferredOSVersion(existing: osVersion, candidate: candidate.osVersion)
        }

        return normalize(
            modelName: modelName,
            chip: chip,
            platform: platform,
            osVersion: osVersion
        )
    }

    private static func isGenericChipName(_ raw: String) -> Bool {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "apple silicon" || normalized == "apple soc"
    }

    private static func preferredModelName(existing: String?, candidate: String?) -> String? {
        guard let candidate = trim(candidate) else { return existing }
        guard let existing = trim(existing) else { return candidate }

        let existingLooksRaw = looksLikeAppleModelIdentifier(existing)
        let candidateLooksRaw = looksLikeAppleModelIdentifier(candidate)
        if existingLooksRaw != candidateLooksRaw {
            return existingLooksRaw ? candidate : existing
        }

        return candidate.count > existing.count ? candidate : existing
    }

    private static func preferredChip(existing: String?, candidate: String?) -> String? {
        guard let candidate = trim(candidate) else { return existing }
        guard let existing = trim(existing) else { return candidate }

        let existingGeneric = isGenericChipName(existing)
        let candidateGeneric = isGenericChipName(candidate)
        if existingGeneric != candidateGeneric {
            return existingGeneric ? candidate : existing
        }

        return candidate.count > existing.count ? candidate : existing
    }

    private static func preferredPlatform(existing: String?, candidate: String?) -> String? {
        guard let candidate = normalizedPlatformName(trim(candidate)) else { return existing }
        guard let existing = normalizedPlatformName(trim(existing)) else { return candidate }

        return candidate.count > existing.count ? candidate : existing
    }

    private static func preferredOSVersion(existing: String?, candidate: String?) -> String? {
        guard let candidate = trim(candidate) else { return existing }
        guard let existing = trim(existing) else { return candidate }

        let comparison = comparePresentationOSVersion(candidate, existing)
        if comparison != .orderedSame {
            return comparison == .orderedDescending ? candidate : existing
        }

        return candidate.count > existing.count ? candidate : existing
    }

    private static func looksLikeAppleModelIdentifier(_ raw: String) -> Bool {
        raw.range(
            of: "^(iphone|ipad|ipod)[0-9]+,[0-9]+$",
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func comparePresentationOSVersion(
        _ lhs: String,
        _ rhs: String
    ) -> ComparisonResult {
        guard let lhsComponents = parsedPresentationVersionComponents(lhs),
              let rhsComponents = parsedPresentationVersionComponents(rhs) else {
            return .orderedSame
        }

        let maxCount = max(lhsComponents.count, rhsComponents.count)
        for index in 0..<maxCount {
            let lhsValue = index < lhsComponents.count ? lhsComponents[index] : 0
            let rhsValue = index < rhsComponents.count ? rhsComponents[index] : 0
            if lhsValue < rhsValue { return .orderedAscending }
            if lhsValue > rhsValue { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func parsedPresentationVersionComponents(_ raw: String) -> [Int]? {
        guard let range = raw.range(
            of: "[0-9]+(?:\\.[0-9]+)*",
            options: [.regularExpression]
        ) else {
            return nil
        }

        let token = raw[range]
        let components = token
            .split(separator: ".")
            .compactMap { Int($0) }

        guard !components.isEmpty else {
            return nil
        }

        return components
    }

    private static func resolvedPresentation(
        forModelIdentifier rawModelIdentifier: String
    ) -> (modelName: String, chip: String)? {
        let modelIdentifier = rawModelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelIdentifier.isEmpty else { return nil }

        switch modelIdentifier {
        case "iPhone17,1":
            return ("iPhone 16 Pro", "A18 Pro")
        case "iPhone17,2":
            return ("iPhone 16 Pro Max", "A18 Pro")
        case "iPhone17,3":
            return ("iPhone 16", "A18")
        case "iPhone17,4":
            return ("iPhone 16 Plus", "A18")
        case "iPad16,3", "iPad16,4":
            return ("iPad Pro 11-inch (M4)", "M4")
        default:
            return nil
        }
    }
}

@available(macOS 14.0, iOS 17.0, *)
extension TrustSyncService {
    public nonisolated static func buildPresentationDisplayGroups(
        from records: [TrustRecord]
    ) -> [TrustRecordDisplayGroup] {
        pruneSupersededDisplayGroups(buildDisplayGroups(from: records))
    }

    public nonisolated static func buildDisplayGroups(
        from records: [TrustRecord]
    ) -> [TrustRecordDisplayGroup] {
        struct GroupAccumulator {
            var anchors: Set<String>
            var records: [TrustRecord]
        }

        let eligibleRecords = records
            .filter { !$0.isTombstone && !$0.isExpired }
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.deviceId < rhs.deviceId
            }

        var groups: [GroupAccumulator] = []

        for record in eligibleRecords {
            let recordAnchors = displayAnchors(for: record)
            let matchingIndices = groups.indices.filter { index in
                !groups[index].anchors.isDisjoint(with: recordAnchors)
            }

            if matchingIndices.isEmpty {
                groups.append(GroupAccumulator(anchors: recordAnchors, records: [record]))
                continue
            }

            let primaryIndex = matchingIndices[0]
            groups[primaryIndex].anchors.formUnion(recordAnchors)
            groups[primaryIndex].records.append(record)

            if matchingIndices.count > 1 {
                for mergedIndex in matchingIndices.dropFirst().sorted(by: >) {
                    groups[primaryIndex].anchors.formUnion(groups[mergedIndex].anchors)
                    groups[primaryIndex].records.append(contentsOf: groups[mergedIndex].records)
                    groups.remove(at: mergedIndex)
                }
            }
        }

        return groups
            .map { accumulator in
                let relatedRecords = accumulator.records.sorted { lhs, rhs in
                    if displayPriority(for: lhs) != displayPriority(for: rhs) {
                        return displayPriority(for: lhs) > displayPriority(for: rhs)
                    }
                    if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                    return lhs.deviceId < rhs.deviceId
                }
                let primaryRecord = relatedRecords[0]
                let displayRecord = mergedDisplayRecord(
                    primaryRecord: primaryRecord,
                    relatedRecords: relatedRecords
                )
                return TrustRecordDisplayGroup(
                    id: accumulator.anchors.sorted().first ?? primaryRecord.deviceId,
                    primaryRecord: primaryRecord,
                    relatedRecords: relatedRecords,
                    displayRecord: displayRecord
                )
            }
            .sorted { lhs, rhs in
                if lhs.displayRecord.updatedAt != rhs.displayRecord.updatedAt {
                    return lhs.displayRecord.updatedAt > rhs.displayRecord.updatedAt
                }
                return lhs.displayRecord.deviceName ?? lhs.displayRecord.deviceId
                    < rhs.displayRecord.deviceName ?? rhs.displayRecord.deviceId
            }
    }

    private nonisolated static func pruneSupersededDisplayGroups(
        _ groups: [TrustRecordDisplayGroup]
    ) -> [TrustRecordDisplayGroup] {
        let strongestConfidenceBySignature = groups.reduce(into: [String: Int]()) { partialResult, group in
            guard let signature = presentationSignature(for: group.displayRecord) else { return }
            partialResult[signature] = max(
                partialResult[signature] ?? Int.min,
                presentationConfidence(for: group.displayRecord)
            )
        }

        return groups.filter { group in
            let record = group.displayRecord
            guard isWeakPresentationPlaceholder(record),
                  let signature = presentationSignature(for: record) else {
                return true
            }

            let strongestConfidence = strongestConfidenceBySignature[signature]
                ?? presentationConfidence(for: record)
            return presentationConfidence(for: record) >= strongestConfidence
        }
    }

    private nonisolated static func displayAnchors(for record: TrustRecord) -> Set<String> {
        var anchors = Set<String>()

        if let fingerprint = normalizedFingerprint(record.currentPathAuthorityFingerprint) {
            anchors.insert("fp:\(fingerprint)")
        }
        if let legacyFingerprint = normalizedFingerprint(record.pubKeyFP) {
            anchors.insert("legacyfp:\(legacyFingerprint)")
        }

        for candidate in PeerTrustLookup.recordLookupCandidates(record) {
            let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty else { continue }
            anchors.insert("candidate:\(normalized)")
        }

        if anchors.isEmpty,
           let normalizedName = normalizedDisplayName(record.deviceName) {
            anchors.insert("name:\(normalizedName)")
        }

        return anchors
    }

    private nonisolated static func displayPriority(for record: TrustRecord) -> Int {
        let caps = capabilityDictionary(for: record.capabilities)
        var score = 0

        if let fingerprint = record.currentPathAuthorityFingerprint, !fingerprint.isEmpty {
            score += 500
        }
        if !record.pubKeyFP.isEmpty {
            score += 250
        }
        if let currentDeviceId = record.currentDeviceIdMetadata,
           !currentDeviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            score += 140
        }
        score += min(record.knownDeviceIds.count, 6) * 20
        if let deviceName = record.deviceName, !deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            score += min(deviceName.count, 40)
        }
        for key in ["platform", "osVersion", "modelName", "chip", "peerEndpoint", "declaredDeviceId"] {
            if let value = caps[key], !value.isEmpty {
                score += 18
            }
        }
        return score
    }

    private nonisolated static func mergedDisplayRecord(
        primaryRecord: TrustRecord,
        relatedRecords: [TrustRecord]
    ) -> TrustRecord {
        let capabilityPayload = mergedCapabilities(primaryRecord: primaryRecord, relatedRecords: relatedRecords)
        let authoritativeRecords = relatedRecords.filter { hasAuthorityAnchors($0) }

        let mergedKnownDeviceIds = Array(
            Set(
                authoritativeRecords.flatMap { $0.knownDeviceIds }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        ).sorted()

        let bestDeviceName = relatedRecords
            .compactMap(\.deviceName)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .max(by: { lhs, rhs in lhs.count < rhs.count })

        let bestCurrentDeviceId = relatedRecords
            .compactMap(\.currentDeviceIdMetadata)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
            ?? authoritativeRecords
                .map(\.currentDeviceId)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }

        return TrustRecord(
            deviceId: primaryRecord.deviceId,
            pubKeyFP: primaryRecord.pubKeyFP,
            publicKey: primaryRecord.publicKey,
            secureEnclavePublicKey: primaryRecord.secureEnclavePublicKey,
            protocolPublicKey: primaryRecord.protocolPublicKey,
            protocolSigningAlgorithm: primaryRecord.protocolSigningAlgorithm,
            protocolPublicKeyFingerprint: primaryRecord.protocolPublicKeyFingerprint,
            legacyP256PublicKey: primaryRecord.legacyP256PublicKey,
            signatureAlgorithm: primaryRecord.signatureAlgorithm,
            kemPublicKeys: primaryRecord.kemPublicKeys,
            attestationLevel: primaryRecord.attestationLevel,
            attestationData: primaryRecord.attestationData,
            capabilities: capabilityPayload,
            createdAt: primaryRecord.createdAt,
            updatedAt: primaryRecord.updatedAt,
            version: primaryRecord.version,
            signature: primaryRecord.signature,
            recordType: primaryRecord.recordType,
            revokedAt: primaryRecord.revokedAt,
            deviceName: bestDeviceName ?? primaryRecord.deviceName,
            currentDeviceId: bestCurrentDeviceId ?? primaryRecord.currentDeviceIdMetadata,
            knownDeviceIds: mergedKnownDeviceIds,
            lifecycleState: primaryRecord.lifecycleStateMetadata
        )
    }

    private nonisolated static func mergedCapabilities(
        primaryRecord: TrustRecord,
        relatedRecords: [TrustRecord]
    ) -> [String] {
        var orderedFlags: [String] = []
        var seenFlags = Set<String>()
        var keyedValues: [String: String] = [:]

        let priorityRecords = [primaryRecord] + relatedRecords.filter { $0.deviceId != primaryRecord.deviceId }

        for record in priorityRecords {
            for capability in record.capabilities {
                let trimmed = capability.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    let key = parts[0]
                    let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty else { continue }
                    if let existing = keyedValues[key] {
                        if shouldReplaceCapabilityValue(
                            key: key,
                            existing: existing,
                            candidate: value
                        ) {
                            keyedValues[key] = value
                        }
                    } else {
                        keyedValues[key] = value
                    }
                } else {
                    let normalized = trimmed.lowercased()
                    if seenFlags.insert(normalized).inserted {
                        orderedFlags.append(trimmed)
                    }
                }
            }
        }

        let normalized = ApplePeerDeviceMetadataNormalizer.normalize(
            modelName: keyedValues["modelName"],
            chip: keyedValues["chip"],
            platform: keyedValues["platform"],
            osVersion: keyedValues["osVersion"]
        )
        keyedValues["modelName"] = normalized.modelName ?? keyedValues["modelName"]
        keyedValues["chip"] = normalized.chip ?? keyedValues["chip"]
        keyedValues["platform"] = normalized.platform ?? keyedValues["platform"]
        keyedValues["osVersion"] = normalized.osVersion ?? keyedValues["osVersion"]

        let preferredKeyOrder = [
            "trusted",
            "platform",
            "osVersion",
            "modelName",
            "chip",
            "peerEndpoint",
            "declaredDeviceId"
        ]

        var keyedPairs: [String] = []
        for key in preferredKeyOrder {
            if let value = keyedValues.removeValue(forKey: key) {
                keyedPairs.append("\(key)=\(value)")
            }
        }
        keyedPairs.append(contentsOf: keyedValues.keys.sorted().compactMap { key in
            guard let value = keyedValues[key] else { return nil }
            return "\(key)=\(value)"
        })

        return orderedFlags + keyedPairs
    }

    private nonisolated static func shouldReplaceCapabilityValue(
        key: String,
        existing: String,
        candidate: String
    ) -> Bool {
        switch key {
        case "chip":
            if existing.caseInsensitiveCompare(candidate) == .orderedSame {
                return false
            }
            return existing.lowercased() == "apple silicon"
                || existing.lowercased() == "apple soc"
        case "osVersion":
            let comparison = compareOSVersion(candidate, existing)
            if comparison != .orderedSame {
                return comparison == .orderedDescending
            }
            return candidate.count > existing.count
        case "modelName":
            let existingLooksRaw = looksLikeAppleModelIdentifier(existing)
            let candidateLooksRaw = looksLikeAppleModelIdentifier(candidate)
            if existingLooksRaw != candidateLooksRaw {
                return existingLooksRaw && !candidateLooksRaw
            }
            return candidate.count > existing.count
        default:
            return candidate.count > existing.count
        }
    }

    private nonisolated static func looksLikeAppleModelIdentifier(_ raw: String) -> Bool {
        raw.range(
            of: "^(iphone|ipad|ipod)[0-9]+,[0-9]+$",
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private nonisolated static func normalizedDisplayName(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return raw
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
    }

    private nonisolated static func normalizedFingerprint(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return raw.lowercased()
    }

    private nonisolated static func compareOSVersion(_ lhs: String, _ rhs: String) -> ComparisonResult {
        guard let lhsComponents = parsedVersionComponents(lhs),
              let rhsComponents = parsedVersionComponents(rhs) else {
            return .orderedSame
        }

        let maxCount = max(lhsComponents.count, rhsComponents.count)
        for index in 0..<maxCount {
            let lhsValue = index < lhsComponents.count ? lhsComponents[index] : 0
            let rhsValue = index < rhsComponents.count ? rhsComponents[index] : 0
            if lhsValue < rhsValue { return .orderedAscending }
            if lhsValue > rhsValue { return .orderedDescending }
        }
        return .orderedSame
    }

    private nonisolated static func parsedVersionComponents(_ raw: String) -> [Int]? {
        guard let range = raw.range(
            of: "[0-9]+(?:\\.[0-9]+)*",
            options: [.regularExpression]
        ) else {
            return nil
        }

        let token = raw[range]
        let components = token
            .split(separator: ".")
            .compactMap { Int($0) }

        guard !components.isEmpty else {
            return nil
        }
        return components
    }

    private nonisolated static func capabilityDictionary(
        for capabilities: [String]
    ) -> [String: String] {
        var result: [String: String] = [:]
        for capability in capabilities {
            let parts = capability.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            result[parts[0]] = value
        }
        return result
    }

    private nonisolated static func presentationConfidence(for record: TrustRecord) -> Int {
        let caps = capabilityDictionary(for: record.capabilities)
        var score = 0

        if let fingerprint = normalizedFingerprint(record.currentPathAuthorityFingerprint) {
            score += fingerprint.isEmpty ? 0 : 120
        }
        if let fingerprint = normalizedFingerprint(record.pubKeyFP) {
            score += fingerprint.isEmpty ? 0 : 80
        }
        if let currentDeviceId = record.currentDeviceIdMetadata?.trimmingCharacters(in: .whitespacesAndNewlines),
           !currentDeviceId.isEmpty {
            score += 60
        }
        if let knownDeviceIds = record.knownDeviceIdsMetadata {
            score += min(knownDeviceIds.count, 6) * 12
        }
        if let declaredDeviceId = caps["declaredDeviceId"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !declaredDeviceId.isEmpty {
            score += 40
        }
        if record.deviceId.lowercased().hasPrefix("id:") {
            score += 20
        }

        return score
    }

    private nonisolated static func isWeakPresentationPlaceholder(_ record: TrustRecord) -> Bool {
        guard !hasAuthorityAnchors(record) else { return false }
        let caps = capabilityDictionary(for: record.capabilities)

        let normalizedDeviceId = record.deviceId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedDeviceId.hasPrefix("id:") || normalizedDeviceId.hasPrefix("bonjour:") {
            return false
        }

        if isUUIDLikeToken(normalizedDeviceId) {
            return true
        }

        if let peerEndpoint = caps["peerEndpoint"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           isUUIDLikeToken(peerEndpoint) {
            return true
        }

        return presentationConfidence(for: record) == 0
    }

    private nonisolated static func hasAuthorityAnchors(_ record: TrustRecord) -> Bool {
        let caps = capabilityDictionary(for: record.capabilities)

        return normalizedFingerprint(record.currentPathAuthorityFingerprint) != nil
            || normalizedFingerprint(record.pubKeyFP) != nil
            || !(record.currentDeviceIdMetadata?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            || !((record.knownDeviceIdsMetadata ?? []).isEmpty)
            || !(caps["declaredDeviceId"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private nonisolated static func isUUIDLikeToken(_ raw: String) -> Bool {
        raw.range(
            of: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private nonisolated static func presentationSignature(for record: TrustRecord) -> String? {
        let caps = capabilityDictionary(for: record.capabilities)
        let normalizedMetadata = ApplePeerDeviceMetadataNormalizer.normalize(
            modelName: caps["modelName"],
            chip: caps["chip"],
            platform: caps["platform"],
            osVersion: caps["osVersion"]
        )

        let name = normalizedDisplayName(record.deviceName)
        let model = normalizedDisplayName(normalizedMetadata.modelName)
        let chip = normalizedDisplayName(normalizedMetadata.chip)
        let platform = normalizedDisplayName(normalizedMetadata.platform)

        let components = [name, model, chip, platform].compactMap { $0 }.filter { !$0.isEmpty }
        guard !components.isEmpty else { return nil }
        return components.joined(separator: "|")
    }
}
