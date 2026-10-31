import Foundation
import GmailAPI
import MailStore
import Network
import Observation
import SyncEngine

@MainActor
@Observable
final class CalendarModel {
    var date = Date()
    var mode: CalendarDisplayMode = .week
    var searchText = ""
    var searchResults: [CalendarDisplayEvent] = []
    var searchStatus = ""
    @ObservationIgnored var searchRevision = 0
    var calendars: [CalendarDisplayCalendar] = []
    var events: [CalendarDisplayEvent] = []
    var accounts: [CalendarAccountOption] = []
    var connectionStates: [String: CalendarConnectionState] = [:]
    var isLoading = false
    var statusText = "Connect Google Calendar to see your events."
    var errorMessage: String?
    var editor: CalendarEditorDraft?
    var selectedEventID: String?
    var undoConfirmation: [String]?
    var isVisible = false {
        didSet { if oldValue != isVisible { schedulePolling() } }
    }
    var accessRevision = 0
    var operations: [CalendarOperation] = []
    var workingHours: CalendarWorkingHours {
        didSet { if let data = try? JSONEncoder().encode(workingHours) { defaults.set(data, forKey: "calendarWorkingHours") } }
    }
    var firstWeekday: Int {
        didSet { defaults.set(firstWeekday, forKey: "calendarFirstWeekday") }
    }
    var calendar: Calendar {
        var value = Calendar.autoupdatingCurrent
        value.timeZone = TimeZone(identifier: workingHours.timeZoneIdentifier) ?? .autoupdatingCurrent
        value.firstWeekday = (1...7).contains(firstWeekday) ? firstWeekday : value.firstWeekday
        return value
    }
    var canUndo: Bool {
        !isUndoing && (operations.contains { $0.status == .queued && $0.attempts == 0 }
            || undoActions.last.map { action in operations.contains { $0.id == action.operationID && $0.status == .completed } } == true
        )
    }
    var isUndoing = false

    func connectionState(for accountID: String) -> CalendarConnectionState {
        connectionStates[accountID] ?? CalendarConnectionState(isEnabled: calendars.contains { $0.accountID == accountID })
    }

    @ObservationIgnored weak var app: AppModel?
    var store: CalendarStore?
    @ObservationIgnored var engines: [String: CalendarSyncEngine] = [:]
    @ObservationIgnored var services: [String: any CalendarService] = [:]
    @ObservationIgnored var preferences: [String: CalendarPreferences] = [:]
    @ObservationIgnored var proposedEditors: [UUID: CalendarEditorDraft] = [:]
    @ObservationIgnored var undoActions: [CalendarUndoAction] = []
    @ObservationIgnored var savedDraftOperations: [UUID: String] = [:]
    @ObservationIgnored var savingDrafts = Set<UUID>()
    @ObservationIgnored var savingEvents = Set<String>()
    @ObservationIgnored var interactionsInFlight = Set<String>()
    @ObservationIgnored var emailResponsesInFlight = Set<String>()
    @ObservationIgnored var proposalTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var stoppingEngines: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var lifecycleRevision = 0
    @ObservationIgnored var notificationRevision = 0
    @ObservationIgnored var editRevision = 0
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let notifications = CalendarNotifications()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var rangeRevision = 0
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var didLoadCalendars = false

    init(app: AppModel?, defaults: UserDefaults? = nil) {
        self.app = app
        let isAudit = ProcessInfo.processInfo.arguments.contains("--ui-audit")
            || ProcessInfo.processInfo.arguments.contains("--ui-audit-calendar")
        let defaults = defaults ?? (isAudit ? UserDefaults(suiteName: "tern.calendar.audit") ?? .standard : .standard)
        self.defaults = defaults
        workingHours = defaults.data(forKey: "calendarWorkingHours")
            .flatMap { try? JSONDecoder().decode(CalendarWorkingHours.self, from: $0) } ?? CalendarWorkingHours()
        firstWeekday = defaults.object(forKey: "calendarFirstWeekday") as? Int ?? Calendar.current.firstWeekday
    }

