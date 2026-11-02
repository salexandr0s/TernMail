import Foundation
import GmailAPI
import MailStore
import Testing
@testable import Tern

@Suite @MainActor struct AssistantTaskReviewTests {
    @Test func reviewPreservesSourceAndIdentityWhileCapturingEditedFieldsAndList() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        fixture.defaults.set("b", forKey: "googleTasks.selectedAccount")
        let first = ReviewTasksService(), second = ReviewTasksService()
        let model = fixture.model(services: ["a": first, "b": second])
        let request = Self.request
        let session = AssistantTaskReviewSession(request: request, model: model, isAuthorized: { true })
        await session.load()
        #expect(model.selectedAccountID == "b")
        #expect(session.account?.id == "a")
        #expect(await first.inserts.isEmpty)
        #expect(await second.inserts.isEmpty)

        session.title = "  Send the revised proposal  "
        session.notes = "Include the new timeline."
        session.hasDueDate = true
        session.dueDate = try #require(GoogleTaskDateCoding.date("2026-11-06"))
        session.selectedListID = "work"
        #expect(session.editedRequest.id == request.id)
        #expect(session.editedRequest.reference == request.reference)
        #expect(session.editedRequest.source == request.source)
        #expect(session.editedRequest.deduplicationKey == request.deduplicationKey)
        #expect(await session.save())

        let insert = try #require(await first.inserts.first)
        #expect(insert.listID == "work")
        #expect(insert.draft.title == "Send the revised proposal")
        #expect(insert.draft.due == "2026-11-06")
        #expect(insert.draft.notes?.contains("Include the new timeline.") == true)
        #expect(insert.draft.notes?.contains("Email: Proposal review") == true)
        #expect(insert.draft.notes?.contains(request.marker) == true)
        #expect(await second.inserts.isEmpty)
        #expect(model.creationState(for: request) == .added)
        #expect(session.error == nil)
    }

    @Test func uncertainSaveOnlyRetriesTheInsertAfterExplicitReviewAndCurrentAuthorization() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let service = ReviewTasksService()
        let model = fixture.model(services: ["a": service])
        var authorized = true
        let request = Self.request
        let session = AssistantTaskReviewSession(request: request, model: model, isAuthorized: { authorized })
        await session.load()
        await service.failInserts(.transport(.timedOut))
        #expect(await session.save() == false)
        #expect(session.isUncertain)
        await service.failInserts(nil)
        #expect(await session.save() == false)
        #expect(await service.inserts.count == 1)
        authorized = false
        #expect(await session.save(retryAfterReview: true) == false)
        #expect(await service.inserts.count == 1)
        authorized = true
        #expect(await session.save(retryAfterReview: true))
        #expect(await service.inserts.count == 2)
        #expect(model.creationState(for: request) == .added)
        let inserts = await service.inserts
        #expect(inserts.first?.draft.notes == inserts.last?.draft.notes)
    }

    @Test func revokedReviewCannotLoadListsOrSaveItsDraft() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let service = ReviewTasksService()
        let model = fixture.model(services: ["a": service])
        let session = AssistantTaskReviewSession(request: Self.request, model: model, isAuthorized: { false })
        await session.load()
        #expect(!session.canSave)
        #expect(session.error != nil)
        #expect(await session.save() == false)
        #expect(await service.reads == 0)
        #expect(await service.inserts.isEmpty)
        #expect(session.title == Self.request.title)
        #expect(session.notes == Self.request.notes)
    }

    private static var request: TaskCreationRequest {
        .init(title: "Review proposal", notes: "Check the timeline.", dueDate: nil,
              source: .init(accountID: "a", threadID: "thread", messageID: "message", subject: "Proposal review"),
              deduplicationKey: "suggestion-proposal-review")
    }

    @MainActor private struct Fixture {
        let suite = "AssistantTaskReviewTests-" + UUID().uuidString
        let defaults: UserDefaults
        init() throws { defaults = try #require(UserDefaults(suiteName: suite)) }
        func clean() { defaults.removePersistentDomain(forName: suite) }
        func model(services: [String: ReviewTasksService]) -> GoogleTasksModel {
            let accounts = services.keys.sorted().map {
                AccountRecord(id: $0, email: "\($0)@example.invalid", displayName: nil,
                    grantedScopes: [GoogleScopes.tasks], addedAt: .distantPast,
                    enabledFeatures: [AccountFeature.tasks.rawValue])
            }
            return GoogleTasksModel(defaults: defaults, loadAccounts: { accounts },
                service: { services[$0] }, enable: { _ in })
        }
    }
}

private actor ReviewTasksService: TasksService {
    struct Insert: Sendable {
        let listID: String
        let draft: GoogleTaskDraft
    }
    private(set) var inserts: [Insert] = []
    private(set) var reads = 0
    private var values: [String: [GoogleTask]] = [:]
    private var insertFailure: GmailError?

    func failInserts(_ error: GmailError?) { insertFailure = error }

    func taskLists(pageToken: String?) async throws -> GoogleTaskListPage {
        reads += 1
        return .init(items: [.init(id: "list", title: "My tasks"), .init(id: "work", title: "Work")])
    }
    func tasks(listID: String, pageToken: String?) async throws -> GoogleTaskPage {
        reads += 1
        return .init(items: values[listID] ?? [])
    }
    func insertTask(listID: String, draft: GoogleTaskDraft) async throws -> GoogleTask {
        inserts.append(.init(listID: listID, draft: draft))
        if let insertFailure { throw insertFailure }
        let task = GoogleTask(id: "created", title: draft.title, notes: draft.notes, due: draft.due)
        values[listID, default: []].append(task)
        return task
    }
    func updateTask(listID: String, taskID: String, update: GoogleTaskUpdate, etag: String?) async throws -> GoogleTask {
        throw GmailError.notFound
    }
    func deleteTask(listID: String, taskID: String, etag: String?) async throws {
        throw GmailError.notFound
    }
}
