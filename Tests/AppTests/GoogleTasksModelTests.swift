import Foundation
import GmailAPI
import MailStore
import Observation
import Synchronization
import Testing
@testable import Tern

@Suite @MainActor struct GoogleTasksModelTests {
    @Test func newQuickTaskDoesNotReadUnrelatedListsAndAConfirmedRetryDoesNotInsertAgain() async throws {
        let fixture = try TasksModelFixture()
        defer { fixture.clean() }
        let service = MemoryTasksService(lists: [.init(id: "list", title: "My tasks"), .init(id: "archive", title: "Archive")])
        let model = fixture.model(accounts: [Self.account("a")], services: ["a": service])
        await model.refresh()
        await service.failTaskList("archive")
        let request = TaskCreationRequest(title: "A quick task", accountID: "a", listID: "list")
        #expect(await model.add(request))
        #expect(await service.insertLists == ["list"])
        #expect(await service.taskListReads.contains("archive") == false)
        #expect(await model.add(request))
        #expect(await service.inserts == 1)
    }

    @Test func taskPresentationTracksValueChangesAndSkipsUnchangedSnapshots() throws {
        let fixture = try TasksModelFixture()
        defer { fixture.clean() }
        let model = fixture.model(accounts: [], services: [:])
        let parent = GoogleTask(id: "parent", title: "Project")
        let child = GoogleTask(id: "child", title: "Review", parent: parent.id)
        let done = GoogleTask(id: "done", title: "Sent", status: "completed")
        model.tasks = [child, done, parent, GoogleTask(id: "deleted", title: "Removed", deleted: true)]
        #expect(model.openTasks == [child, parent])
        #expect(model.completedTasks == [done])
        #expect(model.parentTitle(for: child) == "Project")

        let changes = Mutex(0)
        withObservationTracking {
            _ = model.openTasks
            _ = model.completedTasks
            _ = model.parentTitle(for: child)
        } onChange: { changes.withLock { $0 += 1 } }
        let unchanged = model.tasks
        model.tasks = unchanged
        #expect(changes.withLock { $0 } == 0)

        model.tasks[2].title = "Renamed project"
        #expect(changes.withLock { $0 } == 1)
        #expect(model.openTasks.map(\.title) == ["Review", "Renamed project"])
        #expect(model.parentTitle(for: child) == "Renamed project")

        model.tasks[0].status = "completed"
        model.tasks[0].notes = "Updated under the same ID"
        #expect(model.openTasks.map(\.id) == [parent.id])
        #expect(model.completedTasks.map(\.id) == [child.id, done.id])
        #expect(model.completedTasks.first?.notes == "Updated under the same ID")
        model.tasks[0].deleted = true
        #expect(model.completedTasks == [done])
        model.tasks.removeAll { $0.id == parent.id }
        #expect(model.parentTitle(for: child) == nil)
        #expect(model.openTasks.isEmpty)
        model.tasks = []
        #expect(model.completedTasks.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func creationKeepsItsDestinationAndInsertsAtTheTopBeforeRefresh() async throws {
        let fixture = try TasksModelFixture()
        defer { fixture.clean() }
        let service = MemoryTasksService(lists: [.init(id: "list", title: "My tasks"), .init(id: "other", title: "Other")])
        let model = fixture.model(accounts: [Self.account("a")], services: ["a": service])
        await model.refresh()
        let insert = TasksReadGate(), refresh = TasksReadGate()
        defer { Task { await insert.release(); await refresh.release() } }
        await service.delayInsert(insert, refresh: refresh)
        var request = Self.request("a")
        request.listID = "list"
        let saving = Task { await model.add(request) }
        await insert.waitUntilHeld()
        #expect(model.pendingCreation?.accountID == "a")
        #expect(model.pendingCreation?.listID == "list")
        #expect(model.creationState(for: request) == .adding)
        #expect(model.tasks.isEmpty)

        model.selectList("other")
        await model.refresh()
        #expect(model.pendingCreation?.listID == "list")
        #expect(model.selectedListID == "other")
        await service.put(.init(id: "existing", title: "Existing task"), listID: "list")
        model.selectList("list")
        // selectList schedules its own refresh; wait for that read to publish.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while model.tasks.first?.id != "existing", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.tasks.first?.id == "existing")
        await insert.release()
        await refresh.waitUntilHeld()
        let created = try #require(model.tasks.first)
        #expect(created.title == request.title)
        #expect(model.tasks.last?.id == "existing")
        #expect(model.pendingCreation == nil)
        #expect(model.creationState(for: request) == .added)
        await refresh.release()
        #expect(await saving.value)
        #expect(model.tasks.map(\.id) == [created.id, "existing"])
    }

