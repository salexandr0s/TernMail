import AppKit
import MailStore
import SwiftUI
import Testing
@testable import Tern

@Suite(.serialized) @MainActor struct UnsubscribeInteractionTests {
    @Test func nativeSelection() async throws {
        let store = UnsubscribeTestStore()
        let model = store.makeModel()
        await model.load()
        let context = try avatarContext(store.rows)
        let controller = NSHostingController(rootView: UnsubscribeView(model: model)
            .environment(\.addressAvatarContext, context))
        controller.sizingOptions = []
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1040, height: 760))
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        defer {
            try? capture(controller.view, name: "native-final-state")
            model.stop(); window.close(); window.contentViewController = nil
        }
        try await Task.sleep(for: .milliseconds(200))
        let root = controller.view
        let selectAll = try #require(button("unsubscribe.selectAll", in: root))
        #expect(selectAll.state == .off)
        selectAll.performClick(nil)
        try await unsubscribeEventually { model.selectedCount == 3 && button("unsubscribe.selectAll", in: root)?.state == .on }
        print("UNSUBSCRIBE_NATIVE select-all passed")
        let first = try #require(button("unsubscribe.select." + store.rows[0].id, in: root))
        first.performClick(nil)
        try await unsubscribeEventually { model.selectedCount == 2 && button("unsubscribe.selectAll", in: root)?.state == .mixed }
        print("UNSUBSCRIBE_NATIVE mixed-state passed")
        if ProcessInfo.processInfo.arguments.contains("--unsubscribe-keyboard-live") {
            // XCTest's host cannot reliably activate a window. An operator activates
            // this synthetic window and presses Space using native input instead.
            window.title = "Unsubscribe keyboard audit"
            print("UNSUBSCRIBE_LIVE_ACTIVATE_WINDOW")
            let deadline = ContinuousClock.now.advanced(by: .seconds(60))
            while !window.isKeyWindow && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            try #require(window.isKeyWindow)
            let focusedCheckbox = try #require(button("unsubscribe.selectAll", in: root))
            try #require(window.makeFirstResponder(focusedCheckbox))
            try #require(window.firstResponder === focusedCheckbox)
            print("UNSUBSCRIBE_LIVE_PRESS_SPACE")
            while model.selectedCount != 3 && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            try #require(model.selectedCount == 3)
            try #require(button("unsubscribe.selectAll", in: root)?.state == .on)
            try capture(root, name: "live-keyboard-selected")
            print("UNSUBSCRIBE_NATIVE live keyboard passed")
        }
    }

    @Test func pageLayouts() async throws {
        let store = UnsubscribeTestStore()
        let model = store.makeModel()
        await model.load()
        model.toggleAll()
        let context = try avatarContext(store.rows)
        let controller = NSHostingController(rootView: UnsubscribeView(model: model)
            .environment(\.addressAvatarContext, context))
        controller.sizingOptions = []
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { model.stop(); window.close(); window.contentViewController = nil }
        let root = controller.view
        for (name, width, height, appearance) in [
            ("wide-light-selected", 1040.0, 760.0, NSAppearance.Name.aqua),
            ("compact-light-selected", 720.0, 480.0, NSAppearance.Name.aqua),
            ("wide-dark-selected", 1040.0, 760.0, NSAppearance.Name.darkAqua),
            ("compact-dark-selected", 720.0, 480.0, NSAppearance.Name.darkAqua),
            ("contrast-selected", 720.0, 600.0, NSAppearance.Name.accessibilityHighContrastAqua),
        ] {
            window.appearance = NSAppearance(named: appearance)
            window.setContentSize(NSSize(width: width, height: height))
            try await Task.sleep(for: .milliseconds(120))
            let checkbox = try #require(button("unsubscribe.selectAll", in: root))
            #expect(root.bounds.contains(checkbox.convert(checkbox.bounds, to: root)))
            try capture(root, name: name)
        }
        model.clearSelection()
        window.appearance = NSAppearance(named: .aqua)
        window.setContentSize(NSSize(width: 1040, height: 760))
        try await Task.sleep(for: .milliseconds(100))
        try capture(root, name: "wide-light")
        store.rows[0] = NewsletterSubscription(accountID: "first", senderAddress: "editor@journal.example.invalid",
            senderName: "The Independent Journal of Design, Science, Cities and Everyday Life",
            listID: "a-very-long-monthly-publication.journal.example.invalid", latestMessageID: "long",
            latestThreadID: "long-thread", latestSubject: "A complete guide to making more room for the things you want to read",
            latestDate: .now, messageCount: 1_024_128, mailtoURL: URL(string: "mailto:leave@journal.example.invalid"))
        await model.load()
        window.setContentSize(NSSize(width: 720, height: 600))
        try await Task.sleep(for: .milliseconds(100))
        try capture(root, name: "compact-long-name-fallback")
        model.search = "No matching sender"
        try await Task.sleep(for: .milliseconds(100))
        try capture(root, name: "search-empty")
        #expect(model.visibleSubscriptions.isEmpty)
    }

    @Test func reviewAndManualSheetsRenderAndKeepOutcomesDistinct() async throws {
        let store = UnsubscribeTestStore()
        let model = store.makeModel()
        await model.load()
        model.toggleAll(); model.proposeSelection()
        let confirmation = try #require(model.confirmation)
        try await render(UnsubscribeConfirmationView(model: model, confirmation: confirmation),
            name: "batch-review", width: 528, height: 490)
        model.confirmation = nil
        model.openSubscription(store.rows[2])
        await model.openManualLink()
        let manual = try #require(model.manualSubscription)
        #expect(manual.status == .opened)
        try await render(UnsubscribeManualView(model: model, subscription: manual),
            name: "manual-opened", width: 528, height: 510)
        await model.markManualComplete()
        model.filter = .history
        try await render(UnsubscribeView(model: model), name: "manual-completed", width: 1040, height: 680)
        #expect(model.requestedCount == 0)
        let failed = store.update(store.rows[0].id, status: .failed)
        await model.load()
        model.filter = .active
        try await render(UnsubscribeView(model: model), name: "failed-with-fallback", width: 720, height: 600)
        model.proposeUnsubscribe(failed)
        let retry = try #require(model.confirmation)
        try await render(UnsubscribeConfirmationView(model: model, confirmation: retry),
            name: "retry-review", width: 528, height: 440)
    }

    private func render<V: View>(_ view: V, name: String, width: Double, height: Double) async throws {
        let context = try avatarContext(UnsubscribeTestStore().rows)
        let controller = NSHostingController(rootView: view.environment(\.addressAvatarContext, context))
        controller.sizingOptions = []
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.setContentSize(NSSize(width: width, height: height))
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        defer { window.close(); window.contentViewController = nil }
        try await Task.sleep(for: .milliseconds(120))
        try capture(controller.view, name: name)
    }

    private func button(_ identifier: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.accessibilityIdentifier() == identifier { return button }
        return view.subviews.lazy.compactMap { button(identifier, in: $0) }.first
    }

    private func capture(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        Attachment.record(Array(data), named: "unsubscribe-" + name + ".png")
    }

    private func avatarContext(_ rows: [NewsletterSubscription]) throws -> AddressAvatarContext {
        var profiles: [String: String] = [:]
        let symbols = ["leaf.fill", "sparkle", "mountain.2.fill", "hammer.fill"]
        let colors: [NSColor] = [.systemGreen, .systemIndigo, .systemOrange, .systemBlue]
        for (index, row) in rows.enumerated() {
            let id = "unsubscribe-test-logo-\(index)"
            let image = try #require(NSImage(systemSymbolName: symbols[index % symbols.count], accessibilityDescription: nil))
            let colored = image.withSymbolConfiguration(.init(paletteColors: [colors[index % colors.count]])) ?? image
            AccountProfileImages.shared.setAuditImage(colored, for: id)
            profiles[row.senderAddress] = id
        }
        return AddressAvatarContext(profileAccountIDs: profiles, identity: "unsubscribe-test")
    }
}
