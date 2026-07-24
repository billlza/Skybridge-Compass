import AppKit
import Combine
import SkyBridgeCore
import SwiftUI

/// AppKit presenter for the same explicit pairing approval surface used by the
/// shipping SwiftUI application.
///
/// There is intentionally no automatic decision path. Closing the window without
/// a decision rejects the request through `PairingTrustApprovalService`; service
/// cancellation and timeout remain fail closed as well.
@available(macOS 14.0, *)
@MainActor
public final class PairingTrustApprovalWindowController: NSObject, NSWindowDelegate {
    private let approvalService: PairingTrustApprovalService
    private let applicationActivator: @MainActor () -> Void
    private var pendingRequestSubscription: AnyCancellable?
    private var approvalWindow: NSWindow?
    private var presentedRequestID: UUID?
    private var isClosingResolvedWindow = false

    public override convenience init() {
        self.init(
            approvalService: .shared,
            applicationActivator: {
                NSRunningApplication.current.activate(options: [.activateAllWindows])
            }
        )
    }

    init(
        approvalService: PairingTrustApprovalService,
        applicationActivator: @escaping @MainActor () -> Void
    ) {
        self.approvalService = approvalService
        self.applicationActivator = applicationActivator
        super.init()
    }

    public func start() {
        guard pendingRequestSubscription == nil else { return }
        pendingRequestSubscription = approvalService.$pendingRequest
            .sink { [weak self] request in
                Task { @MainActor [weak self] in
                    self?.synchronizeWindow(with: request)
                }
            }
        synchronizeWindow(with: approvalService.pendingRequest)
    }

    /// Stops presentation and explicitly rejects any request owned by this window.
    /// This is mainly useful for an orderly host shutdown; abrupt process exit still
    /// tears down the connection and cannot produce an approval.
    public func stop() {
        pendingRequestSubscription?.cancel()
        pendingRequestSubscription = nil
        if approvalService.pendingRequest?.id == presentedRequestID {
            approvalService.userDismissedCurrentPrompt()
        }
        closeResolvedWindow()
    }

    private func synchronizeWindow(with publishedRequest: PairingTrustApprovalService.Request?) {
        // A queued publisher delivery must never resurrect a request that has already
        // been resolved or replaced on the main actor.
        let currentRequest = approvalService.pendingRequest
        guard currentRequest?.id == publishedRequest?.id else { return }

        guard let request = currentRequest else {
            closeResolvedWindow()
            return
        }
        if presentedRequestID == request.id, approvalWindow?.isVisible == true {
            bringApprovalWindowForward()
            return
        }

        closeResolvedWindow()
        presentApprovalWindow(for: request)
    }

    private func presentApprovalWindow(for request: PairingTrustApprovalService.Request) {
        let content = PairingTrustApprovalSheet(
            request: request,
            onDecision: { [weak self] decision in
                guard let self,
                      self.approvalService.pendingRequest?.id == request.id,
                      self.approvalService.pendingDecision == nil,
                      !self.approvalService.isPendingResolutionInFlight else {
                    return
                }
                self.approvalService.resolve(request, decision: decision)
            }
        )
        let hostingController = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "SkyBridge P2P Identity Approval"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace]
        window.delegate = self
        window.center()

        approvalWindow = window
        presentedRequestID = request.id
        bringApprovalWindowForward()
    }

    private func bringApprovalWindowForward() {
        guard let approvalWindow else { return }
        approvalWindow.makeKeyAndOrderFront(nil)
        approvalWindow.orderFrontRegardless()
        applicationActivator()
    }

    private func closeResolvedWindow() {
        guard let approvalWindow else {
            presentedRequestID = nil
            return
        }
        isClosingResolvedWindow = true
        approvalWindow.close()
        self.approvalWindow = nil
        presentedRequestID = nil
        isClosingResolvedWindow = false
    }

    public func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === approvalWindow else {
            return
        }
        let requestID = presentedRequestID
        approvalWindow = nil
        presentedRequestID = nil

        guard !isClosingResolvedWindow,
              approvalService.pendingRequest?.id == requestID else {
            return
        }
        approvalService.userDismissedCurrentPrompt()
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === approvalWindow else { return true }
        return !approvalService.isPendingResolutionInFlight
    }

#if DEBUG || SKYBRIDGE_TESTING
    var presentedRequestIDForTesting: UUID? {
        presentedRequestID
    }

    func closePresentedWindowForTesting() {
        approvalWindow?.performClose(nil)
    }
#endif
}
