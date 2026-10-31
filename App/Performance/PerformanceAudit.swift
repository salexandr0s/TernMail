#if DEBUG || TERN_PERFORMANCE
import AppKit
import Foundation
import MailStore
import WebKit

/// Opt-in navigation exercise. The caller must have opened the synthetic stores.
@MainActor
enum PerformanceAudit {
    private static var hasRun = false

    struct Scenario: Codable {
        let name: String
        let requestedInteractions: Int
        let completedInteractions: Int
        let failures: Int
        let timings: NavigationPerformance.Report
    }

    struct Report: Encodable {
        let version = 1
        let isOptimizedBuild: Bool
        let syntheticAccountCount: Int
        let fixtureVisibleThreadCount: Int
        let fixtureConfiguredMessagesPerAccount: Int
        let fixtureEventCount: Int
        let scenarios: [Scenario]
        let scrolling: [PerformanceScrollAudit.Result]
        let initialPhysicalFootprintBytes: UInt64?
        let finalPhysicalFootprintBytes: UInt64?
        let limitation: String
    }

    static func runIfRequested(app: AppModel) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard !hasRun, arguments.contains("--performance-audit"), arguments.contains("--ui-audit") else { return }
        hasRun = true
        let ready = await wait(timeout: .seconds(45)) {
            guard let mailbox = app.mailbox else { return false }
            return mailbox.hasSyncedOnce && mailbox.accounts.count == 2 && !mailbox.listItems.isEmpty
                && !app.calendar.events.isEmpty && !app.calendar.isLoading
        }
        guard ready, let mailbox = app.mailbox,
              mailbox.accounts.allSatisfy({ $0.account.id == "ui-audit" || $0.account.id == "ui-audit-2" }) else {
            writeFailure("Synthetic fixture readiness failed; no benchmark actions were performed.")
            return
        }
        guard let window = NSApp.windows.first(where: { $0.isVisible && ($0.contentView?.bounds.width ?? 0) > 600 }) else {
            writeFailure("No visible benchmark window; no measurements were accepted.")
            return
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let initialMemory = NavigationPerformance.physicalFootprint()
        let count = max(100, min(1_000, argumentInteger("--performance-iterations=") ?? 100))
        var scenarios: [Scenario] = []
        var scrolling: [PerformanceScrollAudit.Result] = []
        app.destination = .mail
        mailbox.selectedMailbox = .combined(SystemLabel.inbox)
        _ = await wait { !mailbox.listItems.isEmpty }
        try? await Task.sleep(for: .milliseconds(500))

        scenarios.append(await exercise("workspace-warm", kind: .workspace, count: count) { index in
            app.destination = index.isMultiple(of: 2) ? .calendar : .mail
        })
        app.destination = .mail
        scenarios.append(await exercise("attachments-return", kind: .mailbox, count: count) { index in
            mailbox.selectedMailbox = .combined(index.isMultiple(of: 2) ? AttachmentLibraryModel.mailboxID : SystemLabel.inbox)
        })
        mailbox.selectedMailbox = .combined(SystemLabel.inbox)
        _ = await wait { mailbox.listItems.count >= 2 }
        let rows = mailbox.listItems.filter { $0.id.threadID.hasPrefix("performance-thread-") }.map(\.id)
        if rows.count >= 2 {
            scenarios.append(await exercise("reader-recent", kind: .reader, count: count) { index in
                mailbox.selectListRows([rows[index % 2]])
            })
            let localRows = Array(rows.prefix(count))
            for row in localRows {
                guard !Task.isCancelled, let owner = mailbox.account(id: row.accountID) else { break }
                try? await owner.engine.openThread(row.threadID, markRead: false)
            }
            scenarios.append(await exercise("reader-local", kind: .reader, count: localRows.count, warmup: 0) { index in
                mailbox.selectListRows([localRows[index]])
            })
        }

        if let scroll = scrollView(in: window, surface: .mailbox) {
            scrolling.append(await PerformanceScrollAudit.run(name: "mailbox", scroll: scroll))
        }
        for size in [20, 100] {
            if let long = mailbox.listItems.first(where: { $0.id.threadID == "performance-long-\(size)" }) {
                mailbox.selectListRows([long.id])
                if let generation = NavigationPerformance.shared.currentGeneration(for: .reader) {
                    _ = await NavigationPerformance.shared.waitForCompletion(.reader, generation: generation, timeout: .seconds(15))
                }
                if let scroll = scrollView(in: window, surface: .reader) {
                    scrolling.append(await PerformanceScrollAudit.run(name: "reader-\(size)", scroll: scroll))
                }
            }
        }
        app.destination = .calendar
        try? await Task.sleep(for: .milliseconds(300))
        if let scroll = scrollView(in: window, surface: .calendar) {
            scrolling.append(await PerformanceScrollAudit.run(name: "calendar", scroll: scroll))
        }
        app.destination = .mail
        mailbox.selectedMailbox = .combined(AttachmentLibraryModel.mailboxID)
        try? await Task.sleep(for: .milliseconds(300))
        if let scroll = scrollView(in: window, surface: .attachments) {
            scrolling.append(await PerformanceScrollAudit.run(name: "attachments", scroll: scroll))
        }
        app.destination = .mail
        mailbox.selectedMailbox = .combined(SystemLabel.inbox)
        #if DEBUG
        let optimized = false
        #else
        let optimized = true
        #endif
        let report = Report(isOptimizedBuild: optimized, syntheticAccountCount: mailbox.accounts.count,
                            fixtureVisibleThreadCount: rows.count,
                            fixtureConfiguredMessagesPerAccount: min(60_000, max(200, argumentInteger("--performance-mails=") ?? 1_000)) + 120,
                            fixtureEventCount: app.calendar.events.count,
                            scenarios: scenarios, scrolling: scrolling,
                            initialPhysicalFootprintBytes: initialMemory,
                            finalPhysicalFootprintBytes: NavigationPerformance.physicalFootprint(),
                            limitation: "Navigation ends at a native drawing commit. Scroll results measure main-run-loop display-link delivery, not presented GPU frames. WebKit child-process memory and actual frame hitches require an external profiler.")
        write(report)
    }