    @Test func missingExplicitListFailsWhileAnUnspecifiedListCanUseTheDefault() async throws {
        let fixture = try TasksModelFixture()
        defer { fixture.clean() }
        fixture.defaults.set("removed-list", forKey: "googleTasks.selectedList.a")
        let service = MemoryTasksService()
        let model = fixture.model(accounts: [Self.account("a")], services: ["a": service])
        var request = Self.request("a")
        request.listID = "removed-list"
        #expect(await model.add(request) == false)
        #expect(await service.inserts == 0)
        #expect(model.errorMessage?.contains("Reload lists") == true)
        request.listID = nil
        #expect(await model.add(request))
        #expect(await service.insertLists == ["list"])
    }

    @Test func disabledAccountCannotReadOrWriteWithAStillGrantedToken() async throws {
        let fixture = try TasksModelFixture()
        defer { fixture.clean() }
        let service = MemoryTasksService()
        var disabled = Self.account("a")
        disabled.enabledFeatures = []
        let model = fixture.model(accounts: [disabled], services: ["a": service])
        await model.refresh()
        #expect(model.needsConnection)
        let request = Self.request("a")
        #expect(await model.add(request) == false)
        #expect(await service.reads == 0)
        #expect(await service.inserts == 0)
        #expect(model.pendingCreation?.source?.accountID == "a")
    }

    @Test func emailCreationUsesItsOwnAccountAndRemembersTheChosenList() async throws {
        let fixture = try TasksModelFixture()
        defer { fixture.clean() }
        let first = MemoryTasksService(lists: [.init(id: "inbox", title: "My tasks"), .init(id: "work", title: "Work")])
        let second = MemoryTasksService()
        fixture.defaults.set("b", forKey: "googleTasks.selectedAccount")
        fixture.defaults.set("work", forKey: "googleTasks.selectedList.a")
        let model = fixture.model(accounts: [Self.account("a"), Self.account("b")], services: ["a": first, "b": second])
        await model.refresh()
        #expect(model.selectedAccountID == "b")
        let request = Self.request("a")
        #expect(await model.add(request))
        #expect(model.selectedAccountID == "a")
        #expect(model.selectedListID == "work")
        #expect(await first.insertLists == ["work"])
        #expect(await second.inserts == 0)
        let added = try #require(await first.values["work"]?.first)
        #expect(added.notes?.contains("authuser=a@example.invalid") == true)
        #expect(added.notes?.contains(request.marker) == true)
        #expect(added.dueDay == "2026-11-06")
        #expect(await model.add(request))
        #expect(await first.inserts == 1)
        #expect(model.creationState(for: request) == .added)
    }

    @Test func uncertainCreationSurvivesRelaunchAndFailedReconciliation() async throws {
        let fixture = try TasksModelFixture()
        defer { fixture.clean() }
        let service = MemoryTasksService()
        await service.setInsertFailure(.transport(.timedOut))
        let request = Self.request("a")
        let model = fixture.model(accounts: [Self.account("a")], services: ["a": service])
        #expect(await model.add(request) == false)
        #expect(model.creationState(for: request) == .uncertain)
        let reopened = fixture.model(accounts: [Self.account("a")], services: ["a": service])
        await service.setReadFailure(.transport(.notConnectedToInternet))
        #expect(await reopened.add(request) == false)
        #expect(reopened.creationState(for: request) == .uncertain)
        await service.setReadFailure(nil)
        #expect(await reopened.add(request) == false)
        #expect(await service.inserts == 1)
        await service.put(GoogleTask(id: "remote", title: request.title, notes: request.marker), listID: "list")
        #expect(await reopened.add(request))
        #expect(await service.inserts == 1)
        #expect(reopened.creationState(for: request) == .added)
    }

