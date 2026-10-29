import SwiftUI
import os

/// Presentation rate of this dashboard's native weather surface, not the display refresh rate
/// or the rate of unrelated SwiftUI/remote-desktop rendering.
public enum WeatherFrameRateReading: Equatable, Sendable {
    case unavailable
    case measuring
    case paused
    case framesPerSecond(Int)
}

@MainActor
public final class WeatherFrameRateMonitor: ObservableObject {
    @Published public private(set) var reading: WeatherFrameRateReading = .unavailable
    private var source: UUID?
    private var pendingReading: WeatherFrameRateReading = .unavailable
    private var publicationPending = false

    public init() {}

    func beginSource(isAnimating: Bool) -> UUID {
        let source = UUID()
        self.source = source
        enqueue(isAnimating ? .measuring : .paused)
        return source
    }

    func update(_ reading: WeatherFrameRateReading, source: UUID) {
        guard self.source == source else { return }
        enqueue(reading)
    }

    func endSource(_ source: UUID) {
        guard self.source == source else { return }
        self.source = nil
        enqueue(.unavailable)
    }

    private func enqueue(_ reading: WeatherFrameRateReading) {
        pendingReading = reading
        guard !publicationPending, self.reading != reading else { return }
        publicationPending = true
        // Lifecycle changes can originate in updateNSView/updateUIView. Publish after that
        // update, coalescing transitions and never publishing SwiftUI state once per frame.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.publicationPending = false
            if self.reading != self.pendingReading { self.reading = self.pendingReading }
        }
    }
}

private struct WeatherFrameRateMonitorKey: EnvironmentKey {
    static let defaultValue: WeatherFrameRateMonitor? = nil
}

public extension EnvironmentValues {
    /// Opt in only while the FPS indicator is enabled. No monitor means no presentation callbacks.
    var weatherFrameRateMonitor: WeatherFrameRateMonitor? {
        get { self[WeatherFrameRateMonitorKey.self] }
        set { self[WeatherFrameRateMonitorKey.self] = newValue }
    }
}

/// A bounded counter shared with Metal's presentation callback. The renderer samples it
/// from its existing draw loop at most once per second; it owns no timer or display link.
final class PresentedFrameRateCounter: Sendable {
    private struct State: Sendable {
        var frames = 0
        var windowStart: TimeInterval
    }

    private let state: OSAllocatedUnfairLock<State>

    init(startingAt timestamp: TimeInterval) {
        precondition(timestamp.isFinite)
        state = OSAllocatedUnfairLock(initialState: State(windowStart: timestamp))
    }

    func recordPresentation(at timestamp: TimeInterval) {
        // Metal returns zero for frames that weren't presented, including dropped frames.
        guard timestamp.isFinite, timestamp > 0 else { return }
        state.withLock { $0.frames += 1 }
    }

    func sample(at timestamp: TimeInterval) -> Int? {
        guard timestamp.isFinite else { return nil }
        return state.withLock { state in
            let elapsed = timestamp - state.windowStart
            guard elapsed >= 1 else { return nil }
            let fps = Int((Double(state.frames) / elapsed).rounded())
            state.frames = 0
            state.windowStart = timestamp
            return fps
        }
    }
}
