import XCTest

@MainActor
final class MailInteractionUITests: XCTestCase {
    func testDragMovesMailOptionDragAddsLabelAndTrashCanRestoreToInbox() {
        let app = launch()
        defer { app.terminate() }
        let inbox = mailbox("combined.INBOX", in: app)
        let hiking = mailbox("ui-audit.Label_1", in: app)
        let trash = mailbox("combined.TRASH", in: app)

        drag(message("Field notes", in: app), to: hiking)
        waitForAbsence(message("Field notes", in: app))
        hiking.click()
        waitForMessage("Field notes", in: app)
        inbox.click()
        waitForMessage("Weekend plans", in: app)
        XCTAssertFalse(message("Field notes", in: app).exists)

        XCUIElement.perform(withKeyModifiers: .option) {
            drag(message("Weekend plans", in: app), to: hiking)
        }
        hiking.click()
        waitForMessage("Weekend plans", in: app)
        waitForMessage("Field notes", in: app)
        inbox.click()
        waitForMessage("Weekend plans", in: app)
        XCTAssertFalse(message("Field notes", in: app).exists)

        drag(message("Weekend plans", in: app), to: trash)
        waitForAbsence(message("Weekend plans", in: app))
        trash.click()
        let trashed = waitForMessage("Weekend plans", in: app)
        trashed.rightClick()
        assertMenu(["Move to Inbox", "Delete Forever…"], in: app)
        dismissMenu(in: app)

        drag(trashed, to: inbox)
        waitForAbsence(message("Weekend plans", in: app))
        inbox.click()
        waitForMessage("Weekend plans", in: app)
        waitForMessage("Book club", in: app)
    }

    func testDraggingASelectedConversationMovesTheWholeSelection() {
        let app = launch()
        defer { app.terminate() }
        let fieldNotes = waitForMessage("Field notes", in: app)
        let weekendPlans = waitForMessage("Weekend plans", in: app)
        let hiking = mailbox("ui-audit.Label_1", in: app)

        fieldNotes.click()
        XCUIElement.perform(withKeyModifiers: .command) { weekendPlans.click() }
        drag(fieldNotes, to: hiking)

        waitForAbsence(message("Field notes", in: app))
        waitForAbsence(message("Weekend plans", in: app))
        waitForMessage("Book club", in: app)
        hiking.click()
        waitForMessage("Field notes", in: app)
        waitForMessage("Weekend plans", in: app)
        XCTAssertFalse(message("Book club", in: app).exists)
    }

    func testContextActionsTargetTheRightClickedConversationAndRestoreIt() {
        let app = launch()
        defer { app.terminate() }
        let inbox = mailbox("combined.INBOX", in: app)
        let trash = mailbox("combined.TRASH", in: app)

        waitForMessage("Weekend plans", in: app).click()
        waitForMessage("Field notes", in: app).rightClick()
        assertMenu(["Move to Trash"], in: app)
        contextItem("Move to Trash", in: app).click()

        waitForAbsence(message("Field notes", in: app))
        waitForMessage("Weekend plans", in: app)
        waitForMessage("Book club", in: app)
        trash.click()
        waitForMessage("Field notes", in: app).rightClick()
        assertMenu(["Move to Inbox"], in: app)
        contextItem("Move to Inbox", in: app).click()
        waitForAbsence(message("Field notes", in: app))

        inbox.click()
        waitForMessage("Field notes", in: app)
        waitForMessage("Weekend plans", in: app)
        waitForMessage("Book club", in: app)
    }

