import Foundation
import GRDB
import Testing
@testable import MailStore

private let acct = "acct"
private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let pending = LabelRules.temporaryPrefix + "1"
private let blue = PendingAction.LabelChange.Color(textColor: "#ffffff", backgroundColor: "#1c4587")

@Suite struct LabelRulesTests {
    @Test func displayedLabelsKeepQueuedChangesOverAnOlderListing() async throws {
        let cache = try MailCache.inMemory()
        let listing = [system(SystemLabel.inbox), user("Label_1", "Trips"), user("Label_2", "Bills")]
        try await cache.write { tx in
            try tx.replaceLabels(listing, accountID: acct)
            _ = try tx.enqueueLabelChange(.createLabel, labelID: pending, change: .init(newName: "Plans", newColor: .set(blue)), accountID: acct, now: now, notBefore: now)
            var rename = try tx.enqueueLabelChange(.updateLabel, labelID: "Label_1", change: .init(newName: "Travel", oldName: "Trips"), accountID: acct, now: now, notBefore: now)
            rename.state = .sent
            rename.sentAt = now
            try tx.updateAction(rename)
            _ = try tx.enqueueLabelChange(.deleteLabel, labelID: "Label_2", change: .init(deletedLabel: user("Label_2", "Bills")), accountID: acct, now: now, notBefore: now)
            // A listing fetched before the changes reached Gmail, committed after.
            try tx.replaceLabels(listing, accountID: acct)
            try tx.dropSentActions(sentBefore: now, accountID: acct)
        }
        let shown = try await cache.read { tx in try tx.displayedLabels(accountID: acct) }
        #expect(shown.map(\.name) == [SystemLabel.inbox, "Plans", "Travel"])
        #expect(shown.first { $0.name == "Plans" }.map { ($0.id, $0.backgroundColor) } ?? ("", nil) == (pending, blue.backgroundColor))
    }

