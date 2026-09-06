import Foundation
import XCTest
import SkyBridgeProtocolCore

/// 一控多的准入、焦点与流量分级规则。两端（macOS 局域网、iOS 跨网）共用这一份，
/// 所以这里锁定的是产品语义本身，而不是某一端的实现细节。
final class ControlledHostSessionPolicyTests: XCTestCase {
    private typealias Policy = ControlledHostSessionPolicy

    // MARK: - 准入

    func testSecondHostIsAdmittedAndThirdIsRefusedWithTheNumbersNeededToExplainIt() {
        XCTAssertEqual(Policy.defaultConcurrentHostLimit, 2)
        XCTAssertEqual(Policy.admit(hostKey: "a", activeHostKeys: []), .admitted)
        XCTAssertEqual(Policy.admit(hostKey: "b", activeHostKeys: ["a"]), .admitted)
        XCTAssertEqual(
            Policy.admit(hostKey: "c", activeHostKeys: ["a", "b"]),
            .refusedAtCapacity(limit: 2, activeHostCount: 2),
            "超出上限必须带上数字，UI 才能说清为什么被拒绝"
        )
    }

    func testControllingTheSameHostAgainIsNotANewSession() {
        XCTAssertEqual(
            Policy.admit(hostKey: "a", activeHostKeys: ["a", "b"]),
            .alreadyControlled,
            "已在控制的主机应当切焦点，而不是占掉一个新名额或被拒绝"
        )
    }

    func testCapacityRefusalNeverSilentlyDisplacesAnExistingHost() {
        // 这条断言存在的意义：拒绝必须是 refusedAtCapacity，绝不能退化成 admitted 让调用方去顶替别人。
        for existing in [Set(["a", "b"]), Set(["x", "y"])] {
            guard case .refusedAtCapacity = Policy.admit(hostKey: "new", activeHostKeys: existing) else {
                return XCTFail("达到上限时必须拒绝，不得放行")
            }
        }
    }

    func testLimitIsSanitisedSoAMisconfiguredZeroStillAdmitsOne() {
        XCTAssertEqual(Policy.admit(hostKey: "a", activeHostKeys: [], limit: 0), .admitted)
        XCTAssertEqual(
            Policy.admit(hostKey: "b", activeHostKeys: ["a"], limit: 0),
            .refusedAtCapacity(limit: 1, activeHostCount: 1)
        )
    }

    // MARK: - 焦点

    func testRemovingANonFocusedHostLeavesTheFocusAlone() {
        XCTAssertEqual(
            Policy.focusedHost(afterRemoving: "b", remaining: ["a", "b"], currentFocus: "a"),
            "a",
            "用户正在操作的画面不能因为另一台退出而被顶掉"
        )
    }

    func testRemovingTheFocusedHostMovesFocusToTheMostRecentSurvivor() {
        XCTAssertEqual(
            Policy.focusedHost(afterRemoving: "a", remaining: ["a", "b"], currentFocus: "a"),
            "b"
        )
        XCTAssertNil(
            Policy.focusedHost(afterRemoving: "a", remaining: ["a"], currentFocus: "a"),
            "最后一台退出后没有焦点"
        )
    }

    func testAStaleFocusPointingAtAGoneHostIsRepaired() {
        XCTAssertEqual(
            Policy.focusedHost(afterRemoving: "c", remaining: ["a", "b"], currentFocus: "gone"),
            "a",
            "焦点指向不存在的主机时必须自愈，不能返回一个死键"
        )
    }

    // MARK: - 流量分级

    func testOnlyTheFocusedHostGetsFullRateAndAudio() {
        let focused = Policy.budget(for: .focused, requestedFrameRate: 60, requestedAudio: true)
        XCTAssertEqual(focused.targetFrameRate, 60)
        XCTAssertTrue(focused.audioEnabled)

        let background = Policy.budget(for: .background, requestedFrameRate: 60, requestedAudio: true)
        XCTAssertEqual(background.targetFrameRate, Policy.backgroundKeepAliveFrameRate)
        XCTAssertFalse(
            background.audioEnabled,
            "系统音频采集是进程内单例，后台主机要音频必然有一台拿不到"
        )
        XCTAssertTrue(background.allowsAdaptiveResolution)
    }

    func testBackgroundIsNeverMoreExpensiveThanWhatTheUserAskedFor() {
        // 用户本来就把帧率设得比保活帧率还低时，后台不得反而提高帧率。
        let background = Policy.budget(for: .background, requestedFrameRate: 1, requestedAudio: false)
        XCTAssertEqual(background.targetFrameRate, 1)
    }

    func testBackgroundKeepsANonZeroRateSoFocusSwitchingIsNotAColdStart() {
        XCTAssertGreaterThan(
            Policy.backgroundKeepAliveFrameRate, 0,
            "降到 0 会让切换焦点等一个完整关键帧周期"
        )
        XCTAssertLessThan(Policy.backgroundKeepAliveFrameRate, 10)
    }

    func testTotalRequestedRateBarelyGrowsWithHostCount() {
        // 这是「压力随在看几台走，而不是随连了几台走」这条设计意图的可执行形式。
        func totalRate(hosts: [String]) -> Int {
            Policy.budgets(
                hostKeys: hosts,
                focusedHostKey: hosts.first,
                requestedFrameRate: 60,
                requestedAudio: true
            ).values.reduce(0) { $0 + $1.targetFrameRate }
        }
        let one = totalRate(hosts: ["a"])
        let two = totalRate(hosts: ["a", "b"])
        XCTAssertEqual(one, 60)
        XCTAssertEqual(two, 60 + Policy.backgroundKeepAliveFrameRate)
        XCTAssertLessThan(two, one * 2, "第二台主机不得让总帧率翻倍")

        let audioEnabledCount = Policy.budgets(
            hostKeys: ["a", "b"],
            focusedHostKey: "a",
            requestedFrameRate: 60,
            requestedAudio: true
        ).values.filter(\.audioEnabled).count
        XCTAssertEqual(audioEnabledCount, 1, "任何时刻最多一台主机开音频")
    }

    func testNoFocusMeansEveryHostIsThrottled() {
        let budgets = Policy.budgets(
            hostKeys: ["a", "b"],
            focusedHostKey: nil,
            requestedFrameRate: 60,
            requestedAudio: true
        )
        XCTAssertEqual(budgets.count, 2)
        XCTAssertTrue(budgets.values.allSatisfy { !$0.audioEnabled })
        XCTAssertTrue(budgets.values.allSatisfy { $0.targetFrameRate == Policy.backgroundKeepAliveFrameRate })
    }
}