    func testSingleAccountMailboxAndFavoriteLabelsKeepTheirContextActions() {
        let app = launch(singleAccount: true)
        defer { app.terminate() }
        let trash = mailbox("ui-audit.TRASH", in: app)

        // Removing the shortcut exposes the single-account Mailboxes row.
        rightClickInSidebar(trash, in: app)
        assertMenu(["Mark All as Read", "Empty Trash…", "Remove from Favorites"], in: app)
        contextItem("Remove from Favorites", in: app).click()
        waitForAbsence(contextItem("Remove from Favorites", in: app))
        XCTAssertTrue(trash.waitForExistence(timeout: 10))
        rightClickInSidebar(trash, in: app)
        assertMenu(["Mark All as Read", "Empty Trash…", "Add to Favorites"], in: app)
        dismissMenu(in: app)

        let hiking = mailbox("ui-audit.Label_1", in: app)
        rightClickInSidebar(hiking, in: app)
        assertMenu(["Mark All as Read", "Add to Favorites", "New Nested Label…", "Edit Label…", "Delete Label…"], in: app)
        contextItem("Add to Favorites", in: app).click()
        waitForAbsence(contextItem("Add to Favorites", in: app))
        // Favorites precede the account's label rows, so firstMatch now selects the shortcut.
        let favorite = mailbox("ui-audit.Label_1", in: app)
        rightClickInSidebar(favorite, in: app)
        assertMenu(["Mark All as Read", "Remove from Favorites", "New Nested Label…", "Edit Label…", "Delete Label…"], in: app)
        contextItem("New Nested Label…", in: app).click()
        let name = app.sheets.textFields["Label name"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.click()
        name.typeText("Trips")
        XCTAssertTrue(app.sheets.buttons["Create"].isEnabled)
        app.sheets.buttons["Cancel"].click()
        waitForAbsence(name)
        XCTAssertTrue(message("Field notes", in: app).exists,
                      "A sidebar context action must preserve the current mailbox.")
    }

    private func launch(singleAccount: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-audit", "--ui-audit-light", "-ApplePersistenceIgnoreState", "YES",
            "-mailConversations", "YES", "-sidebarFavoritesCollapsed", "NO",
            "-sidebarExpandedMailboxes", "", "-hideViewingPane", "NO"]
        if singleAccount { app.launchArguments.append("--ui-audit-cached-reauth") }
        app.launch()
        let window = app.windows.matching(identifier: "main").firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        waitForMessage("Field notes", in: app)
        waitForMessage("Weekend plans", in: app)
        return app
    }

    private func mailbox(_ id: String, in app: XCUIApplication) -> XCUIElement {
        let row = app.descendants(matching: .any).matching(identifier: "sidebar.mailbox." + id).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Missing sidebar mailbox: \(id)")
        return row
    }

    /// Scrolls the sidebar to a row, then right-clicks it. In a short window a
    /// row can sit outside the visible part of the sidebar, and XCUITest
    /// doesn't scroll it into view, so the click would land on whatever the
    /// window shows at the row's center.
    private func rightClickInSidebar(_ row: XCUIElement, in app: XCUIApplication) {
        // The outline's frame covers only its visible part. isHittable can't
        // stand in for this check: it stays true for a row scrolled out of view.
        let sidebar = app.outlines["Sidebar"].firstMatch
        for _ in 0..<5 where !sidebar.frame.contains(row.frame) {
            // A negative delta scrolls toward the end of the sidebar.
            sidebar.scroll(byDeltaX: 0, deltaY: row.frame.midY > sidebar.frame.midY ? -120 : 120)
        }
        XCTAssertTrue(sidebar.frame.contains(row.frame), "The sidebar row is out of view.")
        row.rightClick()
    }

    private func message(_ subject: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", subject)).firstMatch
    }

    @discardableResult
    private func waitForMessage(_ subject: String, in app: XCUIApplication) -> XCUIElement {
        let row = message(subject, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Missing mail row: \(subject)")
        return row
    }

    private func drag(_ source: XCUIElement, to target: XCUIElement) {
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        source.click(forDuration: 0.5, thenDragTo: target)
    }

    private func assertMenu(_ titles: [String], in app: XCUIApplication) {
        for title in titles {
            let item = contextItem(title, in: app)
            XCTAssertTrue(item.waitForExistence(timeout: 5), "Missing context action: \(title)")
            XCTAssertTrue(item.isEnabled, "Unavailable context action: \(title)")
        }
    }

    private func dismissMenu(in app: XCUIApplication) {
        app.typeKey(.escape, modifierFlags: [])
        waitForAbsence(app.windows.matching(identifier: "main").firstMatch.menus.firstMatch)
    }

    private func contextItem(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.windows.matching(identifier: "main").firstMatch.menuItems[title]
    }

    private func waitForAbsence(_ element: XCUIElement) {
        let absent = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [absent], timeout: 10), .completed)
    }
}
