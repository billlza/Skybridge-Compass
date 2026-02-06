import Foundation
import SwiftUI

public struct LogEntry: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let timestamp: Date
    public let level: LogLevel
    public let category: String
    public let message: String

    public init(id: String = UUID().uuidString, timestamp: Date = Date(), level: LogLevel, category: String, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
    }
}

/// In-app log buffer so Settings -> Logs can show something without depending on OSLogStore APIs.
///
/// Important: Logging may happen at very high frequency (especially Network.framework / discovery).
/// To avoid main-thread Task backlog and memory spikes, we keep a lock-backed buffer and throttle UI flushes.
public final class LogStore: ObservableObject, @unchecked Sendable {
    public static let shared = LogStore()

    @Published public private(set) var entries: [LogEntry] = []

    /// Keep logs bounded to avoid unbounded memory growth.
    public var capacity: Int = 1500

    private let lock = NSLock()
    private var buffer: [LogEntry] = []
    private var dirty = false
    private var flushTimer: DispatchSourceTimer?

    private init() {
        // Throttle UI updates to avoid List diff/render storms
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.2, repeating: 0.2)
        timer.setEventHandler { [weak self] in
            self?.flushIfNeeded()
        }
        timer.resume()
        self.flushTimer = timer
    }

    /// Thread-safe append; does not touch `@Published` directly (flushed periodically on main).
    public func append(level: LogLevel, category: String, message: String) {
        lock.lock()
        buffer.append(LogEntry(level: level, category: category, message: message))
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
        }
        dirty = true
        lock.unlock()
    }

    public func clear() {
        lock.lock()
        buffer.removeAll()
        dirty = true
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.entries.removeAll()
        }
    }

    public func exportText(
        minLevel: LogLevel? = nil,
        search: String? = nil
    ) -> String {
        let query = (search ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let q = query.isEmpty ? nil : query.lowercased()

        let snapshot: [LogEntry] = {
            lock.lock()
            defer { lock.unlock() }
            return buffer
        }()

        let filtered = snapshot.filter { e in
            if let minLevel, e.level.rank < minLevel.rank { return false }
            if let q {
                let hay = "\(e.category) \(e.message)".lowercased()
                if !hay.contains(q) { return false }
            }
            return true
        }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return filtered
            .map { "[\(df.string(from: $0.timestamp))] [\($0.level.rawValue.uppercased())] [\($0.category)] \($0.message)" }
            .joined(separator: "\n")
    }

    private func flushIfNeeded() {
        let snapshot: [LogEntry]?
        lock.lock()
        if dirty {
            dirty = false
            snapshot = buffer
        } else {
            snapshot = nil
        }
        lock.unlock()

        if let snapshot {
            self.entries = snapshot
        }
    }
}

extension LogLevel {
    public var rank: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        }
    }
}

