import Foundation
import SkyBridgeProtocolCore
@testable import SkyBridgeCore
import XCTest

final class AudioPlaybackFailureDiagnosticTests: XCTestCase {
    func testDistinguishesLocalLeaseAndRegistryMembershipFailures() {
        XCTAssertEqual(SkyBridgeCore.AudioPlaybackFailureDiagnostic.label(for: AudioMembershipLeaseFailure.accountChanged), "lease.account_changed")
        XCTAssertEqual(SkyBridgeCore.AudioPlaybackFailureDiagnostic.label(for: AudioMembershipError.callerNotActive), "membership.caller_not_active")
        XCTAssertEqual(SkyBridgeCore.AudioPlaybackFailureDiagnostic.label(for: AudioMembershipError.peerNotActive), "membership.peer_not_active")
        XCTAssertEqual(SkyBridgeCore.AudioPlaybackFailureDiagnostic.label(for: AudioMembershipError.scopeMismatch), "membership.scope_mismatch")
        XCTAssertEqual(SkyBridgeCore.AudioPlaybackFailureDiagnostic.label(for: AudioAccountProviderError.contradicted), "provider.contradicted")
    }

    func testUnknownErrorDoesNotIncludeDomainCodeOrDescription() {
        let error = NSError(domain: "private-account-example", code: 403,
            userInfo: [NSLocalizedDescriptionKey: "Bearer example-secret; private server response"])
        let diagnostic = SkyBridgeCore.AudioPlaybackFailureDiagnostic.label(for: error)
        XCTAssertEqual(diagnostic, "type.NSError")
        XCTAssertFalse(diagnostic.contains("private"))
        XCTAssertFalse(diagnostic.contains("example-secret"))
        XCTAssertFalse(diagnostic.contains("403"))
    }

    func testNativeBluetoothErrorsRetainOnlyDomainCategoryAndNumericCode() {
        let cases = [("CBErrorDomain", 14, "bluetooth.cb.14"),
                     ("CBATTErrorDomain", 5, "bluetooth.att.5")]
        for (domain, code, expected) in cases {
            let error = NSError(domain: domain, code: code, userInfo: [
                NSLocalizedDescriptionKey: "private-device-name; Bearer example-secret",
                NSUnderlyingErrorKey: NSError(domain: "private-account", code: 403)
            ])
            XCTAssertEqual(SkyBridgeCore.AudioPlaybackFailureDiagnostic.label(for: error), expected)
        }
    }

    func testBluetoothDomainLookalikesRemainPrivate() {
        for domain in ["CBErrorDomain.private-account", "cbErrorDomain", "CBATTErrorDomain\nprivate"] {
            let error = NSError(domain: domain, code: 403,
                userInfo: [NSLocalizedDescriptionKey: "Bearer example-secret"])
            XCTAssertEqual(SkyBridgeCore.AudioPlaybackFailureDiagnostic.label(for: error), "type.NSError")
        }
    }

    #if os(macOS)
    func testOpusOutputFailuresRetainClosedCauses() {
        let cases: [(CoreAudioOpusOutputError, String)] = [
            (.invalidOwner, "invalid_owner"), (.wrongOwner, "wrong_owner"),
            (.invalidState, "invalid_state"), (.invalidFormat, "invalid_format"),
            (.invalidSourceCount, "invalid_source_count"), (.busy, "busy"),
            (.authorizationLost, "authorization_lost"), (.insufficientPrefill, "insufficient_prefill"),
            (.endpointChanged, "endpoint_changed"), (.engineStopped, "engine_stopped"),
            (.underrun, "underrun"), (.invalidCallback, "invalid_callback"),
            (.invalidTimeline, "invalid_timeline"), (.timedOut, "timed_out"),
            (.cleanupUnconfirmed, "cleanup_unconfirmed"), (.native(-12345), "native.-12345")
        ]
        for (error, expected) in cases {
            XCTAssertEqual(SkyBridgeCore.AudioPlaybackFailureDiagnostic.label(for: error), "opus_output." + expected)
        }
    }

    func testOutputIssuesUseClosedCategoriesWithoutNativePropertyDetails() {
        let cases: [(CoreAudioExactPcmError, AudioPlaybackOutputIssue)] = [
            (.invalidEndpoint, .endpointUnavailable), (.endpointUnavailable, .endpointUnavailable),
            (.unsupportedTopology, .unsupportedTopology), (.unsupportedLayout, .unsupportedLayout),
            (.formatMismatch, .formatMismatch), (.mixableVirtualFormat, .mixingRequired),
            (.gainOrMuteActive, .processingActive), (.deviceBusy, .deviceBusy),
            (.variableBufferSize, .variableBufferSize), (.malformedProperty(0xDEADBEEF), .propertyUnavailable),
            (.propertyFailure(0xDEADBEEF, -12345), .propertyUnavailable)
        ]
        for (error, expected) in cases {
            XCTAssertEqual(AudioPlaybackOutputIssue(error: error), expected)
        }
        XCTAssertEqual(AudioPlaybackOutputIssue(error: CoreAudioExactPcmError.propertyFailure(0xDEADBEEF, -12345))?.rawValue,
            "output.property_unavailable")
    }

    func testUnclassifiedFailureDoesNotInventOutputAdvice() {
        let privateError = NSError(domain: "private-account", code: 403,
            userInfo: [NSLocalizedDescriptionKey: "Bearer example-secret"])
        XCTAssertNil(AudioPlaybackOutputIssue(error: privateError))
        XCTAssertNil(AudioPlaybackOutputIssue(error: AudioMembershipLeaseFailure.accountChanged))
        XCTAssertNil(AudioPlaybackOutputIssue(error: CoreAudioExactPcmOutputError.authorizationLost))
    }
    #endif
}
