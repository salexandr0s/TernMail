import AppKit
import GmailAPI
import SwiftUI

struct GoogleTasksSidebar: View {
    @Bindable var model: GoogleTasksModel
    var onClose: (() -> Void)? = nil
    var isActive = true
    var onCloseAvailabilityChange: (Bool) -> Void = { _ in }
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
                .padding(.horizontal, Tokens.Space.s3)
                .padding(.top, Tokens.Space.s3)
                .padding(.bottom, Tokens.Space.s5)
            }
            .scrollBounceBehavior(.basedOnSize)
            footer
        }
        .background(Tokens.Surface.muted)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("google-tasks-sidebar")
        .onChange(of: inlineEditor != nil, initial: true) { _, hasInlineEditor in
            onCloseAvailabilityChange(!hasInlineEditor)
        }
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
        HStack(spacing: Tokens.Space.s2) {
            Image(systemName: "checklist")
                .font(.body.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                .background(Color.accentColor.opacity(Tokens.Opacity.wash),
                            in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                .accessibilityHidden(true)
            Text("Tasks").font(.headline)
            Spacer(minLength: 0)
            if model.isLoading { ProgressView().controlSize(.small).accessibilityLabel("Syncing tasks") }
            taskIcon("Refresh Tasks", symbol: "arrow.clockwise") { Task { await model.refresh() } }
                .disabled(model.isLoading)
            if let onClose {
                taskIcon("Close Tasks", symbol: "xmark", action: onClose).disabled(inlineEditor != nil)
            }
        }
        .padding(.leading, Tokens.Space.s4)
        .padding(.trailing, Tokens.Space.s3)
        .padding(.top, Tokens.Space.s3)
        .padding(.bottom, Tokens.Space.s2)
    }

    private var destinations: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            HStack(spacing: 0) {
                Menu {
                    Picker("Account", selection: Binding(
                        get: { model.selectedAccountID },
                        set: { if let accountID = $0 { model.selectAccount(accountID) } }
                    )) {
                        ForEach(model.accounts) { account in
                            SenderAccountLabel(account: account).tag(Optional(account.id))
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Group {
                        if let account = model.selectedAccount { SenderAccountLabel(account: account) }
                        else { Label("Choose account", systemImage: "person.crop.circle") }
                    }
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.vertical, Tokens.Space.s1)
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .font(.caption)
                .foregroundStyle(.primary)
                .ternHover(isEnabled: inlineEditor == nil, radius: Tokens.Radius.sm)
                .accessibilityLabel("Tasks account")
                .accessibilityIdentifier("google-tasks-account")
                .disabled(inlineEditor != nil)
                .help(model.selectedAccount?.email ?? "Choose account")
                Spacer(minLength: 0)
            }
            if !model.lists.isEmpty && !model.needsConnection {
                HStack(alignment: .center, spacing: Tokens.Space.s3) {
                    VStack(alignment: .leading, spacing: Tokens.Space.s1_5) {
                        Menu {
                            ForEach(model.lists) { list in
                                Button { model.selectList(list.id) } label: {
                                    if list.id == model.selectedListID { Label(list.title, systemImage: "checkmark") }
                                    else { Text(list.title) }
                                }
                            }
                        } label: {
                            Text(model.selectedList?.title ?? "Choose list").font(.title2.weight(.semibold))
                                .lineLimit(1)
                        }
                        .menuStyle(.borderlessButton)
                        .foregroundStyle(.primary)
                        .accessibilityLabel("Task list")
                        .accessibilityIdentifier("google-tasks-list")
                        .disabled(inlineEditor != nil)
                        .help(model.selectedList?.title ?? "Choose list")
                        HStack(spacing: Tokens.Space.s1_5) {
                            Text("\(model.openTasks.count) to do").monospacedDigit()
                            if !model.completedTasks.isEmpty {
                                Text("·").accessibilityHidden(true)
                                Text("\(model.completedTasks.count) completed").monospacedDigit()
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    completionRing
                }
            }
        }
        .padding(.horizontal, Tokens.Space.s5)
        .padding(.bottom, Tokens.Space.s3)
    }

    private var completionRing: some View {
        let complete = model.completedTasks.count
        let total = complete + model.openTasks.count
        return ZStack {
            Circle().fill(Color.accentColor.opacity(Tokens.Opacity.wash))
            Circle().stroke(Color.secondary.opacity(Tokens.Opacity.tint), lineWidth: Tokens.Border.focus)
            Circle().trim(from: 0, to: total == 0 ? 0 : CGFloat(complete) / CGFloat(total))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: Tokens.Border.focus, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: total > 0 && complete == total ? "checkmark" : "checklist")
                .font(.caption.weight(.medium)).foregroundStyle(Color.accentColor)
        }
        .frame(width: Tokens.Space.s8, height: Tokens.Space.s8)
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
                .font(.caption)
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
            LazyVStack(spacing: 0) {
                if let pendingTask {
                    GoogleTaskRow(task: pendingTask, parentTitle: nil, isBusy: true, isPending: true,
                        onComplete: {}, onEdit: {}, onDelete: {})
                    if !open.isEmpty {
                        Divider().padding(.leading, Tokens.Space.s12).padding(.trailing, Tokens.Space.s3)
                    }
                }
                ForEach(open) { task in
                    VStack(spacing: 0) {
                        row(task)
                        if task.id != lastOpenID {
                            Divider().padding(.leading, Tokens.Space.s12).padding(.trailing, Tokens.Space.s3)
                        }
                    }
                }
            }
            .padding(Tokens.Space.s1)
            .ternSurface()
        }
        if !completed.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Button { showsCompleted.toggle() } label: {
                    HStack(spacing: Tokens.Space.s2) {
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(showsCompleted ? 90 : 0))
                        Text("Completed").font(.caption.weight(.medium))
                        Text("\(model.completedTasks.count)").font(.caption2.monospacedDigit())
                            .padding(.horizontal, Tokens.Space.s1_5).padding(.vertical, Tokens.Space.s0_5)
                            .background(Color.primary.opacity(Tokens.Opacity.hover), in: Capsule())
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Tokens.Space.s3)
                    .frame(minHeight: Tokens.Control.iconButton)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .ternHover()
                .accessibilityLabel("\(showsCompleted ? "Hide" : "Show") \(model.completedTasks.count) completed tasks")
                .accessibilityValue(showsCompleted ? "Expanded" : "Collapsed")
                .accessibilityIdentifier("google-tasks-completed-toggle")
                .disabled(inlineEditor?.context.task?.isCompleted == true)
                if showsCompleted {
                    LazyVStack(spacing: 0) {
                        ForEach(completed) { task in
                            VStack(spacing: 0) { row(task) }
                        }
                    }
                    .padding(Tokens.Space.s1)
                    .ternSurface()
                    .ternTransition(.disclosure)
                }
            }
            .ternAnimation(value: showsCompleted, duration: Tokens.Motion.slow)
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
            Image(systemName: "plus.circle.fill")
                .font(.title3).foregroundStyle(Color.accentColor)
                .frame(width: Tokens.Space.s6)
                .accessibilityHidden(true)
            TextField("Add a task…", text: $newTitle)
                .font(.callout).textFieldStyle(.plain).focused($entryFocused)
                .onSubmit(addQuickTask)
                .accessibilityIdentifier("google-tasks-new-title")
                .help(model.canAdd ? "Press Return to add a task" : "Finish the pending task before adding another")
            if !newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("Add", action: addQuickTask).buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(!model.canAdd)
            } else {
                taskIcon("Add task with details", symbol: "square.and.pencil") { editor = context(nil) }
                    .disabled(!model.canAdd || inlineEditor != nil)
            }
        }
        .padding(.horizontal, Tokens.Space.s3)
        .padding(.vertical, Tokens.Space.s2)
        .background(Tokens.Surface.primary, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .ternOutline(radius: Tokens.Radius.md, focus: entryFocused ? .accentColor : nil)
        .ternAnimation(value: entryFocused)
        .padding(.horizontal, Tokens.Space.s3)
    }

    private var footer: some View {
        HStack(spacing: Tokens.Space.s1) {
            if model.isCreating, model.pendingCreation != nil {
                Text("Adding task…")
            } else if let notice = model.notice, model.issue == nil, model.errorMessage == nil {
                Label {
                    Text(notice).lineLimit(1)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Tokens.Status.success)
                }
                .help(notice)
            } else if let date = model.lastSyncedAt, model.issue == nil {
                Image(systemName: "checkmark.circle").accessibilityHidden(true)
                Text("Updated \(date.formatted(.relative(presentation: .named)))")
                    .lineLimit(1)
            } else { Text("Google Tasks") }
            Spacer(minLength: Tokens.Space.s2)
            openGoogleButton
        }
        .font(.caption2).foregroundStyle(.secondary)
        .padding(.horizontal, Tokens.Space.s5)
        .padding(.vertical, Tokens.Space.s2)
        .background(Tokens.Surface.muted)
        .overlay(alignment: .top) { Divider() }
    }

    private var openGoogleButton: some View {
        Button("Open Google Tasks", systemImage: "arrow.up.right") {
            var components = URLComponents(string: "https://tasks.google.com/tasks/")
            if let email = model.selectedAccount?.email { components?.queryItems = [URLQueryItem(name: "authuser", value: email)] }
            guard let url = components?.url else { return }
            openURL(url)
        }
        .buttonStyle(.plain).font(.caption2)
        .lineLimit(1).fixedSize()
        .padding(.vertical, Tokens.Space.s2)
        .padding(.horizontal, Tokens.Space.s1)
        .ternHover(pointer: .link)
        .help("Open Google Tasks in your browser")
    }

    private func emptyState(_ title: String, detail: String, symbol: String) -> some View {
        VStack(spacing: Tokens.Space.s3) {
            Image(systemName: symbol).font(.largeTitle.weight(.light)).foregroundStyle(Color.accentColor)
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
                        Button("Add Task") { Task { await model.add(request) } }
                            .buttonStyle(.borderedProminent)
                    }
                    Spacer(minLength: 0)
                    Button("Dismiss") { model.dismissPendingCreation() }.buttonStyle(.borderless)
                }
                .controlSize(.small).disabled(model.isCreating)
            }
        }
        .padding(Tokens.Space.s3)
        .ternSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("google-tasks-pending-recovery")
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
