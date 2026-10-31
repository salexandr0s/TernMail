import Foundation
import Testing
@testable import Diagnostics

@Suite struct SpanRecorderTests {
    @Test func keepsOnlyTheMostRecentSpansOldestFirst() {
        let recorder = SpanRecorder(capacity: 3)
        for index in 1...5 {
            recorder.record(SpanRecord(span: .actionToCommit, duration: .milliseconds(index), endedAt: .now))
        }
        #expect(recorder.records.map(\.duration) == [.milliseconds(3), .milliseconds(4), .milliseconds(5)])
    }

    @Test func summaryReportsPercentilesPerSpan() throws {
        let recorder = SpanRecorder(capacity: 10)
        for millis in [10, 20, 30, 40, 50] {
            recorder.record(SpanRecord(span: .selectionToReader, duration: .milliseconds(millis), endedAt: .now))
        }
        recorder.record(SpanRecord(span: .launchToList, duration: .seconds(2), endedAt: .now))
        let summary = try #require(recorder.summary(for: .selectionToReader))
        #expect(summary.count == 5)
        #expect(summary.median == .milliseconds(30))
        #expect(summary.p90 == .milliseconds(50))
        #expect(summary.max == .milliseconds(50))
        #expect(recorder.summary(for: .passToListValue) == nil)
    }

    @Test func endingATokenRecordsItsDuration() {
        let recorder = SpanRecorder(capacity: 4)
        let token = TernSignposts.begin(.actionToGmail)
        TernSignposts.end(token, recorder: recorder)
        #expect(recorder.records(for: .actionToGmail).count == 1)
    }
}
