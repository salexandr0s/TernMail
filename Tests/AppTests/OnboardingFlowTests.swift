import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Tern

@Suite @MainActor
struct OnboardingFlowTests {
    /// Hosted rendering covers supported sizes; TernUITests exercises the
    /// controls through macOS accessibility, and auth has focused unit suites.
    @Test func allStepsRenderWithMultipleAccountsAtSupportedSizes() async throws {
        let suite = "tern.tests.onboarding.render.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppModel()
        app.onboarding.resolve(hasExistingAccounts: false)
        await app.start()
        for _ in 0..<100 {
            if app.mailbox?.accounts.count == 2 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(app.mailbox?.accounts.count == 2)
        #expect(app.onboarding.isPresented)

        let host = NSHostingView(rootView: OnboardingView(preferenceDefaults: defaults).environment(app))
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1000, height: 680),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        for step in OnboardingState.Step.allCases {
            app.onboarding.step = step
            window.appearance = NSAppearance(named: .aqua)
            try await settle(host)
            try capture(host, name: step.rawValue)
        }
        app.onboarding.step = .preferences
        window.setContentSize(NSSize(width: 720, height: 480))
        window.appearance = NSAppearance(named: .accessibilityHighContrastDarkAqua)
        try await settle(host)
        #expect(host.fittingSize.width <= 720)
        #expect(host.fittingSize.height <= 480)
        try capture(host, name: "preferences-compact-dark")
        #expect(app.assistant.enabledAccountIDs.isEmpty)
        #expect(app.assistant.connection.account == nil)
        await app.prepareToQuit()
        await app.mailbox?.stop()
    }

    private func settle(_ view: NSView) async throws {
        try await Task.sleep(for: .milliseconds(300))
        view.layoutSubtreeIfNeeded()
    }

    private func capture(_ view: NSView, name: String) throws {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        Attachment.record(Array(data), named: "tern-onboarding-\(name).png")
    }
}
