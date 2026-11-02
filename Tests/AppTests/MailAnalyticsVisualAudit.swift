import AppKit
import Foundation
import MailStore
import MessageContent
import SwiftUI
import Testing
@testable import Tern

/// Opt-in captures use synthetic data and attach the shipped views to the test result.
@Suite(.serialized) @MainActor struct MailAnalyticsVisualAudit {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERN_ANALYTICS_VISUAL_AUDIT_DIR"] != nil))
    func renderAnalyticsAndSenderCard() async throws {
        try #require(ProcessInfo.processInfo.arguments.contains("--ui-audit"), "Analytics captures require synthetic accounts")
        let directory = try #require(ProcessInfo.processInfo.environment["TERN_ANALYTICS_VISUAL_AUDIT_DIR"])
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let cache = try MailCache.inMemory()
        let now = Date.now
        let updates = Self.messages(now: now)
        try await cache.write { tx in
            _ = try tx.upsertMessages(updates)
            try tx.upsertAnalyticsMessages(updates)
            try tx.saveBodies([.init(accountID: "analytics-audit", messageID: "m0", html: """
                <p>The revised proposal is attached.</p><div class="gmail_signature">Best,<br>Alex Morgan<br>
                <a href="https://www.linkedin.com/in/alex-morgan-example">LinkedIn</a><br>
                <a href="https://www.linkedin.com/company/alex-morgan-studio">Our studio</a><br>
                <a href="https://www.instagram.com/alex.morgan.example/">Instagram</a><br>
                <a href="https://example.com">Studio website</a></div>
                """, plainText: nil, fetchedAt: now)])
            let draft = LocalDraft(accountID: "analytics-audit", kind: .new,
                content: .init(to: [.init(address: "alex@example.invalid")], subject: "Review of the next project phase",
                               requestsReadReceipt: true), rfcMessageID: "<audit-receipt@example.invalid>", now: now)
            try tx.recordReadReceiptRequest(for: draft, senderAddress: "owner@example.invalid", messageID: "m1", threadID: "t0", sentAt: now)
            try tx.storeReadReceipt(.init(originalMessageID: draft.rfcMessageID, recipient: "alex@example.invalid", disposition: .displayed),
                accountID: "analytics-audit", receiptMessageID: "receipt1", reporter: "alex@example.invalid",
                returnAddresses: ["owner@example.invalid"], receivedAt: now)
        }
        let account = AccountRecord(id: "analytics-audit", email: "owner@example.invalid", displayName: "Personal",
                                    grantedScopes: [], addedAt: now)
        let mailbox = MailboxModel(account: account, cache: cache, gmail: AuditGmail(),
                                   outgoingDirectory: .temporaryDirectory, syncEnabled: false)
        for (name, width, scheme) in [("wide-light", 880.0, ColorScheme.light),
                                      ("breakpoint-light", 760.0, .light), ("narrow-dark", 560.0, .dark)] {
            try await capture(MailAnalyticsWorkspace(route: .init(), mailbox: mailbox),
                size: NSSize(width: width, height: 800), scheme: scheme, waitFor: "Chart",
                name: "analytics-\(name)", captureBottom: true)
        }
        let sections: [(String, MailAnalyticsSection, String)] = [
            ("contacts", .people, "Alex Morgan"),
            ("receipts", .receipts, "Receipt received"),
            ("history-paused", .history, "Mail sync is paused")
        ]
        for (name, section, expected) in sections {
            try await capture(MailAnalyticsWorkspace(route: .init(), mailbox: mailbox, section: section),
                size: NSSize(width: 880, height: 800), scheme: .light, waitFor: expected,
                name: "analytics-\(name)-wide-light", captureBottom: true)
            try await capture(MailAnalyticsWorkspace(route: .init(), mailbox: mailbox, section: section),
                size: NSSize(width: 560, height: 480), scheme: .dark, waitFor: expected,
                name: "analytics-\(name)-narrow-dark", captureBottom: true)
        }
        try await capture(MailAnalyticsWorkspace(route: .init(accountID: account.id,
            address: "alex@example.invalid", name: "Alex Morgan"), mailbox: mailbox, section: .people),
            size: NSSize(width: 560, height: 680), scheme: .dark, waitFor: "linkedin.com/in/alex-morgan-example",
            name: "sender-profile-narrow-dark", captureBottom: true)

        let previousYear = try #require(Calendar.current.date(byAdding: .year, value: -1, to: now))
        let olderMessage = MailAnalyticsMessage(accountID: account.id, messageID: "older", threadID: "t0",
            date: previousYear, subject: "Planning the next project phase",
            sender: "Alex Morgan <alex@example.invalid>", direction: .received)
        try await capture(AnalyticsRecentMessagesView(messages: [olderMessage], mailbox: mailbox)
            .padding(Tokens.Space.s5), size: NSSize(width: 400, height: 220), scheme: .light,
            waitFor: "Planning the next project phase", name: "recent-email-previous-year", captureBottom: false)
        let snapshot = try await cache.mailAnalytics(query: .init(accountIDs: [account.id], period: .year, now: now))
        let largeSnapshot = MailAnalyticsSnapshot(sentCount: snapshot.sentCount * 50_000,
            receivedCount: snapshot.receivedCount * 50_000, threadCount: snapshot.threadCount * 50_000,
            firstReceivedAt: snapshot.firstReceivedAt, firstSentAt: snapshot.firstSentAt, lastContactAt: snapshot.lastContactAt,
            bucketUnit: snapshot.bucketUnit, buckets: snapshot.buckets.map {
                MailAnalyticsBucket(date: $0.date, sentCount: $0.sentCount * 50_000, receivedCount: $0.receivedCount * 50_000)
            }, coverage: [.init(accountID: account.id, indexedMessageCount: snapshot.totalCount * 50_000)])
        try await capture(AnalyticsMetricsView(snapshot: largeSnapshot, period: .year).padding(Tokens.Space.s6),
            size: NSSize(width: 560, height: 360), scheme: .light, waitFor: "Conversations",
            name: "metrics-large-counts-narrow", captureBottom: false)
        let selected = snapshot.buckets.first(where: { $0.receivedCount > 0 })?.date
        try await capture(AnalyticsActivityChart(snapshot: snapshot, selectedDate: selected).padding(Tokens.Space.s6),
            size: NSSize(width: 880, height: 560), scheme: .light, waitFor: "Chart",
            name: "chart-selected-month", captureBottom: false)
        try await capture(AnalyticsActivityChart(snapshot: largeSnapshot, selectedDate: selected).padding(Tokens.Space.s6),
            size: NSSize(width: 560, height: 560), scheme: .dark, waitFor: "Chart",
            name: "chart-selected-narrow", captureBottom: false)
        try await capture(AnalyticsActivityChart(snapshot: snapshot, showsTable: true).padding(Tokens.Space.s6),
            size: NSSize(width: 560, height: 560), scheme: .dark, waitFor: "Values",
            name: "chart-values-month", captureBottom: true)
        let daily = Self.chartSnapshot(now: now, days: 90, sparse: false)
        try await capture(AnalyticsActivityChart(snapshot: daily, selectedDate: daily.buckets[42].date).padding(Tokens.Space.s6),
            size: NSSize(width: 880, height: 560), scheme: .light, waitFor: "Chart",
            name: "chart-dense-daily", captureBottom: false)
        let sparse = Self.chartSnapshot(now: now, days: 30, sparse: true)
        try await capture(AnalyticsActivityChart(snapshot: sparse).padding(Tokens.Space.s6),
            size: NSSize(width: 560, height: 560), scheme: .dark, waitFor: "Chart",
            name: "chart-sparse-daily", captureBottom: false)
        try await capture(MailAnalyticsWorkspace(route: .init(accountID: account.id,
                address: "alex@example.invalid", name: "Alex Morgan"), mailbox: mailbox),
            size: NSSize(width: 880, height: 950), scheme: .light, waitFor: "Chart",
            name: "sender-analytics", captureBottom: true)
        for scheme in [ColorScheme.light, .dark] {
            try await capture(SenderProfilePopover(accountID: account.id, address: "alex@example.invalid",
                name: "  Alex Morgan with a longer display name  ", mailbox: mailbox),
                size: NSSize(width: 400, height: 520), scheme: scheme, waitFor: "linkedin.com/in/alex-morgan-example",
                name: "sender-card-\(scheme == .light ? "light" : "dark")", captureBottom: true)
            try await capture(SenderProfilePopover(accountID: account.id, address: "jordan@example.invalid",
                name: "Jordan Lee", mailbox: mailbox),
                size: NSSize(width: 400, height: 440), scheme: scheme, waitFor: "No links in available signatures",
                name: "sender-card-no-links-\(scheme == .light ? "light" : "dark")", captureBottom: false)
        }
        try await capture(MailAnalyticsWorkspace(route: .init(accountID: account.id,
                address: "new-contact@example.invalid", name: "New contact"), mailbox: mailbox),
            size: NSSize(width: 560, height: 950), scheme: .light, waitFor: "No email in this period",
            name: "analytics-empty-narrow", captureBottom: true)
        let emptySections: [(String, MailAnalyticsSection, String)] = [
            ("profile", .people, "No links in available signatures"),
            ("receipts", .receipts, "No receipt requests yet"),
            ("history", .history, "No indexed email yet")
        ]
        for (name, section, expected) in emptySections {
            try await capture(MailAnalyticsWorkspace(route: .init(accountID: account.id,
                address: "new-contact@example.invalid", name: "New contact"), mailbox: mailbox, section: section),
                size: NSSize(width: 560, height: 680), scheme: .light, waitFor: expected,
                name: "analytics-empty-\(name)", captureBottom: true)
        }
        let emptyMailbox = MailboxModel(account: account, cache: try MailCache.inMemory(), gmail: AuditGmail(),
            outgoingDirectory: .temporaryDirectory, syncEnabled: false)
        try await capture(MailAnalyticsWorkspace(route: .init(), mailbox: emptyMailbox, section: .people),
            size: NSSize(width: 560, height: 480), scheme: .dark, waitFor: "No contacts in this period",
            name: "analytics-empty-contacts", captureBottom: false)
        await emptyMailbox.stop()

        try await cache.write { tx in
            let state = try tx.beginAnalyticsHistory(accountID: account.id)
            _ = try tx.commitAnalyticsHistoryPage(state, updates: updates, missing: [], nextPageToken: nil, loadedAt: now)
        }
        try await capture(MailAnalyticsWorkspace(route: .init(), mailbox: mailbox, section: .history),
            size: NSSize(width: 560, height: 680), scheme: .dark, waitFor: "History scanned",
            name: "analytics-history-scanned", captureBottom: false)
        let loadingMailbox = MailboxModel(account: account, cache: cache, gmail: AuditGmail(),
            outgoingDirectory: .temporaryDirectory)
        let historyModel = MailAnalyticsModel { owner, _ in
            try await Task.sleep(for: .seconds(30))
            return MailAnalyticsCoverage(accountID: owner.account.id, indexedMessageCount: 0, isComplete: true)
        }
        defer { historyModel.stop() }
        try await capture(AnalyticsHistoryView(snapshot: snapshot, model: historyModel, owners: loadingMailbox.accounts)
            .padding(Tokens.Space.s6), size: NSSize(width: 560, height: 440), scheme: .light,
            waitFor: "Partial history", name: "analytics-history-partial", captureBottom: false)
        historyModel.loadHistory(accounts: loadingMailbox.accounts, restart: false)
        try await capture(AnalyticsHistoryView(snapshot: snapshot, model: historyModel, owners: loadingMailbox.accounts)
            .padding(Tokens.Space.s6), size: NSSize(width: 560, height: 440), scheme: .dark,
            waitFor: "Loading mail history", name: "analytics-history-loading", captureBottom: false)
        historyModel.stop()
        await loadingMailbox.stop()

        let receipt = ReadReceiptStatus(accountID: account.id, rfcMessageID: "<large-receipt@example.invalid>",
            messageID: nil, threadID: nil, subject: "Project review", sentAt: now,
            recipients: (1...18).map { index in
                ReadReceiptRecipientStatus(address: index == 1
                    ? "alexander.morgan.with.a.long.address@example.invalid" : "colleague\(index)@example.invalid",
                    receivedAt: index.isMultiple(of: 3) ? now : nil)
            })
        for scheme in [ColorScheme.light, .dark] {
            try await capture(ReadReceiptDetails(status: receipt), size: NSSize(width: 320, height: 440),
                scheme: scheme, waitFor: "6 of 18 receipts received",
                name: "receipt-details-\(scheme == .light ? "light" : "dark")", captureBottom: true)
        }
        await mailbox.stop()
    }

