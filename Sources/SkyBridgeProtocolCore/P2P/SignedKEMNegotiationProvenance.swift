import Foundation

/// Persisted only by the existing SKR import transaction after signature and
/// request binding verification. Presence of KEM bytes alone is not this proof.
public struct SignedKEMNegotiationProvenance: Codable, Sendable, Equatable {
    public let requestedSuiteWireIds: [UInt16]
    public let permittedSuiteWireIds: [UInt16]
    public let requesterPlatform: String
    public let requesterOSVersion: String
    public let requesterQProfile: String?
    public let responderQProfile: String?

    public init(requestedSuiteWireIds: [UInt16], permittedSuiteWireIds: [UInt16],
                requesterPlatform: String, requesterOSVersion: String,
                requesterQProfile: String?, responderQProfile: String?) {
        self.requestedSuiteWireIds = requestedSuiteWireIds
        self.permittedSuiteWireIds = permittedSuiteWireIds
        self.requesterPlatform = requesterPlatform
        self.requesterOSVersion = requesterOSVersion
        self.requesterQProfile = requesterQProfile
        self.responderQProfile = responderQProfile
    }

    public func validate(keys: [UInt16], responderPlatform: String?, responderOSVersion: String?) throws {
        try SignedKEMRefreshNegotiation.validateCapabilities(suites: requestedSuiteWireIds,
            platform: requesterPlatform, osVersion: requesterOSVersion, profile: requesterQProfile,
            allowEmpty: false, requireSorted: false)
        try SignedKEMRefreshNegotiation.validateCapabilities(suites: permittedSuiteWireIds,
            platform: responderPlatform, osVersion: responderOSVersion, profile: responderQProfile,
            allowEmpty: true, requireSorted: true)
        try SignedKEMRefreshNegotiation.requireKeySet(keys, requested: requestedSuiteWireIds,
            permitted: permittedSuiteWireIds, requesterProfile: requesterQProfile, responderProfile: responderQProfile)
    }

    /// A cache produced for a different local ready set/profile cannot establish
    /// what the responder would supply to the current request. Refresh it.
    public func select(mode: PQCModeSelection, locallyReadySuites: [UInt16], localQProfile: String?) throws -> UInt16 {
        guard requestedSuiteWireIds.sorted() == locallyReadySuites.sorted(),
              requesterQProfile == localQProfile else { throw PQCModeSelectionError.negotiatedEvidenceRequired }
        let intersection = SignedKEMRefreshNegotiation.intersection(requested: locallyReadySuites,
            permitted: permittedSuiteWireIds, requesterProfile: localQProfile, responderProfile: responderQProfile)
        return try mode.select(fromVerifiedIntersection: intersection)
    }
}
