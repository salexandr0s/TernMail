import Foundation
import GmailAPI
import MailStore
import MessageContent
import SyncEngine

struct TodayDashboardAccount: Hashable, Sendable {
    let id: String
    let runtime: String
    let title: String
}

/// A removed and re-added account is a different source even when its ID is unchanged.
struct TodayDashboardContext: Hashable, Sendable {
    let profileID: String?
    let runtime: String
    let accounts: [TodayDashboardAccount]
    /// Stored, because the dashboard asks for it once per event and per task.
    let accountIDs: Set<String>

    init(profileID: String?, runtime: String, accounts: [TodayDashboardAccount]) {
        self.profileID = profileID; self.runtime = runtime; self.accounts = accounts
        accountIDs = Set(accounts.map(\.id))
    }
}

struct TodayDashboardCalendarRequest: Hashable, Sendable {
    /// What loaded events are shown for. A new `revision` asks for a reload,
    /// and the events already loaded for the same display stay until it lands.
    struct Display: Hashable, Sendable {
        let context: TodayDashboardContext
        let interval: DateInterval
        let timeZone: String
        let firstWeekday: Int
    }

    let display: Display
    let revision: String

    init(context: TodayDashboardContext, interval: DateInterval, timeZone: String, firstWeekday: Int, revision: String) {
        display = Display(context: context, interval: interval, timeZone: timeZone, firstWeekday: firstWeekday)
        self.revision = revision
    }

    var context: TodayDashboardContext { display.context }
    var interval: DateInterval { display.interval }
    var timeZone: String { display.timeZone }
    var firstWeekday: Int { display.firstWeekday }
}

/// The calendar panel's lists, prepared when events load or the selected day
/// changes, so a body pass does not filter and sort the month again.
struct TodayAgenda: Equatable {
    var isLoaded = false
    var hasCalendars = false
    var monthEvents: [CalendarDisplayEvent] = []
    var dayEvents: [CalendarDisplayEvent] = []
    var upcomingEvents: [CalendarDisplayEvent] = []
}

struct TodayDashboardTask: Identifiable {
    let task: GoogleTask
    let location: GoogleTaskLocation
    let accountTitle: String
    let listTitle: String
    let capturedContext: TodayDashboardContext
    var id: String { "\(location.accountID.utf8.count):\(location.accountID)\(location.listID.utf8.count):\(location.listID)\(task.id)" }
}

struct TodayUnreadMessage: Identifiable, Equatable, Sendable {
    let accountID: String
    let threadID: String
    let messageID: String
    let sender: String
    let subject: String
    let snippet: String
    let date: Date
    let accountTitle: String
    var id: String { "\(accountID.utf8.count):\(accountID)\(messageID)" }
    var link: MailLink { MailLink(accountID: accountID, threadID: threadID, messageID: messageID) }
}

struct TodayUnreadSnapshot: Sendable {
    let messages: [TodayUnreadMessage]
    let totalCount: Int?
    let scannedConversationLimitReached: Bool
    let messageLimitReached: Bool
    static let conversationLimit = 200
    static let messageLimit = 30

    static func make(page: MailListPage, context: TodayDashboardContext, totalCount: Int?, limit: Int = messageLimit) -> Self {
        let titles = Dictionary(context.accounts.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<MailLink>()
        let matching = page.entries.filter {
            titles[$0.message.accountID] != nil && $0.labels.contains(SystemLabel.inbox)
                && $0.labels.contains(SystemLabel.unread)
                && $0.labels.isDisjoint(with: [SystemLabel.trash, SystemLabel.spam, SystemLabel.draft])
        }.sorted {
            if $0.message.date != $1.message.date { return $0.message.date > $1.message.date }
            return ($0.message.accountID, $0.message.id) < ($1.message.accountID, $1.message.id)
        }.compactMap { entry -> TodayUnreadMessage? in
            let message = entry.message
            let link = MailLink(accountID: message.accountID, threadID: message.threadID, messageID: message.id)
            guard seen.insert(link).inserted else { return nil }
            return TodayUnreadMessage(accountID: message.accountID, threadID: message.threadID, messageID: message.id,
                sender: message.sender, subject: message.subject, snippet: message.snippet, date: message.date,
                accountTitle: titles[message.accountID] ?? message.accountID)
        }
        return Self(messages: Array(matching.prefix(max(0, limit))), totalCount: totalCount,
            scannedConversationLimitReached: page.threads.count >= conversationLimit,
            messageLimitReached: matching.count > limit)
    }

    var coverage: String {
        var text = "\(messages.count) cached unread inbox \(messages.count == 1 ? "message" : "messages")"
        if let totalCount { text += " · \(totalCount) unread in the last reported inbox count" }
        if messageLimitReached { text += ". Showing the newest \(Self.messageLimit) available messages" }
        if scannedConversationLimitReached { text += ". Checked the newest \(Self.conversationLimit) cached unread conversations" }
        return text + ". Mail that has not synced is not included."
    }
}

struct TodayCalendarSnapshot: Sendable {
    let events: [CalendarDisplayEvent]
    let calendarCount: Int
    let unavailableCount: Int
    let omittedCount: Int
    let isStale: Bool
    /// False when a read of saved events found none for one of the calendars.
    /// Today keeps what it shows rather than publish that partial read.
    var isComplete = true

    func withStaleness(_ isStale: Bool) -> Self {
        Self(events: events, calendarCount: calendarCount, unavailableCount: unavailableCount,
             omittedCount: omittedCount, isStale: isStale, isComplete: isComplete)
    }