    @Test func oldAccountReadCannotReplaceTheSelectedAccountsTasks() async throws {
        let fixture = try TasksModelFixture()
        defer { fixture.clean() }
        let gate = TasksReadGate()
        let first = MemoryTasksService(gate: gate)
        let second = MemoryTasksService()
        await first.put(.init(id: "a-task", title: "A"), listID: "list")
        await second.put(.init(id: "b-task", title: "B"), listID: "list")
        let model = fixture.model(accounts: [Self.account("a"), Self.account("b")], services: ["a": first, "b": second])
        let delayed = Task { await model.refresh() }
        await gate.waitUntilHeld()
        model.selectAccount("b")
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while model.tasks.first?.id != "b-task", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        await gate.release()
        await delayed.value
        #expect(model.selectedAccountID == "b")
        #expect(model.tasks.map(\.id) == ["b-task"])
    }

    @Test func editorMutationsKeepTheirCapturedAccountAndList() async throws {
        let fixture = try TasksModelFixture()
        defer { fixture.clean() }
        let first = MemoryTasksService(), second = MemoryTasksService()
        let task = GoogleTask(id: "same-id", title: "Original", etag: "v1")
        await first.put(task, listID: "list")
        await second.put(task, listID: "list")
        let model = fixture.model(accounts: [Self.account("a"), Self.account("b")], services: ["a": first, "b": second])
        await model.refresh()
        let original = try #require(model.selectedLocation)
        model.selectAccount("b")
        await model.refresh()
        #expect(await model.update(task, update: .init(title: "Edited"), location: original))
        #expect(await first.updates == 1)
        #expect(await second.updates == 0)
        #expect(model.tasks.first?.title == "Original")
    }

    @Test func revokedAccessDuringCreationPreventsItsPost() async throws {
        let fixture = try TasksModelFixture()
        defer { fixture.clean() }
        let gate = TasksReadGate()
        let service = MemoryTasksService(gate: gate)
        let model = fixture.model(accounts: [Self.account("a")], services: ["a": service])
        let add = Task { await model.add(Self.request("a")) }
        await gate.waitUntilHeld()
        model.invalidateAccount("a")
        await gate.release()
        #expect(await add.value == false)
        #expect(await service.inserts == 0)
    }

    @Test func assistantRevocationBeforeInsertDoesNotLeaveAPendingAddition() async throws {
        let fixture = try TasksModelFixture()
        defer { fixture.clean() }
        let gate = TasksReadGate()
        let service = MemoryTasksService(gate: gate)
        let model = fixture.model(accounts: [Self.account("a")], services: ["a": service])
        let request = Self.request("a")
        var authorized = true
        let add = Task { await model.add(request, isAuthorized: { authorized }) }
        await gate.waitUntilHeld()
        authorized = false
        await gate.release()
        #expect(await add.value == false)
        #expect(await service.inserts == 0)
        #expect(model.pendingCreation == nil)
        #expect(model.creationState(for: request) == .idle)
    }

    @Test func assistantRevocationAfterDispatchStillRecordsTheConfirmedTask() async throws {
        let fixture = try TasksModelFixture()
        defer { fixture.clean() }
        let service = MemoryTasksService()
        let model = fixture.model(accounts: [Self.account("a")], services: ["a": service])
        await model.refresh()
        let insert = TasksReadGate(), refresh = TasksReadGate()
        await service.delayInsert(insert, refresh: refresh)
        let request = Self.request("a")
        var authorized = true
        let add = Task { await model.add(request, isAuthorized: { authorized }) }
        await insert.waitUntilHeld()
        authorized = false
        await insert.release()
        await refresh.waitUntilHeld()
        #expect(model.creationState(for: request) == .added)
        #expect(model.pendingCreation == nil)
        await refresh.release()
        #expect(await add.value)
        #expect(await service.inserts == 1)
    }

