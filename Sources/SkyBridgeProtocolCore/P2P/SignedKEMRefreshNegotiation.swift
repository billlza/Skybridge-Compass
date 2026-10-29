import Foundation

/// SKR v3 metadata and set rules. This is not a trust or signature-verification boundary.
public enum SignedKEMRefreshNegotiation {
    public static let version = 3
    public static let qPeriapt: UInt16 = 0x0012
    public static let preferenceOrder: [UInt16] = [qPeriapt, 0x0001, 0x0101]

    public enum ValidationError: Error, Sendable, Equatable {
        case invalidSuiteSet, invalidMetadata, invalidQProfile, incompleteKeySet
    }

    public static func validateCapabilities(
        suites: [UInt16], platform: String?, osVersion: String?, profile: String?,
        allowEmpty: Bool, requireSorted: Bool
    ) throws {
        guard (allowEmpty || !suites.isEmpty), suites.count <= preferenceOrder.count,
              Set(suites).count == suites.count, suites.allSatisfy(preferenceOrder.contains),
              !requireSorted || suites == suites.sorted() else {
            throw ValidationError.invalidSuiteSet
        }
        guard validMetadata(platform), validMetadata(osVersion) else { throw ValidationError.invalidMetadata }
        if suites.contains(qPeriapt) {
            guard QPeriaptPeerPlatformPolicy.isPeerAppPlatformEligible(platform: platform, osVersion: osVersion),
                  validQProfile(profile) else { throw ValidationError.invalidQProfile }
        } else if profile != nil {
            throw ValidationError.invalidQProfile
        }
    }

    /// Call only on validated capabilities; the caller must authenticate the response separately.
    public static func intersection(requested: [UInt16], permitted: [UInt16], requesterProfile: String?, responderProfile: String?) -> [UInt16] {
        preferenceOrder.filter {
            requested.contains($0) && permitted.contains($0) && ($0 != qPeriapt || requesterProfile == responderProfile)
        }
    }

    public static func requireKeySet(_ keys: [UInt16], requested: [UInt16], permitted: [UInt16], requesterProfile: String?, responderProfile: String?) throws {
        guard keys.sorted() == intersection(requested: requested, permitted: permitted,
            requesterProfile: requesterProfile, responderProfile: responderProfile).sorted() else {
            throw ValidationError.incompleteKeySet
        }
    }

    public static func canonicalSuiteIDs(_ suites: [UInt16]) -> String {
        suites.sorted().map { String(format: "0x%04X", $0) }.joined(separator: ",")
    }

    public static func requestFields(platform: String?, osVersion: String?, profile: String?) -> [(String, String)] {
        [("platform", canonicalToken(platform)), ("osVersion", canonicalToken(osVersion)),
         ("qPeriaptAuthProfile", canonicalToken(profile))]
    }

    public static func responseFields(permitted: [UInt16]?, profile: String?) -> [(String, String)] {
        [("permittedSuiteWireIds", canonicalSuiteIDs(permitted ?? [])),
         ("qPeriaptAuthProfile", canonicalToken(profile))]
    }

    private static func validMetadata(_ value: String?) -> Bool {
        guard let value, !value.isEmpty, value.utf16.count <= 256,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f || $0 == "=" }
    }

    private static func validQProfile(_ profile: String?) -> Bool {
        guard let profile else { return false }
        let parts = profile.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0] == "q-periapt-abi2-policy-v1",
              [parts[1], parts[2], parts[4]].allSatisfy({ part in
                  part.utf8.count == 64 && part.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
              }), let version = UInt64(parts[3]), String(version) == parts[3] else { return false }
        return true
    }

    private static func canonicalToken(_ value: String?) -> String {
        let result = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return result.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "=" }) ? "" : result
    }
}