    var coverage: String {
        guard calendarCount + unavailableCount + omittedCount > 0 else {
            return "No visible calendars are available in this profile. Connect Calendar or choose visible calendars in Calendar."
        }
        var text = "\(calendarCount) visible \(calendarCount == 1 ? "calendar" : "calendars") in this profile"
        if unavailableCount > 0 { text += " · \(unavailableCount) unavailable" }
        if omittedCount > 0 { text += " · \(omittedCount) additional calendars not loaded" }
        if isStale { text += ". Some events are cached and may be out of date" }
        return text + "."
    }
}

@MainActor
enum TodayDashboardSources {
    static func context(app: AppModel) -> TodayDashboardContext {
        guard let mailbox = app.mailbox else {
            return TodayDashboardContext(profileID: app.accountPreferences?.activeProfileID, runtime: "unavailable", accounts: [])
        }
        let visible = app.accountPreferences?.visibleAccountIDs ?? Set(mailbox.presentedAccounts.map { $0.account.id })
        let accounts = mailbox.accounts.filter { visible.contains($0.account.id) }.map {
            TodayDashboardAccount(id: $0.account.id,
                runtime: "\(ObjectIdentifier($0)):\($0.account.grantedScopes.sorted()):\($0.account.enabledFeatures.sorted())",
                title: mailbox.accountTitle($0.account))
        }.sorted { $0.id < $1.id }
        return TodayDashboardContext(profileID: app.accountPreferences?.activeProfileID,
            runtime: String(describing: ObjectIdentifier(mailbox)), accounts: accounts)
    }

    static func unread(app: AppModel, context: TodayDashboardContext) async throws -> TodayUnreadSnapshot {
        guard context == self.context(app: app), let mailbox = app.mailbox else { throw CancellationError() }
        let ids = context.accountIDs.sorted()
        let snapshot = try await mailbox.cache.read { tx in
            let page = try MailListPageBuilder.mailbox(accountIDs: ids, labelID: SystemLabel.unread,
                limit: TodayUnreadSnapshot.conversationLimit).page(in: tx)
            var counts: [Int] = []
            for id in ids {
                if let count = try tx.unreadCounts(accountID: id)[SystemLabel.inbox]?.messagesUnread { counts.append(count) }
            }
            return TodayUnreadSnapshot.make(page: page, context: context,
                totalCount: counts.count == ids.count && !ids.isEmpty ? counts.reduce(0, +) : nil)
        }
        guard context == self.context(app: app), app.mailbox === mailbox else { throw CancellationError() }
        return snapshot
    }

    /// With `refresh` false this reads saved events only and never reaches the network.
    static func calendar(app: AppModel, request: TodayDashboardCalendarRequest, refresh: Bool) async throws -> TodayCalendarSnapshot {
        let model = app.calendar
        await model.start()
        guard request.context == context(app: app), !Task.isCancelled else { throw CancellationError() }
        let owners = model.calendars.filter { $0.isVisible && request.context.accountIDs.contains($0.accountID) }
        let selected = Array(owners.prefix(24))
        let interval = request.interval
        var unavailable = 0
        var accounts: [String: CalendarAccountLoad] = [:]
        for (index, owner) in selected.enumerated() {
            guard let engine = model.engines[owner.accountID] else { unavailable += 1; continue }
            accounts[owner.accountID, default: CalendarAccountLoad(engine: engine)].calendars.append((index, owner.calendarID))
        }
        // Accounts load side by side. Each account still reads its calendars in order.
        let loaded = await withTaskGroup(of: [(Int, Result<CalendarOccurrenceResult, any Error>)].self) { group in
            for account in accounts.values {
                group.addTask {
                    var results: [(Int, Result<CalendarOccurrenceResult, any Error>)] = []
                    for (index, calendarID) in account.calendars {
                        guard !Task.isCancelled else { break }
                        do {
                            results.append((index, .success(try await account.engine.occurrences(calendarID: calendarID,
                                start: interval.start, end: interval.end, refresh: refresh))))
                        } catch { results.append((index, .failure(error))) }
                    }
                    return results
                }
            }
            var values: [Int: Result<CalendarOccurrenceResult, any Error>] = [:]
            for await results in group { for (index, result) in results { values[index] = result } }
            return values
        }
        guard request.context == context(app: app), !Task.isCancelled else { throw CancellationError() }
        var events: [CalendarDisplayEvent] = []
        var stale = false
        var complete = true
        for (index, owner) in selected.enumerated() {
            guard let engine = accounts[owner.accountID]?.engine else { continue }
            guard let result = loaded[index], model.engines[owner.accountID] === engine else { throw CancellationError() }
            switch result {
            case .success(let value):
                stale = stale || value.isStale || !value.isComplete
                complete = complete && value.isComplete
                events += value.events.map { event in
                    CalendarDisplayEvent(event: event, accountID: owner.accountID, calendarID: owner.calendarID,
                        colorHex: owner.colorHex, canEdit: owner.canWrite,
                        fallbackTimeZoneID: request.timeZone)
                }
            case .failure(let error):
                if error is CancellationError { throw CancellationError() }
                // Only the network read reports lost access. A failed read of
                // saved events leaves that to the refresh that follows it.
                if refresh { model.handleCalendarAccessFailure(error, accountID: owner.accountID, calendarID: owner.calendarID) }
                unavailable += 1
                complete = false
            }
        }
        events = CalendarPendingEvents.project(events, operations: model.operations, calendars: selected,
            interval: request.interval, calendar: model.calendar)
        return TodayCalendarSnapshot(events: events, calendarCount: selected.count - unavailable,
            unavailableCount: unavailable, omittedCount: owners.count - selected.count, isStale: stale,
            isComplete: refresh || complete)
    }

    private struct CalendarAccountLoad: Sendable {
        let engine: CalendarSyncEngine
        var calendars: [(index: Int, id: String)] = []
    }
}
