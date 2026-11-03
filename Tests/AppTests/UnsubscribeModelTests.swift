import Foundation
import MailStore
import MessageContent
import Testing
@testable import Tern

@Suite @MainActor struct UnsubscribeModelTests {
    @Test func selectAllOnlySelectsVisibleEligibleSubscriptions() async throws {
        let store = UnsubscribeTestStore()
        let model = store.makeModel()
        await model.load()
        model.toggleAll()
        #expect(model.selectedCount == 3)
        #expect(model.allVisibleSelected)
        #expect(!model.selectedIDs.contains(store.rows[2].id))
        model.toggleSelection(store.rows[0])
        #expect(model.someVisibleSelected)
        model.search = "Garden"
        #expect(model.selectedCount == 0)
        model.toggleAll()
        #expect(model.selectedCount == 1)
        model.proposeSelection()
        #expect(model.confirmation?.subscriptions.map(\.id) == [store.rows[0].id])
        model.selectedAccountID = "second"
        #expect(model.confirmation == nil)
        #expect(model.selectedIDs.isEmpty)
    }

    @Test func batchPersistsPartialSuccessAndNeverRetriesOnReload() async throws {
        let store = UnsubscribeTestStore()
        store.failures = [store.rows[1].id]
        let model = store.makeModel()
        await model.load()
        model.toggleAll(); model.proposeSelection(); model.confirmUnsubscribe()
        try await unsubscribeEventually { !model.isWorking }
        #expect(store.requests.count == 3)
        #expect(model.requestedCount == 2)
        #expect(model.errorMessage != nil)
        #expect(model.visibleSubscriptions.contains { $0.status == .failed })
        await model.load()
        #expect(store.requests.count == 3)
        model.filter = .history
        #expect(model.visibleSubscriptions.count == 2)
        #expect(!model.canSelectAll)
    }

    @Test func openingManualOptionRequiresSeparateCompletion() async throws {
        let store = UnsubscribeTestStore()
        let model = store.makeModel()
        await model.load()
        model.openSubscription(store.rows[2])
        await model.openManualLink()
        #expect(store.opened == [store.rows[2].id])
        #expect(model.manualSubscription?.status == .opened)
        #expect(model.requestedCount == 0)
        #expect(store.requests.isEmpty)
        await model.markManualComplete()
        #expect(model.manualSubscription == nil)
        model.filter = .history
        #expect(model.visibleSubscriptions.first?.status == .completed)
        #expect(model.requestedCount == 0)
    }

    @Test func accountRemovalFencesALateBatchResult() async throws {
        let store = UnsubscribeTestStore()
        let gate = UnsubscribeTestGate()
        store.requestGate = gate
        let model = store.makeModel()
        await model.load()
        model.proposeUnsubscribe(store.rows[0]); model.confirmUnsubscribe()
        try await unsubscribeEventually { store.requests.count == 1 }
        model.configure(accounts: [], unavailable: [])
        gate.release()
        try await Task.sleep(for: .milliseconds(30))
        #expect(model.subscriptions.isEmpty)
        #expect(!model.isWorking)
        #expect(model.confirmation == nil)
    }

    @Test func stopBatchDoesNotStartRemainingRequests() async throws {
        let store = UnsubscribeTestStore()
        let gate = UnsubscribeTestGate()
        store.requestGate = gate
        let model = store.makeModel()
        await model.load()
        model.toggleAll(); model.proposeSelection(); model.confirmUnsubscribe()
        try await unsubscribeEventually { store.requests.count == 1 }
        model.stopBatch(); gate.release()
        try await unsubscribeEventually { !model.isWorking }
        #expect(store.requests.count == 1)
        #expect(model.requestedCount == 1)
    }

    @Test func cancelledBatchReadsPersistedOutcomeOutsideCancelledTask() async throws {
        let store = UnsubscribeTestStore()
        let gate = UnsubscribeTestGate()
        store.requestGate = gate; store.throwAfterAcceptedCancellation = true
        let model = store.makeModel()
        await model.load()
        model.toggleAll(); model.proposeSelection(); model.confirmUnsubscribe()
        try await unsubscribeEventually { store.requests.count == 1 }
        model.stopBatch(); gate.release()
        try await unsubscribeEventually { !model.isWorking }
        #expect(store.requests.count == 1)
        #expect(model.requestedCount == 1)
        #expect(!model.selectedIDs.contains(store.rows[0].id))
    }

