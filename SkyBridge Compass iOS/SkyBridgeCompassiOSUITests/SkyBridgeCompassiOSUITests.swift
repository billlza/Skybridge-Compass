import XCTest

final class SkyBridgeCompassiOSUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    func testGuestModeLaunchesDashboard() throws {
        launchApp()
        enterDashboardIfNeeded()

        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["dashboard.tab.home"].waitForExistence(timeout: 5))
    }

    func testMainTabNavigationSmoke() throws {
        launchApp()
        enterDashboardIfNeeded()

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5))

        let tabs: [(label: String, buttonIdentifier: String, rootIdentifier: String)] = [
            ("首页", "dashboard.tab.button.home", "dashboard.tab.home"),
            ("设备", "dashboard.tab.button.devices", "dashboard.tab.devices"),
            ("文件", "dashboard.tab.button.files", "dashboard.tab.files"),
            ("远程", "dashboard.tab.button.remote", "dashboard.tab.remote"),
            ("设置", "dashboard.tab.button.settings", "dashboard.tab.settings"),
        ]

        for (index, tab) in tabs.enumerated() {
            let button = tabButton(
                in: tabBar,
                index: index,
                accessibilityIdentifier: tab.buttonIdentifier,
                fallbackLabel: tab.label
            )
            XCTAssertTrue(button.waitForExistence(timeout: 5), "Expected tab button \(tab.buttonIdentifier)")
            button.tap()
            XCTAssertTrue(
                app.otherElements[tab.rootIdentifier].waitForExistence(timeout: 5),
                "Expected tab root \(tab.rootIdentifier) after tapping \(tab.label)"
            )
        }
    }

    func testPairingTrustPromptHappyPath() throws {
        launchApp(additionalArguments: ["UITEST_AUTH_GUEST", "UITEST_SCENARIO_PAIRING"])

        let allowOnceButton = app.buttons["pairing.allowOnce"].firstMatch
        XCTAssertTrue(allowOnceButton.waitForExistence(timeout: 5))
        allowOnceButton.tap()

        XCTAssertFalse(allowOnceButton.waitForExistence(timeout: 1))
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["dashboard.tab.home"].waitForExistence(timeout: 5))
    }

    func testFilesHappyPathShowsQuickSendAndTransferState() throws {
        launchApp(additionalArguments: ["UITEST_SCENARIO_FILES"])
        enterDashboardIfNeeded()

        let tabBar = app.tabBars.firstMatch
        let filesButton = tabButton(
            in: tabBar,
            index: 2,
            accessibilityIdentifier: "dashboard.tab.button.files",
            fallbackLabel: "文件"
        )
        XCTAssertTrue(filesButton.waitForExistence(timeout: 5))
        filesButton.tap()

        let quickSendCard = app.buttons["files.quickSend.uitest-files-device"].firstMatch
        XCTAssertTrue(quickSendCard.waitForExistence(timeout: 5))
        quickSendCard.tap()

        XCTAssertTrue(app.otherElements["files.active.ready"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["files.history.ready"].waitForExistence(timeout: 5))
    }

    func testRemoteEntryHappyPathConnectsToViewer() throws {
        launchApp(additionalArguments: ["UITEST_SCENARIO_REMOTE"])
        enterDashboardIfNeeded()

        let tabBar = app.tabBars.firstMatch
        let remoteButton = tabButton(
            in: tabBar,
            index: 3,
            accessibilityIdentifier: "dashboard.tab.button.remote",
            fallbackLabel: "远程"
        )
        XCTAssertTrue(remoteButton.waitForExistence(timeout: 5))
        remoteButton.tap()

        XCTAssertTrue(app.otherElements["remote.stream.ready"].waitForExistence(timeout: 5))
    }

    private func launchApp(additionalArguments: [String] = []) {
        app = XCUIApplication()
        app.launchArguments += [
            "UITEST_MODE",
            "UITEST_RESET_STATE",
            "UITEST_DISABLE_ANIMATIONS",
        ] + additionalArguments
        app.launch()
    }

    private func enterDashboardIfNeeded() {
        if app.tabBars.firstMatch.waitForExistence(timeout: 5) {
            return
        }

        let guestButton = app.buttons["auth.guest"].firstMatch
        let localizedGuestButton = app.buttons["以游客身份继续"].firstMatch
        let didFindGuestButton = guestButton.waitForExistence(timeout: 5) || localizedGuestButton.waitForExistence(timeout: 1)

        XCTAssertTrue(didFindGuestButton, "Expected guest login button to exist")

        let buttonToTap = guestButton.exists ? guestButton : localizedGuestButton
        XCTAssertTrue(buttonToTap.exists)
        buttonToTap.tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["dashboard.tab.home"].waitForExistence(timeout: 5))
    }

    private func tabButton(
        in tabBar: XCUIElement,
        index: Int,
        accessibilityIdentifier: String,
        fallbackLabel: String
    ) -> XCUIElement {
        let identifiedButton = tabBar.buttons[accessibilityIdentifier].firstMatch
        if identifiedButton.waitForExistence(timeout: 1) {
            return identifiedButton
        }

        let localizedButton = tabBar.buttons[fallbackLabel].firstMatch
        if localizedButton.waitForExistence(timeout: 1) {
            return localizedButton
        }

        return tabBar.buttons.element(boundBy: index)
    }
}
