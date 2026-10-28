#if os(macOS)
import CSkyBridgeUSBHost
import IOKit
import XCTest
import SkyBridgeProtocolCore
@testable import SkyBridgeAppleTransport
@testable import SkyBridgeCore

@MainActor
final class AndroidUSBConnectionMessagesTests: XCTestCase {
    private func native(phase: SBUSBPhase, domain: SBUSBDomain, code: Int32) -> USBHostFailure {
        USBHostFailure(SBUSBResult(status: SB_USB_NATIVE_FAILURE, phase: phase, domain: domain,
            nativeCode: code, bytesTransferred: 0, byteCountKnown: false))
    }
    func testOnlyExactOpenExclusiveAccessGetsOccupancyExplanation() {
        let expected = AndroidUSBConnectionError.interfaceBusy.localizedDescription
        XCTAssertEqual(AndroidUSBConnectionCoordinator.describeFailure(
            native(phase: SB_USB_PHASE_OPEN, domain: SB_USB_DOMAIN_IORETURN, code: kIOReturnExclusiveAccess)), expected)
        for failure in [
            native(phase: SB_USB_PHASE_RELEASE, domain: SB_USB_DOMAIN_IORETURN, code: kIOReturnExclusiveAccess),
            native(phase: SB_USB_PHASE_OPEN, domain: SB_USB_DOMAIN_POSIX, code: kIOReturnExclusiveAccess),
            native(phase: SB_USB_PHASE_OPEN, domain: SB_USB_DOMAIN_IORETURN, code: kIOReturnNoDevice)
        ] {
            XCTAssertNotEqual(AndroidUSBConnectionCoordinator.describeFailure(failure), expected)
        }
    }
    func testRecoveryUsesExactNativeStatusDomainAndPhase() {
        let exclusive = native(phase: SB_USB_PHASE_OPEN, domain: SB_USB_DOMAIN_IORETURN, code: kIOReturnExclusiveAccess)
        XCTAssertEqual(AndroidUSBConnectionCoordinator.presentFailure(exclusive).recovery, .reviewDriverExtensions)
        XCTAssertEqual(AndroidUSBConnectionCoordinator.presentFailure(AndroidUSBConnectionError.interfaceBusy).recovery,
                       .reviewDriverExtensions)
        for failure in [
            native(phase: SB_USB_PHASE_RELEASE, domain: SB_USB_DOMAIN_IORETURN, code: kIOReturnExclusiveAccess),
            native(phase: SB_USB_PHASE_OPEN, domain: SB_USB_DOMAIN_POSIX, code: kIOReturnExclusiveAccess),
            native(phase: SB_USB_PHASE_OPEN, domain: SB_USB_DOMAIN_IORETURN, code: kIOReturnNoDevice),
            USBHostFailure(SBUSBResult(status: SB_USB_CANCELLED, phase: SB_USB_PHASE_OPEN,
                domain: SB_USB_DOMAIN_IORETURN, nativeCode: kIOReturnExclusiveAccess, bytesTransferred: 0, byteCountKnown: false))
        ] {
            XCTAssertNil(AndroidUSBConnectionCoordinator.presentFailure(failure).recovery)
        }
        XCTAssertNil(AndroidUSBConnectionCoordinator.presentFailure(USBHostByteError.timedOut).recovery)
        let matchingText = NSError(domain: "test", code: 1,
            userInfo: [NSLocalizedDescriptionKey: AndroidUSBConnectionError.interfaceBusy.localizedDescription])
        XCTAssertNil(AndroidUSBConnectionCoordinator.presentFailure(matchingText).recovery,
                     "Matching localized text cannot select driver recovery guidance")
    }

    func testWrappedCauseRetainsRecoveryAndCleanupFailure() {
        let primary = native(phase: SB_USB_PHASE_OPEN, domain: SB_USB_DOMAIN_IORETURN, code: kIOReturnExclusiveAccess)
        let wrapped = AndroidUSBPreparationCleanupFailure(primary: primary,
            cleanup: native(phase: SB_USB_PHASE_RELEASE, domain: SB_USB_DOMAIN_IORETURN, code: -1234))
        let presentation = AndroidUSBConnectionCoordinator.presentFailure(wrapped)
        XCTAssertEqual(presentation.recovery, .reviewDriverExtensions)
        XCTAssertTrue(presentation.message.contains("-1234"))
        XCTAssertTrue(presentation.message.contains(AndroidUSBConnectionError.interfaceBusy.localizedDescription))
        XCTAssertEqual(AndroidUSBConnectionCoordinator.presentFailure(
            AndroidUSBSessionCleanupFailure(failures: [wrapped])).recovery, .reviewDriverExtensions)
    }

    func testBoundedErrorTraversalCannotOfferRecoveryFromAnUninspectedCause() {
        var failure: any Error = AndroidUSBConnectionError.interfaceBusy
        for _ in 0..<8 { failure = AndroidUSBPreparationCleanupFailure(primary: failure, cleanup: AndroidUSBConnectionError.cleanupUnconfirmed) }
        let presentation = AndroidUSBConnectionCoordinator.presentFailure(failure)
        XCTAssertNil(presentation.recovery)
        XCTAssertFalse(presentation.message.isEmpty)
        let missing = AndroidUSBConnectionCoordinator.presentFailure(AndroidUSBSessionCleanupFailure(failures: []))
        XCTAssertNil(missing.recovery)
        XCTAssertFalse(missing.message.isEmpty)
    }

    func testCleanupContextDoesNotHidePrimaryOrNativeFailure() {
        let failure = AndroidUSBPreparationCleanupFailure(primary: AndroidUSBConnectionError.attachmentChanged,
            cleanup: native(phase: SB_USB_PHASE_RELEASE, domain: SB_USB_DOMAIN_IORETURN, code: -1234))
        let text = AndroidUSBConnectionCoordinator.describeFailure(failure)
        XCTAssertTrue(text.contains(AndroidUSBConnectionError.attachmentChanged.localizedDescription))
        XCTAssertTrue(text.contains("-1234"))
    }

    func testNativeTimeoutHasActionableMessageInsteadOfInternalEnumCode() {
        let text = AndroidUSBConnectionCoordinator.describeFailure(USBHostByteError.timedOut)
        XCTAssertTrue(text.contains("SkyBridge"))
        XCTAssertFalse(text.contains("connection.usb.retryTimeout"))
        XCTAssertFalse(text.contains("重新插拔"))
        XCTAssertFalse(text.contains("USBHostByteError"))
        let timeouts: [any Error] = [USBHostMultiplexError.timedOut, USBLinkEpochProtocol.Failure.timeout]
        for failure in timeouts {
            let presentation = AndroidUSBConnectionCoordinator.presentFailure(failure)
            XCTAssertEqual(presentation.message, text)
            XCTAssertNil(presentation.recovery)
        }
    }
    func testProfileMismatchAsksForCompatibleApplicationsWithoutDriverRecovery() {
        let presentation = AndroidUSBConnectionCoordinator.presentFailure(USBHostAccessoryError.profileMismatch)
        XCTAssertTrue(presentation.message.contains("更新"))
        XCTAssertFalse(presentation.message.contains("USBHostAccessoryError"))
        XCTAssertNil(presentation.recovery)
    }
}
#endif
