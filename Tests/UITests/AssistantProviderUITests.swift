import XCTest

@MainActor
final class AssistantProviderUITests: XCTestCase {
    func testStandaloneClaudeCLIConnectsAndRespondsToSyntheticPrompt() throws {
        guard ProcessInfo.processInfo.environment["TERN_CLAUDE_LIVE_UI_TEST"] == "1" else {
            throw XCTSkip("Set TERN_CLAUDE_LIVE_UI_TEST=1 to use the signed-in Claude CLI with synthetic mail.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-audit", "--ui-audit-light", "--ui-audit-live-claude",
                               "-ApplePersistenceIgnoreState", "YES"]
        var didConnect = false
        app.launch()
        defer {
            if didConnect { disconnectLiveClaude(in: app) }
            app.terminate()
        }
        app.activate()
        let mainWindow = app.windows.matching(identifier: "main").firstMatch
        if !mainWindow.exists { app.typeKey("0", modifierFlags: .command) }
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 15))
        let settings = openAssistantSettings(in: app)
        let provider = settings.descendants(matching: .any).matching(identifier: "assistant.provider").firstMatch
        select("Claude (CLI)", picker: provider, app: app)
        let connect = settings.buttons["assistant.claude-cli.connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        connect.click()
        XCTAssertTrue(settings.staticTexts["Connected"].waitForExistence(timeout: 30))
        didConnect = true
        XCTAssertFalse(settings.secureTextFields["assistant.claude-cli.sign-in-code"].exists)

        let modelPicker = settings.popUpButtons.matching(NSPredicate(
            format: "label == %@ OR value == %@", "Assistant model", "Account default")).firstMatch
        XCTAssertTrue(modelPicker.waitForExistence(timeout: 20), "Connecting must load the model catalogue.")
        modelPicker.click()
        for model in ["Account default", "Sonnet", "Opus", "Haiku"] {
            XCTAssertTrue(app.menuItems[model].waitForExistence(timeout: 5))
        }
        app.menuItems["Haiku"].click()

        let mailAccess = settings.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@", "Allow assistant access to audit@example.invalid")).firstMatch
        XCTAssertTrue(mailAccess.waitForExistence(timeout: 5))
        for _ in 0..<3 where !mailAccess.isHittable {
            settings.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -350)
        }
        if String(describing: mailAccess.value ?? "") != "1" { mailAccess.click() }
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 1 OR value == %@", "1"), object: mailAccess)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)

        // The global shortcut opens the assistant without interacting with real mail.
        app.typeKey("a", modifierFlags: [.command, .option])
        let composer = app.descendants(matching: .any).matching(identifier: "assistant.message").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertTrue(composer.isEnabled)
        let marker = "TERN_CLAUDE_UI_OK_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        composer.click()
        composer.typeText("Reply with exactly \(marker). Do not use tools or read mail.")
        app.buttons["assistant.send"].click()
        XCTAssertTrue(app.staticTexts[marker].waitForExistence(timeout: 120), "The standalone app must receive the live CLI answer.")
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Send message"),
                                                object: app.buttons["assistant.send"])
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 20), .completed)
        let assistantWindow = app.windows.containing(.any, identifier: "assistant.message").firstMatch
        let screenshot = XCTAttachment(screenshot: assistantWindow.screenshot())
        screenshot.name = "Standalone Claude CLI synthetic response"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testClaudeConnectionControlsAndProviderChangesClearUnsavedAPIKeys() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-audit", "--ui-audit-light", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.matching(identifier: "main").firstMatch.waitForExistence(timeout: 15))
        app.typeKey(",", modifierFlags: .command)
        let assistantSettings = app.staticTexts["Assistant"].firstMatch
        XCTAssertTrue(assistantSettings.waitForExistence(timeout: 10))
        assistantSettings.click()

        let picker = app.descendants(matching: .any).matching(identifier: "assistant.provider").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        select("OpenAI API", picker: picker, app: app)
        let apiKey = app.secureTextFields["assistant.api-key"]
        XCTAssertTrue(apiKey.waitForExistence(timeout: 5))
        apiKey.click()
        apiKey.typeText("synthetic-unsaved-test-key")

        select("Claude (CLI)", picker: picker, app: app)
        XCTAssertTrue(app.buttons["assistant.claude-cli.connect"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["assistant.claude-cli.sign-in"].exists)
        XCTAssertFalse(apiKey.exists, "The CLI connection must not ask for an API key.")
        XCTAssertFalse(app.secureTextFields["assistant.claude-cli.sign-in-code"].exists,
                       "A sign-in code is accepted only during an active login.")
        let settingsWindow = app.windows.containing(.any, identifier: "assistant.provider").firstMatch
        XCTAssertTrue(settingsWindow.exists)
        let screenshot = XCTAttachment(screenshot: settingsWindow.screenshot())
        screenshot.name = "Claude CLI connection settings"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        select("DeepSeek API", picker: picker, app: app)
        XCTAssertTrue(apiKey.waitForExistence(timeout: 5))
        XCTAssertEqual(apiKey.value as? String, "", "Switching providers must discard an unsaved API key.")
        select("OpenAI API", picker: picker, app: app)
        XCTAssertTrue(apiKey.waitForExistence(timeout: 5))
        XCTAssertEqual(apiKey.value as? String, "", "Returning to a provider must not restore an unsaved key.")
    }

    private func select(_ title: String, picker: XCUIElement, app: XCUIApplication) {
        picker.click()
        let item = app.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.click()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@ OR label == %@", title, title), object: picker)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
    }

    private func openAssistantSettings(in app: XCUIApplication) -> XCUIElement {
        app.activate()
        app.typeKey(",", modifierFlags: .command)
        let assistantSettings = app.staticTexts["Assistant"].firstMatch
        XCTAssertTrue(assistantSettings.waitForExistence(timeout: 10))
        assistantSettings.click()
        let settings = app.windows.containing(.any, identifier: "assistant.provider").firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        return settings
    }

    private func disconnectLiveClaude(in app: XCUIApplication) {
        let assistantWindow = app.windows.containing(.any, identifier: "assistant.message").firstMatch
        if assistantWindow.exists {
            assistantWindow.buttons[XCUIIdentifierCloseWindow].click()
            let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: assistantWindow)
            XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
        }
        let settings = openAssistantSettings(in: app)
        let provider = settings.descendants(matching: .any).matching(identifier: "assistant.provider").firstMatch
        guard String(describing: provider.value ?? "") == "Claude (CLI)" else { return }
        let disconnect = settings.buttons["Disconnect…"].firstMatch
        guard disconnect.exists else { return }
        disconnect.click()
        let confirmation = settings.sheets.buttons["Disconnect"].firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.click()
        XCTAssertTrue(settings.staticTexts["Not connected"].waitForExistence(timeout: 10))
    }
}
