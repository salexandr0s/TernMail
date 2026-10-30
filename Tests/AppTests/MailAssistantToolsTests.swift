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
