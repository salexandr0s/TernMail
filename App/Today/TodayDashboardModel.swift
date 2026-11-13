import Foundation
import GmailAPI
import MailStore
import MessageContent
import Observation
import SyncEngine

/// Today reads the same services as their dedicated destinations, with its own
/// selected day and captured account scope. Merely displaying mail never opens it.
@MainActor @Observable
final class TodayDashboardModel {
    let tasks: GoogleTasksModel
    var selectedDate = Date() { didSet { prepareAgenda() } }
    private(set) var calendarLoading = false
    private(set) var calendarError: String?
    private(set) var unreadLoading = false
    private(set) var unreadError: String?
    private var unreadSnapshot: TodayUnreadSnapshot?
    private var unreadContext: TodayDashboardContext?
    private var taskContext: TodayDashboardContext?
    private var taskRefreshes = 0
    private var calendarSnapshot: TodayCalendarSnapshot?
    private var completedCalendarDisplay: TodayDashboardCalendarRequest.Display?
    private var preparedAgenda = TodayAgenda()
    @ObservationIgnored private let contextProvider: @MainActor () -> TodayDashboardContext
    @ObservationIgnored private let calendarProvider: @MainActor () -> Calendar
    @ObservationIgnored private let calendarRevision: @MainActor () -> String
    @ObservationIgnored private let loadUnread: @MainActor (TodayDashboardContext) async throws -> TodayUnreadSnapshot
    /// The flag is `refresh`: false reads saved events only, true asks the network.
    @ObservationIgnored private let loadCalendar: @MainActor (TodayDashboardCalendarRequest, Bool) async throws -> TodayCalendarSnapshot
    @ObservationIgnored private let openMail: @MainActor (MailLink) -> Void
    @ObservationIgnored private let openCalendarEvent: @MainActor (CalendarDisplayEvent, TodayDashboardContext) async -> Void
    @ObservationIgnored private var active = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var unreadGeneration = 0
    @ObservationIgnored private var calendarLoad: (id: UUID, request: TodayDashboardCalendarRequest, task: Task<Void, Never>)?
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var displayInterval: (key: DisplayIntervalKey, interval: DateInterval)?

    convenience init(app: AppModel) {
        self.init(tasks: app.tasks, context: { [weak app] in
            app.map { TodayDashboardSources.context(app: $0) } ?? TodayDashboardContext(profileID: nil, runtime: "unavailable", accounts: [])
        }, calendar: { [weak app] in app?.calendar.calendar ?? .autoupdatingCurrent }, calendarRevision: { [weak app] in
            guard let model = app?.calendar else { return "unavailable" }
            // Reading these observed collections also invalidates Today after
            // visibility changes and confirmed/queued event edits.
            return "\(model.lifecycleRevision):\(model.accessRevision):\(model.rangeRevision):\(model.calendars.count):\(model.operations.count)"
        }, loadUnread: { [weak app] context in
            guard let app else { throw CancellationError() }
            return try await TodayDashboardSources.unread(app: app, context: context)
        }, loadCalendar: { [weak app] request, refresh in
            guard let app else { throw CancellationError() }
            return try await TodayDashboardSources.calendar(app: app, request: request, refresh: refresh)
        }, openMail: { [weak app] in app?.mailURLs.openConversation($0) }, openEvent: { [weak app] event, context in
            guard let app else { return }
            await app.calendar.openEvent(accountID: event.accountID, calendarID: event.calendarID, eventID: event.event.id,
                isAuthorized: { [weak app] in app.map { TodayDashboardSources.context(app: $0) == context } ?? false })
        })
    }

    init(tasks: GoogleTasksModel, context: @escaping @MainActor () -> TodayDashboardContext,
         calendar: @escaping @MainActor () -> Calendar = { .autoupdatingCurrent },
         calendarRevision: @escaping @MainActor () -> String = { "0" },
         loadUnread: @escaping @MainActor (TodayDashboardContext) async throws -> TodayUnreadSnapshot,
         loadCalendar: @escaping @MainActor (TodayDashboardCalendarRequest, Bool) async throws -> TodayCalendarSnapshot,
         openMail: @escaping @MainActor (MailLink) -> Void = { _ in },
         openEvent: @escaping @MainActor (CalendarDisplayEvent, TodayDashboardContext) async -> Void = { _, _ in }) {
        self.tasks = tasks; contextProvider = context; calendarProvider = calendar; self.calendarRevision = calendarRevision
        self.loadUnread = loadUnread; self.loadCalendar = loadCalendar; self.openMail = openMail; openCalendarEvent = openEvent
    }

