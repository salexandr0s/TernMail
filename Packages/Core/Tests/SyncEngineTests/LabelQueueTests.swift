import Foundation
import GmailAPI
import MailStore
import Testing
@testable import SyncEngine

@Suite struct LabelQueueTests {
    @Test func aConversationGettingANewLabelWaitsForGmailsID() async throws {
        let (engine, cache, gmail, clock) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox]), ("m2", "t2", [SystemLabel.inbox])])
        let create = try await engine.createLabel(named: "Trips", color: nil)
        let temporaryID = try #require(create.labelID)
        #expect(LabelRules.isTemporary(temporaryID))
        let edit = try #require(try await engine.editLabels(threadIDs: ["t1", "t2"], add: [temporaryID], remove: []))
        #expect(try await listed(cache, temporaryID) == ["t1", "t2"])
        clock.advance(3)

        #expect(await engine.sendDueActions() == 1)
        #expect(await gmail.labelCalls == ["create Trips"])
        #expect(await gmail.changes.isEmpty)
        #expect(create.labelID == "Label_1")
        #expect(edit.actions.map(\.addLabelIDs) == [["Label_1"], ["Label_1"]])
        #expect(try await listed(cache, "Label_1") == ["t1", "t2"])

        // Both conversations share the label's key, so they go out together.
        #expect(await engine.sendDueActions() == 2)
        #expect(await gmail.changes == [Change("modifyThreads", ["t1", "t2"], add: ["Label_1"])])
    }

    @Test func undoAndLaterChangesUseGmailsIDOnceItIsKnown() async throws {
        let (engine, cache, gmail, clock) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox]), ("m2", "t2", [SystemLabel.inbox])])
        let temporaryID = try #require(try await engine.createLabel(named: "Trips", color: nil).labelID)
        let edit = try #require(try await engine.editLabels(threadIDs: ["t1"], add: [temporaryID], remove: []))
        clock.advance(3)
        while await engine.sendDueActions() > 0 {}
        // A sync pass that started after the sends drops their rows.
        try await cache.write { tx in try tx.dropSentActions(confirmedThrough: 0, passStart: .distantFuture, accountID: account) }

        try await engine.undo(edit)
        // A picker opened before Gmail answered still holds the temporary ID.
        _ = try await engine.editLabels(threadIDs: ["t2"], add: [temporaryID], remove: [])
        clock.advance(3)
        while await engine.sendDueActions() > 0 {}
        #expect(await gmail.changes == [
            Change("modifyThreads", ["t1"], add: ["Label_1"]),
            Change("batchModify", ["m1"], remove: ["Label_1"]),
            Change("modifyThreads", ["t2"], add: ["Label_1"]),
        ])
    }

    @Test func labelRowsGoOutOneAtATimeWithParentsBeforeChildren() async throws {
        let (engine, cache, gmail, clock) = try await makeEngine()
        try await setLabels([("Label_1", "Work"), ("Label_2", "Work/Trips"), ("Label_3", "Work/Trips/2026"), ("Label_4", "Bills")], cache, gmail)
        let rename = try #require(try await engine.renameLabel("Label_1", to: "Job"))
        _ = try await engine.setLabelColor("Label_4", to: LabelColor.grid[0])
        #expect(try await shownNames(cache) == ["Bills", "Job", "Job/Trips", "Job/Trips/2026"])
        clock.advance(3)

        while await engine.sendDueActions() > 0 {}
        #expect(await gmail.labelCalls == ["patch Label_1", "patch Label_4", "patch Label_2", "patch Label_3"])
        #expect(try await gmail.labels().map(\.name).sorted() == ["Bills", "Job", "Job/Trips", "Job/Trips/2026"])

        try await engine.undo(rename)
        while await engine.sendDueActions() > 0 {}
        #expect(await gmail.labelCalls.dropFirst(4) == ["patch Label_1", "patch Label_2", "patch Label_3"])
        #expect(try await gmail.labels().map(\.name).sorted() == ["Bills", "Work", "Work/Trips", "Work/Trips/2026"])
    }

    @Test func aRenameGmailRefusesKeepsTheLabelsUnderIt() async throws {
        let (engine, cache, gmail, clock) = try await makeEngine()
        try await setLabels([("Label_1", "Work"), ("Label_2", "Work/Trips"), ("Label_3", "Work/Trips/2026")], cache, gmail)
        let rename = try #require(try await engine.renameLabel("Label_1", to: "Job"))
        await gmail.failNextLabelCall("patch", with: .http(status: 400, reason: "invalidArgument"))
        clock.advance(3)

        while await engine.sendDueActions() > 0 {}
        #expect(await gmail.labelCalls == ["patch Label_1"])
        #expect(try await rows(cache).isEmpty)
        #expect(try await shownNames(cache) == ["Work", "Work/Trips", "Work/Trips/2026"])
        // Nothing is left to undo.
        try await engine.undo(rename)
        while await engine.sendDueActions() > 0 {}
        #expect(await gmail.labelCalls == ["patch Label_1"])
        #expect(await events(engine) == [.actionFailed("Gmail didn't accept this change. The label was restored.")])
    }

    @Test func namesAreCheckedBeforeAnythingIsQueued() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        try await setLabels([("Label_1", "Work"), ("Label_2", "Work/Trips"), ("Label_3", "Job/Trips")], cache, gmail)
        await #expect(throws: LabelChangeError.name(.reserved)) { try await engine.createLabel(named: "Inbox", color: nil) }
        await #expect(throws: LabelChangeError.name(.taken)) { try await engine.createLabel(named: " work ", color: nil) }
        // Work/Trips would become Job/Trips, which exists.
        await #expect(throws: LabelChangeError.name(.taken)) { try await engine.renameLabel("Label_1", to: "Job") }
        await #expect(throws: LabelChangeError.notAUserLabel) { try await engine.renameLabel(SystemLabel.inbox, to: "In") }
        #expect(try await rows(cache).isEmpty)
    }

    @Test func aCreateRefusedAsATakenNameAdoptsTheLabel() async throws {
        let (engine, cache, gmail, clock) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox])])
        // Made in another app since the cache last listed labels.
        await gmail.setLabels([try gmailLabel("Label_7", "Trips")])
        let temporaryID = try #require(try await engine.createLabel(named: "trips", color: nil).labelID)
        _ = try await engine.editLabels(threadIDs: ["t1"], add: [temporaryID], remove: [])
        clock.advance(3)

        while await engine.sendDueActions() > 0 {}
        #expect(await gmail.labelCalls == ["create trips"])
        #expect(await gmail.changes == [Change("modifyThreads", ["t1"], add: ["Label_7"])])
    }

    @Test(arguments: [false, true])
    func undoingACreateThatTookAnExistingLabelLeavesItInGmail(undoingDuringTheRequest: Bool) async throws {
        let (engine, _, gmail, clock) = try await makeEngine()
        await gmail.setLabels([try gmailLabel("Label_7", "Trips")])
        let create = try await engine.createLabel(named: "trips", color: nil)
        clock.advance(3)
        if undoingDuringTheRequest {
            await gmail.holdNextChange()
            let sending = Task { await engine.sendDueActions() }
            while await !gmail.isHolding { await Task.yield() }
            try await engine.undo(create)
            await gmail.release()
            await sending.value
        } else {
            await engine.sendDueActions()
            try await engine.undo(create)
        }

        while await engine.sendDueActions() > 0 {}
        #expect(await gmail.labelCalls == ["create trips"])
        #expect(try await gmail.labels().map(\.id) == ["Label_7"])
        #expect(await events(engine) == [.actionFailed("“trips” already existed in Gmail and wasn't deleted.")])
    }

    @Test func aRateLimitedCreateRetriesWithItsChangesKept() async throws {
        let (engine, cache, gmail, clock) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox])])
        let temporaryID = try #require(try await engine.createLabel(named: "Trips", color: nil).labelID)
        _ = try await engine.editLabels(threadIDs: ["t1"], add: [temporaryID], remove: [])
        await gmail.failNextLabelCall("create", with: .rateLimited)
        clock.advance(3)

        await engine.sendDueActions()
        #expect(try await rows(cache).map(\.kind) == [.createLabel, .modifyThreads])
        clock.advance(3)
        while await engine.sendDueActions() > 0 {}
        #expect(await gmail.labelCalls == ["create Trips", "create Trips"])
        #expect(await gmail.changes == [Change("modifyThreads", ["t1"], add: ["Label_1"])])
    }

    @Test func aCreateWhoseAnswerWasLostIsAdoptedNotMadeTwice() async throws {
        let (engine, cache, gmail, clock) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox])])
        let temporaryID = try #require(try await engine.createLabel(named: "Trips", color: nil).labelID)
        _ = try await engine.editLabels(threadIDs: ["t1"], add: [temporaryID], remove: [])
        await gmail.failNextLabelCall("create", with: .server(status: 503), afterApplying: true)
        clock.advance(3)

        await engine.sendDueActions()
        clock.advance(3)
        while await engine.sendDueActions() > 0 {}
        #expect(await gmail.labelCalls == ["create Trips"])
        #expect(await gmail.changes == [Change("modifyThreads", ["t1"], add: ["Label_1"])])
    }

    @Test func aRefusedCreateWithNoMatchTakesItsChangesAlong() async throws {
        let (engine, cache, gmail, clock) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox]), ("m2", "t2", [SystemLabel.inbox])])
        let temporaryID = try #require(try await engine.createLabel(named: "Trips", color: nil).labelID)
        _ = try await engine.editLabels(threadIDs: ["t1"], add: [temporaryID], remove: [])
        _ = try await engine.move(threadIDs: ["t2"], to: temporaryID, from: SystemLabel.inbox)
        #expect(try await listed(cache, SystemLabel.inbox) == ["t1"])
        await gmail.failNextLabelCall("create", with: .http(status: 400, reason: "invalidArgument"))
        clock.advance(3)

        while await engine.sendDueActions() > 0 {}
        #expect(await gmail.labelCalls == ["create Trips"])
        #expect(await gmail.changes.isEmpty)
        #expect(try await rows(cache).isEmpty)
        #expect(try await shownNames(cache).isEmpty)
        #expect(try await listed(cache, SystemLabel.inbox) == ["t1", "t2"])
        #expect(await events(engine) == [.actionFailed("Gmail didn't create the label “Trips”.")])
    }

    @Test func aDeleteWaitsForOlderUsesThenTakesTheLabelOutOfTheCache() async throws {
        let (engine, cache, gmail, clock) = try await makeEngine(undoHolds: .uniform(2))
        try await setLabels([("Label_1", "Trips")], cache, gmail)
        try await seed(cache, [
            ("m1", "t1", [SystemLabel.inbox, "Label_1"]), ("m2", "t2", [SystemLabel.inbox]),
            ("m3", "t3", [SystemLabel.inbox]), ("m4", "t4", [SystemLabel.inbox]),
        ])
        _ = try await engine.editLabels(threadIDs: ["t2"], add: ["Label_1"], remove: [])
        try await engine.deleteLabel("Label_1")
        #expect(try await shownNames(cache).isEmpty)
        #expect(try await listed(cache, "Label_1").isEmpty)
        // Changes from a list opened before the delete still name the label.
        _ = try await engine.editLabels(threadIDs: ["t3"], add: ["Label_1"], remove: [])
        _ = try await engine.move(threadIDs: ["t4"], to: "Label_1", from: SystemLabel.inbox)

        // The older change is still in its undo hold, so the delete waits.
        #expect(await engine.sendDueActions() == 0)
        clock.advance(3)
        while await engine.sendDueActions() > 0 {}
        #expect(await gmail.labelCalls == ["delete Label_1"])
        // The edit on t3 had nothing else to change; the move still leaves the Inbox.
        #expect(await gmail.changes == [
            Change("modifyThreads", ["t2"], add: ["Label_1"]),
            Change("modifyThreads", ["t4"], remove: [SystemLabel.inbox]),
        ])
        // A pass that fetched before the delete reached Gmail stores the label again.
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox, "Label_1"])])
        try await cache.write { tx in try tx.dropSentActions(confirmedThrough: 0, passStart: .distantFuture, accountID: account) }
        #expect(try await rows(cache).isEmpty)
        #expect(try await labels(cache, "t1") == [SystemLabel.inbox])
        #expect(try await listed(cache, "Label_1").isEmpty)
    }

    @Test func aDeleteGmailRefusesPutsTheLabelBack() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        try await setLabels([("Label_1", "Trips")], cache, gmail)
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox, "Label_1"])])
        await gmail.failNextLabelCall("delete", with: .http(status: 403, reason: "forbidden"))
        try await engine.deleteLabel("Label_1")
        #expect(try await listed(cache, "Label_1").isEmpty)

        await engine.sendDueActions()
        #expect(try await shownNames(cache) == ["Trips"])
        #expect(try await listed(cache, "Label_1") == ["t1"])
        #expect(await events(engine) == [.actionFailed("Gmail didn't delete “Trips”. The label was restored.")])
    }

    @Test func undoingACreateBeforeItIsSentTakesItsChangesAlong() async throws {
        let (engine, cache, gmail, clock) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox])])
        let create = try await engine.createLabel(named: "Trips", color: nil)
        let temporaryID = try #require(create.labelID)
        let edit = try #require(try await engine.editLabels(threadIDs: ["t1"], add: [temporaryID], remove: []))
        try await engine.undo(create)
        try await engine.undo(edit)
        clock.advance(3)

        while await engine.sendDueActions() > 0 {}
        #expect(await gmail.labelCalls.isEmpty)
        #expect(await gmail.changes.isEmpty)
        #expect(try await rows(cache).isEmpty)
        #expect(try await shownNames(cache).isEmpty)
    }

    @Test func colorsGmailDoesntAllowAreRefusedBeforeAnyRequest() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        try await setLabels([("Label_1", "Trips")], cache, gmail)
        // An undo restores whatever color Gmail listed, which may be an old one.
        let odd = PendingAction.LabelChange.Color(textColor: "#123456", backgroundColor: "#654321")
        try await cache.write { tx in
            _ = try tx.enqueueLabelChange(
                .updateLabel, labelID: "Label_1", change: .init(newColor: .set(odd)),
                accountID: account, now: baseDate, notBefore: baseDate
            )
            _ = try tx.enqueueLabelChange(
                .createLabel, labelID: LabelRules.temporaryID(), change: .init(newName: "Plans", newColor: .set(odd)),
                accountID: account, now: baseDate, notBefore: baseDate
            )
        }

        while await engine.sendDueActions() > 0 {}
        #expect(await gmail.labelCalls.isEmpty)
        #expect(try await rows(cache).isEmpty)
        #expect(try await shownNames(cache) == ["Trips"])
    }
}

