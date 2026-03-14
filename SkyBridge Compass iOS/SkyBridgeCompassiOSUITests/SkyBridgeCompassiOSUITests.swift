import XCTest

final class SkyBridgeCompassiOSUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false

        app = XCUIApplication()
        app.launchArguments += [
            "UITEST_MODE",
            "UITEST_RESET_STATE",
            "UITEST_DISABLE_ANIMATIONS",
        ]
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    func testGuestModeLaunchesDashboard() throws {
        enterDashboardIfNeeded()

        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["dashboard.tab.home"].waitForExistence(timeout: 5))
    }

    func testMainTabNavigationSmoke() throws {
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
