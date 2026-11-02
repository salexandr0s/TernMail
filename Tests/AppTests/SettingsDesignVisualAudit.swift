import AppKit
import GmailAPI
import MailStore
import MessageContent
import SwiftUI
import Testing
@testable import Tern

/// Actual Settings routes and native editors, with only in-memory accounts and GET-only local responses.
@Suite(.serialized) @MainActor struct SettingsDesignVisualAudit {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERN_SETTINGS_DESIGN_AUDIT_DIR"] != nil))
    func renderSettingsDestinations() async throws {
        try #require(ProcessInfo.processInfo.arguments.contains("--ui-audit"), "Settings captures require synthetic accounts")
        try #require(ProcessInfo.processInfo.arguments.contains("--ui-audit-calendar"), "Calendar settings captures require the local management service")
        let directory = try #require(ProcessInfo.processInfo.environment["TERN_SETTINGS_DESIGN_AUDIT_DIR"])
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let suite = "SettingsDesignVisualAudit.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let standard = UserDefaults.standard
        let savedDestination = standard.object(forKey: SettingsDestination.storageKey)
        let savedSource = standard.object(forKey: SignatureSource.storageKey)
        defer {
            standard.set(savedDestination, forKey: SettingsDestination.storageKey)
            standard.set(savedSource, forKey: SignatureSource.storageKey)
            defaults.removePersistentDomain(forName: suite)
        }
        defaults.set(SignatureSource.local.rawValue, forKey: SignatureSource.storageKey)
        defaults.set(false, forKey: DomainLogoImages.preferenceKey)
        let app = AppModel()
        await app.start()
        defer { Task { await app.signOut() } }
        let mailbox = try #require(app.mailbox)
        let deadline = ContinuousClock.now + .seconds(6)
        while (!mailbox.hasSyncedOnce || mailbox.accounts.count < 2), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(mailbox.hasSyncedOnce && mailbox.accounts.count == 2)
        try await seed(app)
        app.settingsClientForAudit = { Self.localClient($0) }

        for destination in SettingsDestination.allCases {
            let host = SettingsCaptureHost(app: app, defaults: defaults, destination: destination)
            defer { host.close() }
            try await host.waitForContent(Self.expectedContent(destination))
            try await host.capture("\(destination.rawValue)-light", directory: directory)
            if destination == .calendar {
                try host.selectSegment(label: "Assistant & Scheduling")
                try await host.waitForContent("Assistant access to")
                try await host.capture("calendar-scheduling-light", directory: directory)
            }
            if destination == .profiles {
                try host.press(label: "Assign accounts to Work")
                try await host.waitForContent("Nickname")
            }
            if destination == .reading || destination == .messageList || destination == .writing {
                host.scrollDetailToBottom()
                try await host.waitForContent(destination == .reading ? "Show Mail in Spotlight"
                    : destination == .writing ? "Show full recipient addresses" : "Label visibility")
                try await host.capture("\(destination.rawValue)-lower-light", directory: directory)
            }
        }

        defaults.set(1.5, forKey: ReadingPreferences.textScaleKey)
        defaults.set(false, forKey: ReadingPreferences.adaptDarkKey)
        defaults.set(ComposeFont.serif.rawValue, forKey: ComposePreferences.fontKey)
        defaults.set(DeleteKeyBehavior.trash.rawValue, forKey: MailTriagePreferences.deleteKey)
        defaults.set(AttachmentOpenLocation.downloads.rawValue, forKey: AttachmentOpenLocation.key)
        for destination in [SettingsDestination.general, .mailActions, .attachments, .suggestions,
                            .reading, .messageList, .writing, .accountPreferences, .profiles, .calendar] {
            let host = SettingsCaptureHost(app: app, defaults: defaults, destination: destination,
                size: NSSize(width: 740, height: 500), scheme: .dark)
            defer { host.close() }
            let expected = switch destination {
            case .general: "Undo Send delay"
            case .suggestions: "Email address to hide"
            case .reading: "Sample message"
            case .messageList: "Message list preview"
            case .calendar: "Revert"
            default: Self.expectedContent(destination)
            }
            try await host.waitForContent(expected)
            try await host.capture("\(destination.rawValue)-narrow-dark", directory: directory)
        }
        defaults.set(SignatureSource.gmail.rawValue, forKey: SignatureSource.storageKey)
        let gmailSignature = SettingsCaptureHost(app: app, defaults: defaults, destination: .signatures)
        try await gmailSignature.waitForContent("Gmail signature")
        try await gmailSignature.capture("signatures-gmail-light", directory: directory)
        gmailSignature.close()
        defaults.set(SignatureSource.local.rawValue, forKey: SignatureSource.storageKey)

        try await captureEditors(app: app, defaults: defaults, directory: directory)
        try await captureShortcuts(defaults: defaults, directory: directory)
        app.settingsClientForAudit = { _ in nil }
        let unavailable = SettingsCaptureHost(app: app, defaults: defaults, destination: .filters)
        try await unavailable.waitForContent("Gmail settings unavailable")
        try await unavailable.capture("filters-unavailable-light", directory: directory)
        unavailable.close()
        app.settingsClientForAudit = { id in Self.localClient(id, fails: true) }
        let failed = SettingsCaptureHost(app: app, defaults: defaults, destination: .filters, scheme: .dark)
        try await failed.waitForContent("Couldn't load Gmail settings")
        try await failed.capture("filters-load-error-dark", directory: directory)
        failed.close()
        app.settingsClientForAudit = nil
        await app.signOut()
    }

