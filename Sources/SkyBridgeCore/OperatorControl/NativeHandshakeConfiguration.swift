import Foundation
import AppKit
import SkyBridgeProtocolCore

/// Native configuration is independent of XCTest and of the selected KEM.
@MainActor
public enum NativeHandshakeConfiguration {
    public static let usbDiscoveryResponder = USBPeerDiscoveryResponder()
    public static var isBusy: Bool {
        FileTransferManager.shared.hasActiveTransferWork
            || InboundFileTransferApprovalService.shared.pendingRequest != nil
            || ControlledHostWorkspace.shared.sessions.contains { $0.state == .connecting || $0.state == .connected || $0.state == .disconnecting }
    }
    public static func snapshot() throws -> HandshakeConfigurationSnapshot {
        try SettingsManager.shared.handshakeConfigurationSnapshot(busy: isBusy)
    }
    public static func apply(_ profile: HandshakeProfile, revision: String,
                             revalidate: HandshakeConfigurationService.Revalidate = {}) async throws -> HandshakeConfigurationSnapshot {
        try await SettingsManager.shared.applyHandshakeProfile(profile, expectedRevision: revision, isBusy: { isBusy }, revalidate: revalidate)
    }
    public static func identity() async throws -> HandshakeManagementIdentity {
        let proof = try await CommittedLocalProtocolIdentitySnapshot.loadActive()
        let id = try await SelfIdentityProvider.shared.existingProtocolIdentityDeviceIdReadOnly()
        let value = HandshakeManagementIdentity(deviceID: id, algorithm: proof.algorithm.rawValue,
            publicKey: proof.publicKey, fingerprint: proof.authoritativeFingerprint)
        try value.validate()
        return value
    }
    public static func trusted(_ identity: HandshakeManagementIdentity) async throws -> Bool {
        try identity.validate()
        return await DefaultHandshakeTrustProvider().currentPathTrustedFingerprints(for: identity.deviceID).contains(identity.fingerprint)
    }
    public static func sign(_ data: Data) async throws -> Data {
        let proof = try await CommittedLocalProtocolIdentitySnapshot.loadActive()
        return try await ProtocolSignatureProviderSelector.select(for: proof.algorithm).sign(data, key: proof.keyHandle)
    }
    nonisolated public static func verify(_ data: Data, signature: Data, identity: HandshakeManagementIdentity) async throws -> Bool {
        try identity.validate()
        guard let algorithm = ProtocolSigningAlgorithm(rawValue: identity.algorithm) else { throw HandshakeConfigurationError.identityMismatch }
        return try await ProtocolSignatureProviderSelector.select(for: algorithm).verify(data, signature: signature, publicKey: identity.publicKey)
    }
    private static func readGrant(_ key: String) throws -> Bool {
        do {
            return try HandshakeManagementGrant.decode(KeychainManager.shared.exportKeyStrict(
                service: HandshakeManagementGrant.service, account: HandshakeManagementGrant.account(key)), key: key)
        } catch { throw HandshakeConfigurationError.storageUnavailable }
    }
    private static func writeGrant(_ key: String, allowed: Bool) throws {
        let data = try JSONEncoder().encode(HandshakeManagementGrant(identityKey: key, allowed: allowed))
        guard KeychainManager.shared.importKey(data: data, service: HandshakeManagementGrant.service,
            account: HandshakeManagementGrant.account(key)) else { throw HandshakeConfigurationError.storageUnavailable }
    }
    public static let service = HandshakeConfigurationService(
        identity: { try await identity() }, trusted: { try await trusted($0) },
        verify: { try await verify($0, signature: $1, identity: $2) }, sign: { try await sign($0) },
        snapshot: { try snapshot() }, apply: { try await apply($0, revision: $1, revalidate: $2) },
        readGrant: { try readGrant($0) }, writeGrant: { try writeGrant($0, allowed: $1) },
        approve: { await approve($0, profile: $1) },
        approveFiles: { await approve($0, profile: nil) })

    private static func approve(_ identity: HandshakeManagementIdentity, profile: HandshakeProfile?) async -> HandshakeConfigurationService.Decision {
            let request = HandshakeConfigurationApproval.shared
            let approvalID = UUID()
            let decision = Task { @MainActor in await request.decide(identity, profile: profile, requestID: approvalID) }
            // The native request also has a terminal surface. A closed main
            // window must not prevent the local owner from deciding it there.
            guard let window = NSApp.mainWindow else {
                return await withTaskCancellationHandler { await decision.value } onCancel: { decision.cancel() }
            }
            let alert = NSAlert()
            alert.messageText = profile == nil ? "允许已配对设备在 CLI 审批文件？" : "允许已配对设备管理握手配置？"
            alert.informativeText = "设备：\(identity.deviceID)\n身份：\(identity.fingerprint)\n请求：\(profile?.title ?? "逐文件允许或拒绝此身份发送的文件")\n\(profile == nil ? "不会自动接收文件，也不能审批其他身份的文件。" : "仅管理 Q-Periapt、X-Wing 和 ML-KEM；不会更换配对身份或启用 Classic。")"
            alert.addButton(withTitle: profile == nil ? "允许 10 分钟" : "仅本次")
            alert.addButton(withTitle: "始终允许此身份")
            alert.addButton(withTitle: "拒绝")
            // The sheet remains non-modal to the service executor and has the
            // same bounded cancellation/timeout semantics as the iOS UI.
            let sheet = Task { @MainActor in
                // Task creation order does not guarantee that decide() has
                // published its request before this presenter is scheduled.
                while request.pending == nil && !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(10)) }
                    catch is CancellationError { return }
                    catch {
                        SkyBridgeLogger.p2p.error("Approval presentation wait failed")
                        decision.cancel()
                        return
                    }
                }
                guard !Task.isCancelled, request.pending?.id == approvalID else { return }
                let result = await alert.beginSheetModal(for: window)
                request.resolve(approvalID, decision: result == .alertFirstButtonReturn ? .allowOnce : (result == .alertSecondButtonReturn ? .alwaysAllow : .reject))
            }
            let result = await withTaskCancellationHandler { await decision.value } onCancel: { decision.cancel() }
            if alert.window.sheetParent === window { window.endSheet(alert.window) }
            sheet.cancel()
            return result
        }
}
