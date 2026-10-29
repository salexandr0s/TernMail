import Foundation

/// One IMAP connection's conversation, from the greeting to IDLE, with no
/// I/O. Server bytes, tokens and timer events go in. Bytes to send, timers,
/// token requests, "INBOX changed" signals and how the connection ended
/// come out.
///
/// The flow: CAPABILITY, AUTHENTICATE XOAUTH2, a second CAPABILITY when the
/// sign-in answer has none, EXAMINE INBOX, then IDLE, restarted every
/// `idleRestartInterval`. Once EXAMINE has finished, every EXISTS, EXPUNGE
/// or FETCH is a signal, and so is the EXAMINE itself, which covers changes
/// made while disconnected.
public struct IdleSession: Sendable {
    public enum Timer: Sendable, Hashable {
        /// Ends IDLE and starts it again.
        case idleRestart
        /// The server took too long to answer.
        case reply
    }

    /// What the monitor does after a connection ends.
    public enum Ending: Sendable, Equatable {
        case reconnect(Reconnect)
        /// The server lacks XOAUTH2 or IDLE, so trying again won't help.
        case unsupported
        /// Sign-in failed twice, the second time with a refreshed token.
        case authenticationFailed
    }

    public struct Reconnect: Sendable, Equatable {
        /// Skip the backoff delay.
        public var immediately: Bool
        /// Ask the token provider for a new token on the next connection.
        public var forceRefresh: Bool
        /// Start the backoff again from its shortest delay.
        public var resetBackoff: Bool

        public init(immediately: Bool, forceRefresh: Bool, resetBackoff: Bool) {
            self.immediately = immediately
            self.forceRefresh = forceRefresh
            self.resetBackoff = resetBackoff
        }
    }

    public enum Action: Sendable, Equatable {
        /// May hold the XOAUTH2 string. `Data` describes itself by size only.
        case send(Data)
        case requestToken(forceRefresh: Bool)
        /// Replaces a running timer of the same kind.
        case startTimer(Timer, after: Duration)
        case cancelTimer(Timer)
        /// INBOX may have changed.
        case signal
        /// Close the connection and cancel every timer. No actions follow.
        case close(Ending)
    }

    /// RFC 2177 asks for less than 29 minutes. Google documents no limit,
    /// and one report puts Gmail's near 15.
    public static let idleRestartInterval: Duration = .seconds(9 * 60)
    public static let doneTimeout: Duration = .seconds(30)
    public static let replyTimeout: Duration = .seconds(60)
    /// A BYE after a session at least this long reconnects at once. Gmail
    /// ends OAuth sessions about when the token expires.
    public static let longSession: Duration = .seconds(10 * 60)
    /// A session that idled this long resets the backoff.
    public static let healthyIdle: Duration = .seconds(60)

    private enum State {
        case greeting
        case capability(tag: String)
        case waitingForToken(attempt: Int)
        case authenticating(tag: String, attempt: Int, sentCredentials: Bool)
        case postAuthCapability(tag: String)
        case examining(tag: String)
        case startingIdle(tag: String)
        case idling(tag: String)
        case endingIdle(tag: String)
        case closed(Ending)
    }

    private let address: String
    private let startedAt: ContinuousClock.Instant
    private let forceRefresh: Bool
    private var parser = IMAPResponseParser()
    private var state = State.greeting
    private var tagNumber = 0
    /// What the server offered before sign-in, which RFC 3501 lets it change after.
    private var greetingCapabilities: Set<String> = []
    /// What it offers after sign-in. Nil until an answer lists them.
    private var capabilities: Set<String>?
    private var examined = false
    private var idlingSince: ContinuousClock.Instant?
    /// The XOAUTH2 string, held only until a server without SASL-IR asks for it.
    private var pendingCredentials: String?

    /// - Parameter forceRefresh: Whether the first token request forces a refresh.
    public init(address: String, startedAt: ContinuousClock.Instant, forceRefresh: Bool = false) {
        self.address = address
        self.startedAt = startedAt
        self.forceRefresh = forceRefresh
    }

    /// The actions for a new connection, which waits for the greeting.
    public func start() -> [Action] {
        [.startTimer(.reply, after: Self.replyTimeout)]
    }

    public mutating func receive(_ bytes: Data, at now: ContinuousClock.Instant) -> [Action] {
        if case .closed = state { return [] }
        let responses: [IMAPResponse]
        do {
            responses = try parser.feed(bytes)
        } catch {
            return close(.reconnect(afterBackoff(at: now)))
        }
        var actions: [Action] = []
        var signalled = false
        for response in responses {
            if case .closed = state { break }
            if examined, Self.isChange(response) {
                // One signal per batch is enough to start a sync.
                if !signalled { actions.append(.signal) }
                signalled = true
                continue
            }
            actions += handle(response, at: now, signalled: &signalled)
        }
        return actions
    }