    private func seed(_ app: AppModel) async throws {
        let store = try #require(app.settingsAccountStore)
        let accounts = try await store.accounts()
        for account in accounts {
            try await store.updateAccount(id: account.id) { $0.enabledFeatures.append(AccountFeature.gmailSettings.rawValue) }
        }
        try await store.saveComposeTemplate(.init(id: "design-template", name: "Project follow-up",
            document: ComposeDocument(plainText: "Thanks for the review. Here are the next steps we agreed on.")))
        try await store.saveLocalSignature(.init(id: "design-signature", name: "Work signature",
            document: ComposeDocument(plainText: "Alex Morgan\nDesign team")))
        try await store.saveMailProfile(.init(id: "design-profile", name: "Work · Product and Engineering",
            notificationSchedule: .weekdays([
                DailyTimeRange(startMinute: 9 * 60, endMinute: 12 * 60),
                DailyTimeRange(startMinute: 13 * 60, endMinute: 17 * 60)
            ])))
        try await store.setSuggestionBlocked(true, address: "old-project@example.invalid", accountID: "ui-audit")
        await app.accountPreferences?.refresh()
        await app.accountPreferences?.update("ui-audit") {
            $0.nickname = "Alexandria Morgan · Product, Research and Engineering"
        }
        await app.calendar.seedCalendarAudit()
        let ownedCalendar = try #require(app.calendar.calendars.first { $0.entry.accessRole == "owner" })
        _ = try await app.calendar.shares(ownedCalendar)
    }

    private func captureEditors(app: AppModel, defaults: UserDefaults, directory: String) async throws {
        let profiles = SettingsCaptureHost(app: app, defaults: defaults, destination: .profiles)
        defer { profiles.close() }
        try await profiles.waitForContent("Edit Work · Product and Engineering")
        try profiles.press(label: "Edit Work · Product and Engineering")
        try await profiles.waitForSheet(containing: "Save Changes")
        let profileSheet = try #require(profiles.window.sheets.first)
        try await profiles.capture("profile-editor-hours-light", directory: directory, window: profileSheet)
        profiles.close()

        let assistant = SettingsCaptureHost(content: AnyView(AssistantSettingsView(model: app.assistant, isSheet: true)
            .environment(app).modifier(AddressAvatarEnvironment(app: app))),
            size: NSSize(width: 560, height: 400), scheme: .dark)
        defer { assistant.close() }
        try await assistant.waitForContent("Continue with ChatGPT")
        try await assistant.waitForContent("Done")
        try await assistant.capture("assistant-settings-sheet-short-dark", directory: directory)
        assistant.scrollDetailToBottom()
        try await assistant.waitForContent("Clear Chat")
        try await assistant.capture("assistant-settings-sheet-privacy-short-dark", directory: directory)
        assistant.close()

        let templates = SettingsCaptureHost(app: app, defaults: defaults, destination: .templates)
        defer { templates.close() }
        try await templates.waitForContent("Save Template")
        let name = try #require(templates.nativeViews.compactMap { $0 as? NSTextField }
            .first { $0.isEditable && $0.placeholderString == "Template name" })
        let editor = try #require(templates.nativeViews.compactMap { $0 as? ComposeTextView }.first)
        name.selectText(nil)
        let fieldEditor = try #require(templates.window.fieldEditor(false, for: name) as? NSTextView)
        fieldEditor.insertText("A thoughtful follow-up after the project review", replacementRange: NSRange(location: 0, length: fieldEditor.string.utf16.count))
        try #require(templates.window.makeFirstResponder(editor))
        editor.insertText("Hi Jordan,\n\nThanks for walking through the proposal. I have collected our next steps below.\n\nAlex",
            replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try await templates.waitForContent("Unsaved changes")
        try await templates.capture("templates-unsaved-draft-light", directory: directory)
        templates.close()

        let model = SettingsModel(accountID: "ui-audit", app: app)
        await model.load()
        try #require(model.hasLoaded)
        model.error = "The selected forwarding address is no longer verified. Choose another verified address, or remove forwarding and keep the other actions. Your filter has not been saved."
        let filter = GmailFilter(id: "design-edit", criteria: .init(from: "project-updates@example.invalid", subject: "Weekly project review"),
            action: .init(addLabelIds: ["STARRED"], removeLabelIds: ["INBOX"]))
        let editorHost = SettingsCaptureHost(content: AnyView(FilterEditorSheet(model: model, original: filter)),
            size: NSSize(width: 560, height: 480), scheme: .dark)
        defer { editorHost.close() }
        try await editorHost.waitForContent("Save Filter")
        try await editorHost.waitForContent("Your filter has not been saved")
        try await editorHost.capture("filter-editor-error-dark", directory: directory)

        let preferences = MessageListPreferences(defaults: defaults)
        preferences.density = .compact
        preferences.showsImportance = true
        let compact = SettingsCaptureHost(content: AnyView(MessageListSettingsView(mailbox: app.mailbox, preferences: preferences)
            .defaultAppStorage(defaults)), size: NSSize(width: 532, height: 600), scheme: .light)
        defer { compact.close() }
        try await compact.waitForContent("Density")
        try await compact.capture("message-list-compact-preview-light", directory: directory)
    }

