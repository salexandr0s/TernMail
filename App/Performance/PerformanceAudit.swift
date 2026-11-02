#if DEBUG || TERN_PERFORMANCE
import AppKit
import Foundation
import MailStore
import WebKit

/// Opt-in navigation exercise. The caller must have opened the synthetic stores.
@MainActor
enum PerformanceAudit {
    private enum Scope: String {
        case all
        case workspaceOnly = "workspace-only"
        case readerOnly = "reader-only"
    }

    private static var hasRun = false
    private static var unexpectedNativeInputEvents = 0
    private static weak var auditWindow: NSWindow?
    private static var auditCache: MailCache?
    private static var keyViewLoopBeforeAudit: Bool?
    private static var keyViewLoopDuringAudit: Bool?

    struct MemorySample: Codable {
        let completedInteractions: Int
        let physicalFootprintBytes: UInt64?
        let preparedDocumentBytes: Int
        let attachedReaderWebViews: Int
        let storedContent: CacheUsage?
    }

    struct Scenario: Codable {
        let name: String
        let requestedInteractions: Int
        let completedInteractions: Int
        let failures: Int
        let failureReason: String?
        let memorySamples: [MemorySample]
        var transportAtStart: PerformanceAuditTransport.Statistics?
        var transportAtEnd: PerformanceAuditTransport.Statistics?
        let timings: NavigationPerformance.Report
    }