    func start() async {
        guard !isStarted else { return }
        isStarted = true
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-audit-calendar") {
            await seedCalendarAudit(); return
        }
#endif
        do {
            if ProcessInfo.processInfo.arguments.contains("--ui-audit") {
                store = try CalendarStore.inMemory()
            } else if let app {
                let url = try app.calendarStoreURL()
                store = try await Task.detached { try CalendarStore.open(at: url) }.value
            }
            await refresh()
            CalendarNotificationRouter.shared.bind(self)
            schedulePolling()
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                guard path.status == .satisfied else { return }
                Task { @MainActor [weak self] in await self?.refresh() }
            }
            monitor.start(queue: .main)
            self.monitor = monitor
        } catch { errorMessage = error.localizedDescription }
    }

    private func schedulePolling() {
        guard isStarted, !ProcessInfo.processInfo.arguments.contains("--ui-audit") else { return }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let seconds = self?.isVisible == true ? 60 : 300
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                await self?.refresh()
            }
        }
    }

    func stop() async {
        lifecycleRevision += 1
        pollTask?.cancel(); pollTask = nil
        monitor?.cancel(); monitor = nil
        rangeRevision += 1
        for engine in engines.values { await engine.stop() }
        for task in proposalTasks.values { await task.value }
        for task in stoppingEngines.values { await task.value }
        engines = [:]; services = [:]; isStarted = false
    }

    func accessExpired(_ accountID: String) {
        lifecycleRevision += 1; rangeRevision += 1; editRevision += 1; searchRevision += 1
        if connectionState(for: accountID).isEnabled || engines[accountID] != nil {
            connectionStates[accountID] = CalendarConnectionState(isEnabled: true, issue: .signInRequired)
        }
        invalidateAssistantAccess()
        services[accountID] = nil
        let engine = engines.removeValue(forKey: accountID)
        let prior = stoppingEngines[accountID]
        let tasks = Array(proposalTasks.values)
        stoppingEngines[accountID] = Task {
            await prior?.value
            await engine?.stop()
            for task in tasks { await task.value }
            await notifications.remove(accountID: accountID)
        }
        if editor?.source?.accountID == accountID || calendars.contains(where: { $0.accountID == accountID && $0.id == editor?.calendarKey }) { editor = nil }
        calendars.removeAll { $0.accountID == accountID }
        events.removeAll { $0.accountID == accountID }
        searchResults.removeAll { $0.accountID == accountID }
    }

    func removeAccount(_ accountID: String) async {
        accessExpired(accountID)
        connectionStates[accountID] = nil
        await stoppingEngines[accountID]?.value
        stoppingEngines[accountID] = nil
        do { try await store?.deleteAccountData(accountID: accountID) }
        catch { errorMessage = "Could not remove all local calendar data. Try again." }
        await notifications.remove(accountID: accountID)
        operations.removeAll { $0.accountID == accountID }
        preferences = preferences.filter { $0.value.accountID != accountID }
        undoActions.removeAll { $0.accountID == accountID }
    }

    func refresh() async {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-audit-calendar") {
            await refreshCalendarAudit(); return
        }
