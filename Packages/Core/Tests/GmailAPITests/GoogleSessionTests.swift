import Foundation
import os
import Testing
@testable import GmailAPI

@Suite(.timeLimit(.minutes(1))) struct GoogleSessionTests {
    @Test(arguments: [false, true])
    func transportFailuresRetryReadsButNeverReplaySends(sending: Bool) async {
        let transport = FailingTransport(code: .timedOut)
        let tokens = CountingTokens()
        let time = OSAllocatedUnfairLock(initialState: TimeInterval.zero)
        let budget = GmailRequestBudget(now: { time.withLock { $0 } }, sleep: { duration in
            try Task.checkCancellation()
            let parts = duration.components
            time.withLock { $0 += Double(parts.seconds) + Double(parts.attoseconds) / 1e18 }
        })
        let client = GmailClient(tokens: tokens, transport: transport, gmailRequestBudget: budget)

        await #expect(throws: GmailError.transport(.timedOut)) {
            if sending {
                _ = try await client.sendDraft(id: "d1")
            } else {
                _ = try await client.profile()
            }
        }

        #expect(await transport.requests.count == (sending ? 1 : 4))
        #expect(time.withLock { $0 } == (sending ? 0 : 7))
        #expect(await tokens.refreshes == 0)
    }

    @Test(arguments: [false, true])
    func transportCancellationOnlyBecomesTaskCancellationWhenTheTaskWasCancelled(cancelTask: Bool) async {
        let transport = FailingTransport(code: .cancelled, cancelTask: cancelTask)
        let budget = GmailRequestBudget(sleep: { _ in
            Issue.record("A cancelled send must not wait to retry")
            throw CancellationError()
        })
        let tokens = CountingTokens()
        let client = GmailClient(tokens: tokens, transport: transport, gmailRequestBudget: budget)
        await withThrowingTaskGroup(of: GmailMessage.self) { group in
            group.addTask { try await client.sendDraft(id: "d1") }
            do {
                _ = try await group.next()
                Issue.record("The cancelled transport request returned successfully")
            } catch {
                if cancelTask {
                    #expect(error is CancellationError)
                } else {
                    #expect(error as? GmailError == .transport(.cancelled))
                }
            }
        }

        #expect(await transport.requests.count == 1)
        #expect(await tokens.refreshes == 0)
        let state = await budget.snapshot()
        #expect(state.executing.isEmpty)
        #expect(state.waiting.isEmpty)
        #expect(state.sharedCooldown == 0)
        #expect(state.laneCooldowns.isEmpty)
    }
}

private actor FailingTransport: HTTPTransport {
    let code: URLError.Code
    let cancelTask: Bool
    private(set) var requests: [URLRequest] = []

    init(code: URLError.Code, cancelTask: Bool = false) {
        self.code = code
        self.cancelTask = cancelTask
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        // Cancel the request's child task at the transport boundary, before
        // returning the error URLSession reports for a cancelled request.
        if cancelTask { withUnsafeCurrentTask { $0?.cancel() } }
        throw URLError(code)
    }
}
