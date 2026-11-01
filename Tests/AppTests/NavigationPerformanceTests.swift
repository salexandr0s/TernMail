import AppKit
import Testing
@testable import Tern

@Suite @MainActor struct NavigationPerformanceTests {
    @Test func readinessAndTheCurrentDrawingCommitAreBothRequired() throws {
        let performance = NavigationPerformance()
        let first = performance.begin(.reader)
        performance.didCommitVisibleContent(.reader, generation: first)
        #expect(performance.records.isEmpty)
        performance.contentReady(.reader, cacheTier: .local, generation: first)
        let second = performance.begin(.reader)
        performance.contentReady(.reader, cacheTier: .local, generation: first)
        performance.didCommitVisibleContent(.reader, generation: first)
        #expect(!performance.isReady(.reader, generation: second))
        #expect(performance.records.map(\.outcome) == [.superseded])
        #expect(performance.report().summaries.isEmpty)

        performance.contentReady(.reader, cacheTier: .retained, generation: second)
        performance.didCommitVisibleContent(.reader, generation: second)
        performance.didCommitVisibleContent(.reader, generation: second)
        #expect(performance.records.map(\.outcome) == [.superseded, .visibleCommit])
        #expect(performance.report().summaries["reader.retained.programmatic"]?.count == 1)
        #expect(try #require(performance.records.last?.contentReadyMilliseconds) >= 0)
    }

    @Test func missingVisibleContentIsATimeoutAndNeverASuccess() async throws {
        let performance = NavigationPerformance()
        let generation = performance.begin(.mailbox)
        performance.contentReady(.mailbox, cacheTier: .local, generation: generation)
        let result = await performance.waitForCompletion(.mailbox, generation: generation, timeout: .milliseconds(1))
        #expect(result?.outcome == .timedOut)
        #expect(performance.report().summaries.isEmpty)
    }

    @Test func processingIntervalStartsAtRequiredBytesAndRejectsStaleGenerations() async throws {
        let performance = NavigationPerformance()
        let stale = performance.begin(.reader)
        let generation = performance.begin(.reader)
        performance.requiredContentReady(.reader, generation: stale)
        try await Task.sleep(for: .milliseconds(15))
        let bytesReady = ContinuousClock.now
        try await Task.sleep(for: .milliseconds(5))
        performance.requiredContentReady(.reader, generation: generation, at: bytesReady)
        performance.requiredContentReady(.reader, generation: generation, at: .now)
        performance.contentReady(.reader, cacheTier: .network, generation: generation)
        performance.didCommitVisibleContent(.reader, generation: generation)
        let result = try #require(performance.records.last)
        let processing = try #require(result.readyToVisibleMilliseconds)
        #expect(processing >= 5)
        #expect(result.elapsedMilliseconds - processing >= 15)
        #expect(performance.report().processingSummaries["reader.network.programmatic"]?.count == 1)
        let retained = performance.begin(.reader)
        performance.contentReady(.reader, cacheTier: .retained)
        performance.didCommitVisibleContent(.reader, generation: retained)
        #expect(performance.records.last?.readyToVisibleMilliseconds == nil)
        #expect(performance.latestGeneration(for: .reader) == retained)
        #expect(result.processingOrigin == .readerObservationDelivery)
        let network = performance.begin(.reader)
        let response = ContinuousClock.now
        performance.requiredContentReady(.reader, generation: network, at: response)
        performance.requiredContentReady(.reader, generation: network, at: response, origin: .syntheticTransportResponse)
        performance.contentReady(.reader, cacheTier: .network)
        performance.didCommitVisibleContent(.reader, generation: network)
        #expect(performance.records.last?.processingOrigin == .syntheticTransportResponse)
    }