    private func captureShortcuts(defaults: UserDefaults, directory: String) async throws {
        defaults.set(false, forKey: SingleKeyShortcuts.settingKey)
        let wide = SettingsCaptureHost(content: AnyView(KeyboardShortcutsView().defaultAppStorage(defaults)),
            size: NSSize(width: 880, height: 700), scheme: .light)
        defer { wide.close() }
        try await wide.waitForContent("Search keyboard shortcuts")
        try await wide.capture("keyboard-shortcuts-light", directory: directory)
        wide.close()

        let narrow = SettingsCaptureHost(content: AnyView(KeyboardShortcutsView().defaultAppStorage(defaults)),
            size: NSSize(width: 480, height: 600), scheme: .dark)
        defer { narrow.close() }
        try await narrow.waitForContent("Search keyboard shortcuts")
        try narrow.enterText("new", placeholder: "Search commands")
        try await narrow.waitForContent("Outside the Assistant window")
        try await narrow.waitForContent("New Chat")
        try await narrow.capture("keyboard-shortcuts-search-narrow-dark", directory: directory)
        try narrow.enterText("command shift reply", placeholder: "Search commands")
        try await narrow.waitForContent("Reply All")
        try await narrow.capture("keyboard-shortcuts-named-keys-narrow-dark", directory: directory)
        try narrow.enterText("single-key", placeholder: "Search commands")
        try await narrow.toggleSwitch(identifier: "shortcuts.singleKeys")
        try await narrow.waitForContent("Next Conversation")
        #expect(defaults.bool(forKey: SingleKeyShortcuts.settingKey))
        try await narrow.capture("keyboard-shortcuts-enabled-narrow-dark", directory: directory)
        try narrow.enterText("no-matching-shortcut", placeholder: "Search commands")
        try await narrow.waitForContent("No Results")
        try await narrow.capture("keyboard-shortcuts-empty-narrow-dark", directory: directory)
        try narrow.press(label: "Clear shortcut search")
        try await narrow.waitForContent("New Message")
    }

    private static func expectedContent(_ destination: SettingsDestination) -> String {
        switch destination {
        case .general: "View all keyboard shortcuts"
        case .mailActions: "Delete key action"
        case .notifications: "Notification action"
        case .connections: "Add Account"
        case .accountPreferences: "Nickname"
        case .profiles: "Add Profile"
        case .reading: "Text size"
        case .messageList: "Density"
        case .attachments: "Open attachments from"
        case .writing: "New messages from"
        case .templates: "Save Template"
        case .signatures: "Save Signature"
        case .suggestions: "Show old-project@example.invalid in recipient suggestions"
        case .organizeMail: "Open Assistant Settings"
        case .filters: "Add Filter"
        case .blocked: "Unblock blocked-sender@example.invalid"
        case .vacation: "Save vacation responder"
        case .calendar: "Event notifications"
        case .assistant: "Continue with ChatGPT"
        case .failedChanges: "Changes that Gmail can't save will appear here."
        case .maintenance: "Refresh Size"
        }
    }

