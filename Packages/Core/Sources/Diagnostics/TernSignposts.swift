import Foundation
import os

/// The moments Tern measures. Names are stable so Instruments, `log stream`
/// and the span tools can filter on them.
public enum TernSpan: String, Sendable, CaseIterable, Codable {
    /// IMAP signal received to the history pass commit that carried the mail.
    case imapSignalToCommit
    /// Pass commit to the list observation delivering the new rows.
    case passToListValue
    /// Triage command to the pending action being written.
    case actionToCommit
    /// Triage command to the list observation reflecting it.
    case actionToListValue
    /// Triage command to Gmail's 2xx.
    case actionToGmail
    /// Selection change to the reader showing the conversation.
    case selectionToReader
    /// Reader shown to the first message body painted.
    case readerFirstPaint
    /// Mailbox change to the list showing its rows.
    case mailboxSwitchToList
    /// Process start to the first list rows on screen.
    case launchToList
}

/// An open interval. End it with `TernSignposts.end(_:)`.
public struct SpanToken: Sendable {
    public let span: TernSpan
    let start: ContinuousClock.Instant
    // OSSignpostIntervalState is an opaque handle that os_signpost accepts
    // from any thread. It is only ever passed back to `endInterval`.
    nonisolated(unsafe) let state: OSSignpostIntervalState
}

/// Signpost intervals plus a duration record for each one that ends.
public enum TernSignposts {
    public static let subsystem = "dev.tern"
    static let signposter = OSSignposter(subsystem: subsystem, category: "spans")

    /// Starts `span`. Several of the same span can be open at once.
    public static func begin(_ span: TernSpan) -> SpanToken {
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval("span", id: id, "\(span.rawValue, privacy: .public)")
        return SpanToken(span: span, start: .now, state: state)
    }

    /// Ends `token` and records its duration.
    public static func end(_ token: SpanToken, recorder: SpanRecorder = .shared) {
        let duration = token.start.duration(to: .now)
        signposter.endInterval("span", token.state, "\(token.span.rawValue, privacy: .public)")
        recorder.record(SpanRecord(span: token.span, duration: duration, endedAt: .now))
    }

    /// Measures `body`.
    public static func measure<T>(_ span: TernSpan, _ body: () throws -> T) rethrows -> T {
        let token = begin(span)
        defer { end(token) }
        return try body()
    }

    /// Measures `body` across its suspensions.
    public static func measure<T: Sendable>(
        _ span: TernSpan, _ body: () async throws -> T
    ) async rethrows -> T {
        let token = begin(span)
        defer { end(token) }
        return try await body()
    }
}

/// Loggers by area. Log names and numbers only; mail content, addresses and
/// tokens never go through these.
public enum TernLog {
    public static let sync = Logger(subsystem: TernSignposts.subsystem, category: "sync")
    public static let queue = Logger(subsystem: TernSignposts.subsystem, category: "queue")
    public static let store = Logger(subsystem: TernSignposts.subsystem, category: "store")
    public static let ui = Logger(subsystem: TernSignposts.subsystem, category: "ui")
}

extension Logger {
    /// Logs `name` with numeric fields, so no free-form text reaches the log.
    public func event(_ name: StaticString, _ fields: KeyValuePairs<StaticString, Int> = [:]) {
        let summary = fields.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        info("\(name.description, privacy: .public) \(summary, privacy: .public)")
    }
}