    @Test func sharedProbeKeepsReadinessAndQueuedCommitGenerationsIndependent() async throws {
        let performance = NavigationPerformance(selectionFeedbackEnabled: true)
        let probe = VisibleContentProbe.ProbeView(performance: performance)
        probe.configure(kinds: [.workspace, .mailbox, .selectionFeedback], isActive: true, revision: 1)
        let workspace = performance.begin(.workspace)
        let mailbox = performance.begin(.mailbox)
        let feedback = performance.begin(.selectionFeedback)
        performance.contentReady(.workspace, cacheTier: .retained, generation: workspace)
        performance.contentReady(.selectionFeedback, cacheTier: .local, generation: feedback)
        let ready = probe.readyDrawingCommits()
        #expect(Set(ready.map(\.kind)) == [.workspace, .selectionFeedback])
        let oldWorkspace = try #require(ready.first { $0.kind == .workspace })
        let oldFeedback = try #require(ready.first { $0.kind == .selectionFeedback })
        #expect(probe.isCurrentDrawingCommit(oldWorkspace))
        #expect(probe.isCurrentDrawingCommit(oldFeedback))
        _ = performance.begin(.workspace)
        #expect(!probe.isCurrentDrawingCommit(oldWorkspace))
        #expect(probe.isCurrentDrawingCommit(oldFeedback))
        performance.contentReady(.mailbox, cacheTier: .local, generation: mailbox)
        #expect(Set(probe.readyDrawingCommits().map(\.kind)) == [.mailbox, .selectionFeedback])
        // Removing and restoring a kind cannot validate a previously queued draw.
        probe.configure(kinds: [.workspace, .mailbox], isActive: true, revision: 1)
        #expect(!probe.isCurrentDrawingCommit(oldFeedback))
        probe.configure(kinds: [.workspace, .mailbox, .selectionFeedback], isActive: true, revision: 1)
        #expect(!probe.isCurrentDrawingCommit(oldFeedback))
        let beforeHide = try #require(probe.readyDrawingCommits().first { $0.kind == .mailbox })
        probe.configure(kinds: [.workspace, .mailbox, .selectionFeedback], isActive: false, revision: 1)
        #expect(probe.readyDrawingCommits().isEmpty)
        #expect(!probe.isCurrentDrawingCommit(beforeHide))
        probe.configure(kinds: [.workspace, .mailbox, .selectionFeedback], isActive: true, revision: 2)
        #expect(!probe.isCurrentDrawingCommit(beforeHide))
        // No foreground native viewport: sharing readiness must not manufacture
        // any visible endpoint for any kind.
        probe.draw(.zero)
        await Task.yield()
        #expect(performance.records.allSatisfy { $0.outcome != .visibleCommit })
        probe.stop()
    }

    @Test func reportDoesNotAcceptPrivateDestinationNames() {
        let performance = NavigationPerformance()
        let generation = performance.begin(.workspace, destination: "private folder title")
        performance.contentReady(.workspace, cacheTier: .retained)
        performance.didCommitVisibleContent(.workspace, generation: generation)
        #expect(performance.records.first?.destination == nil)
        #expect(performance.report().summaries["workspace.retained.programmatic"]?.count == 1)
    }

    @Test func percentilesIncludeTheSlowTail() throws {
        let summary = try #require(NavigationPerformance.Summary((1...100).map(Double.init)))
        #expect(summary.p50Milliseconds == 50)
        #expect(summary.p95Milliseconds == 95)
        #expect(summary.p99Milliseconds == 99)
        #expect(summary.maximumMilliseconds == 100)
        #expect(NavigationPerformance.Summary([]) == nil)
    }

    @Test func detachedOrInactiveProbesCannotCompleteAnInteraction() {
        let performance = NavigationPerformance()
        let generation = performance.begin(.reader)
        performance.contentReady(.reader, cacheTier: .prepared)
        let probe = VisibleContentProbe.ProbeView(performance: performance)
        probe.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        probe.configure(kind: .reader, isActive: true, revision: 1)
        probe.draw(probe.bounds)
        #expect(!probe.isVisibleContent)
        #expect(performance.records.isEmpty)
        probe.configure(kind: .reader, isActive: false, revision: 2)
        probe.draw(probe.bounds)
        #expect(performance.currentGeneration(for: .reader) == generation)
        probe.stop()
    }

    @Test func nativeInputTimingExpiresBeforeAnUnrelatedTask() async throws {
        let performance = NavigationPerformance(selectionFeedbackEnabled: true)
        performance.captureInput(timestamp: ProcessInfo.processInfo.systemUptime - 0.025)
        let input = performance.begin(.selectionFeedback)
        performance.contentReady(.selectionFeedback, cacheTier: .local)
        performance.didCommitVisibleContent(.selectionFeedback, generation: input)
        let record = try #require(performance.records.last)
        #expect(record.timingOrigin == .input)
        // Uptime is a large floating-point value; subtracting 25 ms can round
        // a few nanoseconds below the mathematical duration.
        #expect(try #require(record.inputQueueDelayMilliseconds) >= 24.9)
        try await Task.sleep(for: .milliseconds(10))
        let programmatic = performance.begin(.selectionFeedback)
        performance.contentReady(.selectionFeedback, cacheTier: .local)
        performance.didCommitVisibleContent(.selectionFeedback, generation: programmatic)
        #expect(performance.records.last?.timingOrigin == .programmatic)
        #expect(performance.records.last?.inputQueueDelayMilliseconds == nil)
    }

