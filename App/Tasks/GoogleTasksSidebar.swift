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
    @State private var inlineEditor: GoogleTaskEditingSession?
    @State private var deletion: GoogleTaskEditorContext?
    @State private var confirmsRetry = false
    @FocusState private var entryFocused: Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            header
            if !model.accounts.isEmpty { destinations }
            if !model.needsConnection && !model.lists.isEmpty { composer }
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                    feedback
                    if let inlineEditor, !canShowTaskContent || inlineEditor.context.location != model.selectedLocation {
                        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                            Text("Editing in \(inlineEditor.context.listTitle)").font(.caption).foregroundStyle(.secondary)
                            editingRow(inlineEditor)
                        }
                    }
                    if let request = model.pendingCreation, !model.isCreating { pending(request) }
                    if canShowTaskContent {
                        taskContent
                    } else if !model.hasLoadedAccounts {
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
                    }
                }
                .padding(.horizontal, Tokens.Space.s4)
                .padding(.top, Tokens.Space.s4)
                .padding(.bottom, Tokens.Space.s5)
            }
            .scrollBounceBehavior(.basedOnSize)
            footer
        }
        .background(Tokens.Surface.canvas)
        .accessibilityElement(children: .contain)
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
            if let input = NSApp.keyWindow?.firstResponder as? NSTextInputClient, input.hasMarkedText() { return .ignored }
            if let inlineEditor {
                guard !inlineEditor.isSaving else { return .ignored }
                self.inlineEditor = nil
                entryFocused = true
                return .handled
            }
            guard newTitle.isEmpty, editor == nil, let onClose else { return .ignored }
            onClose()
            return .handled
        }
    }

    private var header: some View {
        TernPageHeader(title: "Tasks") {
            HStack(spacing: Tokens.Space.s1) {
                if model.isLoading { ProgressView().controlSize(.small).accessibilityLabel("Syncing tasks") }
                taskIcon("Refresh Tasks", symbol: "arrow.clockwise") { Task { await model.refresh() } }
                    .disabled(model.isLoading)
                if let onClose {
                    taskIcon("Close Tasks", symbol: "xmark", action: onClose).disabled(inlineEditor != nil)
                }
            }
        }
        .padding(.horizontal, Tokens.Space.s4)
        .padding(.vertical, Tokens.Space.s3)
        .accessibilityIdentifier("google-tasks-heading")
    }

    private var destinations: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            if !model.lists.isEmpty && !model.needsConnection {
                HStack(alignment: .center, spacing: Tokens.Space.s3) {
                    completionRing
                    VStack(alignment: .leading, spacing: Tokens.Space.s1_5) {
                        listPicker
                        accountPicker
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                HStack(spacing: Tokens.Space.s2) {
                    Text("\(model.openTasks.count) to do").font(.callout.bold())
                    Spacer(minLength: 0)
                    Text("\(model.completedTasks.count) completed").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                accountPicker
            }
        }
        .padding(Tokens.Space.s4)
        .ternSurface()
        .padding(.horizontal, Tokens.Space.s4)
        .padding(.bottom, Tokens.Space.s4)
    }

    private var accountPicker: some View {
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
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Tasks account")
        .accessibilityIdentifier("google-tasks-account")
        .disabled(inlineEditor != nil)
        .help(model.selectedAccount?.email ?? "Choose account")
    }

    private var listPicker: some View {
        Menu {
            ForEach(model.lists) { list in
                Button { model.selectList(list.id) } label: {
                    if list.id == model.selectedListID { Label(list.title, systemImage: "checkmark") }
                    else { Text(list.title) }
                }
            }
        } label: {
            Text(model.selectedList?.title ?? "Choose list").font(.title3.bold())
                .lineLimit(2).multilineTextAlignment(.leading)
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("Task list")
        .accessibilityIdentifier("google-tasks-list")
        .disabled(inlineEditor != nil)
        .help(model.selectedList?.title ?? "Choose list")
    }

    private var completionRing: some View {
        let complete = model.completedTasks.count
        let total = complete + model.openTasks.count
        return ZStack {
            Circle().stroke(Color.secondary.opacity(Tokens.Opacity.tint), lineWidth: Tokens.Border.focus)
            Circle().trim(from: 0, to: total == 0 ? 0 : CGFloat(complete) / CGFloat(total))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: Tokens.Border.focus, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: total > 0 && complete == total ? "checkmark" : "checklist")
                .font(.headline).foregroundStyle(Color.accentColor)
        }
        .frame(width: Tokens.Space.s10, height: Tokens.Space.s10)
        .padding(Tokens.Space.s0_5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(complete) of \(total) tasks complete")
        .help("\(complete) of \(total) tasks complete")
        .ternAnimation(value: complete)
    }

    @ViewBuilder private var feedback: some View {
        if let text = model.errorMessage ?? model.issue?.message, text != inlineEditor?.error {
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                HStack(alignment: .top, spacing: Tokens.Space.s2) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Tokens.Status.error)
                    Text(text).fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
                if !model.needsConnection {
                    Button("Refresh") { Task { await model.refresh() } }.buttonStyle(.link)
                }
            }
            .padding(Tokens.Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.Status.error.opacity(Tokens.Opacity.wash), in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
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

    private var canShowTaskContent: Bool {
        model.hasLoadedAccounts && !model.accounts.isEmpty && !model.needsConnection && !model.lists.isEmpty
            && !(model.lastSyncedAt == nil && (model.issue != nil || (model.isLoading && model.tasks.isEmpty)))
    }

    @ViewBuilder private var taskContent: some View {
        let open = displayedTasks(completed: false)
        let completed = displayedTasks(completed: true)
        let pendingTask = self.pendingTask
        let lastOpenID = open.last?.id
        if open.isEmpty && pendingTask == nil {
            emptyState(model.completedTasks.isEmpty ? "A fresh list" : "All caught up",
                detail: model.completedTasks.isEmpty ? "Add your first task above, or turn a line from an email into a task."
                    : "Everything in this list is complete. New tasks will appear here.", symbol: "checkmark.circle")
        } else {
            Text("To do").font(.headline).padding(.horizontal, Tokens.Space.s1)
            LazyVStack(spacing: 0) {
                if let pendingTask {
                    GoogleTaskRow(task: pendingTask, parentTitle: nil, isBusy: true, isPending: true,
                        onComplete: {}, onEdit: {}, onDelete: {})
                    if !open.isEmpty {
                        Divider().padding(.leading, Tokens.Space.s12).padding(.trailing, Tokens.Space.s3)
                    }
                }
                ForEach(open) { task in
                    row(task)
                    if task.id != lastOpenID {
                        Divider().padding(.leading, Tokens.Space.s12).padding(.trailing, Tokens.Space.s3)
                    }
                }
            }
            .padding(Tokens.Space.s1)
            .ternSurface(style: .grouped)
        }
        if !completed.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                Button { showsCompleted.toggle() } label: {
                    HStack(spacing: Tokens.Space.s2) {
                        Image(systemName: "chevron.right").font(.callout.weight(.semibold))
                            .rotationEffect(.degrees(showsCompleted ? 90 : 0))
                        Text("Completed").font(.headline)
                        Text("\(model.completedTasks.count)").font(.callout.monospacedDigit())
                            .padding(.horizontal, Tokens.Space.s1_5).padding(.vertical, Tokens.Space.s0_5)
                            .background(Color.primary.opacity(Tokens.Opacity.hover), in: Capsule())
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Tokens.Space.s3)
                    .frame(minHeight: Tokens.Space.s10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .ternHover()
                .accessibilityLabel("\(showsCompleted ? "Hide" : "Show") \(model.completedTasks.count) completed tasks")
                .accessibilityValue(showsCompleted ? "Expanded" : "Collapsed")
                .accessibilityIdentifier("google-tasks-completed-toggle")
                .disabled(inlineEditor?.context.task?.isCompleted == true)
                if showsCompleted {
                    LazyVStack(spacing: 0) { ForEach(completed) { row($0) } }
                        .padding(Tokens.Space.s1)
                        .ternSurface(style: .grouped)
                }
            }
            .ternAnimation(value: showsCompleted)
        }
    }

    @ViewBuilder private func row(_ task: GoogleTask) -> some View {
        if let inlineEditor, inlineEditor.context.location == model.selectedLocation,
           inlineEditor.context.task?.id == task.id {
            editingRow(inlineEditor)
        } else {
            GoogleTaskRow(task: task, parentTitle: model.parentTitle(for: task),
                isBusy: model.taskIsBusy(task), allowsEditing: inlineEditor == nil,
                onComplete: { Task { await model.setCompleted(task, completed: !task.isCompleted) } },
                onEdit: {
                    guard inlineEditor == nil, let context = context(task) else { return }
                    inlineEditor = GoogleTaskEditingSession(model: model, context: context)
                }, onDelete: { deletion = context(task) })
        }
    }

    private func editingRow(_ session: GoogleTaskEditingSession) -> some View {
        GoogleTaskEditor(session: session) {
            if inlineEditor === session {
                inlineEditor = nil
                entryFocused = true
            }
        }
        .id(session.context.id)
    }

    /// A refresh may complete or remove the task. Keep its editor in the
    /// original section until Save or Cancel so the draft stays reachable.
    private func displayedTasks(completed: Bool) -> [GoogleTask] {
        let tasks = completed ? model.completedTasks : model.openTasks
        guard let session = inlineEditor, session.context.location == model.selectedLocation,
              let original = session.context.task else { return tasks }
        if original.isCompleted != completed { return tasks.filter { $0.id != original.id } }
        return tasks.contains { $0.id == original.id } ? tasks : [original] + tasks
    }

    /// Saving uses the same row and metadata as Google's result, without
    /// exposing an unconfirmed task to completion, editing, or reconciliation.
    private var pendingTask: GoogleTask? {
        guard model.isCreating, let request = model.pendingCreation,
              (request.source?.accountID ?? request.accountID) == model.selectedAccountID,
              let listID = request.listID, listID == model.selectedListID,
              let email = model.selectedAccount?.email,
              let draft = try? request.draft(email: email) else { return nil }
        return GoogleTask(id: "pending-\(request.id)", title: draft.title, notes: draft.notes, due: draft.due)
    }

    private var composer: some View {
        HStack(spacing: Tokens.Space.s2) {
            Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(Color.accentColor).accessibilityHidden(true)
            TextField("Add a task…", text: $newTitle)
                .font(.body).textFieldStyle(.plain).focused($entryFocused)
                .onSubmit(addQuickTask)
                .accessibilityIdentifier("google-tasks-new-title")
                .help(model.canAdd ? "Press Return to add a task" : "Finish the pending task before adding another")
            if !newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("Add", action: addQuickTask).buttonStyle(.borderedProminent)
                    .disabled(!model.canAdd)
                    .accessibilityIdentifier("google-tasks-add")
            } else {
                taskIcon("Add task with details", symbol: "square.and.pencil") { editor = context(nil) }
                    .disabled(!model.canAdd || inlineEditor != nil)
            }
        }
        .padding(.horizontal, Tokens.Space.s3)
        .padding(.vertical, Tokens.Space.s3)
        .background(Tokens.Surface.primary, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .ternOutline(radius: Tokens.Radius.md, focus: entryFocused ? .accentColor : nil)
        .padding(.horizontal, Tokens.Space.s4)
    }

    private var footer: some View {
        HStack(spacing: Tokens.Space.s1) {
            if model.isCreating, model.pendingCreation != nil {
                Text("Adding task…")
            } else if let notice = model.notice, model.issue == nil, model.errorMessage == nil {
                Label(notice, systemImage: "checkmark.circle").lineLimit(1).help(notice)
            } else if let date = model.lastSyncedAt, model.issue == nil {
                Image(systemName: "checkmark.circle").accessibilityHidden(true)
                Text("Updated \(date.formatted(.relative(presentation: .named)))")
                    .lineLimit(1)
            } else { Text("Google Tasks") }
            Spacer(minLength: Tokens.Space.s2)
            openGoogleButton
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, Tokens.Space.s4)
        .padding(.vertical, Tokens.Space.s3)
        .background(Tokens.Surface.muted)
    }

    private var openGoogleButton: some View {
        Button("Open Google Tasks", systemImage: "arrow.up.right") {
            var components = URLComponents(string: "https://tasks.google.com/tasks/")
            if let email = model.selectedAccount?.email { components?.queryItems = [URLQueryItem(name: "authuser", value: email)] }
            guard let url = components?.url else { return }
            openURL(url)
        }
        .buttonStyle(.plain).font(.caption).fixedSize()
        .help("Open Google Tasks in your browser")
    }

    private func emptyState(_ title: String, detail: String, symbol: String) -> some View {
        VStack(spacing: Tokens.Space.s3) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(Color.accentColor)
                .frame(width: Tokens.Space.s16, height: Tokens.Space.s16)
                .background(Color.accentColor.opacity(Tokens.Opacity.wash), in: Circle())
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
                .font(.callout.bold()).foregroundStyle(.secondary)
            Text(request.title).font(.body.bold()).lineLimit(3).help(request.title)
            if let source = request.source { Text(source.subject).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
            let accountID = request.source?.accountID ?? request.accountID
            if let accountID, accountID != model.selectedAccountID {
                Button("Show Task Account") { model.selectAccount(accountID) }.controlSize(.small)
            } else if !model.needsConnection {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Tokens.Space.s2) {
                        pendingPrimaryActions(request, uncertain: uncertain)
                        Spacer(minLength: 0)
                        dismissPendingButton
                    }
                    VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                        pendingPrimaryActions(request, uncertain: uncertain)
                        dismissPendingButton
                    }
                }
                .controlSize(.small).disabled(model.isCreating)
            }
        }
        .padding(Tokens.Space.s3)
        .ternSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("google-tasks-pending-recovery")
    }

    @ViewBuilder private func pendingPrimaryActions(_ request: TaskCreationRequest, uncertain: Bool) -> some View {
        if uncertain {
            Button("Check Again") { Task { await model.add(request) } }.fixedSize()
            Button("Add Again…") { confirmsRetry = true }.fixedSize()
        } else {
            Button("Add Task") { Task { await model.add(request) } }
                .buttonStyle(.borderedProminent).fixedSize()
        }
    }

    private var dismissPendingButton: some View {
        Button("Dismiss") { model.dismissPendingCreation() }.buttonStyle(.borderless).fixedSize()
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
        .ternHover(radius: Tokens.Radius.md)
        .help(title).accessibilityLabel(title)
    }
}
