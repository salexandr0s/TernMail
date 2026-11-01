import Foundation
import GmailAPI
import MailStore
import SyncEngine
import Testing
@testable import Tern

@Suite @MainActor struct CalendarModelTests {
    @Test func oversizedRefreshCannotLeaveAnOlderRetainedSnapshotForItsRange() async throws {
        try await withFixture { fixture in
            let original = Self.event(id: "growing")
            let day = try #require(original.startDate)
            fixture.model.mode = .day
            fixture.model.date = day
            await fixture.service.put(original)
            await fixture.model.activateRange()
            let key = fixture.model.rangeIdentity
            #expect(fixture.model.rangeSnapshots[key] != nil)

            var refreshed = original
            refreshed.summary = "Updated oversized event"
            refreshed.description = String(repeating: "x", count: 7 * 1_024 * 1_024)
            await fixture.service.put(refreshed)
            await fixture.model.reloadOccurrences()

            #expect(fixture.model.events.first?.title == refreshed.summary)
            #expect(fixture.model.rangeSnapshots[key] == nil)
            #expect(!fixture.model.rangeSnapshotOrder.contains(key))
            fixture.model.date = try #require(fixture.model.calendar.date(byAdding: .day, value: 1, to: day))
            await fixture.model.activateRange()
            fixture.model.date = day
            await fixture.model.activateRange()
            #expect(fixture.model.events.first?.title == refreshed.summary)
        }
    }

    @Test func adjacentLocalDaysPrepareWithoutPublishingOrRequestingAndActivateWarm() async throws {
        try await withFixture { fixture in
            let center = try await fixture.cacheDayNeighborhood()
            fixture.model.isVisible = true
            await fixture.model.reloadOccurrences(refresh: false)
            let visible = try #require(fixture.model.presentation?.id)
            let revision = fixture.model.presentationRevision
            let preparation = try #require(fixture.model.adjacentRangeTask?.task)
            await preparation.value

            #expect(fixture.model.presentation?.id == visible)
            #expect(fixture.model.presentationRevision == revision)
            #expect(fixture.model.rangeSnapshots.count == 3)
            #expect(fixture.model.rangeSnapshots[fixture.model.rangeIdentity]?.presentation.id == visible)
            #expect(fixture.model.rangeSnapshots.values.reduce(0) { $0 + $1.byteCost } <= 12 * 1_024 * 1_024)
            for offset in [-1, 1] {
                fixture.model.date = try #require(fixture.model.calendar.date(byAdding: .day, value: offset, to: center))
                let prepared = try #require(fixture.model.rangeSnapshots[fixture.model.rangeIdentity]?.presentation)
                await fixture.model.activateRange()
                #expect(fixture.model.presentation?.id == prepared.id)
                #expect(fixture.model.events.map(\.event.id) == ["adjacent-\(offset)"])
            }
            #expect(await fixture.service.rangeRequestCount == 0)
        }
    }

    @Test func incompleteAdjacentLocalDaysDoNotTriggerSpeculativeNetworkRequests() async throws {
        try await withFixture { fixture in
            let event = Self.event(id: "only-current")
            fixture.model.mode = .day
            fixture.model.date = try #require(event.startDate)
            try await fixture.cacheRange([event])
            fixture.model.isVisible = true
            await fixture.model.reloadOccurrences(refresh: false)
            await fixture.model.adjacentRangeTask?.task.value

            #expect(fixture.model.rangeSnapshots.count == 1)
            #expect(fixture.model.events.map(\.event) == [event])
            #expect(await fixture.service.rangeRequestCount == 0)
        }
    }

