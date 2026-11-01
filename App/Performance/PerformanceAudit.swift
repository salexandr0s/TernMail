#if DEBUG || TERN_PERFORMANCE
import AppKit
import Foundation
import MailStore
import WebKit

/// Opt-in navigation exercise. The caller must have opened the synthetic stores.
@MainActor
enum PerformanceAudit {
    private static var hasRun = false
    private static weak var auditWindow: NSWindow?

    struct MemorySample: Codable {
        let completedInteractions: Int
        let physicalFootprintBytes: UInt64?
    }

    struct Scenario: Codable {
        let name: String
        let requestedInteractions: Int
        let completedInteractions: Int
        let failures: Int
        let failureReason: String?
        let memorySamples: [MemorySample]
        let timings: NavigationPerformance.Report
    }

    struct Report: Encodable {
        let version = 2
        let isOptimizedBuild: Bool
        let syntheticAccountCount: Int
        let fixtureVisibleThreadCount: Int
        let fixtureConfiguredMessagesPerAccount: Int
        let fixtureEventCount: Int
        let scenarios: [Scenario]
        let scrolling: [PerformanceScrollAudit.Result]
        let mainActorResponsiveness: PerformanceMainThreadAudit.Result
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
        auditWindow = window
        guard await wait(timeout: .seconds(15), until: { isForeground }) else {
            writeFailure("Audit never obtained foreground activation and a key window; no timings were accepted.")
            return
        }
        let heartbeat = PerformanceMainThreadAudit()
        let initialMemory = NavigationPerformance.physicalFootprint()
        let count = max(100, min(1_000, argumentInteger("--performance-iterations=") ?? 100))
        var scenarios: [Scenario] = []
        var scrolling: [PerformanceScrollAudit.Result] = []
        func record(_ scenario: Scenario) {
            scenarios.append(scenario)
            writeProgress(scenarios)
        }
        app.destination = .mail
        mailbox.selectedMailbox = .combined(SystemLabel.inbox)
        _ = await wait { !mailbox.listItems.isEmpty }
        try? await Task.sleep(for: .milliseconds(500))

        record(await exercise("workspace-warm", kind: .workspace, count: count) { index in
            app.destination = index.isMultiple(of: 2) ? .calendar : .mail
        })
        app.destination = .mail
        record(await exercise("attachments-return", kind: .mailbox, count: count) { index in
            mailbox.selectedMailbox = .combined(index.isMultiple(of: 2) ? AttachmentLibraryModel.mailboxID : SystemLabel.inbox)
        })
        mailbox.selectedMailbox = .combined(SystemLabel.inbox)
        _ = await wait { mailbox.listItems.count >= 2 }
        while isForeground, mailbox.listItems.filter({ $0.id.threadID.hasPrefix("performance-thread-") }).count < count + 2 {
            let before = mailbox.listItems.count
            mailbox.loadMoreThreads()
            if !(await wait(timeout: .seconds(2), until: { mailbox.listItems.count > before })) { break }
        }
        let rows = mailbox.listItems.filter { $0.id.threadID.hasPrefix("performance-thread-") }.map(\.id)
        if rows.count >= 2 {
            record(await exercise("reader-recent", kind: .reader, count: count) { index in
                mailbox.selectListRows([rows[index % 2]])
            })
            let localRows = Array(rows.dropFirst(2).prefix(count))
            for row in localRows {
                guard isForeground, !Task.isCancelled, let owner = mailbox.account(id: row.accountID) else { break }
                try? await owner.engine.openThread(row.threadID, markRead: false)
            }
            if localRows.count == count {
                record(await exercise("reader-local", kind: .reader, count: count, warmup: 0) { index in
                    mailbox.selectListRows([localRows[index]])
                })
            } else {
                record(failedScenario("reader-local", count: count, reason: "The requested local-body corpus was not available."))
            }
        } else {
            record(failedScenario("reader-recent", count: count, reason: "Two recent reader fixtures were not available."))
            record(failedScenario("reader-local", count: count, reason: "The local-body corpus was not available."))
        }

