import Foundation
import GmailAPI
import Testing
@testable import MailStore

@Suite struct SettingsRowTests {
    let acct = "acct"
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let filter = GmailFilter(criteria: .init(from: "news@example.com"), action: .init(removeLabelIds: ["INBOX"]))

    func vacation(_ subject: String) -> PendingAction.SettingsChange {
        .vacation(fields: [.subject], new: VacationSettings(responseSubject: subject), previous: VacationSettings())
    }

    func signature(_ address: String) -> PendingAction.SettingsChange {
        .signature(address: address, html: "<b>Me</b>", previousHTML: "")
    }

    @Test func rowsThatShareAKeyGoOutOneAtATimeInOrder() async throws {
        let cache = try MailCache.inMemory()
        let later = now + 60
        try await cache.write { [self] tx in
            // The first change waits out a retry's backoff.
            let first = try tx.enqueueSettingsChange(vacation("Away"), accountID: acct, now: now, notBefore: later)
            let second = try tx.enqueueSettingsChange(vacation("Back"), accountID: acct, now: now, notBefore: now)
            #expect(try tx.claimDueActions(accountID: acct, now: now, lane: .settings).isEmpty)

            #expect(try tx.claimDueActions(accountID: acct, now: later, lane: .settings).map(\.id) == [first.id])
            // Undo marks a row in flight as undone; its reverse still waits for it.
            let firstID = try #require(first.id)
            var undone = try #require(try tx.action(id: firstID))
            undone.state = .undone
            try tx.updateAction(undone)
            #expect(try tx.claimDueActions(accountID: acct, now: later, lane: .settings).isEmpty)

            try tx.deleteAction(id: firstID)
            #expect(try tx.claimDueActions(accountID: acct, now: later, lane: .settings).map(\.id) == [second.id])

            // Every filter row shares one key, whatever it does.
            let create = try tx.enqueueSettingsChange(.createFilter(filter: filter, listedIDs: nil), accountID: acct, now: now, notBefore: now)
            _ = try tx.enqueueSettingsChange(.deleteFilter(id: "f1", filter: filter), accountID: acct, now: now, notBefore: now)
            #expect(try tx.claimDueActions(accountID: acct, now: later, lane: .settings).map(\.id) == [create.id])
        }
    }

    @Test func differentSettingsDontWaitForEachOther() async throws {
        let cache = try MailCache.inMemory()
        try await cache.write { [self] tx in
            let rows = try [
                vacation("Away"),
                signature("Me@Example.com"),
                // The same address in another case waits for the first.
                signature("me@example.com"),
                signature("other@example.com"),
                .replaceFilter(oldID: "f1", old: filter, new: filter, listedIDs: nil, newID: nil),
            ].map { try tx.enqueueSettingsChange($0, accountID: acct, now: now, notBefore: now) }

            let claimed = try tx.claimDueActions(accountID: acct, now: now, lane: .settings)
            #expect(claimed.map(\.id) == [rows[0].id, rows[1].id, rows[3].id, rows[4].id])
            #expect(claimed.map(\.kind) == [.updateVacation, .updateSignature, .updateSignature, .replaceFilter])
        }
    }

    @Test func settingsRowsDrainInTheirOwnLane() async throws {
        let cache = try MailCache.inMemory()
        try await cache.write { [self] tx in
            // A label change held back by a retry doesn't hold up settings.
            let archive = try tx.enqueue(
                .modifyThreads, accountID: acct, threadIDs: ["t1"], remove: [SystemLabel.inbox], now: now, notBefore: now + 60
            )
            let change = try tx.enqueueSettingsChange(signature("me@example.com"), accountID: acct, now: now, notBefore: now)

            #expect(try tx.claimDueActions(accountID: acct, now: now, lane: .settings).map(\.id) == [change.id])
            #expect(try tx.claimDueActions(accountID: acct, now: now + 60, lane: .labels).map(\.id) == [archive.id])
            #expect(try tx.claimDueActions(accountID: acct, now: now + 60, lane: .compose).isEmpty)
        }
    }
}
