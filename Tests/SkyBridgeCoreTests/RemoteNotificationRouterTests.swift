import CloudKit
import XCTest
@testable import SkyBridgeCore

/// Covers the silent-push wake path.
///
/// Two properties matter beyond "it works": a payload is only allowed to trigger work when it names
/// a subscription this process actually maintains (any sender holding the device token can post
/// arbitrary payloads), and the reported outcome must reflect whether data really changed, because
/// the system throttles background wakeups for apps that always claim `newData`.
@available(macOS 14.0, iOS 17.0, *)
final class RemoteNotificationRouterTests: XCTestCase {

    // MARK: - Recognition

    func testNonCloudKitPayloadIsNotRecognized() {
        let descriptor = RemoteNotificationPayloadDescriptor(
            remoteNotificationUserInfo: ["aps": ["content-available": 1], "hello": "world"]
        )

        XCTAssertEqual(descriptor, .notCloudKit)
        XCTAssertEqual(
            RemoteNotificationRouter.recognize(
                descriptor: descriptor,
                ownedSubscriptionIDs: ["skybridge-device-changes"]
            ),
            .notCloudKit
        )
    }

    func testUnownedSubscriptionIsRejectedEvenWhenItIsValidCloudKit() {
        let recognition = RemoteNotificationRouter.recognize(
            descriptor: .cloudKit(subscriptionID: "someone-elses-subscription"),
            ownedSubscriptionIDs: ["skybridge-device-changes"]
        )

        XCTAssertEqual(
            recognition,
            .foreignCloudKitSubscription(subscriptionID: "someone-elses-subscription"),
            "未持有的订阅 id 要么是过期订阅要么是伪造负载，都不得触发后台工作"
        )
    }

    func testMissingSubscriptionIDIsRejected() {
        XCTAssertEqual(
            RemoteNotificationRouter.recognize(
                descriptor: .cloudKit(subscriptionID: nil),
                ownedSubscriptionIDs: ["skybridge-device-changes"]
            ),
            .foreignCloudKitSubscription(subscriptionID: nil)
        )
    }

    func testOwnedSubscriptionIsRecognized() {
        XCTAssertEqual(
            RemoteNotificationRouter.recognize(
                descriptor: .cloudKit(subscriptionID: "skybridge-device-changes"),
                ownedSubscriptionIDs: ["skybridge-device-changes", "other"]
            ),
            .cloudKitSubscription(subscriptionID: "skybridge-device-changes")
        )
    }

    func testNoOwnedSubscriptionsMeansNothingIsAccepted() {
        XCTAssertEqual(
            RemoteNotificationRouter.recognize(
                descriptor: .cloudKit(subscriptionID: "skybridge-device-changes"),
                ownedSubscriptionIDs: []
            ),
            .foreignCloudKitSubscription(subscriptionID: "skybridge-device-changes"),
            "尚未有子系统声明所有权时，推送不得授权任何刷新"
        )
    }

    // MARK: - Routing

    func testHandlerRunsOnlyForItsOwnSubscriptionAndReportsNewData() async {
        let router = RemoteNotificationRouter()
        let invocations = InvocationCounter()

        await router.registerHandler(forSubscriptionID: "sub-a") {
            await invocations.increment()
            return true
        }

        let owned = await router.handle(descriptor: .cloudKit(subscriptionID: "sub-a"))
        let countAfterOwned = await invocations.count
        XCTAssertEqual(owned, .newData)
        XCTAssertEqual(countAfterOwned, 1)

        let foreign = await router.handle(descriptor: .cloudKit(subscriptionID: "sub-b"))
        let countAfterForeign = await invocations.count
        XCTAssertEqual(foreign, .noData)
        XCTAssertEqual(
            countAfterForeign,
            1,
            "外部订阅不得触发本进程的处理器"
        )

        let notCloudKit = await router.handle(descriptor: .notCloudKit)
        let countAfterNonCloudKit = await invocations.count
        XCTAssertEqual(notCloudKit, .noData)
        XCTAssertEqual(countAfterNonCloudKit, 1)
    }

