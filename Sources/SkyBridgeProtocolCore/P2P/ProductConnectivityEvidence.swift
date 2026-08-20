import Foundation

/// Product-selected endpoint posture at the start of one normal handshake.
///
/// This is deliberately distinct from the negotiated suite. An endpoint that
/// prefers X-Wing can honestly negotiate pure ML-KEM with a pure-PQC peer; the
/// external release validator joins both endpoint records instead of asking
/// either endpoint to infer the peer's setting.
public enum ProductConnectivityEndpointProfile: String, Sendable, Hashable {
    case xwing
    case pqc
    case classic
}

/// Families that were actually present in one endpoint's local handshake offer.
///
/// Native Apple PQC attempts commonly offer both X-Wing and pure ML-KEM even
/// though the product has one configured preference. Keeping the offer as a
/// set avoids pretending that a mixed, signed offer was one endpoint profile.
public enum ProductConnectivityOfferedProfiles: String, Sendable, Hashable {
    case xwing
    case pqc
    case pqcAndXWing = "pqc+xwing"
    case classic
}

public enum ProductConnectivityHandshakeRole: String, Sendable, Hashable {
    case initiator
    case responder
}

public enum ProductConnectivityEvidenceProduct: String, Sendable, Hashable {
    case macOSApp = "SkyBridgeCompassApp"
    case iOSApp = "SkyBridgeCompassiOS"
}

public enum ProductConnectivityPolicyRejectionReason: String, Sendable {
    case strictPQCRejectsClassic = "strict-pqc-rejects-classic"
}

public enum ProductConnectivityAttemptFailureReason: String, Sendable {
    case handshakeFailed = "handshake-failed"
    case transportClosed = "transport-closed"
    case cancelled
    case superseded
    case publicationFailed = "publication-failed"
}

/// Pure classification helpers shared by the macOS core and the iOS app.
public enum ProductConnectivityProfileClassifier {
    /// Classifies the actual committed local product selection. The selected
    /// suite comes from the local provider snapshot, never from the peer or the
    /// eventual negotiated suite.
    public static func configuredProfile(
        requirePQC: Bool,
        selectedSuiteWireID: UInt16
    ) -> ProductConnectivityEndpointProfile? {
        let suite = CryptoSuite(wireId: selectedSuiteWireID)
        guard suite.isNegotiable else { return nil }
        guard requirePQC else {
            return suite.isPQCGroup ? nil : .classic
        }
        guard suite.isPQCGroup else { return nil }
        return suite.wireId == CryptoSuite.xwingMLDSA.wireId ? .xwing : .pqc
    }

    /// Classifies the suite families actually present in one local offer.
    /// Classic/PQC mixtures remain invalid because product evidence never
    /// observes a compatibility-fallback policy. X-Wing plus pure PQC is a
    /// normal native-PQC offer and is represented explicitly.
    public static func offeredProfiles(
        suiteWireIDs: [UInt16]
    ) -> ProductConnectivityOfferedProfiles? {
        guard !suiteWireIDs.isEmpty else { return nil }
        let suites = suiteWireIDs.map(CryptoSuite.init(wireId:))
        guard suites.allSatisfy(\.isNegotiable) else { return nil }
        let profiles = Set(suites.map { suite -> ProductConnectivityEndpointProfile in
            if suite.wireId == CryptoSuite.xwingMLDSA.wireId { return .xwing }
            return suite.isPQCGroup ? .pqc : .classic
        })
        switch profiles {
        case [.xwing]:
            return .xwing
        case [.pqc]:
            return .pqc
        case [.xwing, .pqc]:
            return .pqcAndXWing
        case [.classic]:
            return .classic
        default:
            return nil
        }
    }

