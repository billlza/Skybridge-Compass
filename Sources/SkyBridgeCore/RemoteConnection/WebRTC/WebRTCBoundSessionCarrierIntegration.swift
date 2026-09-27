import Foundation
import SkyBridgeProtocolCore

/// Exact Apple transport incarnation authorized to carry one BoundSession
/// transition. The key-incarnation digest is internal routing state and is
/// never exposed as a secret, root, or application callback value.
struct WebRTCBoundSessionSecureOwnerIdentity: Equatable {
    let sessionID: String
    let sessionObjectIdentifier: ObjectIdentifier
    let controlTaskToken: UUID
    let keyIncarnationDigest: Data
}

/// Internal capability issued only from the manager's current secure transport
/// state. Future FFI glue may hold it, but application callers cannot construct
/// or use it across the SkyBridgeCore module boundary.
struct WebRTCBoundSessionOperationOwner {
    let identity: WebRTCBoundSessionSecureOwnerIdentity
    let session: WebRTCSession
    let keys: SessionKeys
}

/// A one-shot consume-only gate. Taking a delivery removes the registration
/// before invoking product code, so a duplicate cannot re-enter the same Rust
/// typestate transition. The consumer has no generic packet callback.
@MainActor
struct WebRTCBoundSessionConsumerGate {
    typealias Consumer =
        @MainActor (
            _ recordKind: BoundSessionWebRTCRecordKindV1,
            _ exactRecord: Data
        ) async throws -> Void

    private struct Registration {
        let ownerIdentity: WebRTCBoundSessionSecureOwnerIdentity
        let expectedRecordKind: BoundSessionWebRTCRecordKindV1
        let consumer: Consumer
    }

    private var registration: Registration?

    mutating func arm(
        ownerIdentity: WebRTCBoundSessionSecureOwnerIdentity,
        expectedRecordKind: BoundSessionWebRTCRecordKindV1,
        consumer: @escaping Consumer
    ) throws {
        if let registration,
            registration.ownerIdentity == ownerIdentity
        {
            throw WebRTCBoundSessionCarrierIntegrationError.consumerAlreadyArmed
        }
        registration = Registration(
            ownerIdentity: ownerIdentity,
            expectedRecordKind: expectedRecordKind,
            consumer: consumer
        )
    }

    mutating func takeConsumer(
        ownerIdentity: WebRTCBoundSessionSecureOwnerIdentity,
        recordKind: BoundSessionWebRTCRecordKindV1
    ) throws -> Consumer {
        guard let registration else {
            throw WebRTCBoundSessionCarrierIntegrationError.consumerNotArmed
        }
        guard registration.ownerIdentity == ownerIdentity else {
            throw WebRTCBoundSessionCarrierIntegrationError.ownerMismatch
        }
        guard registration.expectedRecordKind == recordKind else {
            throw WebRTCBoundSessionCarrierIntegrationError.unexpectedRecordKind(
                expected: registration.expectedRecordKind,
                actual: recordKind
            )
        }
        self.registration = nil
        return registration.consumer
    }

    mutating func invalidate() {
        registration = nil
    }
}

enum WebRTCBoundSessionCarrierIntegrationError: Error, Equatable, LocalizedError {
    case consumerAlreadyArmed
    case consumerNotArmed
    case ownerMismatch
    case unexpectedRecordKind(
        expected: BoundSessionWebRTCRecordKindV1,
        actual: BoundSessionWebRTCRecordKindV1
    )

    var errorDescription: String? {
        switch self {
        case .consumerAlreadyArmed:
            "BoundSession consume-only callback is already armed for this secure owner"
        case .consumerNotArmed:
            "BoundSession consume-only callback is not armed"
        case .ownerMismatch:
            "BoundSession secure transport owner mismatch"
        case .unexpectedRecordKind(let expected, let actual):
            "BoundSession consume-only typestate mismatch: expected \(expected.rawValue), got \(actual.rawValue)"
        }
    }
}