    func testOutcomeReflectsWhetherDataActuallyChanged() async {
        let router = RemoteNotificationRouter()
        await router.registerHandler(forSubscriptionID: "sub-unchanged") { false }

        let outcome = await router.handle(descriptor: .cloudKit(subscriptionID: "sub-unchanged"))
        XCTAssertEqual(
            outcome,
            .noData,
            "没有新数据时必须报 noData，否则系统会因虚报 newData 而收紧后台唤醒配额"
        )
    }

    func testHandlerFailureIsReportedAsFailed() async {
        struct ExpectedFailure: Error, Sendable {}

        let router = RemoteNotificationRouter()
        await router.registerHandler(forSubscriptionID: "sub-failed") {
            throw ExpectedFailure()
        }

        let outcome = await router.handle(descriptor: .cloudKit(subscriptionID: "sub-failed"))
        XCTAssertEqual(
            outcome,
            .failed,
            "真实刷新失败不得伪装成 noData"
        )
    }

    func testRouterWaitsForTheRegisteredRefreshToFinish() async {
        let router = RemoteNotificationRouter()
        let gate = BlockingHandlerGate()
        let outcomeBox = RemoteNotificationOutcomeBox()
        await router.registerHandler(forSubscriptionID: "sub-delayed") {
            await gate.blockUntilReleased()
            return true
        }

        let handlingTask = Task {
            let outcome = await router.handle(
                descriptor: .cloudKit(subscriptionID: "sub-delayed")
            )
            await outcomeBox.set(outcome)
        }

        await gate.waitUntilEntered()
        let prematureOutcome = await outcomeBox.value
        XCTAssertNil(
            prematureOutcome,
            "系统 completion 必须等待真实 CloudKit 刷新，而不是在任务入队后立即返回"
        )

        await gate.release()
        await handlingTask.value
        let completedOutcome = await outcomeBox.value
        XCTAssertEqual(completedOutcome, .newData)
    }

    func testUnregisteredSubscriptionStopsBeingAccepted() async {
        let router = RemoteNotificationRouter()
        await router.registerHandler(forSubscriptionID: "sub-a") { true }
        let registered = await router.registeredSubscriptionIDs()
        XCTAssertEqual(registered, ["sub-a"])

        await router.unregisterHandler(forSubscriptionID: "sub-a")

        let afterUnregister = await router.registeredSubscriptionIDs()
        let outcome = await router.handle(descriptor: .cloudKit(subscriptionID: "sub-a"))
        XCTAssertTrue(afterUnregister.isEmpty)
        XCTAssertEqual(outcome, .noData)
    }

    func testReRegistrationReplacesTheHandlerRatherThanAccumulating() async {
        let router = RemoteNotificationRouter()
        let first = InvocationCounter()
        let second = InvocationCounter()

        await router.registerHandler(forSubscriptionID: "sub-a") {
            await first.increment()
            return true
        }
        await router.registerHandler(forSubscriptionID: "sub-a") {
            await second.increment()
            return true
        }

        _ = await router.handle(descriptor: .cloudKit(subscriptionID: "sub-a"))

        let firstCount = await first.count
        let secondCount = await second.count
        let registeredCount = await router.registeredSubscriptionIDs().count
        XCTAssertEqual(firstCount, 0, "重复注册必须替换而不是叠加，避免子系统重启后残留闭包")
        XCTAssertEqual(secondCount, 1)
        XCTAssertEqual(registeredCount, 1)
    }

    func testBlankSubscriptionIDIsNotRegistrable() async {
        let router = RemoteNotificationRouter()
        await router.registerHandler(forSubscriptionID: "   ") { true }

        let registered = await router.registeredSubscriptionIDs()
        XCTAssertTrue(
            registered.isEmpty,
            "空 subscriptionID 会让任何缺少订阅 id 的负载都被当成己方订阅"
        )
    }

    func testCloudKitSubscriptionIDIsStable() {
        XCTAssertEqual(
            CloudKitService.deviceChangesSubscriptionID,
            "skybridge-device-changes",
            "常量与服务端既有订阅 id 不一致会让所有静默推送被判为外部订阅并丢弃"
        )
    }
}

private actor InvocationCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

private actor BlockingHandlerGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func blockUntilReleased() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private actor RemoteNotificationOutcomeBox {
    private(set) var value: RemoteNotificationOutcome?

    func set(_ outcome: RemoteNotificationOutcome) {
        value = outcome
    }
}
