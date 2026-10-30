import Foundation
import MailStore
import SyncEngine
import TernAI
import Testing
@testable import Tern

@MainActor
@Suite struct MailAssistantToolsTests {
    @Test func rejectsAccountsAndThreadsOutsideTheImmutableScope() async throws {
        let mailbox = try makeAssistantMailbox()
        let second = AccountRecord(id: "second", email: "second@example.invalid", displayName: nil, grantedScopes: [], addedAt: .now)
        await mailbox.addAccount(second, gmail: AuditGmail(.second))
        let tools = MailAssistantTools(mailbox: mailbox, allowedAccountIDs: ["first"], allowedThreadIDs: [ThreadKey(accountID: "first", threadID: "t2")]) { true }
        await #expect(throws: AssistantMailError.invalidTarget) {
            try await tools.execute(call("read_thread", ["account_id": .string("second"), "thread_id": .string("t2")]))
        }
        await #expect(throws: AssistantMailError.invalidTarget) {
            try await tools.execute(call("read_thread", ["account_id": .string("first"), "thread_id": .string("t1")]))
        }
        let result = try await tools.execute(call("read_thread", ["account_id": .string("first"), "thread_id": .string("t2")]))
        #expect(!result.sources.isEmpty)
        #expect(result.sources.allSatisfy { $0.accountID == "first" && $0.threadID == "t2" })
        #expect(result.data["messages"]?.arrayValue?.count == 2)
        await mailbox.stop()
    }

    @Test func presentationUsesRetrievedMetadataAndPreservesRankingWithoutDuplicateThreads() async throws {
        let mailbox = try makeAssistantMailbox()
        let hiking = LabelRecord(accountID: "first", id: "Label_1", name: "Hiking", isSystem: false,
                                 textColor: "#ffffff", backgroundColor: "#009900")
        try await mailbox.cache.write { try $0.replaceLabels([hiking], accountID: "first") }
        let tools = MailAssistantTools(mailbox: mailbox, allowedAccountIDs: ["first"]) { true }
        let search = try await tools.execute(call("search_mail", [
            "query": .string("plans"), "account_id": .string("first"), "page_token": .null
        ]))
        #expect(search.emailResults.isEmpty)
        let trail = try #require(search.sources.first { $0.threadID == "t3" })
        let weekend = try #require(search.sources.first { $0.threadID == "t2" })
        let result = try await tools.execute(call("present_emails", ["emails": .array([
            emailSelection(trail.id, reason: "Check the trail details first."),
            emailSelection(weekend.id),
            emailSelection(trail.id, reason: "This duplicate must not replace the first reason.")
        ])]))
        #expect(result.emailResults.map(\.source.threadID) == ["t3", "t2"])
        let first = try #require(result.emailResults.first)
        #expect(first.senderName == "River")
        #expect(first.senderEmail == "river@example.invalid")
        #expect(first.subject == "Trail plans")
        #expect(first.accountEmail == "audit@example.invalid")
        #expect(first.labels == [hiking])
        #expect(first.reason == "Check the trail details first.")
        #expect(first.isUnread)
        #expect(first.avatarData == nil)
        #expect(result.emailResults.last?.isStarred == true)
        #expect(result.emailResults.last?.messageCount == 2)
        await mailbox.stop()
    }

    @Test func uncachedReadsRegisterMessageSourcesForOneCanonicalCard() async throws {
        let mailbox = try makeAssistantMailbox()
        let tools = MailAssistantTools(mailbox: mailbox, allowedAccountIDs: ["first"],
                                       allowedThreadIDs: [ThreadKey(accountID: "first", threadID: "t2")]) { true }
        let read = try await tools.execute(call("read_thread", ["account_id": .string("first"), "thread_id": .string("t2")]))
        #expect(read.emailResults.isEmpty)
        #expect(read.sources.count == 2)
        let result = try await tools.execute(call("present_emails", [
            "emails": .array(read.sources.map { emailSelection($0.id) })
        ]))
        #expect(result.emailResults.count == 1)
        let email = try #require(result.emailResults.first)
        #expect(email.subject == "Weekend plans")
        #expect(email.isUnread)
        #expect(email.isStarred)
        #expect(email.messageCount == 2)
        #expect(email.date != nil)
        let cached = try await mailbox.cache.read { try $0.thread(id: "t2", accountID: "first") }
        #expect(cached == nil)
        await mailbox.stop()
    }

    @Test func presentationKeepsIdenticalThreadIDsInDifferentAccountsDistinct() async throws {
        let mailbox = try makeAssistantMailbox()
        await mailbox.addAccount(AccountRecord(id: "second", email: "second@example.invalid", displayName: nil,
                                               grantedScopes: [], addedAt: .now), gmail: AuditGmail(.second))
        let tools = MailAssistantTools(mailbox: mailbox, allowedAccountIDs: ["first", "second"]) { true }
        let first = try await tools.execute(call("read_thread", ["account_id": .string("first"), "thread_id": .string("t2")]))
        let second = try await tools.execute(call("read_thread", ["account_id": .string("second"), "thread_id": .string("t2")]))
        let firstSource = try #require(first.sources.first)
        let secondSource = try #require(second.sources.first)
        let result = try await tools.execute(call("present_emails", ["emails": .array([
            emailSelection(secondSource.id), emailSelection(firstSource.id)
        ])]))
        #expect(result.emailResults.map(\.source.accountID) == ["second", "first"])
        #expect(result.emailResults.map(\.subject) == ["Garden plans", "Weekend plans"])
        #expect(Set(result.emailResults.map(\.id)).count == 2)
        await mailbox.stop()
    }

    @Test func presentationRejectsInventedSourcesMetadataOverflowAndRevokedScope() async throws {
        let mailbox = try makeAssistantMailbox()
        var enabled = true
        let tools = MailAssistantTools(mailbox: mailbox, allowedAccountIDs: ["first"]) { enabled }
        let read = try await tools.execute(call("read_thread", ["account_id": .string("first"), "thread_id": .string("t2")]))
        let source = try #require(read.sources.first)
        let otherSession = MailAssistantTools(mailbox: mailbox, allowedAccountIDs: ["first"]) { true }
        await #expect(throws: AssistantMailError.invalidTarget) {
            try await otherSession.execute(call("present_emails", ["emails": .array([emailSelection(source.id)])]))
        }
        let foreign = AssistantSource(accountID: "second", threadID: "t2", messageID: "m2", partID: nil, title: "Invented")
        await #expect(throws: AssistantMailError.invalidTarget) {
            try await tools.execute(call("present_emails", ["emails": .array([emailSelection(foreign.id)])]))
        }
        await #expect(throws: MailAssistantTools.ToolError.self) {
            try await tools.execute(call("present_emails", ["emails": .array([
                .object(["source_id": .string(source.id), "reason": .null, "subject": .string("Invented subject")])
            ])]))
        }
        await #expect(throws: MailAssistantTools.ToolError.self) {
            try await tools.execute(call("present_emails", ["emails": .array(Array(repeating: emailSelection(source.id), count: 13))]))
        }
        await #expect(throws: MailAssistantTools.ToolError.self) {
            try await tools.execute(call("present_emails", ["emails": .array([emailSelection(source.id, reason: String(repeating: "a", count: 281))])]))
        }
        enabled = false
        await #expect(throws: AssistantMailError.accessChanged) {
            try await tools.execute(call("present_emails", ["emails": .array([emailSelection(source.id)])]))
        }
        await mailbox.stop()
    }

    @Test func draftAcknowledgementControlsRetryRecoveryAndRevocationStopsReuse() async throws {
        let mailbox = try makeAssistantMailbox()
        var enabled = true
        let tools = MailAssistantTools(mailbox: mailbox, allowedAccountIDs: ["first"]) { enabled }
        let request = try call("prepare_draft", [
            "account_id": .string("first"), "thread_id": .null, "message_id": .null,
            "to": .array([.string("recipient@example.invalid")]), "subject": .string("Proposal"),
            "body": .string("Please review the proposal."), "reply_mode": .string("new")
        ], id: "same-draft-call")
        let first = try await tools.execute(request)
        let second = try await tools.execute(request)
        let id = try #require(first.createdDraftID)
        #expect(second.createdDraftID == id)
        let regenerated = AIToolCall(id: "regenerated-draft-call", namespace: request.namespace, name: request.name, arguments: request.arguments)
        let recovered = try await tools.execute(regenerated)
        #expect(recovered.createdDraftID == id)
        let drafts = try await mailbox.cache.read { try $0.localDrafts(accountID: "first") }
        #expect(drafts.count == 1)
        #expect(drafts.first?.state == .editing)
        #expect(drafts.first?.sendRequested == false)
        tools.acknowledge(callID: regenerated.id)
        let later = AIToolCall(id: "later-draft-call", namespace: request.namespace, name: request.name, arguments: request.arguments)
        let distinct = try await tools.execute(later)
        #expect(distinct.createdDraftID != id)
        tools.acknowledge(callID: later.id)
        enabled = false
        await #expect(throws: AssistantMailError.accessChanged) { try await tools.execute(request) }
        await mailbox.stop()
    }

    @Test func interruptedDraftPublicationRecoversAcrossCallIDsWithoutMergingLaterRequests() throws {
        let arguments: AIJSON = .object([
            "account_id": .string("first"), "thread_id": .null, "message_id": .null,
            "to": .array([.string("recipient@example.invalid")]), "subject": .string("Proposal"),
            "body": .string("Please review the proposal."), "reply_mode": .string("new")
        ])
        let originalCall = AIToolCall(id: "interrupted", namespace: "tern", name: "prepare_draft", arguments: try arguments.jsonString())
        var calls = MailAssistantTools.DraftCalls()
        let original = try calls.reserve(originalCall, arguments: arguments)
        // Model the precise boundary where persistence succeeded but cancellation
        // prevented execute from publishing its known result.
        original.result = .init(data: .object(["draft_id": .string(original.draftID)]), createdDraftID: original.draftID)
        let retryCall = AIToolCall(id: "regenerated", namespace: "tern", name: "prepare_draft", arguments: " \n" + originalCall.arguments)
        let retried = try calls.reserve(retryCall, arguments: AIJSON.decode(Data(retryCall.arguments.utf8)))
        #expect(retried.draftID == original.draftID)
        #expect(retried.result?.createdDraftID == original.draftID)

        var changed = try #require(arguments.objectValue)
        changed["body"] = .string("A different request.")
        #expect(throws: MailAssistantTools.ToolError.self) {
            try calls.reserve(originalCall, arguments: .object(changed))
        }
        let different = try call("prepare_draft", changed)
        #expect(try calls.reserve(different, arguments: .object(changed)).draftID != original.draftID)

        calls.markPublished(retryCall.id)
        let laterCall = AIToolCall(id: "later-request", namespace: "tern", name: "prepare_draft", arguments: originalCall.arguments)
        let later = try calls.reserve(laterCall, arguments: arguments)
        #expect(later.draftID != original.draftID)
        #expect(try calls.reserve(originalCall, arguments: arguments).draftID == original.draftID)
    }

    @Test func textExtractionReportsLimitsAndRejectsUnsupportedOrBrokenFiles() throws {
        let text = Data(String(repeating: "a", count: 60_001).utf8)
        let result = try AttachmentTextReader.extract(text, mimeType: "text/plain", filename: "notes.txt")
        #expect(result.truncated)
        #expect(result.text.count == 60_000)
        #expect(throws: (any Error).self) {
            try AttachmentTextReader.extract(Data("not a PDF".utf8), mimeType: "application/pdf", filename: "broken.pdf")
        }
        #expect(throws: (any Error).self) {
            try AttachmentTextReader.extract(Data([0, 1, 2]), mimeType: "image/png", filename: "scan.png")
        }
        #expect(throws: AssistantMailError.attachmentTooLarge) {
            try AttachmentTextReader.extract(Data(count: 5_000_001), mimeType: "text/plain", filename: "large.txt")
        }
    }

    @Test func strictSchemaRejectsUnexpectedArgumentsAndOtherNamespaces() async throws {
        let mailbox = try makeAssistantMailbox()
        let tools = MailAssistantTools(mailbox: mailbox, allowedAccountIDs: ["first"]) { true }
        await #expect(throws: (any Error).self) {
            try await tools.execute(call("read_thread", ["account_id": .string("first"), "thread_id": .string("t1"), "path": .string("/tmp/private")]))
        }
        await #expect(throws: (any Error).self) {
            try await tools.execute(AIToolCall(id: "other", namespace: "shell", name: "read_thread", arguments: "{}"))
        }
        await mailbox.stop()
    }
}

@MainActor
private func makeAssistantMailbox() throws -> MailboxModel {
    MailboxModel(
        account: AccountRecord(id: "first", email: "audit@example.invalid", displayName: nil, grantedScopes: [], addedAt: .now),
        cache: try MailCache.inMemory(), gmail: AuditGmail(),
        outgoingDirectory: FileManager.default.temporaryDirectory.appending(path: "AssistantTests-\(UUID().uuidString)")
    )
}

private func call(_ name: String, _ arguments: [String: AIJSON], id: String = UUID().uuidString) throws -> AIToolCall {
    AIToolCall(id: id, namespace: "tern", name: name, arguments: try AIJSON.object(arguments).jsonString())
}

private func emailSelection(_ sourceID: String, reason: String? = nil) -> AIJSON {
    .object(["source_id": .string(sourceID), "reason": reason.map(AIJSON.string) ?? .null])
}
