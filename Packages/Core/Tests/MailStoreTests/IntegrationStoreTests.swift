import Foundation
import GmailAPI
import GRDB
import MessageContent
import Testing
@testable import MailStore

private let acct = "acct"
private let other = "other"
private let now = Date(timeIntervalSince1970: 1_900_000_000)
private let day: TimeInterval = 24 * 60 * 60
private let uid = "event-1@example.com"

@Suite struct IntegrationStoreTests {
    // MARK: Accounts and identities

    @Test func accountsAddedBeforeIntegrationsReadWithTheDefaults() async throws {
        let queue = try DatabaseQueue()
        try Schema.configMigrator.migrate(queue, upTo: "snooze-v1")
        try await queue.write { db in
            try db.execute(
                sql: "INSERT INTO account (id, email, grantedScopes, addedAt) VALUES (?, ?, '[]', ?)",
                arguments: [acct, "me@example.com", now]
            )
        }
        let account = try #require(try await AccountStore(writer: queue).accounts().first)
        #expect(account.hostedDomain == nil)
        #expect(account.enabledFeatures.isEmpty)
        #expect(!account.signatureOnReplies)
    }

    @Test func identitiesFollowGmailsListAndGoWithTheirAccount() async throws {
        let store = try AccountStore.inMemory()
        try await store.save(AccountRecord(id: acct, email: "me@example.com", displayName: nil, grantedScopes: [], addedAt: now))
        try await store.replaceIdentities(try identities(#"""
            [{"sendAsEmail": "Alias@Example.com", "displayName": "", "signature": "<b>A</b>", "verificationStatus": "accepted"},
             {"sendAsEmail": "pending@example.com", "verificationStatus": "pending"},
             {"sendAsEmail": "me@example.com", "displayName": "Me", "isPrimary": true, "isDefault": true}]
            """#), accountID: acct, fetchedAt: now)
        let listed = try await store.identities(accountID: acct)
        #expect(listed.map(\.address) == ["me@example.com", "Alias@Example.com", "pending@example.com"])
        #expect(listed.map(\.canSend) == [true, true, false])
        #expect(listed[1].displayName == nil)

        // Gmail stopped listing the pending address.
        try await store.replaceIdentities(try identities(#"""
            [{"sendAsEmail": "me@example.com", "isPrimary": true},
             {"sendAsEmail": "Alias@Example.com", "signature": "<b>A</b>", "verificationStatus": "accepted"}]
            """#), accountID: acct, fetchedAt: now + day)
        try await store.setSignature("<i>New</i>", address: "alias@example.com", accountID: acct)
        let refreshed = try await store.identities(accountID: acct)
        #expect(refreshed.map(\.address) == ["me@example.com", "Alias@Example.com"])
        #expect(refreshed.last?.signatureHTML == "<i>New</i>")

        // Saving or changing the account keeps its identities.
        let account = try #require(try await store.accounts().first)
        try await store.save(account)
        let updated = try await store.updateAccount(id: acct) { account in
            account.hostedDomain = "example.com"
            account.enabledFeatures = ["contacts"]
        }
        #expect(updated?.hostedDomain == "example.com")
        #expect(try await store.accounts().first?.enabledFeatures == ["contacts"])
        #expect(try await store.identities(accountID: acct).count == 2)

        try await store.deleteAccount(id: acct)
        #expect(try await store.identities(accountID: acct).isEmpty)
    }

    // MARK: Contacts

    @Test func aFullSyncReplacesItsSourceAndAnIncrementalOneOnlyThePeopleItLists() async throws {
        let cache = try MailCache.inMemory()
        try await cache.write { tx in
            try tx.applyContactSync(
                try people(#"[{"resourceName": "otherContacts/o1", "emailAddresses": [{"value": "bo@example.com"}]}]"#),
                source: .other, syncToken: "o-1", fields: "f", isFullSync: true, now: now, accountID: acct
            )
            try tx.applyContactSync(try people(#"""
                [{"resourceName": "people/c1", "names": [{"displayName": "Ann"}],
                  "emailAddresses": [{"value": "ann@example.com"}, {"value": "Ann.Work@Example.com", "metadata": {"primary": true}}]},
                 {"resourceName": "people/c2", "emailAddresses": [{"value": "cy@example.com"}]}]
                """#), source: .connection, syncToken: "c-1", fields: "f", isFullSync: true, now: now, accountID: acct)
        }
        #expect(try await addresses(cache) == [
            "connection people/c1 Ann.Work@Example.com primary", "connection people/c1 ann@example.com",
            "connection people/c2 cy@example.com primary", "other otherContacts/o1 bo@example.com primary",
        ])

        try await cache.write { tx in
            try tx.applyContactSync(try people(#"""
                [{"resourceName": "people/c1", "metadata": {"deleted": true}},
                 {"resourceName": "people/c2", "names": [{"displayName": "Cy"}], "emailAddresses": [{"value": "cy@example.net"}]},
                 {"resourceName": "people/c3", "names": [{"displayName": "No Mail"}]}]
                """#), source: .connection, syncToken: "c-2", fields: "f", isFullSync: false, now: now + day, accountID: acct)
        }
        #expect(try await addresses(cache) == ["connection people/c2 cy@example.net primary", "other otherContacts/o1 bo@example.com primary"])
        #expect(try await cache.read { tx in try ContactRecord.order(Column("source"), Column("resourceName")).fetchAll(tx.db).map(\.displayName) } == ["Cy", nil])
        let incremental = try await cache.read { tx in try tx.contactSync(source: .connection, accountID: acct) }
        #expect(incremental?.syncToken == "c-2")
        #expect(incremental?.lastFullSyncAt == now)

        try await cache.write { tx in
            try tx.applyContactSync(
                try people(#"[{"resourceName": "people/c4", "emailAddresses": [{"value": "di@example.com"}]}]"#),
                source: .connection, syncToken: "c-3", fields: "f", isFullSync: true, now: now + 2 * day, accountID: acct
            )
        }
        #expect(try await addresses(cache) == ["connection people/c4 di@example.com primary", "other otherContacts/o1 bo@example.com primary"])
        #expect(try await cache.read { tx in try tx.contactSync(source: .connection, accountID: acct) }?.lastFullSyncAt == now + 2 * day)
        #expect(try await cache.read { tx in try tx.contactSync(source: .other, accountID: acct) }?.syncToken == "o-1")

        try await cache.write { tx in try tx.deleteContacts(accountID: acct) }
        #expect(try await addresses(cache).isEmpty)
        #expect(try await cache.read { tx in try tx.contactSync(source: .other, accountID: acct) } == nil)
    }

    @Test func deletingAnAccountClearsItsContactsAndInvitationRows() async throws {
        let cache = try MailCache.inMemory()
        for account in [acct, other] {
            try await seed(cache, ["m1"], account: account)
            let event = try invitation(sequence: 0, stamp: "20261101T090000Z")
            try await cache.write { tx in
                try tx.applyContactSync(
                    try people(#"[{"resourceName": "otherContacts/o1", "emailAddresses": [{"value": "bo@example.com"}]}]"#),
                    source: .other, syncToken: "t", fields: "f", isFullSync: true, now: now, accountID: account
                )
                try tx.saveMessageCalendar(MessageCalendarRecord(accountID: account, messageID: "m1", invitation: event))
                try tx.saveInvitationReply(reply(draft: "d1", .accepted, account: account))
            }
        }
        try await cache.write { tx in try tx.deleteAccountData(accountID: acct) }

        let tables = ["contact", "contactEmail", "contactSync", "messageCalendar", "invitationReply"]
        let left = try await cache.read { tx in
            try tables.map { try String.fetchSet(tx.db, sql: "SELECT accountID FROM \($0)") }
        }
        #expect(left == Array(repeating: [other], count: tables.count))
    }

    // MARK: Invitations

    @Test func theNewestVersionWinsAcrossThreadsAndAnswersAreNotVersions() async throws {
        let cache = try MailCache.inMemory()
        try await seed(cache, ["m1", "m2", "m3", "m4", "m5", "m6"])
        let versions: [(String, Invitation)] = [
            ("m1", try invitation(sequence: 0, stamp: "20261101T090000Z")),
            ("m2", try invitation(sequence: 1, stamp: "20261102T090000Z")),
            // The same version again, in another thread.
            ("m3", try invitation(sequence: 1, stamp: "20261102T090000Z")),
            // The user's own answer: later, but sent by an attendee.
            ("m4", try invitation(method: "REPLY", sequence: 1, stamp: "20261103T090000Z")),
            // One occurrence is keyed apart from the whole event.
            ("m5", try invitation(sequence: 5, stamp: "20261103T090000Z", recurrenceID: "20261112T100000Z")),
        ]
        try await cache.write { tx in
            for (messageID, event) in versions {
                try tx.saveMessageCalendar(MessageCalendarRecord(accountID: acct, messageID: messageID, invitation: event))
            }
        }
        let latest = try #require(try await latestWholeEvent(cache))
        #expect(latest.messageID == "m2")
        let first = try #require(try await cache.read { tx in try tx.messageCalendar(messageID: "m1", accountID: acct) })
        let copy = try #require(try await cache.read { tx in try tx.messageCalendar(messageID: "m3", accountID: acct) })
        #expect(first.isOlder(than: latest))
        #expect(!copy.isOlder(than: latest) && !latest.isOlder(than: copy))
        #expect(latest.invitation.organizer?.email == "org@example.com")

        // At the same SEQUENCE, the later DTSTAMP wins.
        let update = try invitation(sequence: 1, stamp: "20261104T090000Z")
        try await cache.write { tx in
            try tx.saveMessageCalendar(MessageCalendarRecord(accountID: acct, messageID: "m6", invitation: update))
        }
        #expect(try await latestWholeEvent(cache)?.messageID == "m6")
    }

    @Test func anEventKeepsOneAnswerAndUndoingAnEarlierOneKeepsTheLater() async throws {
        let cache = try MailCache.inMemory()
        try await cache.write { tx in
            try tx.saveInvitationReply(reply(draft: "d1", .accepted))
            try tx.saveInvitationReply(reply(draft: "d2", .declined))
            try tx.saveInvitationReply(reply(draft: "d3", .tentative, recurrenceKey: "20261112T100000Z"))
        }
        #expect(try await cache.read { tx in try Int.fetchOne(tx.db, sql: "SELECT COUNT(*) FROM invitationReply") } == 2)
        #expect(try await wholeEventAnswer(cache)?.participationStatus == .declined)

        #expect(try await cache.write { tx in try tx.deleteInvitationReply(localDraftID: "d1", accountID: acct) } == false)
        #expect(try await wholeEventAnswer(cache)?.participationStatus == .declined)
        #expect(try await cache.write { tx in try tx.deleteInvitationReply(localDraftID: "d2", accountID: acct) })
        #expect(try await wholeEventAnswer(cache) == nil)
    }

    // MARK: Pending actions and drafts

    @Test func settingsPayloadsReadBackAsWritten() async throws {
        let cache = try MailCache.inMemory()
        let filter = GmailFilter(
            criteria: .init(from: "news@example.com"),
            action: .init(addLabelIds: ["Label_1"], removeLabelIds: ["INBOX"], forward: "Me@Example.com")
        )
        let vacation = VacationSettings(
            enableAutoReply: true, responseSubject: "Away", responseBodyPlainText: "Back soon",
            responseBodyHtml: "<p>Back soon</p>", startTime: now, endTime: now + day
        )
        let changes: [PendingAction.SettingsChange] = [
            .createFilter(filter: filter, listedIDs: nil),
            .deleteFilter(id: "f1", filter: filter),
            .replaceFilter(oldID: "f1", old: filter, new: filter, listedIDs: ["f1", "f2"], newID: "f3"),
            .vacation(fields: [.body, .startTime], new: vacation, previous: VacationSettings()),
            .signature(address: "me@example.com", html: "<b>Me</b>", previousHTML: ""),
        ]
        let stored = try await cache.write { tx in
            for change in changes {
                var row = PendingAction(
                    accountID: acct, kind: .modifyThreads, threadIDs: [], messageIDs: [], addLabelIDs: [], removeLabelIDs: [],
                    diff: [:], state: .queued, attempts: 0, createdAt: now, notBefore: now, settingsChange: change
                )
                try row.insert(tx.db)
            }
            return try PendingAction.order(Column("id")).fetchAll(tx.db).map(\.settingsChange)
        }
        #expect(stored == changes)
    }

    @Test func aDraftKeepsItsIdentityAndAFromChangeIsAnEdit() async throws {
        let cache = try MailCache.inMemory()
        let draft = LocalDraft(
            accountID: acct, kind: .invitationReply,
            content: DraftContent(subject: "Accepted: Planning", fromAddress: "alias@example.com", signatureHTML: "<b>A</b>"),
            rfcMessageID: "<r1@example.com>", calendarPart: "BEGIN:VCALENDAR", now: now
        )
        try await cache.write { tx in try tx.insertLocalDraft(draft) }
        #expect(try await cache.read { tx in try tx.localDraft(id: draft.id) } == draft)

        var change = draft.content
        change.fromAddress = "me@example.com"
        let content = change
        let edited = try await cache.write { tx in try tx.updateLocalDraft(id: draft.id, content: content, now: now + 1) }
        #expect(edited?.revision == 1)
        let stored = try await cache.read { tx in try tx.localDraft(id: draft.id) }
        #expect(stored?.fromAddress == "me@example.com")
        #expect(stored?.signatureHTML == "<b>A</b>")
        #expect(stored?.calendarPart == "BEGIN:VCALENDAR")
    }
}

// MARK: Fixtures

private func identities(_ json: String) throws -> [SendAsIdentity] {
    try JSONDecoder().decode([SendAsIdentity].self, from: Data(json.utf8))
}

private func people(_ json: String) throws -> [Person] {
    try JSONDecoder().decode([Person].self, from: Data(json.utf8))
}

/// "source resourceName address [primary]" for every stored address, sorted.
private func addresses(_ cache: MailCache) async throws -> [String] {
    try await cache.read { tx in
        try ContactEmailRecord.fetchAll(tx.db).map { email in
            [email.source.rawValue, email.resourceName, email.address, email.isPrimary ? "primary" : nil]
                .compactMap { $0 }.joined(separator: " ")
        }
        .sorted()
    }
}

private func seed(_ cache: MailCache, _ messageIDs: [String], account: String = acct) async throws {
    let updates = messageIDs.map { id in
        CacheTransaction.MessageUpdate(
            record: MessageRecord(
                accountID: account, id: id, threadID: "t-" + id, historyID: 100, date: now,
                snippet: "", sender: "Org <org@example.com>", recipients: "me@example.com", cc: nil,
                subject: "Invitation: Planning", sizeEstimate: 0
            ),
            labelIDs: [SystemLabel.inbox]
        )
    }
    try await cache.write { tx in _ = try tx.upsertMessages(updates) }
}

private func invitation(method: String = "REQUEST", sequence: Int, stamp: String, recurrenceID: String? = nil) throws -> Invitation {
    var event = [
        "BEGIN:VEVENT", "UID:\(uid)", "SEQUENCE:\(sequence)", "DTSTAMP:\(stamp)", "DTSTART:20261105T100000Z",
        "SUMMARY:Planning", "ORGANIZER:mailto:org@example.com", "ATTENDEE;PARTSTAT=NEEDS-ACTION:mailto:me@example.com",
    ]
    if let recurrenceID { event.append("RECURRENCE-ID:\(recurrenceID)") }
    let lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Example//Test//EN", "METHOD:\(method)"]
        + event + ["END:VEVENT", "END:VCALENDAR"]
    return try Invitation(data: Data(lines.joined(separator: "\r\n").utf8))
}

private func reply(
    draft: String, _ status: Invitation.ParticipationStatus, recurrenceKey: String = "", account: String = acct
) -> InvitationReplyRecord {
    InvitationReplyRecord(
        accountID: account, uid: uid, recurrenceKey: recurrenceKey,
        participationStatus: status, localDraftID: draft, queuedAt: now
    )
}

private func latestWholeEvent(_ cache: MailCache) async throws -> MessageCalendarRecord? {
    try await cache.read { tx in try tx.latestInvitation(uid: uid, recurrenceKey: "", accountID: acct) }
}

private func wholeEventAnswer(_ cache: MailCache) async throws -> InvitationReplyRecord? {
    try await cache.read { tx in try tx.invitationReply(uid: uid, recurrenceKey: "", accountID: acct) }
}