    @Test func replacementScopeWaitsForCancelledRequestOutcome() async throws {
        let store = UnsubscribeTestStore()
        let gate = UnsubscribeTestGate()
        store.requestGate = gate; store.throwAfterAcceptedCancellation = true
        let model = store.makeModel()
        await model.load()
        model.proposeUnsubscribe(store.rows[0]); model.confirmUnsubscribe()
        try await unsubscribeEventually { store.requests.count == 1 }
        model.configure(accounts: store.accounts, unavailable: [])
        let loading = Task { await model.load() }
        try await unsubscribeEventually { model.isLoading }
        gate.release()
        await loading.value
        #expect(model.requestedCount == 1)
        #expect(!model.isWorking)
    }

    @Test func scanLoadsPagesAndRetainsProgressOnFailure() async throws {
        let store = UnsubscribeTestStore()
        store.isComplete = false; store.failScanAfter = 2
        let model = store.makeModel()
        model.selectedAccountID = "first"
        await model.load()
        try await unsubscribeEventually { !model.isScanning }
        #expect(store.scanCalls == 2)
        #expect(model.errorMessage != nil)
        #expect(model.subscriptions.count == 3)
        #expect(model.hasMoreToScan)
        store.failScanAfter = nil
        model.startScan()
        try await unsubscribeEventually { !model.isScanning }
        #expect(!model.hasMoreToScan)
    }

    @Test func unavailableAccountsCannotBeSelectedOrActedOn() async throws {
        let store = UnsubscribeTestStore()
        let model = store.makeModel()
        await model.load()
        model.configure(accounts: store.accounts, unavailable: ["first"])
        model.toggleAll()
        #expect(model.selectedCount == 1)
        model.proposeUnsubscribe(store.rows[0])
        #expect(model.confirmation == nil)
        model.openSubscription(store.rows[2])
        #expect(model.manualSubscription == nil)
    }

    @Test func unsubscribeMailtoUsesReceivingAccount() async throws {
        try #require(ProcessInfo.processInfo.arguments.contains("--ui-audit"))
        let app = AppModel()
        await app.start()
        let mailbox = try #require(app.mailbox)
        let receiver = try #require(mailbox.accounts.last?.account.id)
        let draftID = try #require(await mailbox.startMailto(
            MailtoRequest(to: [.init(address: "unsubscribe@example.invalid")], subject: "Remove me", body: "unsubscribe"),
            accountID: receiver))
        let draft = try #require(try await mailbox.cache.read { try $0.localDraft(id: draftID) })
        #expect(draft.accountID == receiver)
        #expect(draft.content.subject == "Remove me")
        #expect(draft.content.to.map(\.address) == ["unsubscribe@example.invalid"])
        #expect(await mailbox.startMailto(MailtoRequest(), accountID: "removed") == nil)
        await app.prepareToQuit()
        await mailbox.stop()
        app.accountPreferences?.stop()
    }
}