    @Test func aFailedRenameUnderALaterOneLeavesTheLaterName() async throws {
        let cache = try MailCache.inMemory()
        let shown = try await cache.write { tx in
            try tx.replaceLabels([user("Label_1", "A")], accountID: acct)
            let first = try tx.enqueueLabelChange(.updateLabel, labelID: "Label_1", change: .init(newName: "B", oldName: "A"), accountID: acct, now: now, notBefore: now)
            _ = try tx.enqueueLabelChange(.updateLabel, labelID: "Label_1", change: .init(newName: "C", oldName: "B"), accountID: acct, now: now, notBefore: now)
            try tx.deleteAction(id: try #require(first.id))
            return try tx.displayedLabels(accountID: acct).map(\.name)
        }
        #expect(shown == ["C"])
    }

    @Test func namesMustBeNewNonEmptyAndNotReserved() {
        let labels = [system(SystemLabel.inbox), user("Label_1", "Trips")]
        #expect(LabelRules.problem(with: " ", among: labels) == .empty)
        #expect(LabelRules.problem(with: "Work/", among: labels) == .empty)
        #expect(LabelRules.problem(with: "Spam", among: labels) == .reserved)
        #expect(LabelRules.problem(with: "inbox", among: labels) == .reserved)
        #expect(LabelRules.problem(with: "trips", among: labels) == .taken)
        #expect(LabelRules.problem(with: "TRIPS", among: labels, renaming: "Label_1") == nil)
        #expect(LabelRules.problem(with: "Trips/2026", among: labels) == nil)
    }

    @Test func childrenAreRenamedWithTheirParentParentsFirst() {
        let labels = [user("1", "Work/Trips/2026"), user("2", "Work"), user("3", "Workshop"), user("4", "Work/Trips")]
        let renamed = LabelRules.renamedChildren(of: "Work", to: "Job", among: labels)
        #expect(renamed.map(\.label.id) == ["4", "1"])
        #expect(renamed.map(\.name) == ["Job/Trips", "Job/Trips/2026"])
    }

    @Test func gmailsIDReplacesTheTemporaryOneEverywhere() async throws {
        let cache = try MailCache.inMemory()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox])])
        let (changed, resolved, underReal) = try await cache.write { tx -> ([PendingAction], String, [String]) in
            _ = try tx.enqueueLabelChange(.createLabel, labelID: pending, change: .init(newName: "Plans"), accountID: acct, now: now, notBefore: now)
            _ = try tx.enqueue(.modifyThreads, accountID: acct, threadIDs: ["t1"], add: [pending], now: now, notBefore: now)
            _ = try tx.enqueueLabelChange(.updateLabel, labelID: pending, change: .init(newColor: .set(blue)), accountID: acct, now: now, notBefore: now)
            let changed = try tx.recordCreatedLabel(temporaryID: pending, realID: "Label_9", accountID: acct)
            return (changed, try tx.resolvedLabelID(pending, accountID: acct), try listed(tx, "Label_9"))
        }
        #expect(changed.map(\.labelID) == ["Label_9", nil, "Label_9"])
        #expect(changed[1].addLabelIDs == ["Label_9"])
        #expect(changed[1].diff["m1"]?.added == ["Label_9"])
        #expect(resolved == "Label_9")
        #expect(underReal == ["t1"])

        let cleared = try await cache.write { tx in
            try tx.clearLabelAliases(accountID: acct)
            return try tx.resolvedLabelID(pending, accountID: acct)
        }
        #expect(cleared == pending)
    }

    @Test func conversationsShareALabelWhileChangesToItWait() async throws {
        let cache = try MailCache.inMemory()
        try await seed(cache, [("m1", "t1", []), ("m2", "t2", []), ("m3", "t3", [])])
        let (first, second) = try await cache.write { tx in
            func label(_ kind: PendingAction.Kind, _ id: String, parent: String? = nil) throws -> Int64? {
                try tx.enqueueLabelChange(kind, labelID: id, change: .init(newName: "x", parentLabelID: parent), accountID: acct, now: now, notBefore: now).id
            }
            func add(_ thread: String, _ labelID: String) throws -> Int64? {
                try tx.enqueue(.modifyThreads, accountID: acct, threadIDs: [thread], add: [labelID], now: now, notBefore: now).id
            }
            let create = try label(.createLabel, pending)
            let useNew = try add("t1", pending)
            let use1 = try add("t2", "Label_1")
            let use2 = try add("t3", "Label_1")
            let delete = try label(.deleteLabel, "Label_1")
            let parent = try label(.updateLabel, "Label_2")
            let child = try label(.updateLabel, "Label_3", parent: "Label_2")

            let first = try tx.claimDueActions(accountID: acct, now: now)
            for var row in first {
                row.state = .sent
                try tx.updateAction(row)
            }
            let second = try tx.claimDueActions(accountID: acct, now: now)
            #expect(first.map(\.id) == [create, use1, use2, parent])
            #expect(second.map(\.id) == [useNew, delete, child])
            return (first.count, second.count)
        }
        #expect((first, second) == (4, 3))
    }

    @Test func aDeletedLabelLeavesConversationsAtOnceAndQueuedRowsOnceGone() async throws {
        let cache = try MailCache.inMemory()
        try await cache.write { tx in try tx.replaceLabels([user("Label_1", "Trips")], accountID: acct) }
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox, "Label_1"]), ("m2", "t2", [SystemLabel.inbox])])
        let (onlyUse, move, deleteRow) = try await cache.write { tx in
            let onlyUse = try tx.enqueue(.modifyThreads, accountID: acct, threadIDs: ["t2"], add: ["Label_1"], now: now, notBefore: now)
            let move = try tx.enqueue(.modifyThreads, accountID: acct, threadIDs: ["t2"], add: ["Label_1"], remove: [SystemLabel.inbox], now: now, notBefore: now)
            #expect(try listed(tx, "Label_1") == ["t1", "t2"])
            let deleteRow = try tx.enqueueLabelChange(.deleteLabel, labelID: "Label_1", change: .init(), accountID: acct, now: now, notBefore: now)
            return (onlyUse, move, deleteRow)
        }
        #expect(try await cache.read { tx in try listed(tx, "Label_1") }.isEmpty)

        // Gmail deleted it: the engine marks the row sent and drops the label
        // in one write, and a later pass drops the sent row.
        let (dropped, kept, listedAfter) = try await cache.write { tx in
            var sent = deleteRow
            sent.state = .sent
            sent.sentAt = now
            try tx.updateAction(sent)
            let dropped = try tx.dropLabel("Label_1", accountID: acct)
            try tx.deleteAction(id: try #require(deleteRow.id))
            return (dropped, try tx.action(id: try #require(move.id)), try listed(tx, "Label_1"))
        }
        #expect(dropped == [onlyUse.id])
        #expect(kept?.addLabelIDs == [])
        #expect(kept?.removeLabelIDs == [SystemLabel.inbox])
        #expect(kept?.diff["m2"] == .init(added: [], removed: [SystemLabel.inbox]))
        #expect(listedAfter.isEmpty)
    }
}

// MARK: Helpers

private func system(_ id: String) -> LabelRecord {
    LabelRecord(accountID: acct, id: id, name: id, isSystem: true)
}

private func user(_ id: String, _ name: String) -> LabelRecord {
    LabelRecord(accountID: acct, id: id, name: name, isSystem: false)
}

private func seed(_ cache: MailCache, _ messages: [(id: String, thread: String, labels: [String])]) async throws {
    let updates = messages.map { message in
        CacheTransaction.MessageUpdate(
            record: MessageRecord(
                accountID: acct, id: message.id, threadID: message.thread, historyID: 100, date: now,
                snippet: "", sender: "A <a@example.com>", recipients: "", cc: nil, subject: "Subject", sizeEstimate: 0
            ),
            labelIDs: message.labels
        )
    }
    try await cache.write { tx in try tx.rebuildThreads(try tx.upsertMessages(updates), accountID: acct) }
}

/// Conversations listed under a label, as the thread list reads them.
private func listed(_ tx: CacheTransaction, _ labelID: String) throws -> [String] {
    try String.fetchAll(
        tx.db, sql: "SELECT threadID FROM threadLabel WHERE accountID = ? AND labelID = ? ORDER BY threadID", arguments: [acct, labelID]
    )
}
