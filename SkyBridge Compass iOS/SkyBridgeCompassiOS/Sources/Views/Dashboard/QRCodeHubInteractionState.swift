import Foundation

@available(iOS 17.0, *)
struct QRCodeHubInteractionState: Equatable, Sendable {
    var isConnecting = false
    var isSubmittingCode = false
    var isSubmittingScannedConnectLink = false
    var sheetErrorMessage: String?

    mutating func startConnectionCodeSubmission() {
        sheetErrorMessage = nil
        isSubmittingCode = true
    }

    mutating func startScannedConnectLinkSubmission() {
        sheetErrorMessage = nil
        isSubmittingScannedConnectLink = true
    }

    mutating func startPairingConnection() {
        isConnecting = true
    }

    mutating func cancelPairingConnection() {
        isConnecting = false
    }

    mutating func resetForModeChange() {
        isConnecting = false
        isSubmittingCode = false
        isSubmittingScannedConnectLink = false
        sheetErrorMessage = nil
    }

    mutating func handleCrossNetworkState(_ state: CrossNetworkWebRTCManager.State) {
        switch state {
        case .failed(let message):
            let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty {
                sheetErrorMessage = normalized
            }
            isSubmittingCode = false
            isSubmittingScannedConnectLink = false
            isConnecting = false
        case .idle, .connecting, .connected:
            break
        }
    }

    mutating func handleReadiness(_ readiness: CrossNetworkWebRTCManager.Readiness) -> Bool {
        switch readiness {
        case .handshakeComplete:
            isSubmittingScannedConnectLink = false
            return true
        case .idle:
            isSubmittingCode = false
            isSubmittingScannedConnectLink = false
            return false
        case .transportReady:
            return false
        }
    }
}