    @Test(arguments: [false, true])
    func purgedAdjacentPreparationCannotRestoreSnapshots(revoked: Bool) async throws {
        try await withFixture { fixture in
            _ = try await fixture.cacheDayNeighborhood()
            fixture.model.isVisible = true
            await fixture.model.reloadOccurrences(refresh: false)
            let preparation = try #require(fixture.model.adjacentRangeTask?.task)
            let visible = fixture.model.presentation?.id
            if revoked { fixture.model.accessExpired(fixture.accountID) }
            else { fixture.model.invalidateRangeSnapshots() }
            await preparation.value

            #expect(fixture.model.rangeSnapshots.isEmpty)
            #expect(fixture.model.adjacentRangeTask == nil)
            if revoked { #expect(fixture.model.events.isEmpty) }
            else { #expect(fixture.model.presentation?.id == visible) }
        }
    }

    @Test func searchCannotRestoreEventsWhenAccessChangesDuringRequest() async throws {
        try await withFixture { fixture in
            let event = Self.event(id: "search-private")
            fixture.model.date = try #require(event.startDate)
            fixture.model.searchText = "Planning"
            await fixture.service.put(event)
            await fixture.service.suspendNextRange()
            let search = Task { await fixture.model.searchEvents() }
            #expect(await fixture.waitForSuspendedRange())

            fixture.model.handleCalendarAccessFailure(CalendarEngineError.permissionDenied,
                accountID: fixture.accountID, calendarID: fixture.owner.calendarID)
            await fixture.service.resumeRange()
            await search.value

            #expect(fixture.model.searchResults.isEmpty)
            #expect(fixture.model.completedSearch == nil)
            #expect(await fixture.service.rangeRequestCount == 1)
        }
    }

    @Test func deniedSearchDoesNotFallBackToRetainedPrivateEvents() async throws {
        try await withFixture { fixture in
            let event = Self.event(id: "search-denied")
            fixture.model.date = try #require(event.startDate)
            fixture.model.events = [fixture.display(event)]
            fixture.model.searchText = "Planning"
            await fixture.service.setRangeFailure(.http(status: 403, reason: nil))

            await fixture.model.searchEvents()

            #expect(fixture.model.searchResults.isEmpty)
            #expect(fixture.model.events.isEmpty)
            #expect(fixture.model.completedSearch == nil)
        }
    }

    @Test func oneHundredUnchangedSearchActivationsReuseCompletedResults() async throws {
        try await withFixture { fixture in
            let event = Self.event(id: "search-warm")
            fixture.model.date = try #require(event.startDate)
            fixture.model.searchText = "Planning"
            await fixture.service.put(event)
            await fixture.model.searchEvents()
            let revision = fixture.model.searchRevision

            for _ in 0..<100 { await fixture.model.searchEvents() }

            #expect(fixture.model.searchResults.map(\.event) == [event])
            #expect(fixture.model.searchRevision == revision)
            #expect(await fixture.service.rangeRequestCount == 2)
        }
    }

    @Test func deniedRangeCannotRestoreAnotherRetainedRangeFromThatCalendar() async throws {
        try await withFixture { fixture in
            let event = Self.event(id: "private")
            let firstDay = try #require(event.startDate)
            fixture.model.mode = .day
            fixture.model.date = firstDay
            await fixture.service.put(event)
            await fixture.model.activateRange()
            fixture.model.date = try #require(fixture.model.calendar.date(byAdding: .day, value: 1, to: firstDay))
            await fixture.model.activateRange()
            #expect(fixture.model.rangeSnapshots.count == 2)

            await fixture.service.setRangeFailure(.http(status: 403, reason: nil))
            await fixture.model.reloadOccurrences()
            fixture.model.date = firstDay
            await fixture.model.activateRange()

            #expect(fixture.model.calendars.isEmpty)
            #expect(fixture.model.events.isEmpty)
            #expect(fixture.model.rangeSnapshots.values.allSatisfy { $0.presentation.events.isEmpty })
        }
    }

    @Test func oneHundredWarmActivationsReusePreparedRangeWithoutRequestsOrPublication() async throws {
        try await withFixture { fixture in
            let event = Self.event(id: "warm")
            fixture.model.mode = .day
            fixture.model.date = try #require(event.startDate)
            await fixture.service.put(event)
            await fixture.model.activateRange()
            let prepared = try #require(fixture.model.presentation)
            let revision = fixture.model.presentationRevision

            for _ in 0..<100 { await fixture.model.activateRange() }

            #expect(fixture.model.presentation?.id == prepared.id)
            #expect(fixture.model.presentationRevision == revision)
            #expect(fixture.model.events.map(\.event) == [event])
            #expect(await fixture.service.rangeRequestCount == 1)
            #expect(fixture.model.rangeSnapshots.count == 1)
        }
    }

    @Test func concurrentActivationSharesItsNetworkRequest() async throws {
        try await withFixture { fixture in
            let event = Self.event(id: "shared")
            fixture.model.mode = .day
            fixture.model.date = try #require(event.startDate)
            await fixture.service.put(event)
            await fixture.service.suspendNextRange()
            let first = Task { await fixture.model.activateRange() }
            #expect(await fixture.waitForSuspendedRange())
            let second = Task { await fixture.model.activateRange() }
            await Task.yield()
            await fixture.service.resumeRange()
            await first.value
            await second.value

            #expect(fixture.model.events.map(\.event) == [event])
            #expect(await fixture.service.rangeRequestCount == 1)
        }
    }

    @Test func rapidReactivationReplacesCanceledRefreshWhileItsRequestFinishes() async throws {
        try await withFixture { fixture in
            let event = Self.event(id: "reactivated")
            fixture.model.mode = .day
            fixture.model.date = try #require(event.startDate)
            await fixture.service.put(event)
            await fixture.service.suspendNextRange()
            let first = Task { await fixture.model.activateRange() }
            #expect(await fixture.waitForSuspendedRange())
            first.cancel()

            let second = Task { await fixture.model.activateRange() }
            for _ in 0..<200 {
                if await fixture.service.rangeRequestCount == 2 { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            #expect(await fixture.service.rangeRequestCount == 2)
            await fixture.service.resumeRange()
            await first.value
            await second.value

            #expect(fixture.model.events.map(\.event) == [event])
        }
    }

    @Test func rangeRetentionIsBoundedAndRevocationDropsPreparedContent() async throws {
        try await withFixture { fixture in
            let event = Self.event(id: "bounded")
            let firstDay = try #require(event.startDate)
            fixture.model.mode = .day
            await fixture.service.put(event)
            for offset in 0..<5 {
                fixture.model.date = try #require(fixture.model.calendar.date(byAdding: .day, value: offset, to: firstDay))
                await fixture.model.activateRange()
            }
            #expect(fixture.model.rangeSnapshots.count == 3)
            #expect(fixture.model.rangeSnapshotOrder.count == 3)
            #expect(fixture.model.rangeSnapshots.values.reduce(0) { $0 + $1.byteCost } <= 12 * 1_024 * 1_024)
            let visible = fixture.model.presentation?.id
            fixture.model.invalidateRangeSnapshots()
            #expect(fixture.model.rangeSnapshots.isEmpty)
            #expect(fixture.model.presentation?.id == visible)

            fixture.model.accessExpired(fixture.accountID)
            #expect(fixture.model.rangeSnapshots.isEmpty)
            #expect(fixture.model.presentation == nil || fixture.model.presentation?.events.isEmpty == true)
            #expect(fixture.model.events.isEmpty)
        }
    }

    @Test func initialRangeLoadsFromNetworkOnlyWhenItsCacheIsIncomplete() async throws {
        try await withFixture { fixture in
            let event = Self.event(id: "first-open")
            fixture.model.mode = .day
            fixture.model.date = try #require(event.startDate)
            await fixture.service.put(event)

            await fixture.model.reloadOccurrences(refresh: false, refreshIfIncomplete: true)
            #expect(fixture.model.events.map(\.event) == [event])
            #expect(await fixture.service.rangeRequestCount == 1)

            fixture.model.events = []
            await fixture.model.reloadOccurrences(refresh: false, refreshIfIncomplete: true)
            #expect(fixture.model.events.map(\.event) == [event])
            #expect(await fixture.service.rangeRequestCount == 1)
        }
    }

    @Test func rangeReloadPublishesCachedEventsBeforeOneFreshRequest() async throws {
        try await withFixture { fixture in
            let cached = Self.event(id: "cached")
            fixture.model.mode = .day
            fixture.model.date = try #require(cached.startDate)
            try await fixture.cacheRange([cached])
            var fresh = cached
            fresh.summary = "Updated planning"
            await fixture.service.put(fresh)
            await fixture.service.suspendNextRange()

            let reload = Task { await fixture.model.reloadOccurrences() }
            #expect(await fixture.waitForSuspendedRange())
            #expect(fixture.model.events.map(\.event) == [cached])
            await fixture.service.resumeRange()
            await reload.value

            #expect(fixture.model.events.map(\.event) == [fresh])
            #expect(await fixture.service.rangeRequestCount == 1)
        }
    }

    @Test func lateRangeResponseCannotReplaceTheNewlySelectedDate() async throws {
        try await withFixture { fixture in
            let first = Self.event(id: "first")
            var second = Self.event(id: "second")
            second.start = CalendarDateTime(dateTime: "2030-01-08T10:00:00+01:00", timeZone: "Europe/Vienna")
            second.end = CalendarDateTime(dateTime: "2030-01-08T11:00:00+01:00", timeZone: "Europe/Vienna")
            fixture.model.mode = .day
            fixture.model.date = try #require(first.startDate)
            await fixture.service.put(first)
            await fixture.service.put(second)
            await fixture.service.suspendNextRange()

            let oldReload = Task { await fixture.model.reloadOccurrences() }
            #expect(await fixture.waitForSuspendedRange())
            fixture.model.date = try #require(second.startDate)
            await fixture.model.reloadOccurrences()
            #expect(fixture.model.events.map(\.event.id) == [second.id])
            await fixture.service.resumeRange()
            await oldReload.value

            #expect(fixture.model.events.map(\.event.id) == [second.id])
            #expect(await fixture.service.rangeRequestCount == 2)
        }
    }

    @Test func cachedRangeUsesCurrentCalendarVisibilityAndPresentationWithoutNetwork() async throws {
        try await withFixture { fixture in
            let event = Self.event(id: "cached")
            fixture.model.mode = .day
            fixture.model.date = try #require(event.startDate)
            try await fixture.cacheRange([event])
            fixture.model.calendars[0].entry.backgroundColor = "#123456"
            fixture.model.calendars[0].entry.accessRole = "reader"
            await fixture.model.reloadOccurrences(refresh: false)
            #expect(fixture.model.events.first?.colorHex == "#123456")
            #expect(fixture.model.events.first?.canEdit == false)

            fixture.model.calendars[0].isVisible = false
            await fixture.model.reloadOccurrences(refresh: false)
            #expect(fixture.model.events.isEmpty)
            #expect(await fixture.service.rangeRequestCount == 0)
        }
    }

    @Test func calendarErrorsSeparateConsentFromCloudSetupAndHideProviderDetails() {
        let disabled = CalendarConnectionIssue(error: GmailError.http(status: 403, reason: "SERVICE_DISABLED"))
        let permission = CalendarConnectionIssue(error: GmailError.http(status: 403, reason: "ACCESS_TOKEN_SCOPE_INSUFFICIENT"))
        #expect(disabled == .apiDisabled)
        #expect(permission == .permissionDenied)
        #expect(!CalendarConnectionState(isEnabled: true, issue: disabled).needsAuthorization)
        #expect(CalendarConnectionState(isEnabled: true, issue: permission).needsAuthorization)
        let privateReason = "unexpected-private-provider-detail"
        let unknown = CalendarConnectionIssue(error: GmailError.http(status: 403, reason: privateReason))
        #expect(unknown == .unavailable)
        #expect(!unknown.message.contains(privateReason))
    }

    @Test func emptyCalendarCacheDoesNotLoseConnectionAndRemovalClearsIt() async throws {
        try await withFixture { fixture in
            fixture.model.calendars = []
            fixture.model.connectionStates[fixture.accountID] = CalendarConnectionState(isEnabled: true, issue: .network)
            #expect(!fixture.model.connectionState(for: fixture.accountID).needsAuthorization)

            fixture.model.accessExpired(fixture.accountID)
            #expect(fixture.model.connectionState(for: fixture.accountID).needsAuthorization)
            #expect(fixture.model.connectionState(for: fixture.accountID).issue == .signInRequired)

            await fixture.model.removeAccount(fixture.accountID)
            #expect(!fixture.model.connectionState(for: fixture.accountID).isEnabled)
            #expect(fixture.model.connectionState(for: fixture.accountID).issue == nil)
        }
    }

    @Test func duplicateOfflineSavesCloseTheEditorAndRetryOneDurableOperation() async throws {
        try await withFixture { fixture in
            await fixture.service.setOffline(true)
            let draft = CalendarEditorDraft(event: Self.event(), calendarKey: fixture.owner.id)
            fixture.model.editor = draft

            try await fixture.model.save(draft)

            #expect(fixture.model.editor == nil)
            try await fixture.model.save(draft)
            let queued = try await fixture.store.operations(accountID: fixture.accountID)
            #expect(queued.count == 1)
            #expect(queued.first?.status == .queued)
            #expect(queued.first?.attempts == 0)
            #expect(await fixture.service.insertCount == 0)

            await fixture.service.setOffline(false)
            try await fixture.engine.flush()
            try await fixture.engine.flush()
            let completed = try await fixture.store.operations(accountID: fixture.accountID)
            #expect(completed.count == 1)
            #expect(completed.first?.id == queued.first?.id)
            #expect(completed.first?.status == .completed)
            #expect(await fixture.service.insertCount == 1)
        }
    }

    @Test func savingAnAssistantProposalReplacesItsProposedOperation() async throws {
        try await withFixture { fixture in
            let id = fixture.model.prepare(event: Self.event(), accountID: fixture.accountID, calendarID: "work")
            await fixture.model.proposalTasks[id]?.value
            let draft = try #require(fixture.model.proposedEditors[id])
            let proposalID = try #require(draft.operationID)
            fixture.model.editor = draft
            await fixture.service.setOffline(true)

            try await fixture.model.save(draft)

            let operations = try await fixture.store.operations(accountID: fixture.accountID)
            #expect(operations.first(where: { $0.id == proposalID })?.status == .cancelled)
            #expect(operations.filter { $0.status == .queued }.count == 1)
            #expect(!operations.contains { $0.status == .proposed })
            #expect(fixture.model.proposedEditors[id] == nil)
            #expect(fixture.model.editor == nil)

            await fixture.service.setOffline(false)
            try await fixture.engine.flush()
            try await fixture.engine.flush()
            #expect(await fixture.service.insertCount == 1)
        }
    }

    @Test(arguments: [false, true])
    func revokingAssistantAccessDiscardsPendingAndPersistedProposals(persistFirst: Bool) async throws {
        try await withFixture { fixture in
            let id = fixture.model.prepare(event: Self.event(), accountID: fixture.accountID, calendarID: "work")
            if persistFirst {
                await fixture.model.proposalTasks[id]?.value
                let draft = try #require(fixture.model.proposedEditors[id])
                fixture.model.editor = draft
                #expect(try await fixture.store.operations(accountID: fixture.accountID).first?.status == .proposed)
            }

            fixture.model.setAssistantAccess(id: fixture.owner.id, access: .off)
            for task in Array(fixture.model.proposalTasks.values) { await task.value }

            #expect(fixture.model.proposedEditors.isEmpty)
            #expect(fixture.model.editor == nil)
            let operations = try await fixture.store.operations(accountID: fixture.accountID)
            #expect(operations.allSatisfy { $0.status == .cancelled })
            if persistFirst { #expect(operations.count == 1) }
            #expect(await fixture.service.insertCount == 0)
            #expect(await fixture.service.patchETags.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func revokingAssistantAccessCancelsAStoredProposalBeforeOrAfterActivityLoads(activityLoaded: Bool) async throws {
        try await withFixture { fixture in
            let operation = try await fixture.engine.propose(.create(Self.event()), calendarID: "work")
            var draft = CalendarEditorDraft(event: Self.event(), calendarKey: fixture.owner.id)
            draft.operationID = operation.id
            fixture.model.editor = draft
            if activityLoaded {
                await fixture.model.reloadOperations()
                #expect(fixture.model.proposedEditors.isEmpty)
            } else {
                fixture.model.proposedEditors[draft.id] = draft
                #expect(fixture.model.operations.isEmpty)
            }

            fixture.model.setAssistantAccess(id: fixture.owner.id, access: .off)
            for task in Array(fixture.model.proposalTasks.values) { await task.value }

            #expect(fixture.model.editor == nil)
            #expect(try await fixture.store.operations(accountID: fixture.accountID).first?.status == .cancelled)
            #expect(await fixture.service.insertCount == 0)
        }
    }

    @Test(arguments: [false, true])
    func undoUsesTheSavedVersionAndRejectsLaterExternalEdits(externalEdit: Bool) async throws {
        try await withFixture { fixture in
            let original = Self.event(id: "event")
            await fixture.service.put(original)
            var edited = original
            edited.summary = "Changed in Tern"
            let source = fixture.display(original)
            let draft = CalendarEditorDraft(event: edited, calendarKey: fixture.owner.id, source: source)
            fixture.model.editor = draft
            try await fixture.model.save(draft)
            let operation = try #require(fixture.model.operations.first)
            let saved = try #require(operation.resultEvent)
            #expect(saved.etag == "remote-1")

            if externalEdit {
                var newer = saved
                newer.summary = "Changed elsewhere"; newer.etag = "external-version"
                await fixture.service.put(newer)
            }
            await fixture.model.undo()

            let remote = try await fixture.service.event(calendarID: "work", eventID: "event")
            let operations = try await fixture.store.operations(accountID: fixture.accountID)
            let inverse = try #require(operations.first { $0.id != operation.id })
            guard case .update(_, _, let reviewedETag) = inverse.mutation else {
                Issue.record("Undo must enqueue an event update."); return
            }
            #expect(reviewedETag == saved.etag)
            if externalEdit {
                #expect(inverse.status == .conflicted)
                #expect(remote.summary == "Changed elsewhere")
                #expect(await fixture.service.patchETags == ["v1"])
            } else {
                #expect(inverse.status == .completed)
                #expect(remote.summary == original.summary)
                #expect(await fixture.service.patchETags == ["v1", "remote-1"])
            }
        }
    }

    @Test func overlappingUndoRequestsEnqueueOnlyOneInverse() async throws {
        try await withFixture { fixture in
            let original = Self.event(id: "event")
            await fixture.service.put(original)
            var edited = original
            edited.summary = "Changed in Tern"
            try await fixture.model.save(CalendarEditorDraft(event: edited, calendarKey: fixture.owner.id,
                source: fixture.display(original)))
            let undo = Task { await fixture.model.undo() }
            let confirmation = Task { await fixture.model.confirmUndo() }
            await undo.value
            await confirmation.value

            let operations = try await fixture.store.operations(accountID: fixture.accountID)
            #expect(operations.count == 2)
            #expect(operations.allSatisfy { $0.status == .completed })
            #expect(await fixture.service.patchETags == ["v1", "remote-1"])
            #expect(try await fixture.service.event(calendarID: "work", eventID: "event").summary == original.summary)
            #expect(fixture.model.undoActions.isEmpty)
            #expect(!fixture.model.isUndoing)
        }
    }

    @Test func movingAnAllDayEventAcrossAutumnDSTPreservesItsTwoCivilDays() async throws {
        try await withFixture { fixture in
            var original = Self.event(id: "trip")
            original.start = CalendarDateTime(date: "2026-11-02")
            original.end = CalendarDateTime(date: "2026-11-04")
            await fixture.service.put(original)
            let destination = try #require(fixture.model.calendar.date(from: DateComponents(year: 2026, month: 10, day: 24)))

            try await fixture.model.move(fixture.display(original), to: destination)

            let saved = try await fixture.service.event(calendarID: "work", eventID: "trip")
            #expect(saved.start?.date == "2026-10-24")
            #expect(saved.end?.date == "2026-10-26")
            let display = fixture.display(saved)
            #expect(display.end.timeIntervalSince(display.start) == 49 * 3600)
        }
    }

    @Test func aSeriesEditKeepsTheVersionReviewedInTheEditor() async throws {
        try await withFixture { fixture in
            var master = Self.event(id: "series")
            master.recurrence = ["RRULE:FREQ=WEEKLY"]
            var occurrence = master
            occurrence.id = "occurrence"
            occurrence.etag = "occurrence-version"
            occurrence.recurringEventId = master.id
            occurrence.originalStartTime = occurrence.start
            var draft = CalendarEditorDraft(event: occurrence, calendarKey: fixture.owner.id,
                source: fixture.display(occurrence), editScope: .series)
            draft.seriesMaster = master
            draft.event.summary = "Reviewed change"
            fixture.model.editor = draft
            var newer = master
            newer.etag = "external-version"; newer.summary = "Concurrent change"
            await fixture.service.put(newer)

            try await fixture.model.save(draft)

            let operation = try #require(try await fixture.store.operations(accountID: fixture.accountID).first)
            guard case .update(let eventID, _, let etag) = operation.mutation else {
                Issue.record("Editing all events must update the series master."); return
            }
            #expect(eventID == master.id)
            #expect(etag == master.etag)
            #expect(operation.status == .conflicted)
            #expect(await fixture.service.patchETags.isEmpty)
            #expect(try await fixture.service.event(calendarID: "work", eventID: master.id).summary == "Concurrent change")
        }
    }

    private static func event(id: String = "") -> GoogleCalendarEvent {
        var event = GoogleCalendarEvent(id: id, summary: "Planning",
            start: CalendarDateTime(dateTime: "2030-01-07T10:00:00+01:00", timeZone: "Europe/Vienna"),
            end: CalendarDateTime(dateTime: "2030-01-07T11:00:00+01:00", timeZone: "Europe/Vienna"))
        event.etag = "v1"
        return event
    }

    private func withFixture(_ body: @MainActor (Fixture) async throws -> Void) async throws {
        let fixture = try await Fixture()
        do { try await body(fixture) }
        catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @MainActor private final class Fixture {
        let accountID = "calendar-model-test-" + UUID().uuidString
        let defaultsName = "CalendarModelTests." + UUID().uuidString
        let defaults: UserDefaults
        let model: CalendarModel
        let store: CalendarStore
        let service = ModelCalendarService()
        let engine: CalendarSyncEngine
        let owner: CalendarDisplayCalendar

        init() async throws {
            defaults = try #require(UserDefaults(suiteName: defaultsName))
            store = try CalendarStore.inMemory()
            engine = CalendarSyncEngine(accountID: accountID, service: service, store: store)
            owner = CalendarDisplayCalendar(entry: ModelCalendarService.entry, accountID: accountID,
                accountName: "Synthetic account", aiAccess: .details)
            model = CalendarModel(app: nil, defaults: defaults)
            model.store = store
            model.engines = [accountID: engine]
            model.calendars = [owner]
            model.workingHours = CalendarWorkingHours(timeZoneIdentifier: "Europe/Vienna")
            let preference = CalendarPreferences(accountID: accountID, calendarID: "work", assistantAccess: .details,
                notificationsEnabled: false)
            model.preferences = [owner.id: preference]
            try await store.replaceCalendars([ModelCalendarService.entry], accountID: accountID)
            try await store.savePreferences(preference)
        }

        func display(_ event: GoogleCalendarEvent) -> CalendarDisplayEvent {
            CalendarDisplayEvent(event: event, accountID: accountID, calendarID: "work", fallbackTimeZoneID: "Europe/Vienna")
        }

        func cacheRange(_ events: [GoogleCalendarEvent]) async throws {
            let interval = model.displayInterval
            let state = try await store.syncState(accountID: accountID, calendarID: "work")
            try await store.saveOccurrences(events, accountID: accountID, calendarID: "work",
                start: interval.start, end: interval.end, expected: state)
        }

        func cacheDayNeighborhood() async throws -> Date {
            let center = try #require(CalendarModelTests.event().startDate)
            model.mode = .day
            for offset in -1...1 {
                let start = try #require(model.calendar.date(byAdding: .day, value: offset, to: center))
                model.date = start
                var event = CalendarModelTests.event(id: "adjacent-\(offset)")
                event.start = CalendarDateTime(date: start)
                event.end = CalendarDateTime(date: start.addingTimeInterval(3_600))
                try await cacheRange([event])
            }
            model.date = center
            return center
        }

        func waitForSuspendedRange() async -> Bool {
            for _ in 0..<200 {
                if await service.hasSuspendedRange { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return false
        }

        func close() async {
            await service.resumeRange()
            await model.stop()
            defaults.removePersistentDomain(forName: defaultsName)
        }
    }

    private actor ModelCalendarService: CalendarService {
        static let entry = GoogleCalendarEntry(id: "work", summary: "Work", timeZone: "Europe/Vienna", accessRole: "owner")
        private var remote: [String: GoogleCalendarEvent] = [:]
        private var offline = false
        private var rangeFailure: GmailError?
        private var shouldSuspendRange = false
        private var rangeContinuation: CheckedContinuation<Void, Never>?
        private(set) var rangeRequestCount = 0
        private(set) var insertCount = 0
        private(set) var patchETags: [String?] = []

        func setOffline(_ value: Bool) { offline = value }
        func setRangeFailure(_ value: GmailError?) { rangeFailure = value }
        func put(_ event: GoogleCalendarEvent) { remote[event.id] = event }
        var hasSuspendedRange: Bool { rangeContinuation != nil }
        func suspendNextRange() { shouldSuspendRange = true }
        func resumeRange() {
            rangeContinuation?.resume()
            rangeContinuation = nil
        }

        func calendarList(pageToken: String?, syncToken: String?) async throws -> CalendarListPage {
            if offline { throw GmailError.transport(.notConnectedToInternet) }
            return CalendarListPage(items: [Self.entry])
        }

        func events(calendarID: String, query: CalendarEventQuery) async throws -> CalendarEventPage {
            if offline { throw GmailError.transport(.notConnectedToInternet) }
            if query.singleEvents, let rangeFailure { throw rangeFailure }
            var events = Array(remote.values)
            if query.singleEvents {
                rangeRequestCount += 1
                if let start = query.timeMin { events.removeAll { ($0.endDate ?? .distantPast) <= start } }
                if let end = query.timeMax { events.removeAll { ($0.startDate ?? .distantFuture) >= end } }
                if shouldSuspendRange {
                    shouldSuspendRange = false
                    await withCheckedContinuation { rangeContinuation = $0 }
                }
            }
            return CalendarEventPage(items: events, nextSyncToken: "snapshot")
        }

        func event(calendarID: String, eventID: String) async throws -> GoogleCalendarEvent {
            guard let event = remote[eventID] else { throw GmailError.notFound }
            return event
        }

        func insertEvent(calendarID: String, event: GoogleCalendarEvent, sendUpdates: String) async throws -> GoogleCalendarEvent {
            insertCount += 1
            var saved = event; saved.etag = "inserted-\(insertCount)"
            remote[saved.id] = saved
            return saved
        }

        func patchEvent(calendarID: String, eventID: String, fields: [String: CalendarJSON], etag: String?, sendUpdates: String) async throws -> GoogleCalendarEvent {
            guard var event = remote[eventID] else { throw GmailError.notFound }
            guard event.etag == etag else { throw GmailError.http(status: 412, reason: nil) }
            patchETags.append(etag)
            for (key, value) in fields { event.rawValue[key] = value == .null ? nil : value }
            event.etag = "remote-\(patchETags.count)"
            remote[eventID] = event
            return event
        }
    }
}
