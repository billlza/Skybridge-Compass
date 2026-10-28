import Foundation
import SkyBridgeCore
import SkyBridgeProtocolCore

@MainActor
enum OperatorFileApprovalRuntime {
    static let methods = ["status", "authorize", "decide", "revoke"].map { "crossnet.file.approval." + $0 }
    private struct Cached {
        let deviceRef: String
        let responder: HandshakeManagementIdentity
        let prompt: RemoteFileApprovalPrompt
    }
    private static var pending: [UUID: Cached] = [:]

    static func execute(_ request: OperatorFileApprovalRequest) async throws -> OperatorFileApprovalResult {
        var result = OperatorFileApprovalResult(request: request)
        let service = P2PDiscoveryService.shared
        guard let target = (service.connectedUSBControlDevices + service.discoveredDevices).first(where: {
            $0.id.uuidString.lowercased() == request.deviceRef.lowercased()
        }) else { result.error_code = "file_approval_target_not_found"; return result }
        pending = pending.filter { $0.value.prompt.expiresAtMilliseconds > Int64(Date().timeIntervalSince1970 * 1000) }
        do {
            if let connection = service.authenticatedConnection(to: target) {
                try await connection.waitForCurrentPeerIdentityExchange()
            }
            let response: HandshakeConfigurationResponse
            if request.action == .decide {
                guard let id = request.approvalID, let allow = request.allow,
                      let cached = pending.removeValue(forKey: id), cached.deviceRef == request.deviceRef,
                      let connection = service.authenticatedConnection(to: target),
                      connection.authenticatedProtocolFingerprint == cached.responder.fingerprint else {
                    throw RemoteFileApprovalError.stale
                }
                let exchange = try await service.exchangeHandshakeConfiguration(for: target, action: .fileDecide,
                    fileDecision: .init(prompt: cached.prompt, allow: allow))
                guard exchange.response.responder == cached.responder else { throw RemoteFileApprovalError.bindingChanged }
                response = exchange.response; result.transport = exchange.transport
                if response.error == nil && response.fileApprovalError == nil {
                    result.decided_id = id.uuidString; result.allowed = allow
                }
            } else {
                let status = try await service.exchangeHandshakeConfiguration(for: target, action: .fileStatus)
                if request.action == .status || status.response.error != nil || status.response.fileApprovalError != nil {
                    response = status.response; result.transport = status.transport
                } else {
                    let exchange = try await service.exchangeHandshakeConfiguration(for: target,
                        action: request.action == .authorize ? .fileAuthorize : .fileRevoke, previous: status.response)
                    response = exchange.response; result.transport = exchange.transport
                }
            }
            result.error_code = response.fileApprovalError?.rawValue ?? response.error?.rawValue
            if let state = response.fileApproval {
                result.authorized = state.authorized; result.pending = state.pending
                for prompt in state.pending {
                    guard pending.count < 64 || pending[prompt.id] != nil else { throw RemoteFileApprovalError.busy }
                    pending[prompt.id] = Cached(deviceRef: request.deviceRef, responder: response.responder, prompt: prompt)
                }
            }
            result.success = result.error_code == nil && response.fileApproval != nil
        } catch let error as RemoteFileApprovalError { result.error_code = error.rawValue }
        catch let error as HandshakeConfigurationError { result.error_code = error.rawValue }
        catch is CancellationError { result.error_code = "file_approval_cancelled_outcome_unknown" }
        catch { result.error_code = "file_approval_transport_failed" }
        return result
    }
}