// MARK: Helpers

private func gmailLabel(_ id: String, _ name: String) throws -> GmailLabel {
    try decode(GmailLabel.self, #"{"id": "\#(id)", "name": "\#(name)", "type": "user"}"#)
}

/// The same user labels on Gmail and in the cache.
private func setLabels(_ labels: [(id: String, name: String)], _ cache: MailCache, _ gmail: FakeGmail) async throws {
    await gmail.setLabels(try labels.map { try gmailLabel($0.id, $0.name) })
    let records = labels.map { LabelRecord(accountID: account, id: $0.id, name: $0.name, isSystem: false) }
    try await cache.write { tx in try tx.replaceLabels(records, accountID: account) }
}

private func shownNames(_ cache: MailCache) async throws -> [String] {
    try await cache.read { tx in try tx.displayedLabels(accountID: account).map(\.name) }
}

/// Conversations listed under a label, sorted by ID.
private func listed(_ cache: MailCache, _ labelID: String) async throws -> [String] {
    for try await threads in cache.threads(accountID: account, labelID: labelID, limit: 100) {
        return threads.map(\.id).sorted()
    }
    return []
}

/// The first message's labels, with queued changes applied.
private func labels(_ cache: MailCache, _ threadID: String) async throws -> Set<String> {
    for try await detail in cache.thread(accountID: account, threadID: threadID) {
        return detail?.messages.first?.labels ?? []
    }
    return []
}

private func rows(_ cache: MailCache) async throws -> [PendingAction] {
    try await cache.read { tx in try tx.pendingActions(accountID: account) }
}

private func events(_ engine: SyncEngine) async -> [SyncEvent] {
    await engine.stop()
    var events: [SyncEvent] = []
    for await event in engine.events { events.append(event) }
    return events
}