    @Test func remoteDeletionClearsTheAddedState() async throws {
        let fixture = try TasksModelFixture()
        defer { fixture.clean() }
        let service = MemoryTasksService()
        let model = fixture.model(accounts: [Self.account("a")], services: ["a": service])
        let request = Self.request("a")
        #expect(await model.add(request))
        let id = try #require(model.tasks.first?.id)
        try await service.deleteTask(listID: "list", taskID: id, etag: nil)
        await model.refresh()
        #expect(model.tasks.isEmpty)
        #expect(model.creationState(for: request) == .idle)
    }

    @Test func missingListEndpointDoesNotReportATaskConflictAndRefreshCanRecover() async throws {
        let fixture = try TasksModelFixture()
        defer { fixture.clean() }
        let service = MemoryTasksService()
        await service.setReadFailure(.notFound)
        let model = fixture.model(accounts: [Self.account("a")], services: ["a": service])
        await model.refresh()
        #expect(model.issue == .unavailable)
        #expect(model.lists.isEmpty)
        #expect(model.lastSyncedAt == nil)
        #expect(!model.isLoading)
        #expect(GoogleTasksIssue(GmailError.http(status: 412, reason: nil)) == .conflict)

        await service.setReadFailure(nil)
        await service.put(.init(id: "remote", title: "Existing task"), listID: "list")
        await model.refresh()
        #expect(model.issue == nil)
        #expect(model.tasks.map(\.id) == ["remote"])
        #expect(model.lastSyncedAt != nil)
    }

    @Test func editingNotesPreservesTheSourceAndDuplicateReference() throws {
        var request = Self.request("a")
        request.notes = "Ask for the revised figures."
        let notes = try #require(request.draft(email: "a@example.invalid").notes)
        let editable = GoogleTaskNotes(notes)
        #expect(editable.text == request.notes)
        #expect(!editable.text.contains(request.marker))
        let changed = editable.replacingText("Updated notes")
        #expect(changed.contains(request.marker))
        #expect(GoogleTaskRow.emailURL(changed) == request.source?.mailLink.ternURL)
        #expect(GoogleTaskNotes("Unrelated notes").replacingText("Edited") == "Edited")
    }

    @Test func completingReopeningAndDeletingUseTheRemoteResult() async throws {
        let fixture = try TasksModelFixture()
        defer { fixture.clean() }
        let service = MemoryTasksService()
        let model = fixture.model(accounts: [Self.account("a")], services: ["a": service])
        let request = Self.request("a")
        #expect(await model.add(request))
        let task = try #require(model.openTasks.first)
        #expect(await model.setCompleted(task, completed: true))
        #expect(model.openTasks.isEmpty)
        let completed = try #require(model.completedTasks.first)
        #expect(await model.setCompleted(completed, completed: false))
        #expect(model.completedTasks.isEmpty)
        let reopened = try #require(model.openTasks.first)
        #expect(reopened.id == task.id)
        #expect(await model.delete(reopened))
        #expect(model.tasks.isEmpty)
        #expect(try await service.allTasks(listID: "list").isEmpty)
        #expect(model.creationState(for: request) == .idle)
    }

    private static func account(_ id: String) -> AccountRecord {
        AccountRecord(id: id, email: "\(id)@example.invalid", displayName: id,
            grantedScopes: [GoogleScopes.tasks], addedAt: .now, enabledFeatures: [AccountFeature.tasks.rawValue])
    }

    private static func request(_ accountID: String) -> TaskCreationRequest {
        TaskCreationRequest(title: "Review the proposal", dueDate: "2026-11-06",
            source: TaskEmailSource(accountID: accountID, threadID: "thread", messageID: "message", subject: "Proposal"),
            deduplicationKey: "proposal-review")
    }
}

