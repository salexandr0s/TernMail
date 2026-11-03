import GmailAPI
import SwiftUI

struct TodayDashboardSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            Label(title, systemImage: symbol).font(.headline)
            content
        }
        .padding(Tokens.Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ternSurface()
        .accessibilityElement(children: .contain)
    }
}

struct TodayTasksPanel: View {
    @Bindable var dashboard: TodayDashboardModel
    let query: String
    @State private var editor: GoogleTaskEditorContext?
    @State private var deletion: TodayDashboardTask?

    private var rows: [TodayDashboardTask] {
        dashboard.taskRows.filter { query.isEmpty || [$0.task.title, $0.task.notes ?? "", $0.accountTitle, $0.listTitle]
            .contains { $0.localizedCaseInsensitiveContains(query) } }
    }

    var body: some View {
        TodayDashboardSection(title: "To do", symbol: "checklist") {
            if !dashboard.taskAccounts.isEmpty { destinations }
            if dashboard.selectedTaskAccountID != nil || dashboard.tasks.selectedAccountID == nil {
                if let error = dashboard.tasks.issue?.message ?? dashboard.tasks.errorMessage {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(Tokens.Status.warning)
                }
                if dashboard.selectedTaskAccountID != nil, let updated = dashboard.tasks.lastSyncedAt {
                    Text("Tasks last updated \(updated.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !dashboard.tasks.hasLoadedAccounts || (dashboard.tasks.isLoading && rows.isEmpty) {
                ProgressView("Loading tasks…").controlSize(.small)
            } else if dashboard.taskAccounts.isEmpty {
                Text("No task accounts are available in this profile.").font(.callout).foregroundStyle(.secondary)
            } else if dashboard.selectedTaskAccountID == nil {
                Text("Choose an account to load its tasks.").font(.callout).foregroundStyle(.secondary)
            } else if dashboard.tasks.needsConnection {
                Text("Connect Google Tasks for the selected account.").font(.callout).foregroundStyle(.secondary)
                Button("Connect Tasks", action: connect)
                    .disabled(dashboard.tasks.isConnecting || dashboard.selectedTaskAccountID == nil)
            } else if rows.isEmpty {
                Text(query.isEmpty ? "No open tasks in this list." : "No matching tasks.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: Tokens.Space.s1) {
                    ForEach(rows) { row in
                        GoogleTaskRow(task: row.task, parentTitle: dashboard.parentTitle(for: row),
                            isBusy: dashboard.isTaskBusy(row),
                            onComplete: { Task { await dashboard.completeTask(row) } },
                            onEdit: { editor = dashboard.makeTaskEditor(row) },
                            onDelete: { deletion = row })
                    }
                }
            }
            Button("New Task", systemImage: "plus") { editor = dashboard.makeTaskEditor(nil) }
                .disabled(dashboard.makeTaskEditor(nil) == nil)
                .accessibilityIdentifier("today-new-task")
        }
        .accessibilityIdentifier("today-tasks")
        .sheet(item: $editor) { GoogleTaskEditor(model: dashboard.tasks, context: $0) }
        .onChange(of: dashboard.context) { _, _ in editor = nil; deletion = nil }
        .confirmationDialog("Delete this task?", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }), titleVisibility: .visible) {
            if let deletion {
                Button("Delete Task", role: .destructive) {
                    Task { await dashboard.deleteTask(deletion) }
                    self.deletion = nil
                }
            }
            Button("Cancel", role: .cancel) { deletion = nil }
        } message: {
            Text("This removes the task and its subtasks from Google Tasks on all your devices.")
        }
    }