#endif
        guard let app, let store else { return }
        guard !isLoading else { refreshAgain = true; return }
        isLoading = true
        let revision = lifecycleRevision
        defer {
            isLoading = false
            if refreshAgain { refreshAgain = false; Task { await self.refresh() } }
        }
        do {
            let records = try await app.calendarAccounts()
            guard revision == lifecycleRevision else { return }
            let recordIDs = Set(records.map(\.id))
            let removedIDs = try await store.accountIDs().subtracting(recordIDs)
            if !removedIDs.isEmpty {
                for removed in removedIDs { await removeAccount(removed) }
                refreshAgain = true; return
            }
            accounts = records.map {
                CalendarAccountOption(id: $0.id, title: $0.displayName ?? $0.email,
                    canManage: $0.enabledFeatures.contains(AccountFeature.calendarManagement.rawValue),
                    canShare: $0.enabledFeatures.contains(AccountFeature.calendarSharing.rawValue))
            }
            let enabled = records.filter { $0.enabledFeatures.contains(AccountFeature.calendar.rawValue) }
            let enabledIDs = Set(enabled.map(\.id))
            var connections = Dictionary(uniqueKeysWithValues: records.map {
                ($0.id, CalendarConnectionState(isEnabled: enabledIDs.contains($0.id)))
            })
            let disabled = Set(engines.keys).subtracting(enabledIDs)
            if !disabled.isEmpty {
                for removed in disabled { await removeAccount(removed) }
                refreshAgain = true; return
            }
            var display: [CalendarDisplayCalendar] = []
            var issues: [String] = []
            for record in enabled {
                guard revision == lifecycleRevision else { return }
                guard let service = app.calendarService(for: record.id) else {
                    if engines[record.id] != nil { accessExpired(record.id) }
                    connections[record.id]?.issue = .signInRequired
                    issues.append("Reconnect an account to refresh its calendars."); continue
                }
                await stoppingEngines[record.id]?.value
                guard revision == lifecycleRevision else { return }
                services[record.id] = service
                let engine: CalendarSyncEngine
                if let existing = engines[record.id] { engine = existing }
                else {
                    engine = CalendarSyncEngine(accountID: record.id, service: service, store: store)
                    engines[record.id] = engine
                }
                let entries: [GoogleCalendarEntry]
                do { entries = try await engine.syncCalendars() }
                catch {
                    let issue = CalendarConnectionIssue(error: error)
                    entries = try await store.calendars(accountID: record.id)
                    connections[record.id]?.issue = issue
                    issues.append(issue.message)
                }
                guard revision == lifecycleRevision else { return }
                let storedPreferences = try await app.calendarPreferences(accountID: record.id)
                for entry in entries where entry.deleted != true {
                    let preference = storedPreferences.first { $0.calendarID == entry.id }
                        ?? CalendarPreferences(accountID: record.id, calendarID: entry.id, visible: entry.hidden != true, notificationsEnabled: false)
                    let key = CalendarDisplayCalendar.key(accountID: record.id, calendarID: entry.id)
                    preferences[key] = preference
                    display.append(CalendarDisplayCalendar(entry: entry, accountID: record.id,
                        accountName: record.displayName ?? record.email, isVisible: preference.visible,
                        aiAccess: CalendarAIAccess(rawValue: preference.assistantAccess.rawValue) ?? .off,
                        useForScheduling: preference.includeInScheduling,
                        canManage: record.enabledFeatures.contains(AccountFeature.calendarManagement.rawValue),
                        canShare: record.enabledFeatures.contains(AccountFeature.calendarSharing.rawValue),
                        notificationsEnabled: preference.notificationsEnabled))
                }
            }
            let oldAccess = calendars.map { "\($0.id):\($0.aiAccess.rawValue):\($0.entry.accessRole ?? ""):\($0.useForScheduling)" }.sorted()
            let newAccess = display.map { "\($0.id):\($0.aiAccess.rawValue):\($0.entry.accessRole ?? ""):\($0.useForScheduling)" }.sorted()
            guard revision == lifecycleRevision else { return }
            for previous in calendars where previous.entry.canReadDetails && !display.contains(where: { $0.id == previous.id && $0.entry.canReadDetails }) {
                await notifications.remove(accountID: previous.accountID, calendarID: previous.calendarID)
            }
            guard revision == lifecycleRevision else { return }
            calendars = display
            connectionStates = connections
            if didLoadCalendars, oldAccess != newAccess { invalidateAssistantAccess() }
            if !didLoadCalendars {
                // The first snapshot restores durable proposals. Only calendars
                // whose saved consent is now off lose their pending proposals.
                for owner in display where owner.aiAccess == .off || !owner.canWrite {
                    try await store.cancelProposals(accountID: owner.accountID, calendarID: owner.calendarID)
                }
                guard revision == lifecycleRevision else { return }
                accessRevision += 1
                app.assistant.refreshAccess()
            }
            didLoadCalendars = true
            await reloadOccurrences()
            for owner in calendars where owner.entry.canReadDetails {
                guard revision == lifecycleRevision else { return }
                do { try await engines[owner.accountID]?.syncEvents(calendarID: owner.calendarID) }
                catch { issues.append("Calendar history is waiting to sync.") }
            }
            for engine in engines.values {
                guard revision == lifecycleRevision else { return }
                do { try await engine.flush() } catch { issues.append("Pending changes are waiting for a connection.") }
            }
            guard revision == lifecycleRevision else { return }
            await reloadOperations()
            await reloadOccurrences()
            if !issues.isEmpty { statusText = Set(issues).sorted().joined(separator: " ") }
            await refreshNotifications()
        } catch { errorMessage = error.localizedDescription }
    }

    func reloadOccurrences() async {
        rangeRevision += 1
        let revision = rangeRevision
        let lifecycle = lifecycleRevision
        let interval = displayInterval
        var found: [CalendarDisplayEvent] = []
        var stale = false
        for owner in calendars where owner.isVisible {
            guard let engine = engines[owner.accountID] else { stale = true; continue }
            do {
                let result = try await engine.occurrences(calendarID: owner.calendarID, start: interval.start, end: interval.end)
                guard revision == rangeRevision else { return }
                stale = stale || result.isStale || !result.isComplete
                found += result.events.filter { !$0.isCancelled }.map {
                    CalendarDisplayEvent(event: $0, accountID: owner.accountID, calendarID: owner.calendarID,
                        colorHex: owner.colorHex, canEdit: CalendarEventPermissions.canEdit($0, in: owner),
                        fallbackTimeZoneID: calendar.timeZone.identifier)
                }
            } catch { stale = true }
        }
        await reloadOperations()
        guard revision == rangeRevision, lifecycle == lifecycleRevision else { return }
        events = CalendarPendingEvents.project(found, operations: operations, calendars: calendars, interval: interval,
                                               calendar: calendar)
        statusText = calendars.isEmpty ? (connectionStates.values.contains(where: \.isEnabled)
            ? "No calendars are available. Refresh or check the account connection."
            : "Connect Google Calendar to see your events.")
            : operations.contains(where: { $0.status == .failed || $0.status == .conflicted })
                ? "Some calendar changes need review in Calendar activity."
                : operations.contains(where: { $0.status == .queued || $0.status == .running })
                ? "Calendar changes are waiting to sync."
                : stale ? "Showing cached events. Some calendars could not be checked." : "Calendars are up to date."
    }

    var displayInterval: DateInterval {
        if mode == .month {
            let days = CalendarLayout.monthDays(containing: date, calendar: calendar)
            if let first = days.first, let last = days.last, let end = calendar.date(byAdding: .day, value: 1, to: last) {
                return DateInterval(start: first, end: end)
            }
        }
        let base = calendar.dateInterval(of: mode.component, for: date) ?? DateInterval(start: date, duration: 86400)
        return base
    }

    func reloadOperations() async {
        guard let store else { return }
        let revision = lifecycleRevision
        var result: [CalendarOperation] = []
        for id in engines.keys { result += (try? await store.operations(accountID: id)) ?? [] }
        guard revision == lifecycleRevision else { return }
        operations = result.sorted { $0.createdAt < $1.createdAt }
        await reconcileEmailSourceLinks()
    }

    func setVisible(id: String, visible: Bool) {
        updatePreference(id) { $0.visible = visible }
        if let index = calendars.firstIndex(where: { $0.id == id }) { calendars[index].isVisible = visible }
        Task { await reloadOccurrences() }
    }
    func setAssistantAccess(id: String, access: CalendarAIAccess) {
        updatePreference(id) { $0.assistantAccess = CalendarAssistantAccess(rawValue: access.rawValue) ?? .off }
        if let index = calendars.firstIndex(where: { $0.id == id }) { calendars[index].aiAccess = access }
        invalidateAssistantAccess()
    }
    func setScheduling(id: String, included: Bool) {
        updatePreference(id) { $0.includeInScheduling = included }
        if let index = calendars.firstIndex(where: { $0.id == id }) { calendars[index].useForScheduling = included }
        invalidateAssistantAccess()
    }
    func setNotifications(id: String, enabled: Bool) {
        notificationRevision += 1
        updatePreference(id) { $0.notificationsEnabled = enabled }
        guard let index = calendars.firstIndex(where: { $0.id == id }) else { return }
        calendars[index].notificationsEnabled = enabled
        let owner = calendars[index]
        Task {
            if enabled { await requestNotifications() }
            else { await notifications.remove(accountID: owner.accountID, calendarID: owner.calendarID) }
        }
    }
    private func updatePreference(_ id: String, _ edit: (inout CalendarPreferences) -> Void) {
        guard var preference = preferences[id] else { return }
        edit(&preference); preferences[id] = preference
        let taskID = UUID()
        let revision = lifecycleRevision
        proposalTasks[taskID] = Task {
            defer { proposalTasks[taskID] = nil }
            do {
                guard revision == lifecycleRevision else { return }
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-audit-calendar") {
                    try await store?.savePreferences(preference); return
                }
#endif
                try await app?.saveCalendarPreferences(preference)
            } catch { if revision == lifecycleRevision { errorMessage = "Could not save calendar preferences." } }
        }
    }
    func invalidateAssistantAccess() {
        accessRevision += 1
        clearAssistantProposals()
        app?.assistant.refreshAccess()
    }
    func clearAssistantProposals() {
        let ids = Set(proposedEditors.keys)
        let proposals = operations.filter { $0.status == .proposed }
        let prepared = proposedEditors.values.compactMap { draft -> (String, String)? in
            guard let operationID = draft.operationID, let owner = calendars.first(where: { $0.id == draft.calendarKey }) else { return nil }
            return (owner.accountID, operationID)
        }
        let operationIDs = Set(proposals.map(\.id) + proposedEditors.values.compactMap(\.operationID))
        if let current = editor, ids.contains(current.id) || current.operationID.map(operationIDs.contains) == true { editor = nil }
        proposedEditors = [:]
        let activeTasks = Array(proposalTasks.values)
        let taskID = UUID()
        proposalTasks[taskID] = Task {
            for task in activeTasks { await task.value }
            for proposal in proposals { _ = try? await store?.cancelOperation(accountID: proposal.accountID, id: proposal.id) }
            for (accountID, operationID) in prepared { _ = try? await store?.cancelOperation(accountID: accountID, id: operationID) }
            await reloadOperations()
            proposalTasks[taskID] = nil
        }
    }
}