    private static func exercise(_ name: String, kind: NavigationInteractionKind, count: Int,
                                 warmup: Int = 6, action: (Int) -> Void) async -> Scenario {
        let performance = NavigationPerformance.shared
        for index in 0..<warmup {
            action(index)
            if let generation = performance.currentGeneration(for: kind) {
                _ = await performance.waitForCompletion(kind, generation: generation)
            }
        }
        performance.reset()
        var failures = 0
        var completed = 0
        for index in 0..<count {
            guard !Task.isCancelled else { failures += count - index; break }
            action(index + warmup)
            guard let generation = performance.currentGeneration(for: kind) else { failures += 1; continue }
            let result = await performance.waitForCompletion(kind, generation: generation)
            if result?.outcome == .visibleCommit { completed += 1 } else { failures += 1 }
            // Stop an uninstrumented scenario rather than spending minutes on timeouts.
            if failures >= 3, completed == 0 { failures += count - index - 1; break }
        }
        return Scenario(name: name, requestedInteractions: count, completedInteractions: completed,
                        failures: failures, timings: performance.report())
    }

    private enum Surface { case mailbox, reader, calendar, attachments }

    private static func scrollView(in window: NSWindow, surface: Surface) -> NSScrollView? {
        guard let root = window.contentView else { return nil }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let candidates = descendants(root).compactMap { $0 as? NSScrollView }.filter { scroll in
            guard !scroll.isHiddenOrHasHiddenAncestor, !scroll.visibleRect.isEmpty,
                  (scroll.documentView?.bounds.height ?? 0) > scroll.contentView.bounds.height + 10 else { return false }
            var view: NSView? = scroll
            while let value = view {
                if value.alphaValue < 0.01 || value is WKWebView { return false }
                view = value.superview
            }
            return true
        }
        if surface == .mailbox {
            return candidates.filter { $0.documentView is NSTableView }.max {
                (($0.documentView as? NSTableView)?.numberOfRows ?? 0) < (($1.documentView as? NSTableView)?.numberOfRows ?? 0)
            }
        }
        return candidates.max { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
    }

    private static func wait(timeout: Duration = .seconds(10), until ready: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !Task.isCancelled, ContinuousClock.now < deadline {
            if ready() { return true }
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return false }
        }
        return false
    }

    private static func argumentInteger(_ prefix: String) -> Int? {
        ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }.flatMap { Int($0.dropFirst(prefix.count)) }
    }

    private static func writeFailure(_ reason: String) { write(["error": reason]) }

    private static func write(_ value: some Encodable) {
        defer {
            if ProcessInfo.processInfo.arguments.contains("--performance-exit") { NSApp.terminate(nil) }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(value)
            let destination = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--performance-output=") }
                .map { URL(fileURLWithPath: String($0.dropFirst("--performance-output=".count))) }
                ?? FileManager.default.temporaryDirectory.appending(path: "Tern-performance-audit.json")
            try data.write(to: destination, options: .atomic)
            print("Tern performance audit: \(destination.path)")
        } catch {
            print("Tern performance audit: report could not be written (\(type(of: error))).")
        }
    }
}
#endif