    private static func localClient(_ accountID: String, fails: Bool = false) -> GmailClient {
        GmailClient(tokens: SettingsAuditTokens(), transport: SettingsAuditTransport(
            address: accountID == "ui-audit" ? "audit@example.invalid" : "second@example.invalid", fails: fails), retryDelays: [])
    }
}

@MainActor private final class SettingsCaptureHost {
    let window: NSWindow
    private let controller: NSHostingController<AnyView>
    var nativeViews: [NSView] { descendants(controller.view) }

    convenience init(app: AppModel, defaults: UserDefaults, destination: SettingsDestination,
                     size: NSSize = NSSize(width: 1_000, height: 800), scheme: ColorScheme = .light) {
        SettingsNavigationRequests.shared.request(destination)
        self.init(content: AnyView(SettingsView().environment(app).modifier(AddressAvatarEnvironment(app: app))
            .defaultAppStorage(defaults)), size: size, scheme: scheme)
    }

    init(content: AnyView, size: NSSize, scheme: ColorScheme) {
        controller = NSHostingController(rootView: AnyView(content.environment(\.colorScheme, scheme)))
        controller.sizingOptions = []
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentViewController = controller
        window.setContentSize(size)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        for sheet in window.sheets { window.endSheet(sheet); sheet.close() }
        window.contentViewController = nil
        window.close()
    }

    func waitForContent(_ expected: String) async throws {
        let deadline = ContinuousClock.now + .seconds(6)
        repeat { try await settle() } while element(label: expected) == nil && ContinuousClock.now < deadline
        try #require(element(label: expected) != nil, "Expected visible page content/control: \(expected)")
    }