struct CalendarConnectionState: Equatable {
    var isEnabled: Bool
    var issue: CalendarConnectionIssue?

    var needsAuthorization: Bool { !isEnabled || issue == .signInRequired || issue == .permissionDenied }
}

/// Only known error categories reach the UI; provider response text stays private.
enum CalendarConnectionIssue: Equatable {
    case signInRequired, permissionDenied, apiDisabled, network, rateLimited, unavailable

    init(error: any Error) {
        guard let error = error as? GmailError else { self = .unavailable; return }
        switch error {
        case .unauthorized: self = .signInRequired
        case .http(status: 403, reason: "SERVICE_DISABLED"), .http(status: 403, reason: "accessNotConfigured"):
            self = .apiDisabled
        case .http where error.isMissingScope: self = .permissionDenied
        case .transport: self = .network
        case .rateLimited: self = .rateLimited
        default: self = .unavailable
        }
    }

    var message: String {
        switch self {
        case .signInRequired: "Sign in again to refresh this account's calendars."
        case .permissionDenied: "Google didn't grant calendar access. Reconnect and allow the requested calendar permissions."
        case .apiDisabled: "Google Calendar is unavailable for this app. Its Google Cloud project needs the Calendar API enabled."
        case .network: "Can't reach Google Calendar. Check your connection and retry."
        case .rateLimited: "Google Calendar is temporarily limiting requests. Try again shortly."
        case .unavailable: "Couldn't load calendars from Google. Try again."
        }
    }
}

struct CalendarUndoAction {
    var operationID: String
    var accountID: String
    var calendarID: String
    var before: GoogleCalendarEvent? = nil
}

enum CalendarModelError: Error, LocalizedError {
    case unavailable, readOnly, invalidEvent, changed, unsupported(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: "This calendar is unavailable. Connect it again in Calendar."
        case .readOnly: "This calendar does not allow that change."
        case .invalidEvent: "Enter a title and an end time after the start time."
        case .changed: "This event changed since you opened it. Open the latest version before saving."
        case .unsupported(let message): message
        }
    }
}