    private var destinations: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            Picker("Account", selection: Binding(get: { dashboard.selectedTaskAccountID }, set: { if let id = $0 { dashboard.selectTaskAccount(id) } })) {
                if dashboard.selectedTaskAccountID == nil { Text("Choose account").tag(Optional<String>.none) }
                ForEach(dashboard.taskAccounts) { account in
                    Text(account.displayName ?? account.email).tag(Optional(account.id))
                }
            }
            .accessibilityIdentifier("today-task-account")
            if !dashboard.taskLists.isEmpty {
                Picker("List", selection: Binding(get: { dashboard.selectedTaskListID }, set: { if let id = $0 { dashboard.selectTaskList(id) } })) {
                    ForEach(dashboard.taskLists) { list in Text(list.title).tag(Optional(list.id)) }
                }
                .accessibilityIdentifier("today-task-list")
            }
        }
        .controlSize(.small)
    }

    private func connect() {
        let context = dashboard.context
        guard let accountID = dashboard.selectedTaskAccountID else { return }
        Task {
            guard dashboard.context == context, dashboard.selectedTaskAccountID == accountID else { return }
            await dashboard.tasks.connect()
            guard dashboard.context == context else { return }
            await dashboard.refresh()
        }
    }
}

struct TodayCalendarPanel: View {
    @Bindable var dashboard: TodayDashboardModel
    let query: String

    private var events: [CalendarDisplayEvent] {
        dashboard.upcomingEvents.filter { query.isEmpty || [$0.title, $0.event.location ?? ""]
            .contains { $0.localizedCaseInsensitiveContains(query) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s4) {
            TodayDashboardSection(title: "Calendar", symbol: "calendar") {
                CalendarMiniMonth(date: $dashboard.selectedDate, calendar: dashboard.calendar, events: dashboard.monthEvents)
                if dashboard.calendarLoading { ProgressView("Updating events…").controlSize(.small) }
                if let error = dashboard.calendarError {
                    Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(Tokens.Status.warning)
                }
                Text(dashboard.calendarCoverage).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier("today-calendar")
            TodayDashboardSection(title: "Upcoming events", symbol: "clock") {
                Text("Next seven days from \(dashboard.selectedDate.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
                if events.isEmpty {
                    Text(query.isEmpty ? "No events in the available calendar data." : "No matching events.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    LazyVStack(spacing: Tokens.Space.s2) {
                        ForEach(events) { event in
                            Button { dashboard.openEvent(event) } label: {
                                CalendarSidebarEventRow(event: event, calendar: dashboard.calendar, showsDate: true)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Open event: \(event.title)")
                            .accessibilityIdentifier("today-event-\(event.id)")
                        }
                    }
                }
            }
            .accessibilityIdentifier("today-agenda")
        }
    }
}

struct TodayUnreadPanel: View {
    let dashboard: TodayDashboardModel
    let query: String

    private var messages: [TodayUnreadMessage] {
        dashboard.unreadMessages.filter { query.isEmpty || [$0.sender, $0.subject, $0.snippet, $0.accountTitle]
            .contains { $0.localizedCaseInsensitiveContains(query) } }
    }

    var body: some View {
        TodayDashboardSection(title: "Unread emails", symbol: "envelope.badge") {
            Text(dashboard.unreadCoverage).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = dashboard.unreadError {
                Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(Tokens.Status.warning)
            }
            if dashboard.unreadLoading && messages.isEmpty {
                ProgressView("Loading unread emails…").controlSize(.small)
            } else if messages.isEmpty {
                Text(query.isEmpty ? "No unread emails in the available mail data." : "No matching unread emails.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: Tokens.Space.s2) {
                    ForEach(messages) { message in
                        Button { dashboard.openUnread(message) } label: {
                            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                                HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s2) {
                                    Text(message.subject.isEmpty ? "No subject" : message.subject)
                                        .font(.body.weight(.semibold)).lineLimit(2)
                                    Spacer(minLength: 0)
                                    Text(message.date.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Text("\(message.sender) · \(message.accountTitle)")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                if !message.snippet.isEmpty { Text(message.snippet).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
                            }
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Tokens.Space.s2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).ternHover()
                        .accessibilityLabel("Open unread email: \(message.subject), from \(message.sender)")
                        .accessibilityIdentifier("today-unread-\(message.messageID)")
                        if message.id != messages.last?.id { Divider() }
                    }
                }
            }
        }
        .accessibilityIdentifier("today-unread")
    }
}
