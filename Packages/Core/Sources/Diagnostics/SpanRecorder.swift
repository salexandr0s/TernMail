import Foundation
import os

/// One finished span.
public struct SpanRecord: Sendable, Equatable {
    public let span: TernSpan
    public let duration: Duration
    public let endedAt: Date

    public init(span: TernSpan, duration: Duration, endedAt: Date) {
        self.span = span
        self.duration = duration
        self.endedAt = endedAt
    }
}

/// Keeps the most recent spans in memory for the diagnostics window and the
/// benchmarks. Safe to call from any thread.
public final class SpanRecorder: Sendable {
    public static let shared = SpanRecorder(capacity: 200)

    public let capacity: Int
    private let state: OSAllocatedUnfairLock<Ring>

    struct Ring {
        var slots: [SpanRecord?]
        var next = 0
        var count = 0
    }

    public init(capacity: Int) {
        let size = max(1, capacity)
        self.capacity = size
        state = OSAllocatedUnfairLock(initialState: Ring(slots: Array(repeating: nil, count: size)))
    }

    public func record(_ record: SpanRecord) {
        state.withLock { ring in
            ring.slots[ring.next] = record
            ring.next = (ring.next + 1) % capacity
            ring.count = min(ring.count + 1, capacity)
        }
    }

    /// Oldest first.
    public var records: [SpanRecord] {
        state.withLock { ring in
            guard ring.count > 0 else { return [] }
            let start = ring.count < capacity ? 0 : ring.next
            return (0..<ring.count).compactMap { ring.slots[(start + $0) % capacity] }
        }
    }

    public func records(for span: TernSpan) -> [SpanRecord] {
        records.filter { $0.span == span }
    }

    public func removeAll() {
        state.withLock { ring in
            ring.slots = Array(repeating: nil, count: capacity)
            ring.next = 0
            ring.count = 0
        }
    }

    public struct Summary: Sendable, Equatable {
        public let count: Int
        public let median: Duration
        public let p90: Duration
        public let max: Duration
    }

    /// Percentiles over the recorded durations of `span`, or nil with none.
    public func summary(for span: TernSpan) -> Summary? {
        let sorted = records(for: span).map(\.duration).sorted()
        guard let last = sorted.last else { return nil }
        func percentile(_ fraction: Double) -> Duration {
            let index = Int((Double(sorted.count - 1) * fraction).rounded())
            return sorted[min(max(index, 0), sorted.count - 1)]
        }
        return Summary(count: sorted.count, median: percentile(0.5), p90: percentile(0.9), max: last)
    }
}
