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

    @Test func selectingAKnownListFetchesTasksWithoutReloadingAllLists() async throws {
        let fixture = try TasksModelFixture()
        defer { fixture.clean() }
        let service = MemoryTasksService(lists: [.init(id: "list", title: "First"), .init(id: "second", title: "Second")])
        await service.put(.init(id: "second-task", title: "Second list task"), listID: "second")
        let model = fixture.model(accounts: [Self.account("a")], services: ["a": service])
        await model.refresh()
        let initialReads = await service.reads
        model.selectList("second")
        let deadline = ContinuousClock.now + .seconds(5)
        while model.tasks.first?.id != "second-task", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.tasks.map(\.id) == ["second-task"])
        #expect(await service.reads == initialReads + 1)
        await model.refresh()
        #expect(await service.reads == initialReads + 3)
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

    @Test func completionUsesTheWriteResponseAndReadsAgainOnlyForATaskWithSubtasks() async throws {
        let fixture = try TasksModelFixture()
        defer { fixture.clean() }
        let service = MemoryTasksService()
        await service.put(.init(id: "single", title: "Single"), listID: "list")
        await service.put(.init(id: "parent", title: "Parent"), listID: "list")
        await service.put(.init(id: "child", title: "Child", parent: "parent"), listID: "list")
        let model = fixture.model(accounts: [Self.account("a")], services: ["a": service])
        await model.refresh()
        let single = try #require(model.openTasks.first { $0.id == "single" })
        var reads = await service.reads
        #expect(await model.setCompleted(single, completed: true))
        #expect(model.completedTasks.map(\.id) == ["single"])
        #expect(model.busyTaskIDs.isEmpty)
        #expect(await service.reads == reads)

        // The response describes only the parent, so the list is read again for its subtasks.
        let parent = try #require(model.openTasks.first { $0.id == "parent" })
        reads = await service.reads
        #expect(await model.setCompleted(parent, completed: true))
        #expect(await service.reads == reads + 2)
    }

    @Test(.timeLimit(.minutes(1))) func aWriteThatOverlapsAListReadEndsWithItsOwnRead() async throws {
        let fixture = try TasksModelFixture()
        defer { fixture.clean() }
        let service = MemoryTasksService()
        await service.put(.init(id: "task", title: "Task"), listID: "list")
        let model = fixture.model(accounts: [Self.account("a")], services: ["a": service])
        await model.refresh()
        let task = try #require(model.openTasks.first)
        let gate = TasksReadGate()
        defer { Task { await gate.release() } }
        await service.holdNextListRead(gate)
        let read = Task { await model.refresh() }
        await gate.waitUntilHeld()
        #expect(model.isLoading)
        // The write retires the read in flight, so its own read has to clear the loading state.
        #expect(await model.setCompleted(task, completed: true))
        #expect(!model.isLoading)
        #expect(model.completedTasks.map(\.id) == ["task"])
        await gate.release()
        await read.value
        #expect(!model.isLoading)
        #expect(model.completedTasks.map(\.id) == ["task"])
    }

    @Test(.timeLimit(.minutes(1))) func switchingListsDrawsCachedRowsAndHoldsThePreviousOnesUntilTheFirstRead() async throws {
        let fixture = try TasksModelFixture()
        defer { fixture.clean() }
        let service = MemoryTasksService(lists: [.init(id: "list", title: "First"), .init(id: "second", title: "Second")])
        await service.put(.init(id: "first-task", title: "First list task"), listID: "list")
        await service.put(.init(id: "second-task", title: "Second list task"), listID: "second")
        let model = fixture.model(accounts: [Self.account("a")], services: ["a": service])
        await model.refresh()
        #expect(model.tasks.map(\.id) == ["first-task"])

        // Nothing is cached for the second list. The first list's rows are held, never its tasks.
        var gate = TasksReadGate()
        await service.holdNextTaskRead(gate)
        model.selectList("second")
        await gate.waitUntilHeld()
        #expect(model.tasks.isEmpty)
        #expect(model.heldRows?.open.map(\.id) == ["first-task"])
        await gate.release()
        try await Self.until { model.tasks.first?.id == "second-task" }
        #expect(model.heldRows == nil)

        // Going back draws the first list from the cache while its read is still out.
        await service.put(.init(id: "first-new", title: "Added elsewhere"), listID: "list")
        gate = TasksReadGate()
        await service.holdNextTaskRead(gate)
        model.selectList("list")
        #expect(model.tasks.map(\.id) == ["first-task"])
        #expect(model.lastSyncedAt != nil)
        #expect(model.heldRows == nil)
        await gate.waitUntilHeld()
        await gate.release()
        try await Self.until { model.tasks.map(\.id) == ["first-task", "first-new"] }

        // Losing access to the account drops the rows cached for its lists.
        model.invalidateAccount("a")
        await model.refresh()
        gate = TasksReadGate()
        await service.holdNextTaskRead(gate)
        model.selectList("second")
        await gate.waitUntilHeld()
        #expect(model.tasks.isEmpty)
        await gate.release()
        try await Self.until { model.tasks.first?.id == "second-task" }
    }

    @Test(.timeLimit(.minutes(1))) func completionDrawsAtOnceAndAFailedWriteRestoresTheRow() async throws {
        let fixture = try TasksModelFixture()
        defer { fixture.clean() }
        let service = MemoryTasksService()
        await service.put(.init(id: "task", title: "Task"), listID: "list")
        let model = fixture.model(accounts: [Self.account("a")], services: ["a": service])
        await model.refresh()
        let task = try #require(model.openTasks.first)
        let gate = TasksReadGate()
        defer { Task { await gate.release() } }
        await service.holdNextUpdate(gate)
        let write = Task { await model.setCompleted(task, completed: true) }
        await gate.waitUntilHeld()
        // The row has moved and is busy. What Google confirmed has not changed.
        #expect(model.openTasks.isEmpty)
        let pending = try #require(model.completedTasks.first)
        #expect(pending.id == "task")
        #expect(model.taskIsBusy(pending))
        #expect(model.tasks.first?.isCompleted == false)
        // The waiting row takes no second change.
        #expect(await model.setCompleted(pending, completed: false) == false)
        #expect(await model.delete(pending) == false)

        await service.setUpdateFailure(.transport(.timedOut))
        await gate.release()
        #expect(await write.value == false)
        #expect(model.openTasks.map(\.id) == ["task"])
        #expect(model.completedTasks.isEmpty)
        #expect(model.busyTaskIDs.isEmpty)
        #expect(model.errorMessage?.hasPrefix("Couldn't confirm the change.") == true)
        // The failed write is not sent again.
        #expect(await service.updates == 1)
    }

    @Test(.timeLimit(.minutes(1))) func aReadDuringAPendingCompletionDoesNotFlipTheRowBack() async throws {
        let fixture = try TasksModelFixture()
        defer { fixture.clean() }
        let service = MemoryTasksService()
        await service.put(.init(id: "task", title: "Task"), listID: "list")
        let model = fixture.model(accounts: [Self.account("a")], services: ["a": service])
        await model.refresh()
        let task = try #require(model.openTasks.first)
        let gate = TasksReadGate()
        defer { Task { await gate.release() } }
        await service.holdNextUpdate(gate)
        let write = Task { await model.setCompleted(task, completed: true) }
        await gate.waitUntilHeld()
        // Google hasn't applied the write, so this read returns the task as open, beside a new one.
        await service.put(.init(id: "other", title: "Added elsewhere"), listID: "list")
        await model.refresh()
        #expect(model.tasks.map(\.id) == ["task", "other"])
        #expect(model.tasks.first?.isCompleted == false)
        #expect(model.openTasks.map(\.id) == ["other"])
        #expect(model.completedTasks.map(\.id) == ["task"])
        #expect(model.taskIsBusy(task))

        await gate.release()
        #expect(await write.value)
        #expect(model.tasks.first?.isCompleted == true)
        #expect(model.openTasks.map(\.id) == ["other"])
        #expect(model.completedTasks.map(\.id) == ["task"])
        #expect(model.busyTaskIDs.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func aListLeftDuringACompletionComesBackWithGooglesAnswer() async throws {
        let fixture = try TasksModelFixture()
        defer { fixture.clean() }
        let service = MemoryTasksService(lists: [.init(id: "list", title: "First"), .init(id: "second", title: "Second")])
        await service.put(.init(id: "first-task", title: "First list task"), listID: "list")
        let model = fixture.model(accounts: [Self.account("a")], services: ["a": service])
        await model.refresh()
        let task = try #require(model.openTasks.first)
        let write = TasksReadGate()
        defer { Task { await write.release() } }
        await service.holdNextUpdate(write)
        let completion = Task { await model.setCompleted(task, completed: true) }
        await write.waitUntilHeld()
        // Leaving caches the list as Google last confirmed it, with the task still open.
        model.selectList("second")
        await write.release()
        #expect(await completion.value)

        // Going back draws from the cache while the list's own read is still out.
        let read = TasksReadGate()
        defer { Task { await read.release() } }
        await service.holdNextTaskRead(read)
        model.selectList("list")
        #expect(model.completedTasks.map(\.id) == ["first-task"])
        #expect(model.openTasks.isEmpty)
        #expect(!model.taskIsBusy(task))
        await read.waitUntilHeld()
        await read.release()
        try await Self.until { !model.isLoading }
        #expect(model.completedTasks.map(\.id) == ["first-task"])
    }

    @Test(.timeLimit(.minutes(1))) func aFinishedWriteDoesNotReleaseALaterWriteToTheSameTask() async throws {
        let fixture = try TasksModelFixture()
        defer { fixture.clean() }
        let service = MemoryTasksService()
        await service.put(.init(id: "parent", title: "Parent"), listID: "list")
        await service.put(.init(id: "child", title: "Child", parent: "parent"), listID: "list")
        let model = fixture.model(accounts: [Self.account("a")], services: ["a": service])
        await model.refresh()
        let parent = try #require(model.openTasks.first { $0.id == "parent" })
        // Completing a task with subtasks is followed by a read. Google answers the write, and
        // that read stays out.
        let read = TasksReadGate()
        defer { Task { await read.release() } }
        await service.holdNextTaskRead(read)
        let completion = Task { await model.setCompleted(parent, completed: true) }
        await read.waitUntilHeld()
        let completed = try #require(model.completedTasks.first { $0.id == "parent" })
        #expect(!model.taskIsBusy(completed))

        let write = TasksReadGate()
        defer { Task { await write.release() } }
        await service.holdNextUpdate(write)
        let reopening = Task { await model.setCompleted(completed, completed: false) }
        await write.waitUntilHeld()
        // The first call returns while the second write is still with Google.
        await read.release()
        #expect(await completion.value)
        #expect(model.taskIsBusy(completed))
        #expect(model.openTasks.contains { $0.id == "parent" })
        #expect(await model.setCompleted(completed, completed: true) == false)

        await write.release()
        #expect(await reopening.value)
        #expect(model.busyTaskIDs.isEmpty)
        #expect(model.openTasks.contains { $0.id == "parent" })
        #expect(await service.updates == 2)
    }

    @Test(.timeLimit(.minutes(1))) func removingAnAccountDropsItsCachedRowsAndPendingCompletion() async throws {
        let fixture = try TasksModelFixture()
        defer { fixture.clean() }
        let service = MemoryTasksService(lists: [.init(id: "list", title: "First"), .init(id: "second", title: "Second")])
        await service.put(.init(id: "first-task", title: "First list task"), listID: "list")
        await service.put(.init(id: "second-task", title: "Second list task"), listID: "second")
        let model = fixture.model(accounts: [Self.account("a")], services: ["a": service])
        await model.refresh()
        // Show the second list and come back, so its rows are cached.
        model.selectList("second")
        try await Self.until { model.tasks.first?.id == "second-task" }
        var read = TasksReadGate()
        await service.holdNextTaskRead(read)
        model.selectList("list")
        await read.waitUntilHeld()
        await read.release()
        try await Self.until { !model.isLoading }
        let task = try #require(model.openTasks.first)
        let write = TasksReadGate()
        defer { Task { await write.release() } }
        await service.holdNextUpdate(write)
        let completion = Task { await model.setCompleted(task, completed: true) }
        await write.waitUntilHeld()
        #expect(model.completedTasks.map(\.id) == ["first-task"])

        // Turning Tasks off removes the account. The fixture still lists it, so it loads again
        // from Google, where the held write has not landed.
        await model.removeAccount("a")
        #expect(model.openTasks.map(\.id) == ["first-task"])
        #expect(model.completedTasks.isEmpty)
        read = TasksReadGate()
        await service.holdNextTaskRead(read)
        model.selectList("second")
        await read.waitUntilHeld()
        #expect(model.tasks.isEmpty)
        await read.release()
        try await Self.until { model.tasks.first?.id == "second-task" }
        // The answer to a write from before the removal is discarded.
        await write.release()
        #expect(await completion.value == false)
        #expect(model.tasks.map(\.id) == ["second-task"])
    }

    @Test(.timeLimit(.minutes(1))) func thePanelsFirstRefreshJoinsAPreloadInFlight() async throws {
        let fixture = try TasksModelFixture()
        defer { fixture.clean() }
        let gate = TasksReadGate()
        defer { Task { await gate.release() } }
        let service = MemoryTasksService(gate: gate)
        await service.put(.init(id: "task", title: "Task"), listID: "list")
        let model = fixture.model(accounts: [Self.account("a")], services: ["a": service])
        model.preload()
        await gate.waitUntilHeld()
        let opening = Task { await model.refreshOnAppear() }
        await gate.release()
        await opening.value
        #expect(model.tasks.map(\.id) == ["task"])
        // One read of the lists and one of the tasks. Opening the panel did not send them again.
        #expect(await service.reads == 2)
    }

    private static func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
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
    private var taskGate: TasksReadGate?
    private var updateGate: TasksReadGate?
    private var updateFailure: GmailError?
    var taskListReads: [String] = []

    init(lists: [GoogleTaskList] = [.init(id: "list", title: "My tasks")], gate: TasksReadGate? = nil) {
        self.lists = lists; self.gate = gate
    }
    func setInsertFailure(_ error: GmailError?) { insertFailure = error }
    func setReadFailure(_ error: GmailError?) { readFailure = error }
    func failTaskList(_ id: String) { failedTaskList = id }
    func holdNextListRead(_ gate: TasksReadGate) { self.gate = gate }
    func holdNextTaskRead(_ gate: TasksReadGate) { taskGate = gate }
    /// The held write has reached the service and has not changed the task yet.
    func holdNextUpdate(_ gate: TasksReadGate) { updateGate = gate }
    func setUpdateFailure(_ error: GmailError?) { updateFailure = error }
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
        if let taskGate { self.taskGate = nil; await taskGate.hold() }
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
        if let updateGate { self.updateGate = nil; await updateGate.hold() }
        if let updateFailure { throw updateFailure }
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