@MainActor final class UnsubscribeTestStore {
    let accounts = [UnsubscribeAccount(id: "first", title: "Personal", email: "me@example.invalid"),
                    UnsubscribeAccount(id: "second", title: "Work", email: "work@example.invalid")]
    var rows: [NewsletterSubscription] = [
        .init(accountID: "first", senderAddress: "hello@garden.example", senderName: "The Sunday Garden",
              listID: "weekly.garden.example", latestMessageID: "garden", latestThreadID: "garden-thread",
              latestSubject: "A slower start to November", latestDate: .now.addingTimeInterval(-3_600), messageCount: 128,
              unsubscribeURL: URL(string: "https://garden.example/unsubscribe"), oneClickURL: URL(string: "https://garden.example/unsubscribe")),
        .init(accountID: "first", senderAddress: "dispatch@northstar.example", senderName: "Northstar Dispatch",
              listID: "dispatch.northstar.example", latestMessageID: "north", latestThreadID: "north-thread",
              latestSubject: "This week in design and technology", latestDate: .now.addingTimeInterval(-86_400), messageCount: 86,
              unsubscribeURL: URL(string: "https://northstar.example/unsubscribe"), oneClickURL: URL(string: "https://northstar.example/unsubscribe")),
        .init(accountID: "first", senderAddress: "notes@fieldwork.example", senderName: "Fieldwork Notes",
              latestMessageID: "field", latestThreadID: "field-thread", latestSubject: "Places to explore this autumn",
              latestDate: .now.addingTimeInterval(-172_800), messageCount: 42, unsubscribeURL: URL(string: "https://fieldwork.example/preferences")),
        .init(accountID: "second", senderAddress: "briefing@build.example", senderName: "The Builders’ Briefing",
              listID: "engineering.build.example", latestMessageID: "build", latestThreadID: "build-thread",
              latestSubject: "Small teams, useful tools, and better software", latestDate: .now.addingTimeInterval(-240_000), messageCount: 24,
              unsubscribeURL: URL(string: "https://build.example/unsubscribe"), oneClickURL: URL(string: "https://build.example/unsubscribe"))
    ]
    var failures: Set<String> = []
    var requests: [String] = []
    var opened: [String] = []
    var requestGate: UnsubscribeTestGate?
    var throwAfterAcceptedCancellation = false
    var isComplete = true
    var scanCalls = 0
    var failScanAfter: Int?

    func snapshot(_ accountID: String) -> NewsletterSnapshot {
        .init(accountID: accountID, subscriptions: rows.filter { $0.accountID == accountID },
              scannedMessageCount: 300 + scanCalls * 100, isComplete: isComplete)
    }

    func makeModel() -> UnsubscribeModel {
        let model = UnsubscribeModel(client: { [self] id in
            UnsubscribeClient(snapshot: { try Task.checkCancellation(); return self.snapshot(id) }, scan: { _ in
                self.scanCalls += 1
                if let fail = self.failScanAfter, self.scanCalls >= fail { throw URLError(.notConnectedToInternet) }
                if self.scanCalls >= 3 { self.isComplete = true }
                return self.snapshot(id)
            }, request: { key in
                self.requests.append(key)
                if let gate = self.requestGate { await gate.wait() }
                if self.failures.contains(key) { self.update(key, status: .failed); throw URLError(.timedOut) }
                let result = self.update(key, status: .requested)
                if self.throwAfterAcceptedCancellation { try Task.checkCancellation() }
                return result
            }, markOpened: { _ = self.update($0, status: .opened) },
               complete: { _ = self.update($0, status: .completed) }, reset: { _ = self.update($0, status: .active) })
        }, openManual: { [self] in opened.append($0.id) })
        model.configure(accounts: accounts, unavailable: [])
        return model
    }

    @discardableResult func update(_ id: String, status: NewsletterUnsubscribeStatus) -> NewsletterSubscription {
        let index = rows.firstIndex { $0.id == id }!
        let item = rows[index]
        let changed = NewsletterSubscription(id: item.id, accountID: item.accountID, senderAddress: item.senderAddress,
            senderName: item.senderName, listID: item.listID, latestMessageID: item.latestMessageID,
            latestThreadID: item.latestThreadID, latestSubject: item.latestSubject, latestDate: item.latestDate,
            messageCount: item.messageCount, unsubscribeURL: item.unsubscribeURL, mailtoURL: item.mailtoURL,
            oneClickURL: item.oneClickURL, status: status, statusDate: .now,
            lastError: status == .failed ? "The request may have reached the sender. Check before retrying." : nil)
        rows[index] = changed
        return changed
    }
}

@MainActor final class UnsubscribeTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor func unsubscribeEventually(_ condition: @escaping @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(4)
    while !condition() {
        try #require(ContinuousClock.now < deadline)
        try await Task.sleep(for: .milliseconds(10))
    }
}
