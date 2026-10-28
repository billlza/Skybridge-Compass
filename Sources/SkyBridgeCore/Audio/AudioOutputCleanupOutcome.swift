import Foundation

/// Resource ownership is independent of a stream's success and of historical diagnostics.
/// Released may preserve an external owner's changed settings; it does not claim those settings
/// were restored. Pending retains the exact native owner for another bounded close.
public struct AudioOutputCleanupOutcome: Sendable, Equatable {
    public enum State: Sendable, Equatable { case pending, released }
    public let state: State
    public let diagnostics: [String]
    public let preservedExternalChanges: [String]
    static let noOutput = AudioOutputCleanupOutcome(state: .released, diagnostics: [], preservedExternalChanges: [])
}