    /// Classifies the suite that this endpoint actually negotiated. This is
    /// evaluated only at the authenticated terminal, never guessed at attempt
    /// start from the local preference or the peer offer.
    public static func negotiatedProfile(
        suiteWireID: UInt16
    ) -> ProductConnectivityEndpointProfile? {
        let suite = CryptoSuite(wireId: suiteWireID)
        guard suite.isNegotiable else { return nil }
        if suite.wireId == CryptoSuite.xwingMLDSA.wireId { return .xwing }
        return suite.isPQCGroup ? .pqc : .classic
    }
}

/// Privacy-safe correlation for the existing signed SOA handshake attempt ID.
///
/// The attempt ID is already a random, non-secret 16-byte protocol value. A
/// direct canonical representation is sufficient for cross-device joining and
/// avoids adding another hash or integrity mechanism.
public enum ProductConnectivityAttemptReference {
    public static func make(from attemptID: Data) -> String? {
        guard attemptID.count == HandshakeSOAExtension.attemptIdLength else { return nil }
        return "at1:" + attemptID.map { String(format: "%02x", $0) }.joined()
    }

    public static func isValid(_ reference: String) -> Bool {
        guard reference.utf8.count == 36, reference.hasPrefix("at1:") else {
            return false
        }
        return reference.dropFirst(4).unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57)
                || (scalar.value >= 97 && scalar.value <= 102)
        }
    }
}

/// Privacy-safe correlation for one committed product protocol identity.
///
/// The input is the existing domain-separated authoritative protocol
/// fingerprint.  The first 128 bits are exposed only inside private process-
/// bound capture as a Level-2 cross-launch correlation reference; this does
/// not add an integrity or anti-tamper mechanism. Public materialization
/// replaces it with an artifact-local alias after equality is verified. Raw
/// public keys, the complete fingerprint, device IDs, and account identifiers
/// never enter the evidence schema.
public enum ProductIdentityEvidenceReference {
    public static func make(
        fromAuthoritativeFingerprint fingerprint: String
    ) -> String? {
        guard fingerprint.utf8.count == 64,
              fingerprint.unicodeScalars.allSatisfy({ scalar in
                  (scalar.value >= 48 && scalar.value <= 57)
                      || (scalar.value >= 97 && scalar.value <= 102)
              }) else {
            return nil
        }
        return "id1:" + fingerprint.prefix(32)
    }

    public static func isValid(_ reference: String) -> Bool {
        guard reference.utf8.count == 36, reference.hasPrefix("id1:") else {
            return false
        }
        return reference.dropFirst(4).unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57)
                || (scalar.value >= 97 && scalar.value <= 102)
        }
    }
}

public enum ProductIdentityEvidenceAlgorithm: String, Sendable, Hashable {
    case mlDSA65 = "mldsa65"
    case mlDSA87 = "mldsa87"
}

public enum ProductIdentityEvidenceProtection: String, Sendable, Hashable {
    case softwareKeychain
    case secureEnclaveRequired
}

/// Non-secret identity facts permitted in the fixed product evidence schema.
public struct ProductIdentityEvidenceDescriptor: Sendable, Hashable {
    public let identityReference: String
    public let algorithm: ProductIdentityEvidenceAlgorithm
    public let protection: ProductIdentityEvidenceProtection

    public init?(
        identityReference: String,
        algorithm: ProductIdentityEvidenceAlgorithm,
        protection: ProductIdentityEvidenceProtection
    ) {
        guard ProductIdentityEvidenceReference.isValid(identityReference) else {
            return nil
        }
        self.identityReference = identityReference
        self.algorithm = algorithm
        self.protection = protection
    }

    public var isFormalProductionIdentity: Bool {
        algorithm == .mlDSA87 && protection == .secureEnclaveRequired
    }
}

/// Exact one-shot owner for an observed normal-product handshake attempt.
/// The owner carries no peer identity, address, key material, or payload data.
public final class ProductConnectivityAttemptOwner: @unchecked Sendable {
    public let product: ProductConnectivityEvidenceProduct
    public let attemptReference: String
    public let generation: UInt64
    public let role: ProductConnectivityHandshakeRole
    public let localProfile: ProductConnectivityEndpointProfile
    public let offeredProfiles: ProductConnectivityOfferedProfiles
    public let requirePQC: Bool
    public let allowClassicFallback: Bool

