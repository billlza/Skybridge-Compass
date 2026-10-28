import AppKit
import Combine
import SwiftUI
import XCTest
import SkyBridgeProtocolCore
@testable import SkyBridgeCore
@testable import SkyBridgeUI

@MainActor
final class AudioPlaybackWindowControllerTests: XCTestCase {
    func testClosingCurrentPromptRejectsWithoutApprovingAndNextPromptCanOpen() async throws {
        _ = NSApplication.shared
        let approvals = try AudioPlaybackApprovalService()
        let receiver = AudioPlaybackReceiverService(approvals: approvals, selectOutput: {
            XCTFail("Presenter must not select a real output")
            throw AudioPlaybackApprovalError.invalidRequest
        })
        let presenter = AudioPlaybackWindowController(activate: {})
        presenter.startPresentation(receiver: receiver)
        let first = try request()
        let task = Task { try await approvals.requestApproval(first, isCurrent: { true }) }
        try await wait { presenter.isWindowVisibleForTesting }
        XCTAssertEqual(presenter.displayedRequestForTesting, first)
        presenter.closeWindowForTesting()
        do { _ = try await task.value; XCTFail("Closing a prompt granted permission") }
        catch { XCTAssertEqual(error as? AudioPlaybackApprovalError, .rejected) }
        XCTAssertNil(approvals.pendingRequest)

        let second = try request()
        let next = Task { try await approvals.requestApproval(second, isCurrent: { true }) }
        try await wait { presenter.isWindowVisibleForTesting && presenter.displayedRequestForTesting == second }
        XCTAssertFalse(approvals.resolve(first, allowOnce: true))
        XCTAssertEqual(approvals.pendingRequest, second)
        await presenter.stop()
        do { _ = try await next.value; XCTFail("Shutdown granted permission") }
        catch { XCTAssertEqual(error as? AudioPlaybackApprovalError, .rejected) }
        XCTAssertFalse(presenter.isWindowVisibleForTesting)
    }

