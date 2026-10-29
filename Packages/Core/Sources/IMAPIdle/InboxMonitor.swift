import Foundation
import GmailAPI
import Network

/// Watches one account's INBOX over IMAP IDLE, connecting again with backoff
/// whenever the connection ends. Tern never reads mail over IMAP: a signal
/// only says that INBOX may have changed, and history sync does the rest.
public actor InboxMonitor {
    public enum Failure: Error, Sendable, Equatable {
        /// The server lacks XOAUTH2 or IDLE.
        case unsupported
        /// Gmail refused the token twice, the second time a refreshed one.
        case authenticationFailed
    }

    private enum Input: Sendable {
        case data(Data)
        case ended
        case timer(IdleSession.Timer)
        case token(Result<String, any Error>)
        case restart
    }

    private let address: String
    private let tokens: any AccessTokenProvider
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "dev.tern.imap-idle")

    private var generation = 0
    private var watching: Task<Void, Never>?
    private var input: AsyncStream<Input>.Continuation?
    private var backoffWait: Task<Void, Never>?

    /// - Parameter tokens: Must grant `https://mail.google.com/`, the only
    ///   scope Gmail accepts for IMAP.
    public init(address: String, tokens: any AccessTokenProvider, host: String = "imap.gmail.com", port: NWEndpoint.Port = .imaps) {
        self.address = address
        self.tokens = tokens
        self.host = NWEndpoint.Host(host)
        self.port = port
    }

    /// Starts watching and ends any earlier stream. The stream yields after
    /// each successful EXAMINE and for each batch of INBOX changes. It
    /// finishes after `stop()`, and throws a `Failure`, or the token
    /// provider's error, when watching can't go on.
    public func signals() -> AsyncThrowingStream<Void, any Error> {
        stop()
        generation += 1
        let current = generation
        let (stream, output) = AsyncThrowingStream<Void, any Error>.makeStream()
        output.onTermination = { [weak self] _ in
            Task { await self?.streamEnded(current) }
        }
        watching = Task { await self.watch(output) }
        return stream
    }

    public func stop() {
        watching?.cancel()
        watching = nil
        backoffWait?.cancel()
    }

    /// Connects again without waiting, as after the Mac wakes or the network
    /// comes back, when the old connection may be dead without knowing it.
    public func reconnectNow() {
        if let backoffWait {
            backoffWait.cancel()
        } else {
            input?.yield(.restart)
        }
    }

    private func streamEnded(_ ended: Int) {
        if ended == generation { stop() }
    }

    private func watch(_ output: AsyncThrowingStream<Void, any Error>.Continuation) async {
        var backoff = Backoff()
        var forceRefresh = false
        while !Task.isCancelled {
            let ending: IdleSession.Ending
            do {
                ending = try await connect(forceRefresh: forceRefresh, output: output)
            } catch is CancellationError {
                break
            } catch {
                output.finish(throwing: error)
                return
            }
            switch ending {
            case .unsupported:
                output.finish(throwing: Failure.unsupported)
                return
            case .authenticationFailed:
                output.finish(throwing: Failure.authenticationFailed)
                return
            case .reconnect(let plan):
                if plan.resetBackoff { backoff.reset() }
                forceRefresh = plan.forceRefresh
                if !plan.immediately { await wait(backoff.nextDelay()) }
            }
        }
        output.finish()
    }

    /// Sleeps unless `reconnectNow()` or `stop()` cuts the wait short.
    private func wait(_ delay: Duration) async {
        let sleep = Task<Void, Never> { _ = try? await Task.sleep(for: delay) }
        backoffWait = sleep
        await withTaskCancellationHandler {
            await sleep.value
        } onCancel: {
            sleep.cancel()
        }
        backoffWait = nil
    }

    /// One connection, from connecting to its end.
    private func connect(forceRefresh: Bool, output: AsyncThrowingStream<Void, any Error>.Continuation) async throws -> IdleSession.Ending {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 30
        // IDLE can be silent for minutes. Keepalive notices a peer that's gone.
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 120
        tcp.keepaliveInterval = 30
        tcp.keepaliveCount = 4
        let connection = NWConnection(host: host, port: port, using: NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp))

        let (inputs, input) = AsyncStream<Input>.makeStream()
        self.input = input
        var timers: [IdleSession.Timer: Task<Void, Never>] = [:]
        var tokenRequest: Task<Void, Never>?
        defer {
            connection.cancel()
            timers.values.forEach { $0.cancel() }
            tokenRequest?.cancel()
            input.finish()
            self.input = nil
        }

        connection.stateUpdateHandler = { state in
            switch state {
            // Waiting means no route right now. The backoff decides when to try again.
            case .failed, .cancelled, .waiting: input.yield(.ended)
            default: break
            }
        }
        Self.receive(on: connection, into: input)
        connection.start(queue: queue)

        let tokens = self.tokens
        func perform(_ actions: [IdleSession.Action]) -> IdleSession.Ending? {
            for action in actions {
                switch action {
                case .send(let bytes):
                    connection.send(content: bytes, completion: .contentProcessed { error in
                        if error != nil { input.yield(.ended) }
                    })
                case .requestToken(let forceRefresh):
                    tokenRequest?.cancel()
                    tokenRequest = Task {
                        do {
                            input.yield(.token(.success(try await tokens.accessToken(forceRefresh: forceRefresh))))
                        } catch {
                            input.yield(.token(.failure(error)))
                        }
                    }
                case .startTimer(let timer, let delay):
                    timers[timer]?.cancel()
                    timers[timer] = Task {
                        try? await Task.sleep(for: delay)
                        if !Task.isCancelled { input.yield(.timer(timer)) }
                    }
                case .cancelTimer(let timer):
                    timers[timer]?.cancel()
                    timers[timer] = nil
                case .signal:
                    output.yield()
                case .close(let ending):
                    return ending
                }
            }
            return nil
        }

        var session = IdleSession(address: address, startedAt: .now, forceRefresh: forceRefresh)
        if let ending = perform(session.start()) { return ending }
        for await next in inputs {
            let actions: [IdleSession.Action]
            switch next {
            case .data(let bytes):
                actions = session.receive(bytes, at: .now)
            case .ended:
                return session.connectionEnded(at: .now)
            case .timer(let timer):
                actions = session.timerFired(timer, at: .now)
            case .token(.success(let token)):
                actions = session.provideToken(token)
            case .token(.failure(let error)):
                throw error
            case .restart:
                return .reconnect(IdleSession.Reconnect(immediately: true, forceRefresh: false, resetBackoff: true))
            }
            if let ending = perform(actions) { return ending }
        }
        // The stream only finishes early when the task is cancelled.
        throw CancellationError()
    }

    private static func receive(on connection: NWConnection, into input: AsyncStream<Input>.Continuation) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            if let data, !data.isEmpty { input.yield(.data(data)) }
            guard !isComplete, error == nil else {
                input.yield(.ended)
                return
            }
            receive(on: connection, into: input)
        }
    }
}