    fileprivate let offeredSuiteWireIDs: Set<UInt16>
    private let lifecycleLock = NSLock()
    private var isTerminal = false

    fileprivate init(
        product: ProductConnectivityEvidenceProduct,
        attemptReference: String,
        generation: UInt64,
        role: ProductConnectivityHandshakeRole,
        localProfile: ProductConnectivityEndpointProfile,
        offeredProfiles: ProductConnectivityOfferedProfiles,
        offeredSuiteWireIDs: Set<UInt16>,
        requirePQC: Bool,
        allowClassicFallback: Bool
    ) {
        self.product = product
        self.attemptReference = attemptReference
        self.generation = generation
        self.role = role
        self.localProfile = localProfile
        self.offeredProfiles = offeredProfiles
        self.offeredSuiteWireIDs = offeredSuiteWireIDs
        self.requirePQC = requirePQC
        self.allowClassicFallback = allowClassicFallback
    }

    fileprivate func transitionToTerminal() -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard !isTerminal else { return false }
        isTerminal = true
        return true
    }
}

/// Canonical, privacy-safe OSLog message formatting for product connectivity
/// evidence. Callers own OSLog process binding; this type owns only validation,
/// one-shot lifecycle, and the fixed public message schema.
public enum ProductConnectivityEvidenceFormatter {
    public static func beginAttempt(
        product: ProductConnectivityEvidenceProduct,
        attemptReference: String,
        generation: UInt64,
        role: ProductConnectivityHandshakeRole,
        localProfile: ProductConnectivityEndpointProfile,
        offeredSuiteWireIDs: [UInt16],
        requirePQC: Bool,
        allowClassicFallback: Bool
    ) -> (owner: ProductConnectivityAttemptOwner, line: String)? {
        let canonicalSuiteWireIDs = Set(offeredSuiteWireIDs)
        guard ProductConnectivityAttemptReference.isValid(attemptReference),
              generation > 0,
              canonicalSuiteWireIDs.count == offeredSuiteWireIDs.count,
              let offeredProfiles = ProductConnectivityProfileClassifier.offeredProfiles(
                suiteWireIDs: offeredSuiteWireIDs
              ),
              validLocalPolicy(
                localProfile: localProfile,
                offeredProfiles: offeredProfiles,
                requirePQC: requirePQC,
                allowClassicFallback: allowClassicFallback
              ) else {
            return nil
        }
        let owner = ProductConnectivityAttemptOwner(
            product: product,
            attemptReference: attemptReference,
            generation: generation,
            role: role,
            localProfile: localProfile,
            offeredProfiles: offeredProfiles,
            offeredSuiteWireIDs: canonicalSuiteWireIDs,
            requirePQC: requirePQC,
            allowClassicFallback: allowClassicFallback
        )
        return (owner, line(
            event: "connectivityAttemptStarted",
            owner: owner,
            fields: ["result=started"]
        ))
    }

    /// Produces a terminal attempt line and the independently joinable endpoint
    /// line only after the caller has durably published the authenticated
    /// session incarnation.
    public static func authenticateAttempt(
        owner: ProductConnectivityAttemptOwner,
        sessionReference: String,
        negotiatedSuite: CryptoSuite
    ) -> [String]? {
        guard let negotiatedProfile = ProductConnectivityProfileClassifier.negotiatedProfile(
                suiteWireID: negotiatedSuite.wireId
              ),
              P2PEvidenceReference.isValid(sessionReference),
              negotiatedSuite.isNegotiable,
              negotiatedSuite.isPQCGroup,
              owner.offeredSuiteWireIDs.contains(negotiatedSuite.wireId),
              owner.requirePQC,
              !owner.allowClassicFallback,
              owner.localProfile != .classic,
              owner.transitionToTerminal() else {
            return nil
        }
        let terminal = line(
            event: "connectivityAttemptAuthenticated",
            owner: owner,
            fields: [
                "session_ref=\(sessionReference)",
                "attemptProfile=\(negotiatedProfile.rawValue)",
                "result=authenticated"
            ]
        )
        let endpoint = (["connectivityEndpoint"] + [
            "transport=p2p",
            "session_ref=\(sessionReference)",
            "attempt_ref=\(owner.attemptReference)",
            "owner=\(owner.product.rawValue)",
            "generation=\(owner.generation)",
            "role=\(owner.role.rawValue)",
            "localProfile=\(owner.localProfile.rawValue)",
            "offeredProfiles=\(owner.offeredProfiles.rawValue)",
            "attemptProfile=\(negotiatedProfile.rawValue)",
            "suite=\(negotiatedSuite.rawValue)",
            "requirePQC=1",
            "allowClassicFallback=0",
            "result=success"
        ]).joined(separator: " ")
        return [terminal, endpoint]
    }