    func testApprovalUsesIndependentWindowAndPreservesDescriptorAfterDecision() async throws {
        _ = NSApplication.shared
        let approvals = try AudioPlaybackApprovalService()
        let receiver = AudioPlaybackReceiverService(approvals: approvals, selectOutput: {
            throw AudioPlaybackApprovalError.invalidRequest
        })
        let presenter = AudioPlaybackWindowController(activate: {})
        let host = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300),
                            styleMask: [.titled], backing: .buffered, defer: false)
        let sheet = NSWindow(contentRect: .init(x: 0, y: 0, width: 200, height: 150),
                             styleMask: [.titled], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false; sheet.isReleasedWhenClosed = false
        host.orderFront(nil); host.beginSheet(sheet, completionHandler: nil)
        defer { host.endSheet(sheet); sheet.close(); host.close() }
        presenter.startPresentation(receiver: receiver)
        let offer = try request()
        let task = Task { try await approvals.requestApproval(offer, isCurrent: { true }) }
        try await wait { presenter.isWindowVisibleForTesting }
        let window = try XCTUnwrap(NSApplication.shared.windows.first { $0.title == "SkyBridge · 音频接收" && $0.isVisible })
        XCTAssertNil(window.sheetParent)
        XCTAssertTrue(host.attachedSheet === sheet)
        if let path = ProcessInfo.processInfo.environment["SKYBRIDGE_AUDIO_UI_TEST_ARTIFACT"] {
            let hosting = try XCTUnwrap(window.contentViewController as? NSHostingController<AnyView>)
            let renderer = ImageRenderer(content: hosting.rootView.background(Color(nsColor: .windowBackgroundColor)))
            renderer.scale = 2
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        XCTAssertTrue(approvals.resolve(offer, allowOnce: true))
        let permission = try await task.value
        XCTAssertTrue(permission.isApproved)
        XCTAssertEqual(presenter.displayedRequestForTesting, offer)
        XCTAssertNil(approvals.pendingRequest)
        permission.revoke()
        await presenter.stop()
    }

    func testResolvedPromptQueuedForPresentationCannotResurrectWindow() async throws {
        _ = NSApplication.shared
        let approvals = try AudioPlaybackApprovalService()
        let receiver = AudioPlaybackReceiverService(approvals: approvals, selectOutput: {
            throw AudioPlaybackApprovalError.invalidRequest
        })
        let presenter = AudioPlaybackWindowController(activate: {})
        presenter.startPresentation(receiver: receiver)
        let immediate = approvals.$pendingRequest.sink { request in
            if let request { approvals.resolve(request, allowOnce: false) }
        }
        do { _ = try await approvals.requestApproval(request(), isCurrent: { true }); XCTFail("Rejected prompt accepted") }
        catch { XCTAssertEqual(error as? AudioPlaybackApprovalError, .rejected) }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(presenter.isWindowVisibleForTesting)
        XCTAssertNil(presenter.displayedRequestForTesting)
        immediate.cancel()
        await presenter.stop()
    }

    func testClosingOldWindowDuringNewPromptPublicationCannotRejectReplacement() async throws {
        _ = NSApplication.shared
        let approvals = try AudioPlaybackApprovalService()
        let receiver = AudioPlaybackReceiverService(approvals: approvals, selectOutput: {
            throw AudioPlaybackApprovalError.invalidRequest
        })
        let presenter = AudioPlaybackWindowController(activate: {})
        presenter.startPresentation(receiver: receiver)
        let first = try request()
        let firstTask = Task { try await approvals.requestApproval(first, isCurrent: { true }) }
        try await wait { presenter.isWindowVisibleForTesting }
        XCTAssertTrue(approvals.resolve(first, allowOnce: true))
        let permission = try await firstTask.value
        permission.revoke()

        let replacement = try request()
        let closeOld = approvals.$pendingRequest.sink { request in
            if request?.id == replacement.id { presenter.closeWindowForTesting() }
        }
        let next = Task { try await approvals.requestApproval(replacement, isCurrent: { true }) }
        try await wait { presenter.displayedRequestForTesting == replacement && presenter.isWindowVisibleForTesting }
        XCTAssertEqual(approvals.pendingRequest, replacement)
        XCTAssertTrue(approvals.resolve(replacement, allowOnce: false))
        do { _ = try await next.value; XCTFail("Replacement accepted") }
        catch { XCTAssertEqual(error as? AudioPlaybackApprovalError, .rejected) }
        closeOld.cancel()
        await presenter.stop()
    }

    private func wait(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw AudioPlaybackApprovalError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testOriginalFilePromptPreservesTheApprovedSourceAndPrivatePlaybackDisclosure() async throws {
        _ = NSApplication.shared
        let approvals = try AudioPlaybackApprovalService()
        let receiver = AudioPlaybackReceiverService(approvals: approvals, selectOutput: {
            throw AudioPlaybackApprovalError.invalidRequest
        })
        let presenter = AudioPlaybackWindowController(activate: {})
        presenter.startPresentation(receiver: receiver)
        let offer = try request(originalFile: true)
        let task = Task { try await approvals.requestApproval(offer, isCurrent: { true }) }
        try await wait { presenter.isWindowVisibleForTesting }
        XCTAssertEqual(presenter.displayedRequestForTesting?.source, offer.source)
        let window = try XCTUnwrap(NSApplication.shared.windows.first { $0.title == "SkyBridge · 音频接收" && $0.isVisible })
        if let path = ProcessInfo.processInfo.environment["SKYBRIDGE_AUDIO_FILE_UI_TEST_ARTIFACT"] {
            let hosting = try XCTUnwrap(window.contentViewController as? NSHostingController<AnyView>)
            let renderer = ImageRenderer(content: hosting.rootView.background(Color(nsColor: .windowBackgroundColor)))
            renderer.scale = 2
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        XCTAssertTrue(approvals.resolve(offer, allowOnce: true))
        let permission = try await task.value
        XCTAssertTrue(permission.approves(ownerID: offer.ownerID, streamID: offer.streamID,
            source: offer.source, outputEndpointUID: offer.outputEndpointUID))
        XCTAssertEqual(presenter.displayedRequestForTesting?.source, offer.source)
        permission.revoke()
        await presenter.stop()
    }

    func testBluetoothPromptPreservesCompatibleSourceAfterApproval() async throws {
        _ = NSApplication.shared
        let approvals = try AudioPlaybackApprovalService()
        let receiver = AudioPlaybackReceiverService(approvals: approvals, selectOutput: {
            throw AudioPlaybackApprovalError.invalidRequest
        })
        let presenter = AudioPlaybackWindowController(activate: {})
        presenter.startPresentation(receiver: receiver)
        let format = try AudioStreamingOpusFormat(channels: 2, bitrate: 192_000)
        let offer = try request(sourceBody: .opusOffer(source: .originalFile, format: format))
        let task = Task { try await approvals.requestApproval(offer, isCurrent: { true }) }
        try await wait { presenter.isWindowVisibleForTesting }
        XCTAssertEqual(presenter.displayedRequestForTesting?.source, .opus(source: .originalFile, format: format))
        let window = try XCTUnwrap(NSApplication.shared.windows.first { $0.title == "SkyBridge · 音频接收" && $0.isVisible })
        if let path = ProcessInfo.processInfo.environment["SKYBRIDGE_AUDIO_OPUS_UI_TEST_ARTIFACT"] {
            let hosting = try XCTUnwrap(window.contentViewController as? NSHostingController<AnyView>)
            let renderer = ImageRenderer(content: hosting.rootView.background(Color(nsColor: .windowBackgroundColor)))
            renderer.scale = 2
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        XCTAssertTrue(approvals.resolve(offer, allowOnce: true))
        let permission = try await task.value
        XCTAssertTrue(permission.approves(ownerID: offer.ownerID, streamID: offer.streamID,
            source: offer.source, outputEndpointUID: offer.outputEndpointUID))
        XCTAssertEqual(presenter.displayedRequestForTesting?.source, offer.source)
        XCTAssertNil(approvals.pendingRequest)
        permission.revoke()
        await presenter.stop()
    }

    private func request(originalFile: Bool = false, sourceBody: AudioStreamingMessage.Body? = nil) throws -> AudioPlaybackApprovalRequest {
        let account = try AudioAccountIdentity(authority: "https://audio.invalid", tenantID: "tenant", userID: "user")
        let local = try AudioProtocolIdentity(deviceID: "presenter-local-0001", algorithm: .ed25519, fingerprint: String(repeating: "a", count: 64))
        let peer = try AudioProtocolIdentity(deviceID: "presenter-peer-0002", algorithm: .ed25519, fingerprint: String(repeating: "b", count: 64))
        func row(_ identity: AudioProtocolIdentity, caller: Bool) -> AccountDeviceRecord {
            .init(deviceId: identity.deviceID, deviceName: nil, status: "active", protocolSigningAlgorithm: identity.algorithm.rawValue,
                  protocolPublicKeyFingerprint: identity.fingerprint, platformRawValue: nil, deviceModel: nil,
                  osVersion: nil, appVersion: nil, lanAddresses: [], publicAddress: nil, capabilities: [],
                  registeredAtEpochMilliseconds: nil, lastSeenAtEpochMilliseconds: nil,
                  presenceUpdatedAtEpochMilliseconds: nil, online: false, isCaller: caller)
        }
        let now: Int64 = 1_000_000, monotonic = ContinuousClock.now
        let evidence = try AudioAccountMembership.verifyFreshResponse(
            .init(generatedAtEpochMilliseconds: now, callerDeviceId: local.deviceID, truncated: false,
                  devices: [row(local, caller: true), row(peer, caller: false)], accountScope: account.serverScope),
            account: account, local: local, peer: peer, requestStartedMilliseconds: now, receivedMilliseconds: now,
            requestStartedMonotonic: monotonic, receivedMonotonic: monotonic)
        let source: AudioStreamingMessage.Body
        if let sourceBody { source = sourceBody }
        else if originalFile { source = .fileOffer(transferID: UUID(), length: 28_640_000, sha256: Data(repeating: 0x42, count: 32)) }
        else { source = .captureOffer(try .init(sampleRate: 48_000, channels: 2, encoding: .float32,
            declaredValidBits: 32, waveChannelMask: 3)) }
        return try .init(ownerID: UUID(), offer: .init(streamID: UUID(), body: source),
            membership: evidence, outputEndpointUID: "presenter-test-output")
    }
}