    struct Report: Encodable {
        let version = 4
        let unexpectedNativeInputEvents: Int
        let buildRevision: String
        let requestedScenario: String
        let automaticKeyViewLoopBeforeAudit: Bool?
        let automaticKeyViewLoopDuringAudit: Bool?
        let isOptimizedBuild: Bool
        let syntheticAccountCount: Int
        let fixtureVisibleThreadCount: Int
        let fixtureConfiguredMessagesPerAccount: Int
        let fixtureEventCount: Int
        let imageCorpora: [AuditGmail.ImageCorpus]
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
        let scopeName = arguments.first { $0.hasPrefix("--performance-scenario=") }
            .map { String($0.dropFirst("--performance-scenario=".count)) } ?? "all"
        guard let scope = Scope(rawValue: scopeName) else {
            writeFailure("Unsupported performance scenario; no benchmark actions were performed.")
            return
        }
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
        auditCache = mailbox.cache
        let originalKeyViewLoop = window.autorecalculatesKeyViewLoop
        keyViewLoopBeforeAudit = originalKeyViewLoop
        if arguments.contains("--performance-fixed-key-loop") { window.autorecalculatesKeyViewLoop = false }
        keyViewLoopDuringAudit = window.autorecalculatesKeyViewLoop
        defer { window.autorecalculatesKeyViewLoop = originalKeyViewLoop }
        if let startArgument = arguments.first(where: { $0.hasPrefix("--performance-start-file=") }) {
            let startPath = String(startArgument.dropFirst("--performance-start-file=".count))
            let readinessURL = outputURL.appendingPathExtension("setup.json")
            guard (startPath as NSString).isAbsolutePath,
                  URL(fileURLWithPath: startPath).standardizedFileURL.resolvingSymlinksInPath()
                    != readinessURL.standardizedFileURL.resolvingSymlinksInPath(),
                  !FileManager.default.fileExists(atPath: startPath) else {
                writeFailure("The explicit setup sentinel must be an absent absolute path; no measurements were started.")
                return
            }
            do {
                let state = try JSONSerialization.data(withJSONObject: [
                    "pid": ProcessInfo.processInfo.processIdentifier,
                    "waitingForStart": true, "timeoutSeconds": 90
                ], options: [.prettyPrinted, .sortedKeys])
                try state.write(to: readinessURL, options: .atomic)
            } catch {
                writeFailure("Setup readiness could not be published; no measurements were started.")
                return
            }
            guard await wait(timeout: .seconds(90), until: { FileManager.default.fileExists(atPath: startPath) }) else {
                writeFailure("Explicit setup release timed out or was cancelled; no measurements were started.")
                return
            }
        }
        guard await wait(timeout: .seconds(15), until: { auditMayContinue }) else {
            writeFailure("Audit never obtained foreground activation and a key window; no timings were accepted.")
            return
        }
        unexpectedNativeInputEvents = 0
        let inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel
        ]) { event in
            MainActor.assumeIsolated { unexpectedNativeInputEvents += 1 }
            return event
        }
        guard let inputMonitor else {
            writeFailure("Native input validity monitoring could not start; no measurements were started.")
            return
        }
        defer { NSEvent.removeMonitor(inputMonitor) }
        let previousRowConstructionHook = ThreadListView.onRowContentBuild
        let previousSelectionObserverHook = MessageListRow.onSelectionObserverEvaluation
        let previousRowBodyHook = MessageListRow.onBodyEvaluation
        ThreadListView.onRowContentBuild = { [weak mailbox] source, _ in
            guard source === mailbox else { return }
            NavigationPerformance.shared.increment(.mailRowConstructed)
        }
        MessageListRow.onSelectionObserverEvaluation = { [weak mailbox] source, _ in
            guard source === mailbox else { return }
            NavigationPerformance.shared.increment(.mailSelectionObserverEvaluated)
        }
        MessageListRow.onBodyEvaluation = { [weak mailbox] source, _, _ in
            guard source === mailbox else { return }
            NavigationPerformance.shared.increment(.mailRowBodyEvaluated)
        }
        defer {
            ThreadListView.onRowContentBuild = previousRowConstructionHook
            MessageListRow.onSelectionObserverEvaluation = previousSelectionObserverHook
            MessageListRow.onBodyEvaluation = previousRowBodyHook
        }
        let heartbeat = PerformanceMainThreadAudit()
        let initialMemory = NavigationPerformance.physicalFootprint()
        let count = max(100, min(1_000, argumentInteger("--performance-iterations=") ?? 100))
        await PerformanceAuditTransport.shared.configure(.idle)
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

        if scope != .readerOnly {
            record(await exercise("workspace-warm", kind: .workspace, count: count * 2) { index in
                app.destination = index.isMultiple(of: 2) ? .calendar : .mail
            })
            if scope == .workspaceOnly {
                await finish(app: app, mailbox: mailbox, scope: scope, visibleRows: mailbox.listItems.count, scenarios: scenarios,
                             scrolling: [], heartbeat: heartbeat, initialMemory: initialMemory)
                return
            }
            app.destination = .mail
            record(await exercise("attachments-return", kind: .mailbox, count: count * 2) { index in
                mailbox.selectedMailbox = .combined(index.isMultiple(of: 2) ? AttachmentLibraryModel.mailboxID : SystemLabel.inbox)
            })
        }
        mailbox.selectedMailbox = .combined(SystemLabel.inbox)
        _ = await wait { mailbox.listItems.count >= 2 }
        // Production prefetch reaches +3/-2 rows (and the initial prefix8).
        // Keep every measured preparation miss beyond both warmup and lookahead.
        let localStart = 20
        let localStride = 5
        let requiredRows = localStart + (count - 1) * localStride + 1
        while auditMayContinue, mailbox.listItems.filter({ $0.id.threadID.hasPrefix("performance-thread-") }).count < requiredRows {
            let before = mailbox.listItems.count
            mailbox.loadMoreThreads()
            if !(await wait(timeout: .seconds(2), until: { mailbox.listItems.count > before })) { break }
        }
        let rows = mailbox.listItems.filter { $0.id.threadID.hasPrefix("performance-thread-") }.map(\.id)
        if rows.count >= 2 {
            record(await exercise("reader-recent", kind: .reader, count: count) { index in
                mailbox.selectListRows([rows[index % 2]])
            })
            let localRows = (0..<count).compactMap { index -> MailListRowID? in
                let position = localStart + index * localStride
                return rows.indices.contains(position) ? rows[position] : nil
            }
            for row in localRows {
                guard auditMayContinue, !Task.isCancelled, let owner = mailbox.account(id: row.accountID) else { break }
                try? await owner.engine.openThread(row.threadID, markRead: false)
            }
            let localBodiesPresent = (try? await mailbox.cache.read { transaction in
                try localRows.allSatisfy { row in
                    let messages = try transaction.messages(threadID: row.threadID, accountID: row.accountID)
                    return try !messages.isEmpty && messages.allSatisfy { message in
                        try transaction.body(messageID: message.id, accountID: row.accountID) != nil
                    }
                }
            }) == true
            if localRows.count == count, localBodiesPresent {
                record(await exercise("reader-local", kind: .reader, count: count, warmup: 0) { index in
                    mailbox.selectListRows([localRows[index]])
                    NavigationPerformance.shared.cancel(.selectionFeedback)
                })
            } else {
                let reason = localRows.count < count
                    ? "Local preparation needs \(requiredRows) snapshot rows for \(count) spaced selections; only \(rows.count) were available."
                    : "The selected local-body corpus was not fully stored before timing."
                record(failedScenario("reader-local", count: count, reason: reason))
            }
        } else {
            record(failedScenario("reader-recent", count: count, reason: "Two recent reader fixtures were not available."))
            record(failedScenario("reader-local", count: count, reason: "The local-body corpus was not available."))
        }

        if scope == .readerOnly {
            await finish(app: app, mailbox: mailbox, scope: scope, visibleRows: rows.count, scenarios: scenarios,
                         scrolling: [], heartbeat: heartbeat, initialMemory: initialMemory)
            return
        }

        if rows.count >= 2 {
            for mode in [PerformanceAuditTransport.Mode.activeSync, .offline, .delayed] {
                await PerformanceAuditTransport.shared.configure(mode)
                let driver = conditionDriver(mode, mailbox: mailbox, calendar: app.calendar)
                // Verify the chosen condition is exercised through real engines.
                _ = await wait(timeout: .seconds(5)) { conditionDriverStarted }
                record(await exercise("workspace-" + mode.rawValue, kind: .workspace, count: count * 2) { index in
                    app.destination = index.isMultiple(of: 2) ? .calendar : .mail
                })
                app.destination = .mail
                record(await exercise("attachments-" + mode.rawValue, kind: .mailbox, count: count * 2) { index in
                    mailbox.selectedMailbox = .combined(index.isMultiple(of: 2) ? AttachmentLibraryModel.mailboxID : SystemLabel.inbox)
                })
                mailbox.selectedMailbox = .combined(SystemLabel.inbox)
                record(await exercise("reader-" + mode.rawValue, kind: .reader, count: count) { index in
                    mailbox.selectListRows([rows[index % 2]])
                })
                driver.cancel()
                await driver.value
            }
        } else {
            for mode in ["activeSync", "offline", "delayed"] {
                for prefix in ["workspace-", "attachments-", "reader-"] {
                    record(failedScenario(prefix + mode, count: prefix == "reader-" ? count : count * 2,
                                          reason: "Condition corpus was unavailable."))
                }
            }
        }
        await PerformanceAuditTransport.shared.configure(.delayed)
        app.destination = .mail
        mailbox.selectedMailbox = .combined(SystemLabel.inbox)
        let networkKeys = (0..<100).map { ThreadKey(accountID: "ui-audit", threadID: "performance-network-\(20 + $0 * 5)") }
        let networkListReady = await prepareFixtureList("Synthetic network body", keys: networkKeys, mailbox: mailbox)
        record(await exercise("reader-network", kind: .reader, count: 100, warmup: 0) { index in
            guard networkListReady else { throw AuditFailure.fixture("Network fixture search did not load.") }
            let key = networkKeys[index]
            let missing = try await mailbox.cache.read { transaction in
                let messages = try transaction.messages(threadID: key.threadID, accountID: key.accountID)
                return try !messages.isEmpty && messages.allSatisfy { message in
                    try transaction.body(messageID: message.id, accountID: key.accountID) == nil
                }
            }
            guard missing else { throw AuditFailure.fixture("A network body was already cached or missing its metadata.") }
            let ticket = await PerformanceAuditTransport.shared.willSelect(accountID: key.accountID, threadID: key.threadID)
            try selectFixture(key, in: mailbox)
            await PerformanceAuditTransport.shared.didSelect(ticket, generation: NavigationPerformance.shared.currentGeneration(for: .reader))
        })
        await PerformanceAuditTransport.shared.configure(.idle)
        let imageKeys = (0..<100).map { ThreadKey(accountID: "ui-audit", threadID: "performance-image-heavy-\($0)") }
        if let owner = mailbox.account(id: "ui-audit") {
            for key in imageKeys where auditMayContinue {
                try? await owner.engine.openThread(key.threadID, markRead: false)
            }
        }
        let imagesListReady = await prepareFixtureList("Synthetic image-heavy body", keys: imageKeys, mailbox: mailbox)
        record(await exercise("reader-image-heavy-local", kind: .reader, count: imageKeys.count, warmup: 0) { index in
            guard imagesListReady else { throw AuditFailure.fixture("Image fixture search did not load.") }
            try selectFixture(imageKeys[index], in: mailbox)
        })
        // All100 source bodies/resources are already stored before sampling.
        // Cycling10 identities exceeds the3-session retention cap without growing
        // the in-memory database. Stored-content bytes let reports verify that.
        record(await exercise("reader-memory-plateau", kind: .reader, count: 500, warmup: 20) { index in
            guard imagesListReady else { throw AuditFailure.fixture("Image fixture search did not load.") }
            try selectFixture(imageKeys[index % 10], in: mailbox)
        })
        // Oversized bodies are stress cases, outside representative-corpus percentiles.
        for size in [2, 8] {
            let key = ThreadKey(accountID: "ui-audit", threadID: "performance-stress-\(size)")
            if auditMayContinue, let owner = mailbox.account(id: key.accountID) {
                try? await owner.engine.openThread(key.threadID, markRead: false)
            }
            let stressListReady = await prepareFixtureList("Synthetic \(size) MiB stress body", keys: [key], mailbox: mailbox)
            record(await exercise("reader-stress-\(size)MiB", kind: .reader, count: 1, warmup: 0, timeout: .seconds(60)) { _ in
                guard stressListReady else { throw AuditFailure.fixture("Stress fixture search did not load.") }
                try selectFixture(key, in: mailbox)
            })
        }
        mailbox.search.clear()
        _ = await wait { !mailbox.search.isActive && mailbox.listItems.count >= 20 }
        scrolling.append(await measureScroll("mailbox", in: window, surface: .mailbox))
        for size in [20, 100] {
            guard auditMayContinue else {
                scrolling.append(.failure(name: "reader-\(size)", reason: auditInterruptionReason))
                continue
            }
            // Explicit fixture identity avoids accidentally omitting a long thread
            // because its row is outside the currently loaded list page.
            let key = ThreadKey(accountID: "ui-audit", threadID: "performance-long-\(size)")
            guard await prepareFixtureList("Synthetic \(size)-message conversation", keys: [key], mailbox: mailbox) else {
                scrolling.append(.failure(name: "reader-\(size)", reason: "Long-conversation list snapshot did not load."))
                continue
            }
            do { try selectFixture(key, in: mailbox) } catch {
                scrolling.append(.failure(name: "reader-\(size)", reason: "Long-conversation row was missing."))
                continue
            }
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
        await finish(app: app, mailbox: mailbox, scope: scope, visibleRows: rows.count, scenarios: scenarios,
                     scrolling: scrolling, heartbeat: heartbeat, initialMemory: initialMemory)
    }

    private static func finish(app: AppModel, mailbox: MailboxModel, scope: Scope, visibleRows: Int,
                               scenarios: [Scenario], scrolling: [PerformanceScrollAudit.Result],
                               heartbeat: PerformanceMainThreadAudit, initialMemory: UInt64?) async {
        #if DEBUG
        let optimized = false
        #else
        let optimized = true
        #endif
        let responsiveness = await heartbeat.stop()
        let report = Report(unexpectedNativeInputEvents: unexpectedNativeInputEvents,
                            buildRevision: Bundle.main.object(forInfoDictionaryKey: "TernBuildRevision") as? String ?? "unknown",
                            requestedScenario: scope.rawValue,
                            automaticKeyViewLoopBeforeAudit: keyViewLoopBeforeAudit,
                            automaticKeyViewLoopDuringAudit: keyViewLoopDuringAudit,
                            isOptimizedBuild: optimized, syntheticAccountCount: mailbox.accounts.count,
                            fixtureVisibleThreadCount: visibleRows,
                            fixtureConfiguredMessagesPerAccount: min(60_000, max(200, argumentInteger("--performance-mails=") ?? 1_000)) + 822,
                            fixtureEventCount: app.calendar.events.count, imageCorpora: AuditGmail.performanceImageCorpora,
                            scenarios: scenarios, scrolling: scrolling,
                            mainActorResponsiveness: responsiveness,
                            initialPhysicalFootprintBytes: initialMemory,
                            finalPhysicalFootprintBytes: NavigationPerformance.physicalFootprint(),
                            limitation: "Navigation ends at a native drawing commit. Scroll results measure main-run-loop display-link delivery, not presented GPU frames. Processing origins distinguish synthetic full-response delivery from production reader observation delivery. Native input monitoring counts mouse-down, key-down and scroll-wheel events without payloads; zero does not exclude accessibility automation. WebKit memory attribution and actual rendered frame hitches require external process/profiler evidence.")
        write(report)
    }

    private static func prepareFixtureList(_ query: String, keys: [ThreadKey], mailbox: MailboxModel) async -> Bool {
        guard auditMayContinue else { return false }
        mailbox.search.update(query)
        mailbox.search.restrict(toAccount: "ui-audit")
        mailbox.search.submit()
        let wanted = Set(keys)
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while auditMayContinue, !Task.isCancelled, ContinuousClock.now < deadline {
            let listed = Set(mailbox.listItems.map(\.id.threadKey))
            if wanted.isSubset(of: listed), mailbox.search.status != .searching { return true }
            if mailbox.search.hasLocalAnswer, mailbox.search.hasMoreResults { mailbox.search.loadMoreResults() }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return false }
        }
        return false
    }

    private static func selectFixture(_ key: ThreadKey, in mailbox: MailboxModel) throws {
        guard let row = mailbox.listItems.first(where: { $0.id.threadKey == key })?.id else {
            throw AuditFailure.fixture("Selected fixture is outside the loaded list snapshot.")
        }
        mailbox.selectListRows([row])
        // A row in the snapshot need not be inside the viewport. Its reader and
        // header remain measurable; a generic list repaint is not row feedback.
        NavigationPerformance.shared.cancel(.selectionFeedback)
    }

    private enum AuditFailure: Error { case fixture(String) }
    private static var conditionDriverStarted = false

    /// Uses production SyncEngine entry points against in-memory synthetic clients.
    /// Only one request pass is outstanding; cancellation joins it before changing modes.
    private static func conditionDriver(_ mode: PerformanceAuditTransport.Mode, mailbox: MailboxModel,
                                        calendar: CalendarModel) -> Task<Void, Never> {
        conditionDriverStarted = false
        return Task {
            var index = 0
            while !Task.isCancelled, auditMayContinue {
                if mode == .delayed, let owner = mailbox.account(id: "ui-audit-2") {
                    let threadID = "performance-network-\(index % 100)"
                    // The other synthetic account is never selected in this driver.
                    // Eviction uses the production hold checks and keeps metadata.
                    _ = try? await mailbox.cache.evictContent(for: [CacheThreadReference(accountID: "ui-audit-2", threadID: threadID)], keeping: [], now: .now)
                    try? await owner.engine.openThread(threadID, markRead: false)
                } else {
                    for owner in mailbox.accounts {
                        guard !Task.isCancelled else { return }
                        try? await owner.engine.sync()
                    }
                    if mode == .offline { await calendar.refreshCalendarAudit() }
                }
                conditionDriverStarted = true
                index += 1
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private static func exercise(_ name: String, kind: NavigationInteractionKind, count: Int,
                                 warmup: Int = 6, timeout: Duration = .seconds(5),
                                 action: (Int) async throws -> Void) async -> Scenario {
        let performance = NavigationPerformance.shared
        let transportStart = await PerformanceAuditTransport.shared.statistics()
        for index in 0..<warmup {
            guard auditMayContinue else { return failedScenario(name, count: count, reason: auditInterruptionReason) }
            do { try await action(index) } catch {
                return failedScenario(name, count: count, reason: "Warmup fixture action failed.")
            }
            if let generation = performance.latestGeneration(for: kind) {
                _ = await performance.waitForCompletion(kind, generation: generation, timeout: timeout)
            }
        }
        performance.reset()
        // Reset after warmup; an explicit zero distinguishes no work from an
        // unavailable measurement. These counters do not measure native List diff CPU.
        performance.increment(.mailRowConstructed, by: 0)
        performance.increment(.mailSelectionObserverEvaluated, by: 0)
        performance.increment(.mailRowBodyEvaluated, by: 0)
        var failures = 0
        var completed = 0
        var failureReason: String?
        var memory = [await memorySample(completed: 0)]
        for index in 0..<count {
            guard auditMayContinue else { failures += count - index; failureReason = auditInterruptionReason; break }
            guard !Task.isCancelled else { failures += count - index; failureReason = "Audit cancelled."; break }
            let previous = performance.latestGeneration(for: kind)
            do { try await action(index + warmup) } catch {
                failures += count - index
                failureReason = "Fixture action failed or an expected cache miss was unavailable."
                break
            }
            guard let generation = performance.latestGeneration(for: kind), generation != previous else {
                failures += 1; failureReason = "The action did not start a new measured interaction."; continue
            }
            let result = await performance.waitForCompletion(kind, generation: generation, timeout: timeout)
            if unexpectedNativeInputEvents > 0 {
                failures += count - index
                failureReason = auditInterruptionReason
                break
            }
            if result?.outcome == .visibleCommit { completed += 1 } else { failures += 1 }
            if (index + 1).isMultiple(of: 10) || index + 1 == count {
                memory.append(await memorySample(completed: completed))
                writeCurrentProgress(Scenario(name: name, requestedInteractions: count, completedInteractions: completed,
                                              failures: failures, failureReason: failureReason, memorySamples: memory,
                                              transportAtStart: transportStart, transportAtEnd: await PerformanceAuditTransport.shared.statistics(),
                                              timings: performance.report()))
            }
            if failures >= 3, completed == 0 { failures += count - index - 1; break }
        }
        return Scenario(name: name, requestedInteractions: count, completedInteractions: completed,
                        failures: failures, failureReason: failureReason, memorySamples: memory,
                        transportAtStart: transportStart, transportAtEnd: await PerformanceAuditTransport.shared.statistics(),
                        timings: performance.report())
    }

    private static func memorySample(completed: Int) async -> MemorySample {
        let stored = try? await auditCache?.disposableContentUsage()
        func countReaders(in view: NSView) -> Int {
            (view is ContentSizedWebView ? 1 : 0) + view.subviews.reduce(0) { $0 + countReaders(in: $1) }
        }
        let readers = auditWindow?.contentView.map { countReaders(in: $0) } ?? 0
        return MemorySample(completedInteractions: completed, physicalFootprintBytes: NavigationPerformance.physicalFootprint(),
                            preparedDocumentBytes: ReaderPreparedCache.shared.byteCount,
                            attachedReaderWebViews: readers, storedContent: stored)
    }

    private static func failedScenario(_ name: String, count: Int, reason: String) -> Scenario {
        NavigationPerformance.shared.reset()
        return Scenario(name: name, requestedInteractions: count, completedInteractions: 0,
                        failures: count, failureReason: reason, memorySamples: [], transportAtStart: nil, transportAtEnd: nil, timings: NavigationPerformance.shared.report())
    }

    private static var auditMayContinue: Bool {
        unexpectedNativeInputEvents == 0 && NSApp.isActive
            && auditWindow?.isKeyWindow == true && auditWindow?.occlusionState.contains(.visible) == true
    }

    private static var auditInterruptionReason: String {
        if unexpectedNativeInputEvents > 0 {
            return "Unexpected native input during the programmatic audit (\(unexpectedNativeInputEvents) events); the report is invalid."
        }
        return "Foreground unavailable: appActive=\(NSApp.isActive), keyWindow=\(auditWindow?.isKeyWindow == true), visible=\(auditWindow?.isVisible == true), unoccluded=\(auditWindow?.occlusionState.contains(.visible) == true)."
    }

    private enum Surface: String { case mailbox, reader, calendar, attachments }

    private static func measureScroll(_ name: String, in window: NSWindow, surface: Surface) async -> PerformanceScrollAudit.Result {
        guard auditMayContinue else { return .failure(name: name, reason: auditInterruptionReason) }
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

    private static func writeCurrentProgress(_ scenario: Scenario) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(scenario) {
            try? data.write(to: outputURL.appendingPathExtension("current.json"), options: .atomic)
        }
    }

    private static func write(_ value: some Encodable) {
        defer {
            if ProcessInfo.processInfo.arguments.contains("--performance-exit") {
                let pause = min(30, max(0, argumentInteger("--performance-memory-pause=") ?? 0))
                Task {
                    if pause > 0 { try? await Task.sleep(for: .seconds(pause)) }
                    // Leave the Swift task before AppKit enters its termination
                    // run loop, so the delegate's async quit review can execute.
                    DispatchQueue.main.async { NSApp.terminate(nil) }
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
