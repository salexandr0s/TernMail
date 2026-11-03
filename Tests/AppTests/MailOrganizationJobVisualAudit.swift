import AppKit
import Foundation
import GmailAPI
import SwiftUI
import Testing
import TernAI
@testable import SyncEngine
@testable import Tern

@Suite(.serialized) @MainActor struct MailOrganizationJobVisualAudit {
    @Test(.enabled(if: ProcessInfo.processInfo.arguments.contains("--organization-job-audit")))
    func renderOrganizationJobStates() async throws {
        for (width, scheme) in [(520.0, ColorScheme.light), (760.0, .dark)] {
            let suffix = "\(Int(width))-\(scheme == .dark ? "dark" : "light")"
            try await capture(ScrollView {
                MailOrganizationIntroduction(maximumMessages: .constant(5_000), canAnalyze: true,
                    requirement: nil, onAnalyze: {}, onOpenSettings: { _ in }).padding(Tokens.Space.s5)
            }, width: width, scheme: scheme, name: "intro-\(suffix)", actionID: "organization.analyze")
            for stage in width == 760 ? [OrganizationAnalysisProgress.Stage.discovering, .consolidating, .auditing] : [] {
                try await capture(ScrollView {
                    loading(stage: stage).padding(Tokens.Space.s5)
                }, width: width, scheme: scheme, name: "\(stage.rawValue)-\(suffix)", actionID: "organization.cancel")
            }
            try await capture(ScrollView {
                loading(stage: .auditing, paused: true).padding(Tokens.Space.s5)
            }, width: width, scheme: scheme, name: "paused-\(suffix)", actionID: "organization.resume")
        }
        print("ORGANIZATION_JOB_AUDIT_DIR: \(outputDirectory.path)")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.arguments.contains("--organization-job-audit")))
    func renderCompactSelections() async throws {
        for width in [520.0, 760.0] {
            for scheme in [ColorScheme.light, .dark] {
                let model = try await fixture()
                let suffix = "\(Int(width))-\(scheme == .dark ? "dark" : "light")"
                try await capture(MailOrganizationExperience(model: model, canCreateFilters: true),
                    width: width, scheme: scheme, name: "compact-defaults-\(suffix)", actionID: "organization.apply",
                    captureBottom: true, inspect: { view in
                        #expect(find("PRIVATE_MAIL_", in: view, needsPress: false) == nil)
                        for id in ["news", "receipts", "action"] { try await press("organization.category.\(id).backfill", in: view) }
                        #expect(model.selectedMessageCount == 0 && model.selectedFilterCount == 2 && model.canApply)
                        try attach(view, name: "compact-rules-only-\(suffix)")
                        for id in ["news", "receipts"] { try await press("organization.category.\(id).future", in: view) }
                        #expect(model.selectedCount == 0 && !model.canApply)
                        try attach(view, name: "compact-both-off-\(suffix)")
                        try await press("organization.category.news.backfill", in: view)
                        #expect(!model.categories[0].createsFilter && model.selectedMessageCount == 4 && model.canApply)
                        try attach(view, name: "compact-backfill-only-\(suffix)")
                        if width == 520, scheme == .light {
                            model.setAllSuggestionsSelected(false)
                            try await Task.sleep(for: .milliseconds(250))
                            try await press("organization.category.receipts.future", in: view)
                            #expect(model.categories[1].createsFilter && !model.categories[1].backfillExisting)
                            #expect(model.selectedCount == 1 && model.selectedMessageCount == 0 && model.canApply)
                            model.categories[1].name = "Reading/Newsletters"
                            try await Task.sleep(for: .milliseconds(500))
                            view.layoutSubtreeIfNeeded()
                            #expect(!model.categories[1].createsFilter && !model.categories[1].isSelected)
                            #expect(model.selectedCount == 0 && !model.canApply)
                            try attach(view, name: "compact-renamed-covered-\(suffix)")
                        }
                    })
            }
        }
        let narrow = try await fixture()
        try await capture(MailOrganizationExperience(model: narrow, canCreateFilters: true), width: 420,
                          scheme: .light, name: "compact-defaults-420-light", actionID: "organization.apply")
        for scheme in [ColorScheme.light, .dark] {
            let empty = try await fixture(empty: true)
            try await capture(MailOrganizationExperience(model: empty, canCreateFilters: true), width: 520,
                              scheme: scheme, name: "empty-520-\(scheme == .dark ? "dark" : "light")")
        }
        print("ORGANIZATION_JOB_AUDIT_DIR: \(outputDirectory.path)")
    }

    private func loading(stage: OrganizationAnalysisProgress.Stage, paused: Bool = false) -> some View {
        MailOrganizationLoadingView(phase: paused ? .paused : .analyzing, progress: nil,
            analysisProgress: .init(stage: stage, completedBatches: 7, totalBatches: 20, analyzedCount: 1_750),
            startedAt: nil, sampleCount: 5_000, scanMaximumMessages: 5_000, onResume: {}, onCancel: {})
    }

    private func fixture(empty: Bool = false) async throws -> MailOrganizationModel {
        let label = try JSONDecoder().decode(GmailLabel.self,
            from: Data(#"{"id":"Label_news","name":"Reading/Newsletters","type":"user"}"#.utf8))
        let filters = [
            GmailFilter(id: "rule-exact", criteria: .init(from: "publisher@example.invalid"),
                action: .init(addLabelIds: [label.id], removeLabelIds: ["INBOX"])),
            GmailFilter(id: "rule-compound", criteria: .init(from: "digest@example.invalid", subject: "Weekly digest",
                query: #"category:updates ("research notes" OR "product news")"#, negatedQuery: "unsubscribe",
                hasAttachment: true, excludeChats: true, size: 10_240, sizeComparison: .larger),
                action: .init(addLabelIds: [label.id], forward: "archive@example.invalid")),
            GmailFilter(id: "rule-receipts", criteria: .init(from: "receipts@example.invalid"),
                action: .init(addLabelIds: [label.id]))
        ]
        let messages: [MailOrganizationSample] = empty ? [] : (1...7).map { index in
            let sender = index <= 2 ? "publisher@example.invalid" : index <= 4 ? "alerts@example.invalid"
                : index <= 6 ? "receipts@example.invalid" : "colleague@example.invalid"
            return .init(messageID: "m\(index)", threadID: "t\(index)", sender: sender,
                recipients: ["reader@example.invalid"], subject: "PRIVATE_MAIL_SUBJECT_\(index)", snippet: "PRIVATE_MAIL_PREVIEW_\(index)",
                date: Date(timeIntervalSince1970: 1_793_664_000 + Double(index)), isSent: false,
                labelIDs: index <= 2 ? [label.id] : [], hasMailingListHeaders: index <= 6)
        }
        let samples = MailOrganizationSamples(accountID: "visual", messages: messages, existingLabels: [label],
            selectedCount: messages.count, unavailableCount: 0, isPartial: false, existingFilters: filters, filterContextAvailable: true)
        let plan = OrganizationPlan(categories: empty ? [] : [.init(id: "news", name: label.name,
            explanation: "Regular publications and product updates fit the reading label you already use.", kind: .topic,
            messageIDs: ["m1", "m2", "m3", "m4"], ruleSenders: ["publisher@example.invalid", "alerts@example.invalid"], existingLabelID: label.id),
            .init(id: "receipts", name: "Receipts", explanation: "Purchase confirmations arrive from a consistent automated sender.",
                  kind: .topic, messageIDs: ["m5", "m6"], ruleSenders: ["receipts@example.invalid"]),
            .init(id: "action", name: "Action", explanation: "An incoming request is waiting for your response.",
                  kind: .action, messageIDs: ["m7"], ruleSenders: [])], analyzedCount: messages.count)
        let model = MailOrganizationModel(access: {
            .init(accountID: "visual", instanceID: "synthetic", permissionRevision: 1, connectionRevision: 1,
                  modelID: "synthetic", mailAccessEnabled: true, canCreateFilters: true)
        }, readSamples: { _, _, _ in samples }, analyze: { _, _, _ in
            if empty { Issue.record("An empty mailbox must not start AI analysis.") }
            return plan
        },
            apply: { _, _, _ in throw CancellationError() }, status: { _ in
                .init(pendingCount: 0, sentCount: 0, failedCount: 0, unconfirmedCount: 0)
            })
        model.startAnalysis()
        await model.waitForOperation()
        try #require(model.phase == .review && model.canApply == !empty)
        return model
    }

    private var outputDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("TernOrganizationJobAudit", isDirectory: true)
    }

    private func capture<Content: View>(_ content: Content, width: Double, scheme: ColorScheme, name: String,
                                      actionID: String? = nil, captureBottom: Bool = false,
                                      inspect: (@MainActor (NSView) async throws -> Void)? = nil) async throws {
        let controller = NSHostingController(rootView: content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Tokens.Surface.primary).environment(\.colorScheme, scheme))
        controller.sizingOptions = []
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.setContentSize(NSSize(width: width, height: 860))
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(250))
        controller.view.layoutSubtreeIfNeeded()
        if let actionID { #expect(find(actionID, in: controller.view) != nil) }
        #expect(controller.view.bounds.width == width && controller.view.bounds.height > 0)
        try attach(controller.view, name: name)
        if captureBottom, let scroll = scrollView(in: controller.view), let document = scroll.documentView {
            #expect(document.bounds.width <= scroll.contentView.bounds.width + 1)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(100))
            controller.view.layoutSubtreeIfNeeded()
            try attach(controller.view, name: name + "-bottom")
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(100))
        }
        try await inspect?(controller.view)
    }

    private func press(_ identifier: String, in view: NSView) async throws {
        let control = try #require(find(identifier, in: view))
        let selector = NSSelectorFromString("accessibilityPerformPress")
        let implementation = try #require(control.method(for: selector))
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        // AppKit declares this public accessibility method as -(BOOL)accessibilityPerformPress.
        #expect(unsafeBitCast(implementation, to: Press.self)(control, selector))
        try await Task.sleep(for: .milliseconds(500))
        view.layoutSubtreeIfNeeded()
    }

    private func attach(_ view: NSView, name: String) throws {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        Attachment.record(Array(data), named: "organization-" + name + ".png")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try data.write(to: outputDirectory.appendingPathComponent(name + ".png"))
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        (view as? NSScrollView) ?? view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }

    private func find(_ identifier: String, in root: Any, needsPress: Bool = true) -> NSObject? {
        var seen = Set<ObjectIdentifier>()
        func visit(_ item: Any) -> NSObject? {
            guard let object = item as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return nil }
            func value(_ key: String) -> Any? {
                object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
            }
            if [value("accessibilityIdentifier"), value("accessibilityLabel"), value("accessibilityValue")].contains(where: {
                ($0 as? String)?.contains(identifier) == true
            }), !needsPress || object.responds(to: NSSelectorFromString("accessibilityPerformPress")) { return object }
            let children = value("accessibilityChildren") as? [Any] ?? []
            for child in children + NSAccessibility.unignoredChildren(from: children) + ((object as? NSView)?.subviews ?? []) {
                if let result = visit(child) { return result }
            }
            return nil
        }
        return visit(root)
    }
}
