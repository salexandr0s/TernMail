import XCTest

@MainActor
final class ReviewFixesUITests: XCTestCase {
    func testUnsavedTemplateSurvivesCancelledNewAndSettingsNavigation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-audit", "--ui-audit-light", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.matching(identifier: "main").firstMatch.waitForExistence(timeout: 15))
        app.typeKey(",", modifierFlags: .command)
        let templates = app.staticTexts["Templates"].firstMatch
        XCTAssertTrue(templates.waitForExistence(timeout: 10))
        templates.click()
        let name = app.textFields["compose-template-name"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.click()
        name.typeText("Unfinished reply")

        let create = app.buttons["compose-template-new"]
        create.click()
        XCTAssertTrue(app.buttons["Discard Changes"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].click()
        XCTAssertEqual(name.value as? String, "Unfinished reply")

        app.staticTexts["General"].firstMatch.click()
        XCTAssertTrue(app.buttons["Discard Changes"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].click()
        XCTAssertEqual(name.value as? String, "Unfinished reply")

        create.click()
        XCTAssertTrue(app.buttons["Discard Changes"].waitForExistence(timeout: 5))
        app.buttons["Discard Changes"].click()
        let cleared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", ""), object: name)
        XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 5), .completed)
    }

    func testExpiredSingleAccountKeepsCachedMailAccessible() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-audit", "--ui-audit-cached-reauth", "--ui-audit-light",
                               "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        defer { app.terminate() }

        let reconnect = app.buttons["Sign in again to audit@example.invalid"]
        XCTAssertTrue(reconnect.waitForExistence(timeout: 15))
        let subject = app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", "Field notes", "Field notes")).firstMatch
        XCTAssertTrue(subject.waitForExistence(timeout: 10), "Cached Inbox must remain available after the only account expires.")
        subject.click()
        let message = app.descendants(matching: .any).matching(identifier: "message-disclosure-m1").firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 10), "The cached message must still open in the reader.")
        XCTAssertTrue(reconnect.exists)

        let attachment = XCTAttachment(screenshot: app.windows.matching(identifier: "main").firstMatch.screenshot())
        attachment.name = "Cached mail with an expired account"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
