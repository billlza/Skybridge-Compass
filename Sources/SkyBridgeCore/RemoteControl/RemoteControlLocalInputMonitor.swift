#if os(macOS)
import AppKit
import CoreGraphics
import Foundation

/// Observes activity only while this Mac hosts an approved viewer. It never
/// captures key values or suppresses local input. Both monitors are necessary:
/// AppKit's global monitor excludes events delivered to our own windows.
@MainActor
final class RemoteControlLocalInputMonitor {
    enum Failure: Error, LocalizedError {
        case unavailable
        var errorDescription: String? { "无法监测本机输入，远程输入控制未获授权" }
    }

    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var armedAt: TimeInterval = 0
    private var onActivity: (() -> Void)?

    func arm(onActivity: @escaping () -> Void) throws {
        armedAt = ProcessInfo.processInfo.systemUptime
        self.onActivity = onActivity
        guard localMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged,
            .otherMouseDragged, .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .scrollWheel, .keyDown, .flagsChanged]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.observe(event)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.observe(event)
        }
        guard localMonitor != nil, globalMonitor != nil else {
            stop()
            throw Failure.unavailable
        }
    }

    private func observe(_ event: NSEvent) {
        guard event.timestamp > armedAt,
              let cgEvent = event.cgEvent,
              !RemoteControlInputEventInjector.isOwnInjectedEvent(cgEvent) else { return }
        onActivity?()
    }

    func stop() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        onActivity = nil
    }
}
#endif
