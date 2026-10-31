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
        let performance = NavigationPerformance()
        performance.captureInput(timestamp: ProcessInfo.processInfo.systemUptime - 0.025)
        let input = performance.begin(.selectionFeedback)
        performance.contentReady(.selectionFeedback, cacheTier: .local)
        performance.didCommitVisibleContent(.selectionFeedback, generation: input)
        let record = try #require(performance.records.last)
        #expect(record.timingOrigin == .input)
        #expect(try #require(record.inputQueueDelayMilliseconds) >= 25)
        try await Task.sleep(for: .milliseconds(10))
        let programmatic = performance.begin(.selectionFeedback)
        performance.contentReady(.selectionFeedback, cacheTier: .local)
        performance.didCommitVisibleContent(.selectionFeedback, generation: programmatic)
        #expect(performance.records.last?.timingOrigin == .programmatic)
        #expect(performance.records.last?.inputQueueDelayMilliseconds == nil)
    }
}