    var context: TodayDashboardContext { contextProvider() }
    var calendar: Calendar { calendarProvider() }
    var calendarRequest: TodayDashboardCalendarRequest {
        let calendar = calendar
        return TodayDashboardCalendarRequest(context: context, interval: displayInterval(in: calendar),
            timeZone: calendar.timeZone.identifier, firstWeekday: calendar.firstWeekday, revision: calendarRevision())
    }
    /// Loaded events stay through a new revision. Only another display, such as
    /// another profile, account set, month or time zone, hides them.
    private var showsCompletedCalendar: Bool { completedCalendarDisplay == calendarRequest.display }
    /// The prepared lists, compared with the live display once per read.
    var agenda: TodayAgenda { showsCompletedCalendar ? preparedAgenda : TodayAgenda() }
    var monthEvents: [CalendarDisplayEvent] { agenda.monthEvents }
    var dayEvents: [CalendarDisplayEvent] { agenda.dayEvents }
    var upcomingEvents: [CalendarDisplayEvent] { agenda.upcomingEvents }
    var calendarIsStale: Bool { showsCompletedCalendar && (calendarSnapshot?.isStale == true || calendarError != nil) }
    var hasLoadedCalendar: Bool { agenda.isLoaded }
    var hasAvailableCalendars: Bool { agenda.hasCalendars }
    var calendarCoverageWarning: String? {
        guard hasLoadedCalendar, let snapshot = calendarSnapshot else { return nil }
        var warnings: [String] = []
        if snapshot.unavailableCount > 0 {
            warnings.append("\(snapshot.unavailableCount) \(snapshot.unavailableCount == 1 ? "calendar is" : "calendars are") unavailable.")
        }
        if snapshot.omittedCount > 0 {
            warnings.append("\(snapshot.omittedCount) additional \(snapshot.omittedCount == 1 ? "calendar was" : "calendars were") not loaded.")
        }
        if snapshot.isStale { warnings.append("Some events may be out of date.") }
        return warnings.isEmpty ? nil : warnings.joined(separator: " ")
    }
    var calendarCoverage: String {
        guard showsCompletedCalendar else { return "Calendar data has not loaded for this date and profile." }
        let coverage = calendarSnapshot?.coverage ?? "Calendar data is unavailable."
        return calendarError == nil ? coverage : coverage + " These events may be out of date."
    }
    var hasLoadedUnread: Bool { unreadContext == context && unreadSnapshot != nil }
    var hasLoadedTasks: Bool { taskContext == context }
    /// True while a refresh is on its way to loading this profile's tasks,
    /// including the account reads that come before the tasks model starts loading.
    var tasksLoading: Bool { taskRefreshes > 0 }
    var unreadMessages: [TodayUnreadMessage] { unreadContext == context ? unreadSnapshot?.messages ?? [] : [] }
    var unreadTotalCount: Int? { unreadContext == context ? unreadSnapshot?.totalCount : nil }
    var unreadCoverage: String {
        let context = context
        guard !context.accountIDs.isEmpty else { return "No mail accounts are available in this profile." }
        guard unreadContext == context else { return "Cached unread inbox mail has not loaded for this profile." }
        return unreadSnapshot?.coverage ?? "Cached unread inbox mail is unavailable."
    }

    var taskAccounts: [AccountRecord] {
        let ids = context.accountIDs
        return tasks.accounts.filter { ids.contains($0.id) }
    }
    var selectedTaskAccountID: String? { tasks.selectedAccountID.flatMap { context.accountIDs.contains($0) ? $0 : nil } }
    var selectedTaskListID: String? { selectedTaskAccountID == nil ? nil : tasks.selectedListID }
    var taskLists: [GoogleTaskList] { selectedTaskAccountID == nil ? [] : tasks.lists }
    var taskRows: [TodayDashboardTask] {
        let context = context
        guard taskContext == context, let location = tasks.selectedLocation, context.accountIDs.contains(location.accountID) else { return [] }
        let title = context.accounts.first { $0.id == location.accountID }?.title ?? location.accountID
        return tasks.openTasks.map { TodayDashboardTask(task: $0, location: location, accountTitle: title,
            listTitle: tasks.selectedList?.title ?? "Tasks", capturedContext: context) }
    }

