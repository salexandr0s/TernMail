import SwiftUI

struct TodayTasksPanel: View {
    @Bindable var dashboard: TodayDashboardModel
    let query: String
    @State private var editor: GoogleTaskEditorContext?
    @State private var deletion: TodayDashboardTask?

    private var rows: [TodayDashboardTask] {
        dashboard.taskRows.filter { query.isEmpty || [$0.task.title, $0.task.notes ?? "", $0.accountTitle, $0.listTitle]
            .contains { $0.localizedCaseInsensitiveContains(query) } }
    }
    private var hasScopedAccount: Bool { dashboard.selectedTaskAccountID != nil }
    private var issue: String? {
        guard hasScopedAccount || dashboard.tasks.selectedAccountID == nil else { return nil }
        return dashboard.tasks.issue?.message ?? dashboard.tasks.errorMessage
    }
    /// Only a list that has never synced shows a loading state. Later
    /// refreshes keep the rows and the count, and show the header indicator.
    private var isFirstLoad: Bool {
        !dashboard.tasks.hasLoadedAccounts || (dashboard.tasksLoading && !dashboard.hasLoadedTasks)
            || (dashboard.tasks.isLoading && rows.isEmpty && dashboard.tasks.lastSyncedAt == nil)
    }
    private var count: Int? {
        hasScopedAccount && !dashboard.tasks.needsConnection && (issue == nil || !rows.isEmpty)
            && dashboard.hasLoadedTasks && !isFirstLoad ? rows.count : nil
    }

    var body: some View {
        TodayDashboardSection(title: "To do", symbol: "checklist", count: count, countLabel: "open tasks shown",
            updatingLabel: "Updating tasks…", isUpdating: dashboard.tasks.isLoading && !isFirstLoad,
            action: TodaySectionAction(title: "New Task", isDisabled: dashboard.makeTaskEditor(nil) == nil,
                identifier: "today-new-task", perform: { editor = dashboard.makeTaskEditor(nil) })) {
            if !dashboard.taskAccounts.isEmpty { destinations }
            taskContent
            footer
        }
        .tracksKeyboardNavigation()
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

    private var taskContent: some View {
        let rows = self.rows
        return VStack(alignment: .leading, spacing: 0) {
            if isFirstLoad {
                TodayLoadingStatus("Loading tasks…").padding(.vertical, Tokens.Space.s2)
                    .ternDelayedLoading().ternTransition(.fade)
            } else if dashboard.taskAccounts.isEmpty {
                TodayCompactState(title: "No task accounts", symbol: "person.crop.circle",
                    message: "No task accounts are available in this profile.")
                    .ternTransition(.fade)
            } else if !hasScopedAccount {
                TodayCompactState(title: "Choose a task account", symbol: "person.crop.circle",
                    message: "Select an account above to load its lists.")
                    .ternTransition(.fade)
            } else if dashboard.tasks.needsConnection {
                VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                    TodayCompactState(title: "Connect Google Tasks", symbol: "checklist",
                        message: "Allow access to tasks for the selected account.")
                    Button(dashboard.tasks.isConnecting ? "Connecting…" : "Connect Tasks", action: connect)
                        .controlSize(.small).disabled(dashboard.tasks.isConnecting || !hasScopedAccount)
                }
                .ternTransition(.fade)
            } else if !dashboard.hasLoadedTasks {
                TodayCompactState(title: "Tasks not loaded", symbol: "checklist",
                    message: "Refresh to load the selected list.")
                    .ternTransition(.fade)
            } else if rows.isEmpty {
                TodayCompactState(title: issue == nil ? query.isEmpty ? "No open tasks in this list" : "No matching tasks" : "Tasks unavailable",
                    symbol: issue == nil ? "checklist" : "exclamationmark.circle",
                    message: query.isEmpty ? nil : "Try another search or choose a different list.")
                    .ternTransition(.fade)
            } else {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        GoogleTaskRow(task: row.task, parentTitle: dashboard.parentTitle(for: row),
                            isBusy: dashboard.isTaskBusy(row),
                            onComplete: { Task { await dashboard.completeTask(row) } },
                            onEdit: { editor = dashboard.makeTaskEditor(row) },
                            onDelete: { deletion = row })
                        if row.id != rows.last?.id { Divider() }
                    }
                }
                .ternTransition(.fade)
            }
        }
        .ternAnimation(value: TodayContentKey(
            states: [isFirstLoad, dashboard.taskAccounts.isEmpty, hasScopedAccount, dashboard.tasks.needsConnection,
                     dashboard.hasLoadedTasks],
            ids: rows.map(\.id)))
    }

    private var destinations: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Tokens.Space.s3) { accountPicker; listPicker }
            VStack(alignment: .leading, spacing: Tokens.Space.s2) { accountPicker; listPicker }
        }
        .controlSize(.small).padding(.bottom, Tokens.Space.s1)
    }
    private var accountPicker: some View {
        Picker("Account", selection: Binding(get: { dashboard.selectedTaskAccountID }, set: { if let id = $0 { dashboard.selectTaskAccount(id) } })) {
            if dashboard.selectedTaskAccountID == nil { Text("Choose account").tag(Optional<String>.none) }
            ForEach(dashboard.taskAccounts) { account in Text(account.displayName ?? account.email).tag(Optional(account.id)) }
        }
        .pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("today-task-account")
    }
    @ViewBuilder private var listPicker: some View {
        if !dashboard.taskLists.isEmpty {
            Picker("List", selection: Binding(get: { dashboard.selectedTaskListID }, set: { if let id = $0 { dashboard.selectTaskList(id) } })) {
                ForEach(dashboard.taskLists) { list in Text(list.title).tag(Optional(list.id)) }
            }
            .pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("today-task-list")
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            if let issue { TodayInlineWarning(issue, retry: { Task { await dashboard.refresh() } }) }
            if hasScopedAccount, !dashboard.tasks.needsConnection {
                let updated = dashboard.tasks.lastSyncedAt.map { "Last updated \($0.formatted(date: .abbreviated, time: .shortened)). " } ?? ""
                let summary = dashboard.tasks.lastSyncedAt.map { "Updated \($0.formatted(date: .omitted, time: .shortened)) · Available tasks only." }
                    ?? "Available tasks in the selected list."
                TodayCoverageNote(summary: summary,
                    details: updated + "Shows available open tasks for this account and list. Changes that have not synced may be missing.",
                    label: "Task data")
            }
        }
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
