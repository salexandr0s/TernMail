import AppKit
import Foundation
import SwiftUI
import TernAI
import Testing
@testable import SyncEngine
@testable import Tern

/// Opt-in captures drive the shipped workflow with local, synthetic model closures.
@Suite(.serialized) @MainActor struct MailOrganizationDesignVisualAudit {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERN_ORGANIZATION_VISUAL_AUDIT_DIR"] != nil))
    func renderWorkflowStates() async throws {
        let directory = try outputDirectory()
        for (theme, width, dark) in [("wide-light", 880.0, false), ("narrow-dark", 492.0, true)] {
            let fixture = Fixture()
            let model = fixture.makeModel()
            let host = Host(MailOrganizationExperience(model: model, canCreateFilters: true), width: width, dark: dark)
            defer { host.close(); model.clear() }
            try await host.waitFor("Start with your recent mail")
            try await host.capture("introduction-\(theme)", to: directory, bottom: true)
            model.startAnalysis()
            await model.waitForOperation()
            try await host.waitUntil { host.element("organization.category.news.selected") != nil }
            try await host.capture("review-\(theme)", to: directory, bottom: true)
            host.expectVisible("organization.apply")
            model.categories[0].name = "Research / Product, engineering, and customer experience newsletters"
            model.categories[1].name = "INBOX"
            try await host.capture("review-long-invalid-\(theme)", to: directory, bottom: false)
            #expect(!model.canApply)
            model.categories[1].name = "Action"
            model.applySelection()
            await model.waitForOperation()
            try await host.waitFor("Changes queued for Gmail")
            try await host.capture("queued-\(theme)", to: directory, bottom: false)
            fixture.delivery = .init(pendingCount: 2, sentCount: 3, failedCount: 1, unconfirmedCount: 1)
            await model.refreshDelivery()
            try await host.waitFor("Some changes need attention")
            try await host.capture("delivery-attention-\(theme)", to: directory, bottom: false)
            fixture.delivery = .init(pendingCount: 0, sentCount: 7, failedCount: 0, unconfirmedCount: 0)
            await model.refreshDelivery()
            try await host.waitFor("Your labels are in Gmail")
            try await host.capture("complete-\(theme)", to: directory, bottom: true)
            #expect(fixture.applicationCount == 1)
        }
        for (name, partial, empty, fails) in [("partial", true, false, false),
                                             ("empty", false, true, false), ("analysis-error", false, false, true)] {
            let fixture = Fixture(partial: partial, empty: empty, fails: fails)
            let model = fixture.makeModel()
            model.startAnalysis()
            await model.waitForOperation()
            let host = Host(MailOrganizationExperience(model: model, canCreateFilters: true), width: 492, dark: false)
            defer { host.close(); model.clear() }
            try await host.waitFor(fails ? "Couldn't analyze" : empty ? "No clear suggestions yet" : "Some messages were unavailable")
            try await host.capture(name, to: directory, bottom: true)
        }
        let requirementFixture = Fixture()
        let requirementModel = requirementFixture.makeModel()
        let requirement = MailOrganizationRequirement(message: "Connect ChatGPT to find labels that fit your mail.", destination: .assistant)
        let requirementHost = Host(MailOrganizationExperience(model: requirementModel, canCreateFilters: false,
            requirement: requirement), width: 492, dark: true)
        defer { requirementHost.close(); requirementModel.clear() }
        try await requirementHost.waitFor("Connect ChatGPT")
        try await requirementHost.capture("connection-required", to: directory, bottom: true)
        for phase in [MailOrganizationModel.Phase.reading, .analyzing, .applying] {
            let fixture = Fixture(pause: phase)
            let model = fixture.makeModel()
            model.startAnalysis()
            if phase == .applying { await model.waitForOperation(); model.applySelection() }
            let host = Host(MailOrganizationExperience(model: model, canCreateFilters: true), width: 492, dark: false)
            defer { host.close(); model.clear() }
            try await host.waitUntil { model.phase == phase }
            let name = phase == .reading ? "reading" : phase == .analyzing ? "analyzing" : "applying"
            try await host.capture(name, to: directory, bottom: false)
            if phase != .applying {
                try host.press("organization.cancel")
                try await host.waitUntil { model.phase == .idle }
                #expect(model.samples == nil && model.categories.isEmpty)
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERN_ORGANIZATION_VISUAL_AUDIT_DIR"] != nil))
    func focusedCategoryRetainsChoicesWhenResized() async throws {
        let directory = try outputDirectory()
        let fixture = Fixture()
        let model = fixture.makeModel()
        model.startAnalysis()
        await model.waitForOperation()
        var opened: MailOrganizationSample?
        let host = Host(MailOrganizationExperience(model: model, canCreateFilters: true,
            onOpenMessage: { opened = $0 }), width: 880, dark: false)
        defer { host.close(); model.clear() }
        try await host.waitUntil { host.element("organization.category.news.selected") != nil }
        try host.press("organization.category.action.review")
        try await host.waitUntil { host.element("organization.category.action.selected") != nil }
        try host.press("organization.category.action.selected")
        #expect(!model.categories[1].isSelected)
        host.resize(width: 492)
        try await host.waitUntil { host.element("organization.categoryPicker") != nil }
        host.expectVisible("organization.category.action.selected")
        host.expectVisible("organization.apply")
        try await host.capture("focused-category-narrow", to: directory, bottom: false)
        host.resize(width: 880)
        try await host.waitUntil { host.element("organization.category.news.review") != nil }
        try host.press("organization.category.news.review")
        try await host.waitUntil { host.element("organization.category.news.selected") != nil }
        host.scroll(bottom: true)
        try await host.settle()
        try host.press(label: "Include Weekly research 4")
        #expect(!model.categories[0].selectedMessageIDs.contains("m4"))
        #expect(!model.categories[0].createsFilter)
        try host.press(label: "Open Weekly research 4")
        #expect(opened?.messageID == "m4" && opened?.threadID == "t4")
        host.expectVisible("organization.apply")
        try await host.capture("message-excluded-source-opened", to: directory, bottom: true)
        #expect(fixture.applicationCount == 0)
    }

    private func outputDirectory() throws -> URL {
        try #require(ProcessInfo.processInfo.arguments.contains("--ui-audit"), "Organization captures require synthetic accounts")
        let path = try #require(ProcessInfo.processInfo.environment["TERN_ORGANIZATION_VISUAL_AUDIT_DIR"])
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @MainActor private final class Fixture {
        let samples: MailOrganizationSamples
        let empty: Bool
        let fails: Bool
        let pause: MailOrganizationModel.Phase?
        var applicationCount = 0
        var delivery = OrganizationApplicationStatus(pendingCount: 5, sentCount: 2, failedCount: 0, unconfirmedCount: 0)

        init(partial: Bool = false, empty: Bool = false, fails: Bool = false, pause: MailOrganizationModel.Phase? = nil) {
            self.empty = empty; self.fails = fails; self.pause = pause
            var messages: [MailOrganizationSample] = []
            for index in 1...12 {
                let isNewsletter: Bool = index <= 8
                let sender: String = isNewsletter ? "research@example.invalid" : "alex.morgan@example.invalid"
                let subject: String = isNewsletter ? "Weekly research \(index)" : "Project review \(index)"
                let timestamp: TimeInterval = 1_790_000_000 - Double(index) * 86_400
                let message = MailOrganizationSample(messageID: "m\(index)", threadID: "t\(index)",
                    sender: sender, recipients: ["owner@example.invalid"], subject: subject,
                    snippet: "Product and engineering notes for the next release, including the proposed schedule and review decisions.",
                    date: Date(timeIntervalSince1970: timestamp), isSent: index > 10,
                    labelIDs: [], hasMailingListHeaders: isNewsletter)
                messages.append(message)
            }
            samples = MailOrganizationSamples(accountID: "organization-audit", messages: messages,
                existingLabels: [], selectedCount: partial ? 14 : 12, unavailableCount: partial ? 2 : 0, isPartial: partial)
        }

        func makeModel() -> MailOrganizationModel {
            let empty = empty
            let pausesAnalysis = pause == .analyzing
            return MailOrganizationModel(access: {
                .init(accountID: "organization-audit", instanceID: "synthetic", permissionRevision: 1,
                    connectionRevision: 1, modelID: "synthetic", mailAccessEnabled: true, canCreateFilters: true)
            }, readSamples: { _, _, progress in
                if self.fails { throw AIProviderError.network }
                await progress(.init(stage: .reading, processedCount: 6, selectedCount: 12))
                if self.pause == .reading { try await Task.sleep(for: .seconds(30)) }
                return self.samples
            }, analyze: { _, _, _ in
                if pausesAnalysis { try await Task.sleep(for: .seconds(30)) }
                return empty ? .init(categories: [], analyzedCount: 12) : Self.plan
            }, apply: { categories, _, _ in
                self.applicationCount += 1
                if self.pause == .applying { try await Task.sleep(for: .seconds(30)) }
                return OrganizationApplicationReceipt(accountID: "organization-audit", actionIDs: [1, 2, 3, 4, 5, 6, 7],
                    categoryCount: categories.count, messageCount: Set(categories.flatMap(\.messageIDs)).count,
                    filterCount: categories.filter(\.createFilter).flatMap(\.ruleSenders).count,
                    actions: ActionReceipt(actions: []))
            }, status: { _ in self.delivery })
        }

        nonisolated private static var plan: OrganizationPlan {
            .init(categories: [
                .init(id: "news", name: "Research newsletters", explanation: "Recurring product and engineering updates from one publisher.",
                    kind: .topic, messageIDs: (1...8).map { "m\($0)" }, ruleSenders: ["research@example.invalid"]),
                .init(id: "action", name: "Action", explanation: "Incoming project reviews that ask for a response.",
                    kind: .action, messageIDs: ["m9", "m10"], ruleSenders: []),
                .init(id: "waiting", name: "Waiting", explanation: "Sent requests awaiting a reply.",
                    kind: .waiting, messageIDs: ["m11", "m12"], ruleSenders: [])
            ], analyzedCount: 12)
        }
    }

    @MainActor private final class Host {
        let window: NSWindow
        private let controller: NSHostingController<AnyView>
        private var requestedSize: NSSize
        private var elements: [WorkspaceAuditAccessibility.Element] {
            WorkspaceAuditAccessibility.elements(in: controller.view)
        }
        init<Content: View>(_ content: Content, width: CGFloat, dark: Bool) {
            requestedSize = NSSize(width: width, height: 720)
            controller = NSHostingController(rootView: AnyView(content
                .background(Tokens.Surface.canvas).environment(\.colorScheme, dark ? .dark : .light)))
            controller.sizingOptions = []
            window = NSWindow(contentRect: NSRect(origin: .zero, size: requestedSize),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentViewController = controller
            window.setContentSize(requestedSize)
            window.center(); window.makeKeyAndOrderFront(nil)
        }
        func close() { window.contentViewController = nil; window.close() }
        func resize(width: CGFloat) { requestedSize.width = width; window.setContentSize(requestedSize) }
        func settle() async throws {
            controller.view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }
        func waitUntil(_ ready: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            repeat { try await settle() } while !ready() && ContinuousClock.now < deadline
            try #require(ready(), "The Organization view did not become ready")
        }
        func waitFor(_ text: String) async throws {
            try await waitUntil {
                self.elements.contains { element in
                    if element.label?.contains(text) == true { return true }
                    guard element.object.responds(to: NSSelectorFromString("accessibilityValue")) else { return false }
                    return (element.object.value(forKey: "accessibilityValue") as? String)?.contains(text) == true
                }
            }
        }
        func element(_ identifier: String) -> WorkspaceAuditAccessibility.Element? {
            elements.first { $0.identifier == identifier }
        }
        func expectVisible(_ identifier: String) {
            guard let item = element(identifier) else { Issue.record("Missing control: \(identifier)"); return }
            #expect(item.isVisible(in: window), "\(identifier) must fit inside \(window.contentLayoutRect); frame: \(item.frame(in: window))")
        }
        func press(_ identifier: String) throws {
            let item = try #require(element(identifier))
            try #require(item.isVisible(in: window) && item.supportsPress && item.press())
        }
        func press(label: String) throws {
            let item = try #require(elements.first { $0.label == label && $0.supportsPress })
            try #require(item.isVisible(in: window) && item.press())
        }
        func scroll(bottom: Bool) {
            func scrollView(in view: NSView) -> NSScrollView? {
                if let scroll = view as? NSScrollView { return scroll }
                return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
            }
            guard let scroll = scrollView(in: controller.view), let document = scroll.documentView else { return }
            let offset = max(0, document.bounds.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom == document.isFlipped ? offset : 0))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        func capture(_ name: String, to directory: URL, bottom: Bool) async throws {
            scroll(bottom: false)
            try await save(name, to: directory)
            if bottom { scroll(bottom: true); try await save(name + "-bottom", to: directory) }
        }
        private func save(_ name: String, to directory: URL) async throws {
            try await settle()
            #expect(abs(window.contentLayoutRect.width - requestedSize.width) <= 1)
            #expect(abs(window.contentLayoutRect.height - requestedSize.height) <= 1)
            let data = try await NativeWindowCapture.png(of: window)
            try data.write(to: directory.appendingPathComponent(name + ".png"))
            Attachment.record(Array(data), named: name + ".png")
        }
    }
}