    func refresh() async {
        guard !Task.isCancelled else { return }
        active = true
        let captured = context, revision = generation
        taskRefreshes += 1
        defer { taskRefreshes -= 1 }
        async let unread: Void = refreshUnread(expectedGeneration: revision)
        async let events: Void = refreshCalendar(expectedGeneration: revision)
        await tasks.refreshAccounts()
        if captured == context, revision == generation, active, !Task.isCancelled {
            if selectedTaskAccountID == nil, let first = taskAccounts.first { tasks.selectAccount(first.id) }
            if selectedTaskAccountID != nil { await tasks.refresh() }
            if captured == context, revision == generation, active, !Task.isCancelled { taskContext = captured }
        }
        _ = await (unread, events)
    }

    func refreshCalendar(expectedGeneration: Int? = nil) async {
        guard !Task.isCancelled, expectedGeneration == nil || expectedGeneration == generation else { return }
        active = true
        let request = calendarRequest
        if let current = calendarLoad, current.request == request, !current.task.isCancelled {
            await current.task.value; return
        }
        calendarLoad?.task.cancel()
        let id = UUID(), revision = generation
        // An error about events that are still shown stays until this load settles it.
        calendarLoading = true
        if completedCalendarDisplay != request.display { calendarError = nil }
        let task = Task { [weak self] in
            guard let self else { return }
            defer { if calendarLoad?.id == id { calendarLoading = false; calendarLoad = nil } }
            do {
                // Saved events first, so the agenda never waits for the network.
                let saved = try? await loadCalendar(request, false)
                guard active, revision == generation, request == calendarRequest, !Task.isCancelled else { return }
                if let saved, saved.isComplete {
                    // Staleness is the network's call. Until it answers, keep what this display already said.
                    let wasStale = completedCalendarDisplay == request.display && calendarSnapshot?.isStale == true
                    show(saved.withStaleness(wasStale), for: request.display)
                }
                let snapshot = try await loadCalendar(request, true)
                guard active, revision == generation, request == calendarRequest, !Task.isCancelled else { return }
                show(snapshot, for: request.display); calendarError = nil
            } catch is CancellationError {} catch {
                guard active, revision == generation, request == calendarRequest, !Task.isCancelled else { return }
                calendarError = "Couldn't update the calendar. Try refreshing."
            }
        }
        calendarLoad = (id, request, task)
        await task.value
    }

    func refreshUnread(expectedGeneration: Int? = nil) async {
        guard !Task.isCancelled, expectedGeneration == nil || expectedGeneration == generation else { return }
        active = true
        unreadGeneration += 1
        let read = unreadGeneration, revision = generation, captured = context
        unreadLoading = true
        if unreadContext != captured { unreadError = nil }
        defer { if read == unreadGeneration { unreadLoading = false } }
        do {
            let snapshot = try await loadUnread(captured)
            guard active, read == unreadGeneration, revision == generation, captured == context, !Task.isCancelled else { return }
            unreadSnapshot = snapshot; unreadContext = captured; unreadError = nil
        } catch is CancellationError {} catch {
            guard active, read == unreadGeneration, revision == generation, captured == context, !Task.isCancelled else { return }
            unreadError = "Couldn't read cached inbox mail. Try refreshing."
        }
    }

    func process(_ snapshot: MailSyncNotification) async {
        guard active, context.accountIDs.contains(snapshot.accountID) else { return }
        await refreshUnread()
    }

    /// Stops loading while Today is hidden or Tern is inactive. The last content
    /// stays, so the page comes back as it was. Every getter still compares it
    /// with the live context, so another profile or runtime never sees it.
    func stop() {
        active = false; generation += 1; unreadGeneration += 1
        calendarLoad?.task.cancel(); calendarLoad = nil; openTask?.cancel(); openTask = nil
        calendarLoading = false; unreadLoading = false
    }

    /// Stops and drops everything loaded, for sign-out and a cache reset.
    func reset() {
        stop()
        show(nil, for: nil); unreadSnapshot = nil; unreadContext = nil; taskContext = nil
        calendarError = nil; unreadError = nil
    }

