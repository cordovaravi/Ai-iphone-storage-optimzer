import XCTest

/// UI smoke tests. The full E2E matrix (§8: onboarding→scan→offload→paywall→
/// purchase→delete-review) requires a seeded device library and a StoreKit
/// configuration file — those runs live in the release pipeline; this file
/// keeps the target compiling with a launch smoke test.
final class OffloadProUITests: XCTestCase {
    func testAppLaunches() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10))
    }

    /// §6.3 copy audit: no user-facing "subscription" wording anywhere in
    /// the main tabs.
    func testNoSubscriptionWording() {
        let app = XCUIApplication()
        app.launch()
        for tab in ["Storage", "Smart", "Pendrive", "Coach", "Settings"] {
            let button = app.tabBars.buttons[tab]
            if button.waitForExistence(timeout: 5) {
                button.tap()
                XCTAssertFalse(
                    app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'subscription'")).firstMatch.exists,
                    "found forbidden word 'subscription' on \(tab) tab"
                )
            }
        }
    }
}