    nonisolated private static func messages(now: Date) -> [CacheTransaction.MessageUpdate] {
        (0..<90).map { index in
            let sent = index % 3 == 1
            let contact = index % 10 < 6 ? "Alex Morgan <alex@example.invalid>"
                : index % 10 < 9 ? "Jordan Lee <jordan@example.invalid>" : "Casey Park <casey@example.invalid>"
            return .init(record: .init(accountID: "analytics-audit", id: "m\(index)", threadID: "t\(index / 3)", historyID: 1,
                date: now.addingTimeInterval(-Double(index) * 86_400 * 3), snippet: "",
                sender: sent ? "Owner <owner@example.invalid>" : contact,
                recipients: sent ? contact : "owner@example.invalid", cc: nil,
                subject: index == 0 ? "Project proposal and planning for the next season" : "Project update \(index + 1)",
                sizeEstimate: 300), labelIDs: [sent ? SystemLabel.sent : SystemLabel.inbox])
        }
    }

    nonisolated private static func chartSnapshot(now: Date, days: Int, sparse: Bool) -> MailAnalyticsSnapshot {
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: now)
        let buckets = (0..<days).map { index in
            MailAnalyticsBucket(date: calendar.date(byAdding: .day, value: index - days + 1, to: today) ?? today,
                sentCount: sparse ? (index == 20 ? 1 : 0) : (index * 3 + 1) % 9,
                receivedCount: sparse ? (index == 6 ? 1 : 0) : (index * 7 + 4) % 17)
        }
        return MailAnalyticsSnapshot(sentCount: buckets.reduce(0) { $0 + $1.sentCount },
            receivedCount: buckets.reduce(0) { $0 + $1.receivedCount }, threadCount: 0,
            bucketUnit: .day, buckets: buckets)
    }

    private func capture<Content: View>(_ content: Content, size: NSSize, scheme: ColorScheme, waitFor: String,
                                       name: String, captureBottom: Bool) async throws {
        let suite = "MailAnalyticsVisualAudit.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: DomainLogoImages.preferenceKey)
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = NSHostingController(rootView: content
            .defaultAppStorage(defaults)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        window.contentViewController = controller
        window.setContentSize(size)
        window.center()
        window.orderFront(nil)
        defer { window.close() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !contains(waitFor, in: controller.view), ContinuousClock.now < deadline {
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
        controller.view.layoutSubtreeIfNeeded()
        try await attach(window, name: name + ".png")
        #expect(contains(waitFor, in: controller.view), "Expected content did not appear; inspect the attached capture.")
        if captureBottom, let scroll = firstScrollView(in: controller.view), let document = scroll.documentView {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(100))
            controller.view.layoutSubtreeIfNeeded()
            try await attach(window, name: name + "-bottom.png")
        }
    }

    private func attach(_ window: NSWindow, name: String) async throws {
        try await Task.sleep(for: .milliseconds(80))
        let data = try await NativeWindowCapture.png(of: window)
        let directory = try #require(ProcessInfo.processInfo.environment["TERN_ANALYTICS_VISUAL_AUDIT_DIR"])
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
        Attachment.record(Array(data), named: name)
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { firstScrollView(in: $0) }.first
    }

    private func contains(_ text: String, in object: Any) -> Bool {
        var seen = Set<ObjectIdentifier>()
        func visit(_ item: Any) -> Bool {
            guard let object = item as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return false }
            func value(_ key: String) -> Any? {
                object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
            }
            if [value("accessibilityValue"), value("accessibilityLabel")].contains(where: {
                ($0 as? String)?.contains(text) == true
            }) { return true }
            let children = value("accessibilityChildren") as? [Any] ?? []
            let views = (object as? NSView)?.subviews ?? []
            return (children + NSAccessibility.unignoredChildren(from: children)).contains(where: visit)
                || views.contains(where: visit)
        }
        return visit(object)
    }
}
