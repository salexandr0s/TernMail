import Foundation
import GmailAPI
import MailStore
import Testing
@testable import Tern

@Suite @MainActor struct GoogleTaskEditingSessionTests {
    @Test func editedFieldsKeepTheirCapturedDestinationVersionAndFooter() async throws {
        let fixture = try EditingSessionFixture()
        defer { fixture.clean() }
        var source = TaskCreationRequest(title: "Original", source: TaskEmailSource(
            accountID: "a", threadID: "thread", messageID: "message", subject: "Proposal"))
        source.notes = "Original notes"
        let rawNotes = try #require(source.draft(email: "a@example.invalid").notes)
        let task = GoogleTask(id: "task", title: source.title, notes: rawNotes, due: "2026-11-03", etag: "v1")
        let first = EditingTasksService(task: task), second = EditingTasksService(task: task)
        let session = await fixture.session(task: task, services: ["a": first, "b": second])
        session.title = "  Edited title  "
        session.notes = "Edited notes"
        session.dueDate = try #require(GoogleTaskDateCoding.date("2026-11-06"))
        fixture.defaults.set("other", forKey: "googleTasks.selectedList.b")
        session.model.selectAccount("b")
        await session.model.refresh()
        #expect(session.model.selectedListID == "other")

        #expect(await session.save())
        let call = try #require(await first.updates.first)
        #expect(call.listID == "list")
        #expect(call.taskID == task.id)
        #expect(call.etag == "v1")
        #expect(call.update == GoogleTaskUpdate(title: "Edited title",
            notes: "Edited notes\n\n" + GoogleTaskNotes(rawNotes).footer, due: .set("2026-11-06")))
        #expect(await second.updates.isEmpty)
        #expect(session.model.selectedAccountID == "b")
        #expect(session.model.selectedListID == "other")
        #expect(session.error == nil)
        #expect(!session.isSaving)
    }

    @Test func failureAndRemoteDisappearanceLeaveTheDraftIntact() async throws {
        let fixture = try EditingSessionFixture()
        defer { fixture.clean() }
        let task = GoogleTask(id: "task", title: "Original", notes: "Original notes", due: "2026-11-03", etag: "v1")
        let service = EditingTasksService(task: task)
        let session = await fixture.session(task: task, services: ["a": service])
        session.title = "Unsaved title"
        session.notes = "Unsaved notes"
        session.hasDueDate = false
        let draftDate = session.dueDate
        await service.failUpdates(.transport(.notConnectedToInternet))
        #expect(await session.save() == false)
        let failure = try #require(session.error)
        await service.removeTasks()
        await session.model.refresh()

        #expect(session.model.tasks.isEmpty)
        #expect(session.title == "Unsaved title")
        #expect(session.notes == "Unsaved notes")
        #expect(!session.hasDueDate)
        #expect(session.dueDate == draftDate)
        #expect(session.context.task == task)
        #expect(session.error == failure)
        #expect(session.canSave)
    }

    @Test func unchangedTaskDoesNotPatchOrNormalizeNotes() async throws {
        let fixture = try EditingSessionFixture()
        defer { fixture.clean() }
        let notes = "Notes\n\n\nTern task reference: " + String(repeating: "a", count: 64)
        let task = GoogleTask(id: "task", title: "Original", notes: notes, due: "2026-11-03T00:00:00.000Z", etag: "v1")
        let service = EditingTasksService(task: task)
        let session = await fixture.session(task: task, services: ["a": service])
        session.error = "Previous failure"

        #expect(await session.save())
        #expect(await service.updates.isEmpty)
        #expect(session.model.tasks.first?.notes == notes)
        #expect(session.error == nil)
    }

    @Test(.timeLimit(.minutes(1))) func concurrentSaveDoesNotSubmitTwice() async throws {
        let fixture = try EditingSessionFixture()
        defer { fixture.clean() }
        let task = GoogleTask(id: "task", title: "Original", due: "2026-11-03", etag: "v1")
        let service = EditingTasksService(task: task)
        let session = await fixture.session(task: task, services: ["a": service])
        session.hasDueDate = false
        await service.pauseUpdate()
        defer { Task { await service.releaseUpdate() } }
        let saving = Task { await session.save() }
        await service.waitUntilUpdating()
        #expect(session.isSaving)
        #expect(!session.canSave)
        #expect(await session.save() == false)
        #expect(session.isSaving)
        await service.releaseUpdate()

        #expect(await saving.value)
        #expect(await service.updates.count == 1)
        #expect(await service.updates.first?.update.due == .clear)
        #expect(!session.isSaving)
    }

    @Test func invalidInputKeepsTheDraftAndDoesNotWrite() async throws {
        let fixture = try EditingSessionFixture()
        defer { fixture.clean() }
        let service = EditingTasksService()
        let session = await fixture.session(task: nil, services: ["a": service])
        session.title = " \n "
        #expect(!session.canSave)
        #expect(await session.save() == false)
        #expect(session.title == " \n ")
        session.title = String(repeating: "t", count: 1025)
        #expect(await session.save() == false)
        #expect(session.title.count == 1025)
        session.title = "Valid title"
        session.notes = String(repeating: "n", count: 8193)
        #expect(await session.save() == false)
        #expect(session.notes.count == 8193)
        #expect(session.error != nil)
        #expect(!session.isSaving)
        #expect(await service.inserts.isEmpty)
        #expect(await service.updates.isEmpty)
    }

    @Test func newTaskUsesTheCapturedListAndKeepsItsReferenceAcrossRetries() async throws {
        let fixture = try EditingSessionFixture()
        defer { fixture.clean() }
        let service = EditingTasksService()
        let session = await fixture.session(task: nil, services: ["a": service])
        session.title = "  New task  "
        session.notes = "Notes"
        session.hasDueDate = true
        session.dueDate = try #require(GoogleTaskDateCoding.date("2026-11-06"))
        session.model.selectList("other")
        await session.model.refresh()
        await service.failInsert(.http(status: 400, reason: nil))
        #expect(await session.save() == false)
        await service.failInsert(nil)
        #expect(await session.save())

        let inserts = await service.inserts
        #expect(inserts.count == 2)
        #expect(inserts.map(\.listID) == ["list", "list"])
        #expect(inserts.first?.draft == inserts.last?.draft)
        #expect(inserts.last?.draft.title == "New task")
        #expect(inserts.last?.draft.due == "2026-11-06")
        #expect(inserts.last?.draft.notes?.hasPrefix("Notes\n\nTern task reference: ") == true)
        #expect(session.error == nil)
    }
}

