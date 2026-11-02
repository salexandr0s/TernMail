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
        let name = app.textFields["Name"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.click()
        name.typeText("Unfinished reply")

        let create = app.buttons["Create a new template"]
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

        let reconnect = app.descendants(matching: .any).matching(identifier: "account.reconnect").firstMatch
        XCTAssertTrue(reconnect.waitForExistence(timeout: 15))
        let inboxCount = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@ AND value == %@", "Inbox", "2 unread")).firstMatch
        XCTAssertTrue(inboxCount.waitForExistence(timeout: 10), "VoiceOver must receive the visible Inbox count and its meaning.")
        let subject = app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", "Field notes", "Field notes")).firstMatch
        XCTAssertTrue(subject.waitForExistence(timeout: 10), "Cached Inbox must remain available after the only account expires.")
        subject.click()
        let conversationActions = app.buttons["Conversation actions"]
        XCTAssertTrue(conversationActions.waitForExistence(timeout: 10), "The cached conversation must still open.")
        XCTAssertTrue(reconnect.exists)

        let attachment = XCTAttachment(screenshot: app.windows.matching(identifier: "main").firstMatch.screenshot())
        attachment.name = "Cached mail with an expired account"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