    @Test func feedbackIsExplicitlyDisabledWithoutPendingWorkOrNotifications() async {
        let performance = NavigationPerformance()
        var notifications = 0
        let token = performance.observe { _ in notifications += 1 }
        defer { performance.removeObserver(token) }
        let generation = performance.begin(.selectionFeedback)
        performance.contentReady(.selectionFeedback, cacheTier: .local)
        #expect(performance.currentGeneration(for: .selectionFeedback) == nil)
        let started = ContinuousClock.now
        let result = await performance.waitForCompletion(.selectionFeedback, generation: generation, timeout: .seconds(1))
        #expect(started.duration(to: .now) < .milliseconds(250))
        #expect(result == nil && performance.records.isEmpty && notifications == 0)
        let measurement = performance.report().selectionFeedbackMeasurement
        #expect(measurement.endpoint == .disabled)
        #expect(measurement.registeredProbeCount == 0)
    }

    @Test func rowFeedbackRequiresCurrentNativeSelectionAndViewport() async throws {
        let fixture = FeedbackTableFixture()
        defer { fixture.window.close() }
        let performance = NavigationPerformance(selectionFeedbackEnabled: true)
        let probe = VisibleContentProbe.ProbeView(performance: performance)
        probe.frame = NSRect(x: 0, y: 0, width: 280, height: 40)
        var currentTarget = true
        let accountOwner = NSObject()
        let identity = VisibleContentProbe.SelectedRowIdentity(owner: ObjectIdentifier(fixture),
            accountOwner: ObjectIdentifier(accountOwner),
            row: .init(accountID: "audit-a", threadID: "one", messageID: nil))
        let requirement = VisibleContentProbe.SelectedRowRequirement(identity: identity, isCurrent: { currentTarget })
        probe.configure(kinds: [.selectionFeedback], isActive: true, revision: 0, selectedRow: requirement)
        defer { probe.stop() }
        let generation = performance.begin(.selectionFeedback)
        performance.contentReady(.selectionFeedback, cacheTier: .local, generation: generation)
        #expect(!probe.satisfiesSelectedRowRequirement) // no actual native row
        let row = try #require(fixture.table.rowView(atRow: 0, makeIfNecessary: true))
        row.addSubview(probe)
        fixture.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        #expect(probe.readyDrawingCommits().isEmpty)
        fixture.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        #expect(row.isSelected && fixture.table.selectedRowIndexes == [0])
        #expect(probe.satisfiesSelectedRowRequirement)
        let commit = try #require(probe.readyDrawingCommits().first)
        #expect(probe.isCurrentDrawingCommit(commit))

        let beforeNotification = probe.displayRequestCount
        NotificationCenter.default.post(name: NSTableView.selectionDidChangeNotification, object: fixture.table)
        #expect(probe.displayRequestCount == beforeNotification + 1) // wake an early draw
        currentTarget = false
        let beforeUnrelatedSelection = probe.displayRequestCount
        NotificationCenter.default.post(name: NSTableView.selectionDidChangeNotification, object: fixture.table)
        #expect(probe.displayRequestCount == beforeUnrelatedSelection)
        #expect(!probe.isCurrentDrawingCommit(commit))
        _ = performance.begin(.selectionFeedback)
        #expect(probe.displayRequestCount == beforeUnrelatedSelection) // unrelated rows do not redraw
        currentTarget = true
        performance.contentReady(.selectionFeedback, cacheTier: .local)
        #expect(!probe.isCurrentDrawingCommit(commit)) // stale generation
        let current = try #require(probe.readyDrawingCommits().first)
        let newAccountOwner = NSObject()
        let replacement = VisibleContentProbe.SelectedRowRequirement(identity: .init(owner: ObjectIdentifier(fixture),
            accountOwner: ObjectIdentifier(newAccountOwner), row: identity.row), isCurrent: { true })
        probe.configure(kinds: [.selectionFeedback], isActive: true, revision: 0, selectedRow: replacement)
        #expect(!probe.isCurrentDrawingCommit(current)) // same account/row ID, new account owner
        let afterReplacement = try #require(probe.readyDrawingCommits().first)
        let otherAccount = VisibleContentProbe.SelectedRowRequirement(identity: .init(owner: ObjectIdentifier(fixture),
            accountOwner: ObjectIdentifier(newAccountOwner),
            row: .init(accountID: "audit-b", threadID: "one", messageID: nil)), isCurrent: { true })
        probe.configure(kinds: [.selectionFeedback], isActive: true, revision: 0, selectedRow: otherAccount)
        #expect(!probe.isCurrentDrawingCommit(afterReplacement)) // same thread text ID, other account
        withExtendedLifetime((accountOwner, newAccountOwner)) {}

        fixture.scroll.contentView.scroll(to: NSPoint(x: 0, y: 300))
        fixture.scroll.reflectScrolledClipView(fixture.scroll.contentView)
        #expect(!fixture.table.rect(ofRow: 0).intersects(fixture.table.visibleRect))
        #expect(!probe.satisfiesSelectedRowRequirement)
        probe.draw(probe.bounds)
        await Task.yield()
        #expect(performance.records.allSatisfy { $0.outcome != .visibleCommit })
    }

