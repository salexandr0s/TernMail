import Foundation
import Network
import Synchronization
import Testing
@testable import Tern

@MainActor
@Suite struct LoopbackAuthListenerTests {
    @Test(.timeLimit(.minutes(1))) func idleAndPartialHeadersReleaseEverySlotBeforeTheSignInDeadline() async throws {
        let listener = LoopbackAuthListener(timeout: .seconds(10), connectionTimeout: .milliseconds(250))
        let callback = try await listener.start()
        defer { listener.cancel() }
        listener.expect(state: "synthetic-state")

        var sockets: [LoopbackSocket] = []
        for index in 0..<8 {
            let socket = try LoopbackSocket(callback)
            sockets.append(socket)
            try await socket.start()
            if index.isMultiple(of: 2) {
                try await socket.send(Data("GET /auth/callback HTTP/1.1\r\n".utf8))
            }
        }
        let closed = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for socket in sockets {
                group.addTask { await socket.closedWithoutResponse() }
            }
            var count = 0
            for await didClose in group where didClose { count += 1 }
            return count
        }
        #expect(closed == 8)

        var components = try #require(URLComponents(url: callback, resolvingAgainstBaseURL: false))
        components.queryItems = [.init(name: "state", value: "synthetic-state"), .init(name: "code", value: "synthetic-code")]
        let returned = try #require(components.url)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(from: returned)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(try await listener.callback() == returned)
    }

    @Test(.timeLimit(.minutes(1))) func cancellationClosesPendingSocketsAndKeepsTheCancellationResult() async throws {
        let listener = LoopbackAuthListener(timeout: .seconds(10), connectionTimeout: .seconds(5))
        let callback = try await listener.start()
        listener.expect(state: "synthetic-state")
        let socket = try LoopbackSocket(callback)
        try await socket.start()
        try await socket.send(Data("GET /auth/callback HTTP/1.1\r\n".utf8))

        listener.cancel()
        listener.cancel()
        #expect(await socket.closedWithoutResponse())
        await #expect(throws: CancellationError.self) { try await listener.callback() }
    }
}

@MainActor
private final class LoopbackSocket {
    private let connection: NWConnection
    private var ready: CheckedContinuation<Void, any Error>?

    init(_ callback: URL) throws {
        let value = try #require(callback.port)
        let port = try #require(NWEndpoint.Port(rawValue: UInt16(value)))
        connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
    }

    deinit { connection.cancel() }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            connection.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, let ready = self.ready else { return }
                    switch state {
                    case .ready:
                        self.ready = nil
                        ready.resume()
                    case .failed(let error), .waiting(let error):
                        self.ready = nil
                        ready.resume(throwing: error)
                    case .cancelled:
                        self.ready = nil
                        ready.resume(throwing: CancellationError())
                    default: break
                    }
                }
            }
            connection.start(queue: .main)
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    func closedWithoutResponse() async -> Bool {
        let pending = Mutex<CheckedContinuation<Bool, Never>?>(nil)
        let connection = connection
        return await withCheckedContinuation { continuation in
            pending.withLock { $0 = continuation }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { data, _, complete, error in
                let continuation = pending.withLock { value in
                    let result = value; value = nil; return result
                }
                continuation?.resume(returning: (data?.isEmpty ?? true) && (complete || error != nil))
            }
            // A broken server deadline fails this assertion instead of waiting
            // for the overall OAuth deadline or leaving a receive suspended.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                let continuation = pending.withLock { value in
                    let result = value; value = nil; return result
                }
                guard let continuation else { return }
                connection.cancel()
                continuation.resume(returning: false)
            }
        }
    }
}