@MainActor private struct TasksModelFixture {
    let suite = "GoogleTasksModelTests-\(UUID().uuidString)"
    let defaults: UserDefaults
    init() throws { defaults = try #require(UserDefaults(suiteName: suite)) }
    func clean() { defaults.removePersistentDomain(forName: suite) }
    func model(accounts: [AccountRecord], services: [String: MemoryTasksService]) -> GoogleTasksModel {
        GoogleTasksModel(defaults: defaults, loadAccounts: { accounts }, service: { services[$0] }, enable: { _ in })
    }
}

private actor TasksReadGate {
    private var isHeld = false
    private var held: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        isHeld = true
        for waiter in waiters { waiter.resume() }
        waiters = []
        await withCheckedContinuation { held = $0 }
    }
    func waitUntilHeld() async {
        guard !isHeld else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { held?.resume(); held = nil }
}

private actor MemoryTasksService: TasksService {
    let lists: [GoogleTaskList]
    var values: [String: [GoogleTask]] = [:]
    var reads = 0
    var inserts = 0
    var updates = 0
    var insertLists: [String] = []
    private var gate: TasksReadGate?
    private var insertGate: TasksReadGate?
    private var afterInsertGate: TasksReadGate?
    private var insertFailure: GmailError?
    private var readFailure: GmailError?
    private var failedTaskList: String?
    var taskListReads: [String] = []

    init(lists: [GoogleTaskList] = [.init(id: "list", title: "My tasks")], gate: TasksReadGate? = nil) {
        self.lists = lists; self.gate = gate
    }
    func setInsertFailure(_ error: GmailError?) { insertFailure = error }
    func setReadFailure(_ error: GmailError?) { readFailure = error }
    func failTaskList(_ id: String) { failedTaskList = id }
    func delayInsert(_ insert: TasksReadGate, refresh: TasksReadGate) {
        insertGate = insert; afterInsertGate = refresh
    }
    func put(_ task: GoogleTask, listID: String) { values[listID, default: []].append(task) }
    func taskLists(pageToken: String?) async throws -> GoogleTaskListPage {
        reads += 1
        if let gate { self.gate = nil; await gate.hold() }
        if let readFailure { throw readFailure }
        return .init(items: lists)
    }
    func tasks(listID: String, pageToken: String?) async throws -> GoogleTaskPage {
        reads += 1
        taskListReads.append(listID)
        if failedTaskList == listID { throw GmailError.transport(.timedOut) }
        if let readFailure { throw readFailure }
        return .init(items: values[listID] ?? [])
    }
    func insertTask(listID: String, draft: GoogleTaskDraft) async throws -> GoogleTask {
        inserts += 1; insertLists.append(listID)
        if let insertGate { self.insertGate = nil; await insertGate.hold() }
        if let insertFailure { throw insertFailure }
        let task = GoogleTask(id: UUID().uuidString, title: draft.title, notes: draft.notes, due: draft.due, etag: "v1")
        values[listID, default: []].insert(task, at: 0)
        gate = afterInsertGate; afterInsertGate = nil
        return task
    }
    func updateTask(listID: String, taskID: String, update: GoogleTaskUpdate, etag: String?) async throws -> GoogleTask {
        updates += 1
        guard let index = values[listID]?.firstIndex(where: { $0.id == taskID }), var task = values[listID]?[index] else { throw GmailError.notFound }
        if let title = update.title { task.title = title }
        if let notes = update.notes { task.notes = notes }
        if let completed = update.isCompleted { task.status = completed ? "completed" : "needsAction" }
        switch update.due { case .set(let date): task.due = date; case .clear: task.due = nil; case .unchanged: break }
        values[listID]?[index] = task
        return task
    }
    func deleteTask(listID: String, taskID: String, etag: String?) async throws {
        values[listID]?.removeAll { $0.id == taskID }
    }
}