    public mutating func provideToken(_ token: String) -> [Action] {
        guard case .waitingForToken(let attempt) = state else { return [] }
        let credentials = Self.xoauth2(address: address, token: token)
        let tag = nextTag()
        let command: String
        if greetingCapabilities.contains("SASL-IR") {
            command = "\(tag) AUTHENTICATE XOAUTH2 \(credentials)"
            state = .authenticating(tag: tag, attempt: attempt, sentCredentials: true)
        } else {
            command = "\(tag) AUTHENTICATE XOAUTH2"
            pendingCredentials = credentials
            state = .authenticating(tag: tag, attempt: attempt, sentCredentials: false)
        }
        return [.send(Self.line(command)), .startTimer(.reply, after: Self.replyTimeout)]
    }

    public mutating func timerFired(_ timer: Timer, at now: ContinuousClock.Instant) -> [Action] {
        switch (timer, state) {
        case (.idleRestart, .idling(let tag)):
            state = .endingIdle(tag: tag)
            return [.send(Self.line("DONE")), .startTimer(.reply, after: Self.doneTimeout)]
        case (.reply, .greeting), (.reply, .capability), (.reply, .authenticating), (.reply, .postAuthCapability),
             (.reply, .examining), (.reply, .startingIdle), (.reply, .endingIdle):
            // A connection that stops answering is as good as gone.
            return close(.reconnect(afterBackoff(at: now)))
        default:
            // A timer from an earlier state.
            return []
        }
    }

    /// The connection closed or failed before the session closed it.
    public mutating func connectionEnded(at now: ContinuousClock.Instant) -> Ending {
        if case .closed(let ending) = state { return ending }
        let ending = Ending.reconnect(afterBackoff(at: now))
        state = .closed(ending)
        return ending
    }

    // MARK: Responses

    private mutating func handle(_ response: IMAPResponse, at now: ContinuousClock.Instant, signalled: inout Bool) -> [Action] {
        if case .condition(.bye, _) = response { return close(afterBye(at: now)) }
        switch (state, response) {
        case (.greeting, .condition(.ok, _)):
            let tag = nextTag()
            state = .capability(tag: tag)
            return [.send(Self.line("\(tag) CAPABILITY")), .startTimer(.reply, after: Self.replyTimeout)]
        case (.greeting, _):
            // PREAUTH or anything else first isn't a Gmail greeting.
            return close(.reconnect(afterBackoff(at: now)))

        case (.capability, .capability(let names)):
            greetingCapabilities.formUnion(names)
            return []
        case (.capability(let expected), .tagged(let tag, .ok, let code)) where tag == expected:
            greetingCapabilities.formUnion(Self.capabilities(in: code) ?? [])
            guard greetingCapabilities.contains("AUTH=XOAUTH2") else { return close(.unsupported) }
            state = .waitingForToken(attempt: 1)
            return [.cancelTimer(.reply), .requestToken(forceRefresh: forceRefresh)]

        case (.authenticating(let tag, let attempt, false), .continuation):
            let credentials = pendingCredentials ?? ""
            pendingCredentials = nil
            state = .authenticating(tag: tag, attempt: attempt, sentCredentials: true)
            return [.send(Self.line(credentials))]
        case (.authenticating(_, _, true), .continuation):
            // A failure challenge. An empty answer makes the server finish with NO.
            return [.send(Self.line(""))]
        case (.authenticating, .capability(let names)):
            capabilities = Set(names)
            return []
        case (.authenticating(let expected, _, _), .tagged(let tag, .ok, let code)) where tag == expected:
            if let listed = Self.capabilities(in: code) { capabilities = listed }
            if let capabilities { return capabilities.contains("IDLE") ? examine() : close(.unsupported) }
            let next = nextTag()
            state = .postAuthCapability(tag: next)
            return [.send(Self.line("\(next) CAPABILITY")), .startTimer(.reply, after: Self.replyTimeout)]
        case (.authenticating(let expected, let attempt, _), .tagged(let tag, _, _)) where tag == expected:
            pendingCredentials = nil
            guard attempt == 1 else { return close(.authenticationFailed) }
            // The token may have been revoked or about to expire.
            state = .waitingForToken(attempt: 2)
            return [.cancelTimer(.reply), .requestToken(forceRefresh: true)]

        case (.postAuthCapability, .capability(let names)):
            capabilities = (capabilities ?? []).union(names)
            return []
        case (.postAuthCapability(let expected), .tagged(let tag, .ok, let code)) where tag == expected:
            let all = (capabilities ?? []).union(Self.capabilities(in: code) ?? [])
            return all.contains("IDLE") ? examine() : close(.unsupported)

        case (.examining(let expected), .tagged(let tag, .ok, _)) where tag == expected:
            examined = true
            let idle = startIdle()
            guard !signalled else { return idle }
            signalled = true
            return [.signal] + idle

        case (.startingIdle(let tag), .continuation):
            state = .idling(tag: tag)
            if idlingSince == nil { idlingSince = now }
            return [.cancelTimer(.reply), .startTimer(.idleRestart, after: Self.idleRestartInterval)]
        case (.idling(let expected), .tagged(let tag, .ok, _)) where tag == expected,
             (.endingIdle(let expected), .tagged(let tag, .ok, _)) where tag == expected:
            // DONE was answered, or the server ended IDLE by itself.
            return [.cancelTimer(.idleRestart)] + startIdle()

        case (_, .tagged):
            // A NO or BAD where an OK was needed, or a tag nobody sent.
            return close(.reconnect(afterBackoff(at: now)))
        case (.idling, .continuation), (.endingIdle, .continuation):
            return []
        case (_, .continuation):
            return close(.reconnect(afterBackoff(at: now)))
        default:
            // Untagged data that changes nothing here, such as FLAGS or a
            // pre-EXAMINE EXISTS.
            return []
        }
    }