    func waitForSheet(containing label: String) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        repeat {
            try await settle()
            if let sheet = window.sheets.first, element(label: label, window: sheet) != nil { return }
        } while ContinuousClock.now < deadline
        Issue.record("Expected a presented sheet with visible control: \(label)")
        throw CancellationError()
    }

    func press(label: String) throws {
        try performPress(element(label: label))
    }

    func toggleSwitch(identifier: String) async throws {
        let control = try #require(element(identifier: identifier) as? NSSwitch,
                                   "Expected native switch \(identifier)")
        try #require(isVisible(control, in: window) && control.isEnabled,
                     "The \(identifier) switch must be visible and enabled")
        let action = try #require(control.action)
        let newState: NSControl.StateValue = control.state == .off ? .on : .off
        // The native switch's AX press returns false in this host. Dispatch its
        // target/action with the toggled control value; the caller checks the binding.
        control.state = newState
        try #require(control.sendAction(action, to: control.target), "The switch must dispatch its native action")
        try await settle()
        #expect(control.state == newState)
    }

    func selectSegment(label: String) throws {
        let control = try #require(nativeViews.compactMap { $0 as? NSSegmentedControl }.first { control in
            (0..<control.segmentCount).contains { control.label(forSegment: $0) == label }
        }, "Expected native segmented control containing \(label)")
        let segment = try #require((0..<control.segmentCount).first { control.label(forSegment: $0) == label })
        try #require(isVisible(control, in: window) && control.isEnabled && control.isEnabled(forSegment: segment),
                     "The \(label) segment must be visible and enabled")
        // AppKit's segment AX proxy rejects performPress here. Use the control's
        // native selection and target/action, then verify the destination content.
        control.selectedSegment = segment
        try #require(control.sendAction(control.action, to: control.target), "The segment must dispatch its native action")
        #expect(control.selectedSegment == segment)
    }

    private func performPress(_ target: NSObject?) throws {
        let object = try #require(target)
        let selector = NSSelectorFromString("accessibilityPerformPress")
        try #require(object.responds(to: selector))
        let implementation = try #require(object.method(for: selector))
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        try #require(unsafeBitCast(implementation, to: Press.self)(object, selector))
    }

    func enterText(_ text: String, placeholder: String) throws {
        let field = try #require(nativeViews.compactMap { $0 as? NSTextField }
            .first { $0.isEditable && $0.placeholderString == placeholder })
        field.selectText(nil)
        let editor = try #require(window.fieldEditor(false, for: field) as? NSTextView)
        editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    }

    func scrollDetailToBottom() {
        for scroll in nativeViews.compactMap({ $0 as? NSScrollView }) where scroll.bounds.width > Tokens.Settings.sidebarWidth {
            guard let document = scroll.documentView else { continue }
            let y = document.isFlipped ? max(0, document.bounds.height - scroll.contentView.bounds.height) : 0
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    func capture(_ name: String, directory: String, window target: NSWindow? = nil) async throws {
        try await settle()
        target?.contentView?.layoutSubtreeIfNeeded()
        target?.displayIfNeeded()
        let data = try await NativeWindowCapture.png(of: target ?? window)
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        Attachment.record(Array(data), named: name + ".png")
    }

    private func settle() async throws {
        controller.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
    }

    private func element(label: String? = nil, identifier: String? = nil, window target: NSWindow? = nil) -> NSObject? {
        let targetWindow = target ?? window
        var seen = Set<ObjectIdentifier>()
        func visit(_ value: Any) -> NSObject? {
            guard let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return nil }
            if let view = object as? NSView, view.isHiddenOrHasHiddenAncestor { return nil }
            let strings = ["accessibilityLabel", "accessibilityValue", "title", "stringValue"].compactMap { property($0, of: object) as? String }
            let matchesLabel = label.map { label in strings.contains { $0.localizedStandardContains(label) } } ?? false
            let matchesIdentifier = identifier.map { property("accessibilityIdentifier", of: object) as? String == $0 } ?? false
            if (matchesLabel || matchesIdentifier), isVisible(object, in: targetWindow) { return object }
            let children = property("accessibilityChildren", of: object) as? [Any] ?? []
            for child in children + NSAccessibility.unignoredChildren(from: children) + ((object as? NSView)?.subviews ?? []) {
                if let found = visit(child) { return found }
            }
            return nil
        }
        return visit(targetWindow.contentView ?? controller.view)
    }

    private func property(_ key: String, of object: NSObject) -> Any? {
        object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
    }

    private func isVisible(_ object: NSObject, in target: NSWindow) -> Bool {
        if let view = object as? NSView {
            return view.window === target && !view.visibleRect.isEmpty
                && view.convert(view.visibleRect, to: nil).intersects(target.contentLayoutRect)
        }
        if let value = property("accessibilityFrame", of: object) as? NSValue {
            let frame = value.rectValue
            return !frame.isEmpty && frame.intersects(target.convertToScreen(target.contentLayoutRect))
        }
        return false
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
}

private struct SettingsAuditTokens: AccessTokenProvider {
    func accessToken(forceRefresh: Bool) async throws -> String { "local-settings-fixture" }
}

private actor SettingsAuditTransport: HTTPTransport {
    let address: String
    let fails: Bool
    init(address: String, fails: Bool) { self.address = address; self.fails = fails }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard request.httpMethod == "GET", let url = request.url else { throw URLError(.unsupportedURL) }
        let body: [String: Any]
        switch url.path {
        case "/gmail/v1/users/me/settings/filters":
            body = ["filter": [
                ["id": "design-rule", "criteria": ["from": "project-updates@example.invalid", "subject": "Weekly review"],
                 "action": ["addLabelIds": ["STARRED"], "removeLabelIds": ["INBOX"]]],
                ["id": "design-block", "criteria": ["from": "blocked-sender@example.invalid"],
                 "action": ["addLabelIds": ["TRASH"]]]]]
        case "/gmail/v1/users/me/settings/forwardingAddresses":
            body = ["forwardingAddresses": [["forwardingEmail": "archive@example.invalid", "verificationStatus": "accepted"]]]
        case "/gmail/v1/users/me/settings/vacation":
            body = ["enableAutoReply": true, "responseSubject": "Thanks for your message",
                    "responseBodyHtml": "<p>I am away this week and will reply when I return.</p>", "restrictToContacts": false]
        case "/gmail/v1/users/me/settings/sendAs":
            body = ["sendAs": [["sendAsEmail": address, "displayName": "Alex Morgan", "isPrimary": true, "isDefault": true,
                "signature": "<p><b>Alex Morgan</b><br>Product and Engineering</p>"]]]
        default: throw URLError(.unsupportedURL)
        }
        let response = try #require(HTTPURLResponse(url: url, statusCode: fails ? 403 : 200, httpVersion: nil, headerFields: nil))
        let payload: [String: Any] = fails
            ? ["error": ["code": 403, "message": "Synthetic permission failure"] as [String: Any]] : body
        return (try JSONSerialization.data(withJSONObject: payload), response)
    }
}
