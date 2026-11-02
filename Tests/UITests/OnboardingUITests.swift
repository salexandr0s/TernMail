import XCTest

@MainActor
final class OnboardingUITests: XCTestCase {
    func testFirstRunRequiresGoogleAndSupportsBack() {
        continueAfterFailure = false
        let app = launch(connected: false)
        defer { app.terminate() }

        waitForLabel("Get started", on: control("continue", in: app))
        capture(app, named: "Welcome")
        control("continue", in: app).click()

        let connect = control("connectGoogle", in: app)
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        XCTAssertFalse(connect.isEnabled, "Ordinary previews must not start live Google sign-in.")
        waitForEnabled(false, on: control("continue", in: app))
        capture(app, named: "Google — no accounts")

        control("back", in: app).click()
        waitForLabel("Get started", on: control("continue", in: app))
    }

    func testMultipleAccountsCanSkipChatGPTSavePreferencesAndOpenMailbox() {
        continueAfterFailure = false
        let app = launch(connected: true)
        defer { app.terminate() }

        let next = control("continue", in: app)
        waitForLabel("Get started", on: next)
        next.click()

        XCTAssertTrue(control("connectGoogle", in: app).waitForExistence(timeout: 10))
        for address in ["audit@example.invalid", "second@example.invalid"] {
            let account = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", address, address)).firstMatch
            XCTAssertTrue(account.waitForExistence(timeout: 10))
        }
        waitForEnabled(true, on: next)
        capture(app, named: "Google — two accounts")
        next.click()

        let chatGPT = control("connectChatGPT", in: app)
        XCTAssertTrue(chatGPT.waitForExistence(timeout: 10))
        XCTAssertFalse(chatGPT.isEnabled, "Ordinary previews must not start live ChatGPT sign-in.")
        waitForLabel("Set up later", on: next)
        waitForEnabled(true, on: next)
        capture(app, named: "ChatGPT — optional")
        next.click()

        let shortcuts = control("singleKeyShortcuts", in: app)
        XCTAssertTrue(shortcuts.waitForExistence(timeout: 10))
        let previousShortcuts = value(of: shortcuts)
        shortcuts.click()
        waitForValueChange(from: previousShortcuts, on: shortcuts)
        let savedShortcuts = value(of: shortcuts)

        let images = control("blockImages", in: app)
        let previousImages = value(of: images)
        images.click()
        waitForValueChange(from: previousImages, on: images)
        let savedImages = value(of: images)

        select("20 seconds", in: control("undoSend", in: app), app: app)
        select("second@example.invalid", in: control("defaultAccount", in: app), app: app)
        capture(app, named: "Preferences")

        control("back", in: app).click()
        XCTAssertTrue(control("connectChatGPT", in: app).waitForExistence(timeout: 10))
        waitForEnabled(true, on: next)
        next.click()
        XCTAssertTrue(shortcuts.waitForExistence(timeout: 10))
        XCTAssertEqual(value(of: shortcuts), savedShortcuts)
        XCTAssertEqual(value(of: images), savedImages)
        waitForValue("20 seconds", on: control("undoSend", in: app))
        waitForValue("second@example.invalid", on: control("defaultAccount", in: app))

        waitForLabel("Review setup", on: next)
        next.click()
        waitForLabel("Open Tern", on: next)
        waitForEnabled(true, on: next)
        capture(app, named: "Ready")
        next.click()

        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: next)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 10), .completed)
        let inbox = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", "Inbox", "Inbox")).firstMatch
        XCTAssertTrue(inbox.waitForExistence(timeout: 10))
        capture(app, named: "Mailbox after setup")
    }

    private func launch(connected: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-audit", "--ui-audit-light",
            connected ? "--ui-audit-onboarding-connected" : "--ui-audit-onboarding",
            "--ui-audit-onboarding-step=welcome"]
        app.launch()
        return app
    }

    private func control(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "onboarding.\(name)").firstMatch
    }

    private func select(_ title: String, in picker: XCUIElement, app: XCUIApplication) {
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.click()
        let item = app.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.click()
        waitForValue(title, on: picker)
    }

    private func value(of element: XCUIElement) -> String {
        String(describing: element.value ?? "")
    }

    private func waitForLabel(_ label: String, on element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label == %@", label), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
    }

    private func waitForEnabled(_ enabled: Bool, on element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == %@", NSNumber(value: enabled)), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
    }

    private func waitForValue(_ value: String, on element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@ OR label == %@", value, value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }

    private func waitForValueChange(from value: String, on element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
        XCTAssertNotEqual(self.value(of: element), value)
    }

    private func capture(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