    private mutating func examine() -> [Action] {
        let tag = nextTag()
        state = .examining(tag: tag)
        // EXAMINE opens INBOX read-only.
        return [.send(Self.line("\(tag) EXAMINE INBOX")), .startTimer(.reply, after: Self.replyTimeout)]
    }

    private mutating func startIdle() -> [Action] {
        let tag = nextTag()
        state = .startingIdle(tag: tag)
        return [.send(Self.line("\(tag) IDLE")), .startTimer(.reply, after: Self.replyTimeout)]
    }

    /// The names in a `[CAPABILITY …]` code, upper-cased.
    private static func capabilities(in code: IMAPResponse.Code?) -> Set<String>? {
        guard let code, code.name == "CAPABILITY" else { return nil }
        return Set(code.arguments.map { $0.uppercased() })
    }

    private mutating func close(_ ending: Ending) -> [Action] {
        state = .closed(ending)
        pendingCredentials = nil
        return [.close(ending)]
    }

    private mutating func nextTag() -> String {
        tagNumber += 1
        return "A\(tagNumber)"
    }

    private static func isChange(_ response: IMAPResponse) -> Bool {
        switch response {
        case .exists, .expunge, .fetch: true
        default: false
        }
    }

    // MARK: Reconnect policy

    private func afterBackoff(at now: ContinuousClock.Instant) -> Reconnect {
        Reconnect(immediately: false, forceRefresh: false, resetBackoff: idledLongEnough(at: now))
    }

    /// A long session ended as its token expired. A short one may have used
    /// a token that was about to, or the server is turning connections away.
    private func afterBye(at now: ContinuousClock.Instant) -> Ending {
        if now - startedAt >= Self.longSession {
            return .reconnect(Reconnect(immediately: true, forceRefresh: false, resetBackoff: true))
        }
        return .reconnect(Reconnect(immediately: false, forceRefresh: true, resetBackoff: idledLongEnough(at: now)))
    }

    private func idledLongEnough(at now: ContinuousClock.Instant) -> Bool {
        idlingSince.map { now - $0 >= Self.healthyIdle } ?? false
    }

    // MARK: Encoding

    /// The XOAUTH2 initial response, base64-encoded. It holds the address and
    /// the token, so it's never logged.
    static func xoauth2(address: String, token: String) -> String {
        Data("user=\(address)\u{01}auth=Bearer \(token)\u{01}\u{01}".utf8).base64EncodedString()
    }

    private static func line(_ text: String) -> Data {
        Data((text + "\r\n").utf8)
    }
}

extension IdleSession: CustomStringConvertible, CustomReflectable {
    /// The session holds the address and, briefly, the XOAUTH2 string, so it
    /// prints and dumps without its fields.
    public var description: String { "IdleSession" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Waits between reconnects: 1 second at first, doubling up to 5 minutes,
/// each within 20% either way so many clients don't reconnect in step.
public struct Backoff: Sendable {
    public static let shortest: Duration = .seconds(1)
    public static let longest: Duration = .seconds(300)

    private var current = Backoff.shortest

    public init() {}

    /// - Parameter jitter: The fraction to add or take off, from -0.2 to 0.2.
    public mutating func nextDelay(jitter: Double = .random(in: -0.2...0.2)) -> Duration {
        let delay = current * (1 + min(max(jitter, -0.2), 0.2))
        current = min(current * 2, Self.longest)
        return delay
    }

    public mutating func reset() {
        current = Self.shortest
    }
}