    @Test func feedbackProbeReattachesWithoutConfigureAndRegistryDoesNotRetainViews() throws {
        let fixture = FeedbackTableFixture()
        defer { fixture.window.close() }
        let performance = NavigationPerformance(selectionFeedbackEnabled: true)
        let probe = VisibleContentProbe.ProbeView(performance: performance)
        probe.frame = NSRect(x: 0, y: 0, width: 280, height: 40)
        let requirement = VisibleContentProbe.SelectedRowRequirement(identity: .init(owner: ObjectIdentifier(fixture),
            accountOwner: ObjectIdentifier(fixture),
            row: .init(accountID: "audit", threadID: "one", messageID: nil)), isCurrent: { true })
        probe.configure(kinds: [.selectionFeedback], isActive: true, revision: 0, selectedRow: requirement)
        let row = try #require(fixture.table.rowView(atRow: 0, makeIfNecessary: true))
        row.addSubview(probe)
        fixture.table.selectRowIndexes([0], byExtendingSelection: false)
        #expect(performance.report().selectionFeedbackMeasurement.endpoint == .selectedNativeRowDrawingProxyV1)
        #expect(performance.report().selectionFeedbackMeasurement.windowAttachedProbeCount == 1)
        let decoded = try JSONDecoder().decode(NavigationPerformance.Report.self,
            from: JSONEncoder().encode(performance.report()))
        #expect(decoded.selectionFeedbackMeasurement.endpoint == .selectedNativeRowDrawingProxyV1)
        #expect(decoded.selectionFeedbackMeasurement.windowAttachedProbeCount == 1)
        probe.removeFromSuperview()
        #expect(performance.report().selectionFeedbackMeasurement.registeredProbeCount == 0)
        row.addSubview(probe) // no configure call: native lifecycle must reinstall
        let beforeReattachedNotification = probe.displayRequestCount
        NotificationCenter.default.post(name: NSTableView.selectionDidChangeNotification, object: fixture.table)
        #expect(probe.displayRequestCount == beforeReattachedNotification + 1)
        #expect(performance.report().selectionFeedbackMeasurement.windowAttachedProbeCount == 1)
        probe.stop()
        let beforeStoppedNotification = probe.displayRequestCount
        NotificationCenter.default.post(name: NSTableView.selectionDidChangeNotification, object: fixture.table)
        #expect(probe.displayRequestCount == beforeStoppedNotification)
        #expect(performance.report().selectionFeedbackMeasurement.registeredProbeCount == 0)

        weak var weakProbe: VisibleContentProbe.ProbeView?
        autoreleasepool {
            let orphan = VisibleContentProbe.ProbeView(performance: performance)
            weakProbe = orphan
            orphan.configure(kinds: [.selectionFeedback], isActive: true, revision: 0, selectedRow: requirement)
            #expect(performance.report().selectionFeedbackMeasurement.registeredProbeCount == 1)
        }
        #expect(weakProbe == nil)
        #expect(performance.report().selectionFeedbackMeasurement.registeredProbeCount == 0)
    }

    @Test func explicitExportWritesOnlyTheBoundedDiagnosticSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "NavigationPerformanceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "report.json")
        let performance = NavigationPerformance(capacity: 2)
        performance.configureReportExport(to: destination)
        for _ in 0..<3 {
            let generation = performance.begin(.reader, destination: "must never be exported")
            performance.contentReady(.reader, cacheTier: .retained)
            performance.didCommitVisibleContent(.reader, generation: generation)
        }
        await performance.waitForReportExport()
        let data = try Data(contentsOf: destination)
        let report = try JSONDecoder().decode(NavigationPerformance.Report.self, from: data)
        #expect(report.selectionFeedbackMeasurement.endpoint == .disabled)
        #expect(report.records.count == 2)
        #expect(report.records.allSatisfy { $0.outcome == .visibleCommit && $0.destination == nil })
        #expect(!String(decoding: data, as: UTF8.self).contains("must never be exported"))
    }
}

/// A real native table in an ordered-back window. It never activates or requests
/// key status; these tests validate selection/viewport gates, not presented pixels.
@MainActor private final class FeedbackTableFixture: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
                          styleMask: [.titled], backing: .buffered, defer: false)
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
    let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 320, height: 480))

    override init() {
        super.init()
        window.isReleasedWhenClosed = false
        table.addTableColumn(NSTableColumn(identifier: .init("fixture")))
        table.tableColumns[0].width = 320
        table.headerView = nil
        table.rowHeight = 60
        table.intercellSpacing = .zero
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        window.contentView = scroll
        table.reloadData()
        window.orderBack(nil)
        scroll.layoutSubtreeIfNeeded()
        table.layoutSubtreeIfNeeded()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { 8 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 60))
    }
}
