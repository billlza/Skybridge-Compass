import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@available(macOS 14.0, iOS 17.0, *)
private struct PeerTrustRecordLookupCacheKey: Hashable {
    let deviceId: String
    let currentDeviceId: String?
    let knownDeviceIds: [String]
    let capabilities: [String]

    init(_ record: TrustRecord) {
        self.deviceId = record.deviceId
        self.currentDeviceId = record.currentDeviceIdMetadata
        self.knownDeviceIds = record.knownDeviceIdsMetadata ?? []
        self.capabilities = record.capabilities
    }
}

@available(macOS 14.0, iOS 17.0, *)
private final class PeerTrustLookupCache: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumEntryCount = 4096
    private var lookupCandidatesByIdentifier: [String: [String]] = [:]
    private var recordCandidatesByKey: [PeerTrustRecordLookupCacheKey: [String]] = [:]
    private var literalIPAddressByToken: [String: Bool] = [:]

    func lookupCandidates(for key: String, compute: () -> [String]) -> [String] {
        lock.lock()
        if let cached = lookupCandidatesByIdentifier[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = compute()

        lock.lock()
        resetIfNeeded(lookupCandidatesByIdentifier.count)
        lookupCandidatesByIdentifier[key] = resolved
        lock.unlock()
        return resolved
    }

    func recordLookupCandidates(for key: PeerTrustRecordLookupCacheKey, compute: () -> [String]) -> [String] {
        lock.lock()
        if let cached = recordCandidatesByKey[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = compute()

        lock.lock()
        resetIfNeeded(recordCandidatesByKey.count)
        recordCandidatesByKey[key] = resolved
        lock.unlock()
        return resolved
    }

    func literalIPAddress(for key: String, compute: () -> Bool) -> Bool {
        lock.lock()
        if let cached = literalIPAddressByToken[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = compute()

        lock.lock()
        resetIfNeeded(literalIPAddressByToken.count)
        literalIPAddressByToken[key] = resolved
        lock.unlock()
        return resolved
    }

    private func resetIfNeeded(_ count: Int) {
        guard count >= maximumEntryCount else { return }
        lookupCandidatesByIdentifier.removeAll(keepingCapacity: true)
        recordCandidatesByKey.removeAll(keepingCapacity: true)
        literalIPAddressByToken.removeAll(keepingCapacity: true)
    }
}

@available(macOS 14.0, iOS 17.0, *)
enum PeerTrustLookup {
    private static let cache = PeerTrustLookupCache()

    static func trimmedIdentifier(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return raw
    }

    static func normalizedIdentifier(_ raw: String?) -> String? {
        trimmedIdentifier(raw)?.lowercased()
    }

    private static func isPlausibleStableDeviceIdentifierPayload(_ raw: String) -> Bool {
        guard raw.count >= 8 else { return false }
        guard !raw.contains(where: \.isWhitespace) else { return false }
        return raw.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_" || character == ".")
        }
    }

    private static func isLiteralIPAddress(_ raw: String) -> Bool {
        let scopedToken = raw.split(separator: "%", maxSplits: 1).first.map(String.init) ?? raw
        guard looksLikeLiteralIPAddress(scopedToken) else { return false }
        return cache.literalIPAddress(for: scopedToken) {
            isLiteralIPAddressUncached(scopedToken)
        }
    }

    private static func isLiteralIPAddressUncached(_ token: String) -> Bool {
        #if canImport(Darwin) || canImport(Glibc)
        var ipv4Address = in_addr()
        if token.withCString({ inet_pton(AF_INET, $0, &ipv4Address) }) == 1 {
            return true
        }

        var ipv6Address = in6_addr()
        return token.withCString { inet_pton(AF_INET6, $0, &ipv6Address) } == 1
        #else
        return false
        #endif
    }

    private static func looksLikeLiteralIPAddress(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        if token.contains(":") {
            return token.unicodeScalars.allSatisfy { scalar in
                scalar == ":" || scalar == "." || (scalar.value >= 48 && scalar.value <= 57)
                    || (scalar.value >= 65 && scalar.value <= 70)
                    || (scalar.value >= 97 && scalar.value <= 102)
            }
        }
        guard token.contains(".") else { return false }
        return token.unicodeScalars.allSatisfy { scalar in
            scalar == "." || (scalar.value >= 48 && scalar.value <= 57)
        }
    }

    static func sanitizedBonjourServiceInstanceName(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }

        if value.lowercased().hasPrefix("bonjour:") {
            let payload = String(value.dropFirst("bonjour:".count))
            let name = payload.split(separator: "@", maxSplits: 1).first.map(String.init)
            return sanitizedBonjourServiceInstanceName(name)
        }

        if let range = value.range(of: "._") {
            value = String(value[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let lowercased = value.lowercased()
        guard !lowercased.hasPrefix("id:"),
              !lowercased.hasPrefix("host:"),
              !lowercased.hasPrefix("peer:"),
              !lowercased.hasPrefix("recent:"),
              !lowercased.hasPrefix("mac:") else {
            return nil
        }
        guard UUID(uuidString: value.uppercased()) == nil else { return nil }
        guard !isLiteralIPAddress(value) else { return nil }
        guard !value.contains("/") else { return nil }
        return value.isEmpty ? nil : value
    }

    static func persistentDeviceId(from raw: String?) -> String? {
        guard let trimmed = trimmedIdentifier(raw) else { return nil }
        let normalized = trimmed.lowercased()
        if normalized.hasPrefix("id:") {
            let payload = String(normalized.dropFirst("id:".count))
            guard isPlausibleStableDeviceIdentifierPayload(payload) else { return nil }
            guard !isLiteralIPAddress(payload) else { return nil }
            return "id:\(payload)"
        }
        if normalized.hasPrefix("host:")
            || normalized.hasPrefix("peer:")
            || normalized.hasPrefix("bonjour:")
            || normalized.hasPrefix("recent:")
            || trimmed.contains("@") {
            return nil
        }
        guard isPlausibleStableDeviceIdentifierPayload(normalized) else { return nil }
        guard !isLiteralIPAddress(normalized) else { return nil }
        return "id:\(normalized)"
    }

    static func isEndpointAlias(_ raw: String?) -> Bool {
        guard let normalized = normalizedIdentifier(raw) else { return false }
        if normalized.hasPrefix("recent:") {
            return isEndpointAlias(String(normalized.dropFirst("recent:".count)))
        }
        if normalized.hasPrefix("host:") || normalized.hasPrefix("peer:") {
            return true
        }
        if normalized.hasPrefix("id:") {
            let payload = String(normalized.dropFirst("id:".count))
            return isLiteralIPAddress(payload)
        }
        return isLiteralIPAddress(normalized)
    }

    static func lookupCandidates(for identifier: String?) -> [String] {
        guard let cacheKey = trimmedIdentifier(identifier) else { return [] }
        return cache.lookupCandidates(for: cacheKey) {
            lookupCandidatesUncached(for: cacheKey)
        }
    }

    private static func lookupCandidatesUncached(for identifier: String) -> [String] {
        var ordered: [String] = []
        var seen: Set<String> = []

        func append(_ raw: String?) {
            guard let trimmed = trimmedIdentifier(raw) else { return }
            if seen.insert(trimmed).inserted {
                ordered.append(trimmed)
            }

            let lowercased = trimmed.lowercased()
            if lowercased != trimmed, seen.insert(lowercased).inserted {
                ordered.append(lowercased)
            }
        }

        func appendDerived(_ raw: String?) {
            guard let trimmed = trimmedIdentifier(raw) else { return }
            append(trimmed)

            let normalized = trimmed.lowercased()
            if normalized.hasPrefix("recent:") {
                let offset = trimmed.index(trimmed.startIndex, offsetBy: "recent:".count)
                appendDerived(String(trimmed[offset...]))
            }

            if normalized.hasPrefix("id:") {
                let offset = trimmed.index(trimmed.startIndex, offsetBy: 3)
                append(String(trimmed[offset...]))
            } else if let persistent = persistentDeviceId(from: trimmed) {
                append(persistent)
            }

            if let alias = hostAlias(from: trimmed) {
                append(alias)
            }

            if let alias = hostAlias(fromIPAddress: trimmed) {
                append(alias)
            }

            if let alias = bonjourAlias(from: trimmed) {
                append(alias)
            }
        }

        appendDerived(identifier)
        return ordered
    }

    static func lookupCandidates(primary: String?, persistent: String?) -> [String] {
        var ordered: [String] = []
        var seen: Set<String> = []

        func appendCandidates(from raw: String?) {
            for candidate in lookupCandidates(for: raw) where seen.insert(candidate).inserted {
                ordered.append(candidate)
            }
        }

        appendCandidates(from: persistent)
        appendCandidates(from: primary)
        return ordered
    }

    static func capabilityValue(prefix: String, in capabilities: [String]) -> String? {
        for capability in capabilities {
            guard capability.hasPrefix(prefix) else { continue }
            let value = String(capability.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
        }
        return nil
    }

    static func recordLookupCandidates(_ record: TrustRecord) -> [String] {
        let cacheKey = PeerTrustRecordLookupCacheKey(record)
        return cache.recordLookupCandidates(for: cacheKey) {
            recordLookupCandidatesUncached(record)
        }
    }

    /// Returns only records that can authorize after applying lifecycle
    /// denial evidence across every stable ID, route alias, and protocol-key
    /// fingerprint. A tombstone/quarantine must not be bypassed by a second
    /// active record stored under another alias.
    static func authenticationEligibleRecordsRespectingDenial(
        _ records: [TrustRecord]
    ) -> [TrustRecord] {
        let denialRecords = records.filter(isLifecycleDenialEvidence)
        return records.filter { record in
            record.isAuthenticationEligible
                && !denialRecords.contains(where: { recordsShareTrustIdentity(record, $0) })
        }
    }

    static func record(_ record: TrustRecord, matchesDeviceId deviceId: String) -> Bool {
        let candidates = Set(
            lookupCandidates(for: deviceId)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        guard !candidates.isEmpty else { return false }
        return recordLookupCandidates(record).contains {
            candidates.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
    }

    private static func isLifecycleDenialEvidence(_ record: TrustRecord) -> Bool {
        guard !record.isExpired else { return false }
        if record.isTombstone || record.lifecycleState == .revoked {
            return true
        }
        switch record.lifecycleState {
        case .quarantined, .reverificationRequired:
            return true
        case .active, .revoked:
            return false
        }
    }

    static func recordsShareTrustIdentity(_ lhs: TrustRecord, _ rhs: TrustRecord) -> Bool {
        let lhsFingerprints = lhs.currentPathAuthorityFingerprints
        if !lhsFingerprints.isDisjoint(with: rhs.currentPathAuthorityFingerprints) {
            return true
        }

        let lhsLegacyFingerprint = lhs.pubKeyFP
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let rhsLegacyFingerprint = rhs.pubKeyFP
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if !lhsLegacyFingerprint.isEmpty, lhsLegacyFingerprint == rhsLegacyFingerprint {
            return true
        }

        let lhsCandidates = Set(
            recordLookupCandidates(lhs)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        guard !lhsCandidates.isEmpty else { return false }
        return recordLookupCandidates(rhs).contains {
            lhsCandidates.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
    }

    private static func recordLookupCandidatesUncached(_ record: TrustRecord) -> [String] {
        var ordered: [String] = []
        var seen: Set<String> = []

        func appendCandidates(from raw: String?) {
            for candidate in lookupCandidates(for: raw) where seen.insert(candidate).inserted {
                ordered.append(candidate)
            }
        }

        appendCandidates(from: record.deviceId)
        appendCandidates(from: record.currentDeviceIdMetadata)
        for knownDeviceId in record.knownDeviceIdsMetadata ?? [] {
            appendCandidates(from: knownDeviceId)
        }
        appendCandidates(from: capabilityValue(prefix: "peerEndpoint=", in: record.capabilities))
        appendCandidates(from: capabilityValue(prefix: "declaredDeviceId=", in: record.capabilities))
        return ordered
    }

    static func recordMatches(
        _ record: TrustRecord,
        candidates: Set<String>,
        candidateLowercased: Set<String>,
        candidateDisplayNamesLower: Set<String> = []
    ) -> Bool {
        guard !record.isTombstone else { return false }

        for recordCandidate in recordLookupCandidates(record) {
            if candidates.contains(recordCandidate) || candidateLowercased.contains(recordCandidate.lowercased()) {
                return true
            }
        }

        guard let deviceName = trimmedIdentifier(record.deviceName)?.lowercased(),
              !deviceName.isEmpty else {
            return false
        }
        return candidateDisplayNamesLower.contains(deviceName)
    }

    private static func hostAlias(from identifier: String) -> String? {
        guard let normalized = normalizedIdentifier(identifier) else { return nil }
        if normalized.hasPrefix("host:") {
            return hostAlias(fromIPAddress: String(normalized.dropFirst("host:".count)))
        }
        if normalized.hasPrefix("peer:") {
            return hostAlias(fromIPAddress: String(normalized.dropFirst("peer:".count)))
        }
        return nil
    }

    static func hostAlias(fromIPAddress raw: String?) -> String? {
        guard var token = normalizedIdentifier(raw),
              !token.isEmpty else {
            return nil
        }

        if token.hasPrefix("host:") {
            token = String(token.dropFirst("host:".count))
        } else if token.hasPrefix("peer:") {
            token = String(token.dropFirst("peer:".count))
        }

        if token.hasPrefix("[") && token.hasSuffix("]") && token.count >= 2 {
            token = String(token.dropFirst().dropLast())
        }

        if token.hasPrefix("["),
           let closingBracket = token.firstIndex(of: "]") {
            token = String(token[token.index(after: token.startIndex)..<closingBracket])
        }

        if let percent = token.firstIndex(of: "%") {
            token = String(token[..<percent])
        }

        if token.contains(":"),
           let dot = token.lastIndex(of: "."),
           token[token.index(after: dot)...].allSatisfy({ $0.isNumber }) {
            token = String(token[..<dot])
        } else {
            let parts = token.split(separator: ".")
            if parts.count == 5,
               parts.dropLast().allSatisfy({ Int($0) != nil }),
               let port = Int(parts.last ?? ""),
               (0...65535).contains(port) {
                token = parts.dropLast().map(String.init).joined(separator: ".")
            }
        }

        if token.hasPrefix("[") && token.hasSuffix("]") && token.count >= 2 {
            token = String(token.dropFirst().dropLast())
        }

        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, isLiteralIPAddress(normalized) else { return nil }
        return "host:\(normalized)"
    }

    private static func bonjourAlias(from identifier: String) -> String? {
        guard let trimmed = trimmedIdentifier(identifier),
              trimmed.lowercased().hasPrefix("bonjour:") else {
            return nil
        }

        let payload = String(trimmed.dropFirst("bonjour:".count))
        let parts = payload.split(separator: "@", maxSplits: 1).map(String.init)
        guard let name = parts.first, !name.isEmpty else { return nil }
        let domain = parts.count > 1 ? parts[1] : "local."
        return bonjourAlias(name: name, domain: domain)
    }

    private static func bonjourAlias(name: String?, domain: String?) -> String? {
        guard let rawName = trimmedIdentifier(name) else { return nil }

        let rawDomain = domain?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "local."
        let normalizedDomain: String
        if rawDomain.isEmpty {
            normalizedDomain = "local."
        } else if rawDomain.hasSuffix(".") {
            normalizedDomain = rawDomain.lowercased()
        } else {
            normalizedDomain = "\(rawDomain.lowercased())."
        }

        return "bonjour:\(rawName.lowercased())@\(normalizedDomain)"
    }
}
