import CloudKit
import Foundation
import OSLog

/// Result a remote-notification handler must report back to the system.
///
/// Reporting this accurately is not cosmetic: the system uses it to decide how much future
/// background time to grant. Always claiming `newData` gets the app throttled, and always
/// claiming `noData` makes the wake channel useless.
public enum RemoteNotificationOutcome: String, Sendable, Equatable {
    case newData
    case noData
    case failed
}

/// Sendable summary of a received payload.
///
/// The raw `[AnyHashable: Any]` from the platform delegate is not `Sendable`, so it is reduced to
/// this value on the delegate's own thread and only the summary crosses into the router actor.
public enum RemoteNotificationPayloadDescriptor: Sendable, Equatable {
    case notCloudKit
    case cloudKit(subscriptionID: String?)

    /// Reduces a platform payload. Must be called on the thread that received it.
    public init(remoteNotificationUserInfo userInfo: [AnyHashable: Any]) {
        guard let notification = CKNotification(
            fromRemoteNotificationDictionary: userInfo
        ) else {
            self = .notCloudKit
            return
        }
        let subscriptionID = notification.subscriptionID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self = .cloudKit(
            subscriptionID: (subscriptionID?.isEmpty ?? true) ? nil : subscriptionID
        )
    }
}

/// What a received payload was recognized as.
public enum RemoteNotificationRecognition: Sendable, Equatable {
    /// A CloudKit notification whose subscription id we own.
    case cloudKitSubscription(subscriptionID: String)
    /// A CloudKit notification for a subscription we do not own.
    case foreignCloudKitSubscription(subscriptionID: String?)
    /// Not a CloudKit notification at all.
    case notCloudKit
}

/// Routes silent remote notifications to the subsystem that owns the corresponding subscription.
///
/// Exists so the wake path is a single, testable component rather than logic buried in two
/// platform app delegates. Handlers are registered by their owning subsystem, which keeps
/// SkyBridgeCore free of any dependency on the iOS or macOS app layer.
///
/// Fail-closed: an unrecognized payload is never treated as a reason to run work. Silent pushes
/// are attacker-influenceable in the sense that any sender who obtains the device token can post
/// arbitrary payloads, so recognition is by owned subscription id only.
@available(macOS 14.0, iOS 17.0, *)
public actor RemoteNotificationRouter {
    public static let shared = RemoteNotificationRouter()

    /// Work performed when a subscription we own reports a change.
    /// Returns whether the refresh actually produced new data and throws when the refresh failed.
    public typealias SubscriptionHandler = @Sendable () async throws -> Bool

    private var handlersBySubscriptionID: [String: SubscriptionHandler] = [:]
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "RemoteNotification")

    init() {}

    /// Registers the owner of a CloudKit subscription id. Re-registration replaces the handler so
    /// a subsystem restart cannot leave a stale closure behind.
    public func registerHandler(
        forSubscriptionID subscriptionID: String,
        handler: @escaping SubscriptionHandler
    ) {
        let key = subscriptionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            logger.error("❌ 拒绝注册空 subscriptionID 的远程通知处理器")
            return
        }
        handlersBySubscriptionID[key] = handler
        logger.info("📝 已注册远程通知处理器: subscription=\(key, privacy: .public)")
    }

    public func unregisterHandler(forSubscriptionID subscriptionID: String) {
        handlersBySubscriptionID.removeValue(
            forKey: subscriptionID.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    public func registeredSubscriptionIDs() -> Set<String> {
        Set(handlersBySubscriptionID.keys)
    }

    /// Handles a payload and reports the outcome the platform delegate must forward to the system.
    public func handle(
        descriptor: RemoteNotificationPayloadDescriptor
    ) async -> RemoteNotificationOutcome {
        switch Self.recognize(
            descriptor: descriptor,
            ownedSubscriptionIDs: handlersBySubscriptionID.keys.reduce(into: Set<String>()) {
                $0.insert($1)
            }
        ) {
        case .notCloudKit:
            logger.error("⛔️ 收到非 CloudKit 远程通知负载，已拒绝处理")
            return .noData

        case .foreignCloudKitSubscription(let subscriptionID):
            // Not an error condition on its own, but it must never trigger work: an unowned
            // subscription id is either a stale subscription or a forged payload.
            logger.warning(
                """
                ⚠️ 收到未持有的 CloudKit 订阅通知，已忽略: \
                subscription=\(subscriptionID ?? "-", privacy: .public)
                """
            )
            return .noData

        case .cloudKitSubscription(let subscriptionID):
            guard let handler = handlersBySubscriptionID[subscriptionID] else {
                // recognize() only returns this case for owned ids, so a missing handler means the
                // owner was unregistered concurrently.
                logger.warning(
                    "⚠️ 订阅处理器在处理期间被注销: subscription=\(subscriptionID, privacy: .public)"
                )
                return .noData
            }

            do {
                let producedNewData = try await handler()
                logger.info(
                    """
                    ✅ 远程通知已处理: subscription=\(subscriptionID, privacy: .public) \
                    newData=\(producedNewData ? 1 : 0, privacy: .public)
                    """
                )
                return producedNewData ? .newData : .noData
            } catch {
                logger.error(
                    """
                    ❌ 远程通知刷新失败: subscription=\(subscriptionID, privacy: .public) \
                    error=\(error.localizedDescription, privacy: .public)
                    """
                )
                return .failed
            }
        }
    }

    /// Pure classification, so recognition rules are testable without a CloudKit account.
    public nonisolated static func recognize(
        descriptor: RemoteNotificationPayloadDescriptor,
        ownedSubscriptionIDs: Set<String>
    ) -> RemoteNotificationRecognition {
        switch descriptor {
        case .notCloudKit:
            return .notCloudKit
        case .cloudKit(let subscriptionID):
            guard let subscriptionID,
                  ownedSubscriptionIDs.contains(subscriptionID) else {
                return .foreignCloudKitSubscription(subscriptionID: subscriptionID)
            }
            return .cloudKitSubscription(subscriptionID: subscriptionID)
        }
    }
}