        scrolling.append(await measureScroll("mailbox", in: window, surface: .mailbox))
        for size in [20, 100] {
            guard isForeground else {
                scrolling.append(.failure(name: "reader-\(size)", reason: "Foreground activation was lost."))
                continue
            }
            // Explicit fixture identity avoids accidentally omitting a long thread
            // because its row is outside the currently loaded list page.
            mailbox.selectedThreadIDs = [ThreadKey(accountID: "ui-audit", threadID: "performance-long-\(size)")]
            guard let generation = NavigationPerformance.shared.currentGeneration(for: .reader),
                  await NavigationPerformance.shared.waitForCompletion(.reader, generation: generation, timeout: .seconds(15))?.outcome == .visibleCommit else {
                scrolling.append(.failure(name: "reader-\(size)", reason: "Long conversation did not become readable."))
                continue
            }
            scrolling.append(await measureScroll("reader-\(size)", in: window, surface: .reader))
        }
        app.destination = .calendar
        try? await Task.sleep(for: .milliseconds(300))
        scrolling.append(await measureScroll("calendar", in: window, surface: .calendar))
        app.destination = .mail
        mailbox.selectedMailbox = .combined(AttachmentLibraryModel.mailboxID)
        try? await Task.sleep(for: .milliseconds(300))
        scrolling.append(await measureScroll("attachments", in: window, surface: .attachments))
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
                            mainActorResponsiveness: await heartbeat.stop(),
                            initialPhysicalFootprintBytes: initialMemory,
                            finalPhysicalFootprintBytes: NavigationPerformance.physicalFootprint(),
                            limitation: "Navigation ends at a native drawing commit. Scroll results measure main-run-loop display-link delivery, not presented GPU frames. WebKit child-process memory and actual frame hitches require an external profiler.")
        write(report)
    }

    private static func exercise(_ name: String, kind: NavigationInteractionKind, count: Int,
                                 warmup: Int = 6, action: (Int) -> Void) async -> Scenario {
        let performance = NavigationPerformance.shared
        for index in 0..<warmup {
            guard isForeground else { return failedScenario(name, count: count, reason: "Foreground activation was lost.") }
            action(index)
            if let generation = performance.currentGeneration(for: kind) {
                _ = await performance.waitForCompletion(kind, generation: generation)
            }
        }
        performance.reset()
        var failures = 0
        var completed = 0
        var failureReason: String?
        var memory = [MemorySample(completedInteractions: 0, physicalFootprintBytes: NavigationPerformance.physicalFootprint())]
        for index in 0..<count {
            guard isForeground else { failures += count - index; failureReason = "Foreground activation was lost."; break }
            guard !Task.isCancelled else { failures += count - index; break }
            action(index + warmup)
            guard let generation = performance.currentGeneration(for: kind) else { failures += 1; continue }
            let result = await performance.waitForCompletion(kind, generation: generation)
            if result?.outcome == .visibleCommit { completed += 1 } else { failures += 1 }
            if (index + 1).isMultiple(of: 10) {
                memory.append(MemorySample(completedInteractions: completed, physicalFootprintBytes: NavigationPerformance.physicalFootprint()))
            }
            // Stop an uninstrumented scenario rather than spending minutes on timeouts.
            if failures >= 3, completed == 0 { failures += count - index - 1; break }
        }
        return Scenario(name: name, requestedInteractions: count, completedInteractions: completed,
                        failures: failures, failureReason: failureReason, memorySamples: memory, timings: performance.report())
    }

    private static func failedScenario(_ name: String, count: Int, reason: String) -> Scenario {
        NavigationPerformance.shared.reset()
        return Scenario(name: name, requestedInteractions: count, completedInteractions: 0,
                        failures: count, failureReason: reason, memorySamples: [], timings: NavigationPerformance.shared.report())
    }

    private static var isForeground: Bool {
        NSApp.isActive && auditWindow?.isKeyWindow == true && auditWindow?.occlusionState.contains(.visible) == true
    }

    private enum Surface: String { case mailbox, reader, calendar, attachments }

    private static func measureScroll(_ name: String, in window: NSWindow, surface: Surface) async -> PerformanceScrollAudit.Result {
        guard isForeground else { return .failure(name: name, reason: "Foreground activation was lost.") }
        guard let scroll = scrollView(in: window, surface: surface) else {
            return .failure(name: name, reason: "The explicitly identified scrolling surface was missing or had no scrollable content.")
        }
        return await PerformanceScrollAudit.run(name: name, scroll: scroll)
    }

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
        let identifier = NSUserInterfaceItemIdentifier("tern-performance-scroll-" + surface.rawValue)
        let identified = candidates.filter { $0.identifier == identifier }
        return identified.count == 1 ? identified.first : nil
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

    private static var outputURL: URL {
        ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--performance-output=") }
            .map { URL(fileURLWithPath: String($0.dropFirst("--performance-output=".count))) }
            ?? FileManager.default.temporaryDirectory.appending(path: "Tern-performance-audit.json")
    }

    private static func writeProgress(_ scenarios: [Scenario]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(scenarios) {
            try? data.write(to: outputURL.appendingPathExtension("progress.json"), options: .atomic)
        }
    }

    private static func write(_ value: some Encodable) {
        defer {
            if ProcessInfo.processInfo.arguments.contains("--performance-exit") {
                let pause = min(30, max(0, argumentInteger("--performance-memory-pause=") ?? 0))
                Task {
                    if pause > 0 { try? await Task.sleep(for: .seconds(pause)) }
                    NSApp.terminate(nil)
                }
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(value)
            let destination = outputURL
            try data.write(to: destination, options: .atomic)
            print("Tern performance audit: \(destination.path)")
        } catch {
            print("Tern performance audit: report could not be written (\(type(of: error))).")
        }
    }
}
#endif