@MainActor private struct EditingSessionFixture {
    let suite = "GoogleTaskEditingSessionTests-\(UUID().uuidString)"
    let defaults: UserDefaults
    init() throws { defaults = try #require(UserDefaults(suiteName: suite)) }
    func clean() { defaults.removePersistentDomain(forName: suite) }
    func session(task: GoogleTask?, services: [String: EditingTasksService]) async -> GoogleTaskEditingSession {
        let accounts = services.keys.sorted().map {
            AccountRecord(id: $0, email: "\($0)@example.invalid", displayName: $0,
                grantedScopes: [GoogleScopes.tasks], addedAt: .now, enabledFeatures: [AccountFeature.tasks.rawValue])
        }
        let model = GoogleTasksModel(defaults: defaults, loadAccounts: { accounts }, service: { services[$0] }, enable: { _ in })
        await model.refresh()
        return GoogleTaskEditingSession(model: model, context: .init(task: task,
            location: .init(accountID: "a", listID: "list"), listTitle: "Tasks"))
    }
}

private actor EditingTasksService: TasksService {
    struct Update: Sendable {
        let listID: String
        let taskID: String
        let update: GoogleTaskUpdate
        let etag: String?
    }
    struct Insert: Sendable {
        let listID: String
        let draft: GoogleTaskDraft
    }
    private var values: [String: [GoogleTask]]
    private var updateFailure: GmailError?
    private var insertFailure: GmailError?
    private var pausesUpdate = false
    private var updateContinuation: CheckedContinuation<Void, Never>?
    private var updateWaiters: [CheckedContinuation<Void, Never>] = []
    var updates: [Update] = []
    var inserts: [Insert] = []

    init(task: GoogleTask? = nil) { values = ["list": task.map { [$0] } ?? []] }
    func failUpdates(_ error: GmailError?) { updateFailure = error }
    func failInsert(_ error: GmailError?) { insertFailure = error }
    func removeTasks() { values = [:] }
    func pauseUpdate() { pausesUpdate = true }
    func waitUntilUpdating() async {
        guard updateContinuation == nil else { return }
        await withCheckedContinuation { updateWaiters.append($0) }
    }
    func releaseUpdate() { updateContinuation?.resume(); updateContinuation = nil }
    func taskLists(pageToken: String?) async throws -> GoogleTaskListPage {
        .init(items: [.init(id: "list", title: "Tasks"), .init(id: "other", title: "Other")])
    }
    func tasks(listID: String, pageToken: String?) async throws -> GoogleTaskPage { .init(items: values[listID] ?? []) }
    func insertTask(listID: String, draft: GoogleTaskDraft) async throws -> GoogleTask {
        inserts.append(Insert(listID: listID, draft: draft))
        if let insertFailure { throw insertFailure }
        let task = GoogleTask(id: "created", title: draft.title, notes: draft.notes, due: draft.due, etag: "v1")
        values[listID, default: []].append(task)
        return task
    }
    func updateTask(listID: String, taskID: String, update: GoogleTaskUpdate, etag: String?) async throws -> GoogleTask {
        updates.append(Update(listID: listID, taskID: taskID, update: update, etag: etag))
        if pausesUpdate {
            pausesUpdate = false
            await withCheckedContinuation { continuation in
                updateContinuation = continuation
                for waiter in updateWaiters { waiter.resume() }
                updateWaiters = []
            }
        }
        if let updateFailure { throw updateFailure }
        guard let index = values[listID]?.firstIndex(where: { $0.id == taskID }), var task = values[listID]?[index] else {
            throw GmailError.notFound
        }
        if let title = update.title { task.title = title }
        if let notes = update.notes { task.notes = notes }
        switch update.due { case .set(let day): task.due = day; case .clear: task.due = nil; case .unchanged: break }
        values[listID]?[index] = task
        return task
    }
    func deleteTask(listID: String, taskID: String, etag: String?) async throws {
        values[listID]?.removeAll { $0.id == taskID }
    }
}
