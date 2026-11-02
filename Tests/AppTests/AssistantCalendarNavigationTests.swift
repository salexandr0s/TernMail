import Foundation
import GmailAPI
import MailStore
import SyncEngine
import Testing
@testable import Tern

@Suite @MainActor struct AssistantCalendarNavigationTests {
    @Test(arguments: [false, true])
    func revokedCalendarCitationCannotPresentAfterItsEventLoads(regrant: Bool) async throws {
        let store = try CalendarStore.inMemory()
        let service = SuspendedCitationCalendarService()
        let engine = CalendarSyncEngine(accountID: "a", service: service, store: store)
        let entry = GoogleCalendarEntry(id: "c", summary: "Calendar", accessRole: "owner")
        try await store.replaceCalendars([entry], accountID: "a")
        let model = CalendarModel(app: nil)
        model.store = store
        model.engines = ["a": engine]
        let owner = CalendarDisplayCalendar(entry: entry, accountID: "a", accountName: "Account", aiAccess: .details)
        model.calendars = [owner]
        model.preferences = [owner.id: .init(accountID: "a", calendarID: "c", assistantAccess: .details)]
        let originalDate = model.date
        let opening = Task { await model.openAssistantEvent(accountID: "a", calendarID: "c", eventID: "e") }
        await service.waitUntilLoading()
        model.setAssistantAccess(id: owner.id, access: .off)
        if regrant { model.setAssistantAccess(id: owner.id, access: .details) }
        await service.release()
        await opening.value
        #expect(model.editor == nil)
        #expect(model.date == originalDate)
        #expect(model.errorMessage == nil)
        if regrant {
            await model.openAssistantEvent(accountID: "a", calendarID: "c", eventID: "e")
            #expect(model.editor?.event.id == "e")
        }
        await model.stop()
    }
}

private actor SuspendedCitationCalendarService: CalendarService {
    private var shouldSuspend = true
    private var continuation: CheckedContinuation<Void, Never>?
    private var loadingWaiter: CheckedContinuation<Void, Never>?

    func event(calendarID: String, eventID: String) async throws -> GoogleCalendarEvent {
        if shouldSuspend {
            shouldSuspend = false
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                loadingWaiter?.resume(); loadingWaiter = nil
            }
        }
        return GoogleCalendarEvent(id: eventID, summary: "Private event",
            start: .init(dateTime: "2030-11-02T10:00:00Z"), end: .init(dateTime: "2030-11-02T11:00:00Z"))
    }

    func waitUntilLoading() async {
        if continuation != nil { return }
        await withCheckedContinuation { loadingWaiter = $0 }
    }

    func release() { continuation?.resume(); continuation = nil }
}
