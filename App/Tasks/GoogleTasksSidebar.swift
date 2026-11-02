import AppKit
import GmailAPI
import SwiftUI

struct GoogleTasksSidebar: View {
    @Bindable var model: GoogleTasksModel
    var onClose: (() -> Void)? = nil
    var isActive = true
    @State private var newTitle = ""
    @State private var showsCompleted = false
    @State private var editor: GoogleTaskEditorContext?
    @State private var deletion: GoogleTaskEditorContext?
    @State private var confirmsRetry = false
    @FocusState private var entryFocused: Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            header
            if !model.accounts.isEmpty { destinations }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                    feedback
                    if let request = model.pendingCreation { pending(request) }
                    if !model.hasLoadedAccounts {
                        ProgressView("Loading tasks…").frame(maxWidth: .infinity).padding(.vertical, Tokens.Space.s12)
                    } else if model.accounts.isEmpty {
                        emptyState("Your tasks, beside your mail", detail: "Add a Google account in Tern to connect its tasks.", symbol: "checklist")
                    } else if model.needsConnection {
                        connection
                    } else if model.isLoading && model.lastSyncedAt == nil && model.tasks.isEmpty {
                        ProgressView("Loading tasks…").frame(maxWidth: .infinity).padding(.vertical, Tokens.Space.s12)
                    } else if model.issue != nil && model.lastSyncedAt == nil {
                        emptyState("Tasks couldn't load", detail: "Refresh when you're ready to try again.", symbol: "arrow.triangle.2.circlepath")
                    } else if model.lists.isEmpty {
                        emptyState("No task lists", detail: "Create a list in Google Tasks, then refresh.", symbol: "list.bullet.rectangle")
                        openGoogleButton.frame(maxWidth: .infinity)
                    } else {
                        taskContent
                    }
                }
                .padding(Tokens.Space.s3)
            }
            .scrollBounceBehavior(.basedOnSize)
            if !model.needsConnection && !model.lists.isEmpty { composer }
            footer
        }
        .background(Tokens.Surface.primary)
        .accessibilityIdentifier("google-tasks-sidebar")
        .task(id: isActive) {
            guard isActive else { return }
            model.resume()
            await model.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                if NSApp.isActive { await model.refresh() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard isActive else { return }
            Task { await model.refresh() }
        }
        .sheet(item: $editor) { GoogleTaskEditor(model: model, context: $0) }
        .confirmationDialog("Delete this task?", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }),
            titleVisibility: .visible) {
            if let deletion, let task = deletion.task {
                Button("Delete Task", role: .destructive) {
                    Task { await model.delete(task, location: deletion.location) }
                    self.deletion = nil
                }
            }
            Button("Cancel", role: .cancel) { deletion = nil }
        } message: {
            Text("This removes the task and its subtasks from Google Tasks on all your devices.")
        }
        .confirmationDialog("Add the task again?", isPresented: $confirmsRetry, titleVisibility: .visible) {
            if let request = model.pendingCreation {
                Button("Add Again") { Task { await model.add(request, retryAfterReview: true) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The previous request may have reached Google. Check Google Tasks first to avoid a duplicate.")
        }
        .onKeyPress(.escape) {
            guard newTitle.isEmpty, editor == nil, let onClose else { return .ignored }
            if let input = NSApp.keyWindow?.firstResponder as? NSTextInputClient, input.hasMarkedText() { return .ignored }
            onClose()
            return .handled
        }
    }

    private var header: some View {
        HStack(spacing: Tokens.Space.s2) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2).foregroundStyle(Color.accentColor)
                .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
                Text("Tasks").font(.headline)
                Text("Google Tasks").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if model.isLoading { ProgressView().controlSize(.small).accessibilityLabel("Syncing tasks") }
            taskIcon("Refresh Tasks", symbol: "arrow.clockwise") { Task { await model.refresh() } }
                .disabled(model.isLoading)
            if let onClose { taskIcon("Close Tasks", symbol: "xmark", action: onClose) }
        }
        .padding(.horizontal, Tokens.Space.s4)
        .padding(.vertical, Tokens.Space.s3)
    }

    private var destinations: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            HStack(spacing: 0) {
                Menu {
                    ForEach(model.accounts) { account in
                        Button { model.selectAccount(account.id) } label: {
                            if account.id == model.selectedAccountID { Label(account.email, systemImage: "checkmark") }
                            else { Text(account.email) }
                        }
                    }
                } label: {
                    Label(model.selectedAccount?.email ?? "Choose account", systemImage: "person.crop.circle")
                        .lineLimit(1).truncationMode(.middle)
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .font(.caption)
                .accessibilityLabel("Tasks account")
                .accessibilityIdentifier("google-tasks-account")
                Spacer(minLength: 0)
            }
            if !model.lists.isEmpty && !model.needsConnection {
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s2) {
                    Menu {
                        ForEach(model.lists) { list in
                            Button { model.selectList(list.id) } label: {
                                if list.id == model.selectedListID { Label(list.title, systemImage: "checkmark") }
                                else { Text(list.title) }
                            }
                        }
                    } label: {
                        Text(model.selectedList?.title ?? "Choose list").font(.title3.weight(.semibold))
                            .lineLimit(1)
                    }
                    .menuStyle(.borderlessButton)
                    .accessibilityLabel("Task list")
                    .accessibilityIdentifier("google-tasks-list")
                    Spacer(minLength: 0)
                    Text("\(model.openTasks.count) to do")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
                }
            }
        }
        .padding(.horizontal, Tokens.Space.s5)
        .padding(.bottom, Tokens.Space.s3)
    }

    @ViewBuilder private var feedback: some View {
        if let text = model.errorMessage ?? model.issue?.message {
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                Label(text, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(Tokens.Status.error)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.needsConnection {
                    Button("Refresh") { Task { await model.refresh() } }.buttonStyle(.link)
                }
            }
            .padding(Tokens.Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.Status.error.opacity(Tokens.Opacity.wash), in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        } else if let notice = model.notice {
            Label(notice, systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, Tokens.Space.s2)
        }
    }

    private var connection: some View {
        VStack(spacing: Tokens.Space.s4) {
            emptyState("Keep your tasks in sync", detail: "Add tasks from emails and see them in Google Tasks on your other devices.", symbol: "checklist")
            Button { Task { await model.connect() } } label: {
                HStack(spacing: Tokens.Space.s2) {
                    if model.isConnecting { ProgressView().controlSize(.small) }
                    Text(model.isConnecting ? "Connecting…" : "Connect Google Tasks")
                }
            }
            .buttonStyle(.borderedProminent).disabled(model.isConnecting)
            .accessibilityIdentifier("google-tasks-connect")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Tokens.Space.s5)
    }

    @ViewBuilder private var taskContent: some View {
        if model.openTasks.isEmpty {
            emptyState(model.completedTasks.isEmpty ? "Start with one task" : "All caught up",
                detail: model.completedTasks.isEmpty ? "Add a task below, or select text in an email and choose Add to Google Tasks."
                    : "Everything in this list is complete. New tasks will appear here.", symbol: "checkmark.circle")
        } else {
            LazyVStack(spacing: 0) {
                ForEach(model.openTasks) { task in
                    row(task)
                    if task.id != model.openTasks.last?.id {
                        Divider().padding(.leading, Tokens.Space.s12)
                    }
                }
            }
        }
        if !model.completedTasks.isEmpty {
            DisclosureGroup(isExpanded: $showsCompleted) {
                LazyVStack(spacing: 0) { ForEach(model.completedTasks) { row($0) } }
                    .padding(.top, Tokens.Space.s2)
            } label: {
                Text("Completed · \(model.completedTasks.count)").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, Tokens.Space.s2)
            .padding(.top, Tokens.Space.s3)
        }
    }

    private func row(_ task: GoogleTask) -> some View {
        GoogleTaskRow(task: task, parentTitle: task.parent.flatMap { id in model.tasks.first { $0.id == id }?.title },
            isBusy: model.taskIsBusy(task), onComplete: { Task { await model.setCompleted(task, completed: !task.isCompleted) } },
            onEdit: { editor = context(task) }, onDelete: { deletion = context(task) })
    }

    private var composer: some View {
        HStack(spacing: Tokens.Space.s2) {
            Image(systemName: "plus").foregroundStyle(Color.accentColor).accessibilityHidden(true)
            TextField("Add a task", text: $newTitle)
                .textFieldStyle(.plain).focused($entryFocused)
                .onSubmit(addQuickTask)
                .accessibilityIdentifier("google-tasks-new-title")
            if !newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("Add", action: addQuickTask).buttonStyle(.borderless).disabled(!model.canAdd)
            } else {
                taskIcon("Add task with details", symbol: "slider.horizontal.3") { editor = context(nil) }
                    .disabled(!model.canAdd)
            }
        }
        .padding(.horizontal, Tokens.Space.s3)
        .padding(.vertical, Tokens.Space.s2)
        .background(Color.accentColor.opacity(Tokens.Opacity.wash), in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .ternOutline(radius: Tokens.Radius.md, style: .contrastOnly)
        .padding(.horizontal, Tokens.Space.s4)
        .padding(.top, Tokens.Space.s2)
    }

    private var footer: some View {
        HStack(spacing: Tokens.Space.s1) {
            if let date = model.lastSyncedAt, model.issue == nil {
                Image(systemName: "arrow.triangle.2.circlepath").accessibilityHidden(true)
                Text("Updated \(date.formatted(.relative(presentation: .named)))")
                    .lineLimit(1)
            } else { Text("Google Tasks") }
            Spacer(minLength: Tokens.Space.s2)
            openGoogleButton
        }
        .font(.caption2).foregroundStyle(.secondary)
        .padding(.horizontal, Tokens.Space.s5)
        .padding(.vertical, Tokens.Space.s3)
    }

    private var openGoogleButton: some View {
        Button("Open Google Tasks", systemImage: "arrow.up.right") {
            var components = URLComponents(string: "https://tasks.google.com/tasks/")
            if let email = model.selectedAccount?.email { components?.queryItems = [URLQueryItem(name: "authuser", value: email)] }
            guard let url = components?.url else { return }
            openURL(url)
        }
        .buttonStyle(.link).font(.caption2)
    }

    private func emptyState(_ title: String, detail: String, symbol: String) -> some View {
        VStack(spacing: Tokens.Space.s3) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(Color.accentColor)
                .padding(Tokens.Space.s4)
                .background(Color.accentColor.opacity(Tokens.Opacity.wash), in: RoundedRectangle(cornerRadius: Tokens.Radius.lg))
                .accessibilityHidden(true)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Tokens.Space.s4)
        .padding(.vertical, Tokens.Space.s8)
    }

    private func pending(_ request: TaskCreationRequest) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            let uncertain = model.creationState(for: request) == .uncertain
            Label(uncertain ? "Addition not confirmed" : "Ready to add", systemImage: uncertain ? "questionmark.circle" : "envelope.badge")
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(request.title).font(.callout).lineLimit(3).help(request.title)
            if let source = request.source { Text(source.subject).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            let accountID = request.source?.accountID ?? request.accountID
            if let accountID, accountID != model.selectedAccountID {
                Button("Show Task Account") { model.selectAccount(accountID) }.controlSize(.small)
            } else if !model.needsConnection {
                HStack {
                    if model.creationState(for: request) == .uncertain {
                        Button("Check Again") { Task { await model.add(request) } }
                        Button("Add Again…") { confirmsRetry = true }
                    } else {
                        Button(model.isCreating ? "Adding…" : "Add Task") { Task { await model.add(request) } }
                            .buttonStyle(.borderedProminent)
                    }
                    Spacer(minLength: 0)
                    Button("Dismiss") { model.dismissPendingCreation() }.buttonStyle(.borderless)
                }
                .controlSize(.small).disabled(model.isCreating)
            }
        }
        .padding(Tokens.Space.s3)
        .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .ternOutline(radius: Tokens.Radius.md, style: .contrastOnly)
    }

    private func context(_ task: GoogleTask?) -> GoogleTaskEditorContext? {
        guard let location = model.selectedLocation else { return nil }
        return GoogleTaskEditorContext(task: task, location: location, listTitle: model.selectedList?.title ?? "Tasks")
    }

    private func addQuickTask() {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, model.canAdd, model.pendingCreation == nil else { return }
        let request = TaskCreationRequest(title: title, accountID: model.selectedAccountID, listID: model.selectedListID)
        newTitle = ""
        Task {
            await model.add(request)
            entryFocused = true
        }
    }

    private func taskIcon(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
        }
        .buttonStyle(.borderless).foregroundStyle(.secondary)
        .help(title).accessibilityLabel(title)
    }
}
