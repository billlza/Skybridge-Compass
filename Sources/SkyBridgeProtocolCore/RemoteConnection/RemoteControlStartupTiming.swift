import Foundation

/// Shared human-approval budget. Each transport retains its existing bounded
/// configuration budget after the first authenticated acknowledgement.
public enum RemoteControlStartupTiming {
    public static let hostApprovalTimeoutSeconds: TimeInterval = 45
    public static let noticeIdentityTimeout: Duration = .seconds(2)

    public static func acknowledgementTimeout(
        hasApprovedSession: Bool,
        configurationTimeout: Duration
    ) -> Duration {
        precondition(configurationTimeout > .zero)
        if hasApprovedSession { return configurationTimeout }
        return noticeIdentityTimeout + .seconds(hostApprovalTimeoutSeconds) + configurationTimeout
    }
}
