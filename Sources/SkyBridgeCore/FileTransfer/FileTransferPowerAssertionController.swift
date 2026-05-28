import Foundation
import OSLog

#if os(macOS)
import IOKit.pwr_mgt
#endif

protocol FileTransferPowerAssertionControlling: AnyObject {
    var isHoldingAssertion: Bool { get }

    func update(shouldKeepAwake: Bool, hasActiveTransfers: Bool)
    func release()
}

final class FileTransferPowerAssertionController: FileTransferPowerAssertionControlling {
    private let reason: String
    private let logger = Logger(subsystem: "com.skybridge.filetransfer", category: "PowerAssertion")

    #if os(macOS)
    private var assertionId = IOPMAssertionID(kIOPMNullAssertionID)
    #endif

    init(reason: String = "SkyBridge file transfer") {
        self.reason = reason
    }

    var isHoldingAssertion: Bool {
        #if os(macOS)
        return assertionId != IOPMAssertionID(kIOPMNullAssertionID)
        #else
        return false
        #endif
    }

    func update(shouldKeepAwake: Bool, hasActiveTransfers: Bool) {
        if shouldKeepAwake && hasActiveTransfers {
            acquireIfNeeded()
        } else {
            release()
        }
    }

    func release() {
        #if os(macOS)
        guard assertionId != IOPMAssertionID(kIOPMNullAssertionID) else { return }
        let id = assertionId
        assertionId = IOPMAssertionID(kIOPMNullAssertionID)
        let result = IOPMAssertionRelease(id)
        if result != kIOReturnSuccess {
            logger.error("Failed to release file-transfer power assertion: \(result, privacy: .public)")
        }
        #endif
    }

    deinit {
        release()
    }

    private func acquireIfNeeded() {
        #if os(macOS)
        guard assertionId == IOPMAssertionID(kIOPMNullAssertionID) else { return }

        var newAssertionId = IOPMAssertionID(kIOPMNullAssertionID)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoIdleSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &newAssertionId
        )

        if result == kIOReturnSuccess {
            assertionId = newAssertionId
        } else {
            logger.error("Failed to create file-transfer power assertion: \(result, privacy: .public)")
        }
        #endif
    }
}
