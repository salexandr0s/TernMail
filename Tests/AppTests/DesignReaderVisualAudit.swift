import AppKit
import GmailAPI
import MailStore
import MessageContent
import SwiftUI
import Testing
import TernAI
import WebKit
@testable import Tern

/// Opt-in reader captures use synthetic mail and never invoke a write action.
@Suite(.serialized) @MainActor struct DesignReaderVisualAudit {
    private let audit = AssistantResultsVisualAudit()

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERN_ASSISTANT_RESULTS_AUDIT_DIR"] != nil))
    func compactAidsKeepTheOriginalMessageInAShortViewport() async throws {
        try #require(ProcessInfo.processInfo.arguments.contains("--ui-audit"))
        let app = AppModel()
        await app.start()
        let mailbox = try #require(app.mailbox), cache = try #require(app.cache)
        try await waitUntil { mailbox.hasSyncedOnce }
        let key = ThreadKey(accountID: "ui-audit", threadID: "design-reader-\(UUID().uuidString)")
        let sentAt = Date(timeIntervalSince1970: 1_793_606_400)
        let record = MessageRecord(accountID: key.accountID, id: key.threadID, threadID: key.threadID, historyID: 1,
            date: sentAt, snippet: "Please review the revised proposal.", sender: "Alex Morgan <alex@example.invalid>",
            recipients: "UI Audit <audit@example.invalid>", cc: nil, subject: "Revised proposal", sizeEstimate: 800)
        try await cache.write {
            _ = try $0.upsertMessages([.init(record: record, labelIDs: [SystemLabel.inbox])])
            try $0.rebuildThreads([key.threadID], accountID: key.accountID)
        }
        var iterator = cache.thread(accountID: key.accountID, threadID: key.threadID).makeAsyncIterator()
        let detail = try #require(try await iterator.next() ?? nil)
        let message = try #require(detail.messages.first)
        let summary = try JSONDecoder().decode(AssistantSummary.self, from: Data("""
            {"summary":"The revised proposal is ready. Alex needs your feedback before confirming the schedule.",
             "source_ids":[],"decisions":[{"text":"The review will use the revised proposal.","source_ids":[]}],
             "open_tasks":[{"description":"Review the proposal","owner":"You","due_date":"2026-11-05","source_ids":[]}]}
            """.utf8))
        let report = ThreadSummaryReport(summary: summary, sources: [], hasPartialCoverage: true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let suggestions = EmailCalendarModel()
        suggestions.update(messages: [.init(id: message.id, subject: record.subject, date: sentAt,
            text: "We may review the proposal on 5 November at 10:00.", allowsDateDetection: false)],
            addresses: [], timeZone: .gmt, now: sentAt)
        let event = EmailCalendarItem(id: "interpreted:reader-review", messageID: message.id, title: "Proposal review",
            evidence: "We may review the proposal on 5 November at 10:00.", kind: .proposed,
            event: GoogleCalendarEvent(summary: "Proposal review", start: .init(dateTime: "2026-11-05T10:00:00Z"),
                end: .init(dateTime: "2026-11-05T11:00:00Z")), uncertainties: ["Confirm the date with Alex."])
        try #require(suggestions.restoreInterpretation([event], for: suggestions.revision))
        for (width, scheme) in [(420.0, ColorScheme.light), (720.0, .dark)] {
            try await audit.capture(ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                    EmailCalendarSuggestionsView(model: suggestions, calendar: calendar,
                        onReview: { _ in Issue.record("The capture must not review or save an event") },
                        onOpenExisting: { _ in }, onRespond: { _, _ in })
                    ThreadSummaryContent(report: report, detail: detail, isExpanded: .constant(false),
                        onOpenSource: { _ in }, onRefresh: {}, onSettings: {})
                    VStack(spacing: 0) {
                        MessageHeader(message: message, mailbox: mailbox, isExpanded: true,
                            compose: { _ in }, onMarkUnreadFromHere: {}, onToggle: {}) { EmptyView() }
                        Divider()
                        Text("Hello,\n\nPlease review the revised proposal and send your feedback before we confirm the schedule.\n\nThanks,\nAlex")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Tokens.Space.s4)
                    }
                    .background(Tokens.Surface.primary, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                }
                .padding(Tokens.Space.s4)
            }, size: NSSize(width: width, height: 540), scheme: scheme,
                name: "design-reader-compact-\(Int(width))-\(scheme == .dark ? "dark" : "light")",
                inspect: { window, view in
                    let header = try #require(self.element("message-header-" + message.id, in: view))
                    let frame = try #require(header.value(forKey: "accessibilityFrame") as? NSValue).rectValue
                    let contentFrame = window.convertToScreen(window.contentLayoutRect)
                    #expect(contentFrame.contains(frame), "The original message header must be visible without scrolling")
                })
        }
        await app.signOut()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERN_ASSISTANT_RESULTS_AUDIT_DIR"] != nil))
    func plainTextMeasureWrapsAtNarrowAndUltrawideWidths() async throws {
        try #require(ProcessInfo.processInfo.arguments.contains("--ui-audit"))
        let prose = """
        Hello everyone,

        The revised route is ready for review. Please check the equipment list and send your comments before we confirm the plan. Each section should stay comfortable to read when the window grows wider.

          Preserve these two leading spaces.
        \tPreserve this tab and the blank lines.

        Details: https://example.invalid/\(String(repeating: "very-long-path-without-spaces-", count: 12))

        Thanks,
        Alex
        """
        for (width, scale, scheme) in [(360.0, 1.0, ColorScheme.light), (1440.0, 1.0, .light),
                                      (360.0, 2.0, .dark), (1440.0, 2.0, .dark)] {
            let rendered = MessageDocument.render(plainText: prose, policy: .init(textScale: scale))
            #expect(rendered.searchableText == prose)
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
            let web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 720), configuration: configuration)
            let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = web
            window.orderBack(nil)
            defer { web.stopLoading(); window.close() }
            web.loadHTMLString(rendered.html, baseURL: nil)
            try await waitUntil { !web.isLoading && web.url != nil }
            let metrics = try #require(try await web.evaluateJavaScript("""
                (() => {
                    const element = document.querySelector('.tern-plain');
                    const style = getComputedStyle(element);
                    return {width: element.getBoundingClientRect().width, viewport: innerWidth,
                        contentWidth: document.documentElement.scrollWidth,
                        lineHeight: parseFloat(style.lineHeight), fontSize: parseFloat(style.fontSize),
                        maxInlineSize: style.maxInlineSize, whiteSpace: style.whiteSpace,
                        overflowWrap: style.overflowWrap, text: element.textContent};
                })()
                """, in: nil, contentWorld: .defaultClient) as? [String: Any])
            let measuredWidth = try #require(metrics["width"] as? Double)
            let viewport = try #require(metrics["viewport"] as? Double)
            let maxMeasure = try #require(Double((metrics["maxInlineSize"] as? String ?? "").replacingOccurrences(of: "px", with: "")))
            let font = try #require(metrics["fontSize"] as? Double)
            let lineHeight = try #require(metrics["lineHeight"] as? Double)
            #expect(abs(measuredWidth - min(viewport, maxMeasure)) < 1)
            #expect((metrics["contentWidth"] as? Double ?? .infinity) <= viewport + 1)
            #expect(abs(font - 13 * scale) < 0.1)
            #expect(abs(lineHeight / font - 1.45) < 0.01)
            #expect(metrics["whiteSpace"] as? String == "pre-wrap")
            #expect(metrics["overflowWrap"] as? String == "anywhere")
            #expect(metrics["text"] as? String == prose)
            let image = try await web.takeSnapshot(configuration: nil)
            let tiff = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            let name = "design-reader-plain-\(Int(width))-\(Int(scale * 100))-\(scheme == .dark ? "dark" : "light").png"
            Attachment.record(Array(data), named: name)
            let directory = try #require(ProcessInfo.processInfo.environment["TERN_ASSISTANT_RESULTS_AUDIT_DIR"])
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
        }
        let senderHTML = MessageDocument.render(html: "<p style='width:900px;line-height:2'>Sender formatting</p>").html
        #expect(!senderHTML.contains("max-inline-size:75ch"))
        #expect(senderHTML.contains("width:900px;line-height:2"))
        let printed = PrintDocument.render(subject: "Proposal", messages: [
            .init(subject: "Proposal", sender: "Alex", recipients: "You", date: "Today", body: .init(plainText: prose))
        ])
        #expect(!printed.contains("max-inline-size:75ch"))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(30)) }
        try #require(condition())
    }

    private func element(_ identifier: String, in view: NSView) -> NSObject? {
        var seen: Set<ObjectIdentifier> = []
        func visit(_ value: Any) -> NSObject? {
            guard let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return nil }
            func attribute(_ name: String) -> Any? {
                object.responds(to: NSSelectorFromString(name)) ? object.value(forKey: name) : nil
            }
            if attribute("accessibilityIdentifier") as? String == identifier { return object }
            let children = attribute("accessibilityChildren") as? [Any] ?? []
            for child in children + NSAccessibility.unignoredChildren(from: children) + ((object as? NSView)?.subviews ?? []) {
                if let found = visit(child) { return found }
            }
            return nil
        }
        return visit(view)
    }
}