    public static func rejectAttempt(
        owner: ProductConnectivityAttemptOwner,
        peerOfferedSuiteWireIDs: [UInt16],
        reason: ProductConnectivityPolicyRejectionReason
    ) -> String? {
        guard Set(peerOfferedSuiteWireIDs).count == peerOfferedSuiteWireIDs.count,
              let peerOfferedProfiles = ProductConnectivityProfileClassifier.offeredProfiles(
            suiteWireIDs: peerOfferedSuiteWireIDs
        ) else {
            return nil
        }
        let validRejection: Bool = switch reason {
        case .strictPQCRejectsClassic:
            owner.role == .responder
                && owner.requirePQC
                && !owner.allowClassicFallback
                && owner.localProfile != .classic
                && owner.offeredProfiles != .classic
                && peerOfferedProfiles == .classic
        }
        guard validRejection, owner.transitionToTerminal() else { return nil }
        return line(
            event: "connectivityPolicyRejected",
            owner: owner,
            fields: [
                "peerOfferedProfiles=\(peerOfferedProfiles.rawValue)",
                "peerOfferSignature=verified",
                "reason=\(reason.rawValue)",
                "result=rejected"
            ]
        )
    }

    public static func failAttempt(
        owner: ProductConnectivityAttemptOwner,
        reason: ProductConnectivityAttemptFailureReason
    ) -> String? {
        guard owner.transitionToTerminal() else { return nil }
        return line(
            event: "connectivityAttemptFailed",
            owner: owner,
            fields: ["reason=\(reason.rawValue)", "result=failed"]
        )
    }

    private static func validLocalPolicy(
        localProfile: ProductConnectivityEndpointProfile,
        offeredProfiles: ProductConnectivityOfferedProfiles,
        requirePQC: Bool,
        allowClassicFallback: Bool
    ) -> Bool {
        guard !allowClassicFallback else { return false }
        if requirePQC {
            switch localProfile {
            case .xwing:
                return offeredProfiles == .xwing || offeredProfiles == .pqcAndXWing
            case .pqc:
                return offeredProfiles == .pqc || offeredProfiles == .pqcAndXWing
            case .classic:
                return false
            }
        }
        return localProfile == .classic && offeredProfiles == .classic
    }

    private static func line(
        event: String,
        owner: ProductConnectivityAttemptOwner,
        fields: [String]
    ) -> String {
        ([event] + ownerFields(owner) + fields).joined(separator: " ")
    }

    private static func ownerFields(_ owner: ProductConnectivityAttemptOwner) -> [String] {
        [
            "transport=p2p",
            "attempt_ref=\(owner.attemptReference)",
            "owner=\(owner.product.rawValue)",
            "generation=\(owner.generation)",
            "role=\(owner.role.rawValue)",
            "localProfile=\(owner.localProfile.rawValue)",
            "offeredProfiles=\(owner.offeredProfiles.rawValue)",
            "requirePQC=\(owner.requirePQC ? 1 : 0)",
            "allowClassicFallback=\(owner.allowClassicFallback ? 1 : 0)"
        ]
    }
}
