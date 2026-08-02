import Foundation

/// Decision used at the automatic inbound-file commit boundary.
///
/// `FileScanResult.isSafe` is a legacy presentation/serialization compatibility property that
/// treats warnings as acceptable. Automatic transfer admission is stricter: only a completed
/// `.safe` scan may move a staged file into the user's destination.
enum AutomaticTransferScanAdmission: Sendable, Equatable {
    case allow
    case block(AutomaticTransferScanBlockReason)
}

enum AutomaticTransferScanBlockReason: Sendable, Equatable {
    case unsafe(threatName: String?)
    case reviewRequired(warningCodes: [String])
    case incomplete(verdict: ScanVerdict, warningCodes: [String])

    var engineError: FileTransferEngineError {
        switch self {
        case .unsafe(let threatName):
            return .securityThreatDetected(threatName: threatName ?? "未知威胁")
        case .reviewRequired(let warningCodes):
            return .securityScanReviewRequired(warningCodes: warningCodes)
        case .incomplete(let verdict, let warningCodes):
            return .securityScanIncomplete(
                verdict: verdict,
                warningCodes: warningCodes
            )
        }
    }

    var managerError: FileTransferError {
        switch self {
        case .unsafe(let threatName):
            return .securityThreatDetected(threatName: threatName ?? "未知威胁")
        case .reviewRequired(let warningCodes):
            return .securityScanReviewRequired(warningCodes: warningCodes)
        case .incomplete(let verdict, let warningCodes):
            return .securityScanIncomplete(
                verdict: verdict,
                warningCodes: warningCodes
            )
        }
    }

    var notificationReason: String {
        switch self {
        case .unsafe:
            return "unsafe"
        case .reviewRequired:
            return "review_required"
        case .incomplete:
            return "incomplete"
        }
    }

    var warningCodes: [String] {
        switch self {
        case .unsafe:
            return []
        case .reviewRequired(let warningCodes), .incomplete(_, let warningCodes):
            return warningCodes
        }
    }
}

extension FileScanResult {
    var automaticTransferAdmission: AutomaticTransferScanAdmission {
        let warningCodes = Array(Set(warnings.map(\.code))).sorted()
        switch verdict {
        case .safe:
            return .allow
        case .unsafe:
            return .block(.unsafe(threatName: threatName))
        case .warning:
            return .block(.reviewRequired(warningCodes: warningCodes))
        case .unknown:
            return .block(.incomplete(verdict: verdict, warningCodes: warningCodes))
        }
    }
}

func postAutomaticTransferScanRejection(
    result: FileScanResult,
    fileURL: URL,
    notificationCenter: NotificationCenter = .default
) {
    guard case .block(let reason) = result.automaticTransferAdmission else { return }

    switch reason {
    case .unsafe(let threatName):
        notificationCenter.post(
            name: .fileThreatDetected,
            object: nil,
            userInfo: [
                "fileURL": fileURL,
                "threatName": threatName ?? "Unknown",
                "scanMethod": result.scanMethod.rawValue
            ]
        )
    case .reviewRequired, .incomplete:
        notificationCenter.post(
            name: .fileScanAdmissionRejected,
            object: nil,
            userInfo: [
                "fileURL": fileURL,
                "verdict": result.verdict.rawValue,
                "reason": reason.notificationReason,
                "warningCodes": reason.warningCodes,
                "scanMethod": result.scanMethod.rawValue
            ]
        )
    }
}