    func selectTaskAccount(_ id: String) { if taskAccounts.contains(where: { $0.id == id }) { tasks.selectAccount(id) } }
    func selectTaskList(_ id: String) { if selectedTaskAccountID != nil { tasks.selectList(id) } }
    func makeTaskEditor(_ row: TodayDashboardTask?) -> GoogleTaskEditorContext? {
        if let row {
            guard valid(row) else { return nil }
            return GoogleTaskEditorContext(task: row.task, location: row.location, listTitle: row.listTitle)
        }
        guard taskContext == context, tasks.canAdd, let location = tasks.selectedLocation, context.accountIDs.contains(location.accountID) else { return nil }
        return GoogleTaskEditorContext(task: nil, location: location, listTitle: tasks.selectedList?.title ?? "Tasks")
    }
    func completeTask(_ row: TodayDashboardTask) async {
        guard valid(row) else { return }
        _ = await tasks.update(row.task, update: GoogleTaskUpdate(isCompleted: !row.task.isCompleted), location: row.location)
    }
    func deleteTask(_ row: TodayDashboardTask) async {
        guard valid(row) else { return }
        _ = await tasks.delete(row.task, location: row.location)
    }
    func isTaskBusy(_ row: TodayDashboardTask) -> Bool { tasks.busyTaskIDs.contains(tasks.busyKey(row.task.id, location: row.location)) }
    func parentTitle(for row: TodayDashboardTask) -> String? { valid(row) ? tasks.parentTitle(for: row.task) : nil }
    func openUnread(_ row: TodayUnreadMessage) {
        guard unreadContext == context, unreadMessages.contains(row) else { return }
        openMail(row.link)
    }
    func openEvent(_ event: CalendarDisplayEvent) {
        guard monthEvents.contains(event) else { return }
        let captured = context
        openTask?.cancel()
        openTask = Task { [weak self] in
            guard let self, captured == context, !Task.isCancelled else { return }
            await openCalendarEvent(event, captured)
        }
    }

    private func valid(_ row: TodayDashboardTask) -> Bool {
        let context = context
        return taskContext == context && row.capturedContext == context && context.accountIDs.contains(row.location.accountID)
            && tasks.selectedLocation == row.location && tasks.openTasks.contains(row.task)
    }

    private func show(_ snapshot: TodayCalendarSnapshot?, for display: TodayDashboardCalendarRequest.Display?) {
        calendarSnapshot = snapshot; completedCalendarDisplay = display
        prepareAgenda()
    }

    /// Runs when events load and when the selected day changes. The lists are
    /// for the display they were loaded for; `agenda` hides them from any other.
    private func prepareAgenda() {
        var agenda = TodayAgenda()
        if let snapshot = calendarSnapshot, let display = completedCalendarDisplay {
            let calendar = calendar, ids = display.context.accountIDs
            let start = calendar.startOfDay(for: selectedDate)
            let month = snapshot.events.filter { ids.contains($0.accountID) }
            func events(inNextDays count: Int) -> [CalendarDisplayEvent] {
                guard let end = calendar.date(byAdding: .day, value: count, to: start) else { return [] }
                return month.filter { $0.start < end && $0.end > start }.sorted {
                    if $0.start != $1.start { return $0.start < $1.start }
                    return $0.id < $1.id
                }
            }
            agenda = TodayAgenda(isLoaded: true, hasCalendars: snapshot.calendarCount > 0, monthEvents: month,
                                 dayEvents: events(inNextDays: 1), upcomingEvents: events(inNextDays: 7))
        }
        // The same lists are not published again, so a reload that brings the same events redraws nothing.
        if agenda != preparedAgenda { preparedAgenda = agenda }
    }

    /// The month grid plus the seven days after the selected day. Remembered,
    /// because every calendar getter compares the loaded display with this one.
    private func displayInterval(in calendar: Calendar) -> DateInterval {
        let key = DisplayIntervalKey(date: selectedDate, calendar: calendar, timeZone: calendar.timeZone.identifier,
                                     firstWeekday: calendar.firstWeekday)
        if let displayInterval, displayInterval.key == key { return displayInterval.interval }
        let days = CalendarLayout.monthDays(containing: selectedDate, calendar: calendar)
        let start = days.first ?? calendar.startOfDay(for: selectedDate)
        let last = days.last ?? start
        let gridEnd = calendar.date(byAdding: .day, value: 1, to: last) ?? last.addingTimeInterval(86400)
        let upcomingEnd = calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: selectedDate)) ?? gridEnd
        let interval = DateInterval(start: start, end: max(gridEnd, upcomingEnd))
        displayInterval = (key, interval)
        return interval
    }

    private struct DisplayIntervalKey: Equatable {
        let date: Date
        let calendar: Calendar
        let timeZone: String
        let firstWeekday: Int
    }
}
