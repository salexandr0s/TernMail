import Foundation
import GmailAPI
import MailStore
import Observation
import SwiftUI

/// An editable copy of one suggestion. Its source and duplicate marker stay
/// fixed while the user changes the task and chooses its destination list.
@MainActor @Observable
final class AssistantTaskReviewSession {
    let model: GoogleTasksModel
    let original: TaskCreationRequest
    var title: String
    var notes: String
    var hasDueDate: Bool
    var dueDate: Date
    var selectedListID: String?
    private(set) var lists: [GoogleTaskList] = []
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var error: String?
    private var loadIssue: GoogleTasksIssue?
    @ObservationIgnored private let isAuthorized: @MainActor () -> Bool

    init(request: TaskCreationRequest, model: GoogleTasksModel,
         isAuthorized: @escaping @MainActor () -> Bool) {
        self.model = model
        original = request
        title = request.title
        notes = request.notes
        hasDueDate = request.dueDate != nil
        dueDate = request.dueDate.flatMap { GoogleTaskDateCoding.date($0) } ?? .now
        selectedListID = request.listID
        self.isAuthorized = isAuthorized
    }

    var accountID: String? { original.source?.accountID ?? original.accountID }
    var account: AccountRecord? { model.accounts.first { $0.id == accountID } }
    var hasAccess: Bool { isAuthorized() }
    var needsConnection: Bool {
        guard let accountID, account != nil else { return false }
        return model.authorizedService(for: accountID) == nil
            || loadIssue?.needsConnection == true
            || (model.selectedAccountID == accountID && model.issue?.needsConnection == true)
    }
    var isUncertain: Bool { model.creationState(for: original) == .uncertain }
    var canSave: Bool {
        hasAccess && !isLoading && !isSaving && !model.isCreating && !needsConnection
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && lists.contains { $0.id == selectedListID }
    }

    /// List choices belong to the source account, independently of whichever
    /// account is visible in the Tasks sidebar.
    func load() async {
        guard !isLoading, !isSaving, checkAuthorization() else { return }
        isLoading = true
        error = nil
        loadIssue = nil
        defer { isLoading = false }
        await model.refreshAccounts()
        guard checkAuthorization(), !Task.isCancelled else { return }
        guard let accountID, account != nil else {
            error = "The email's account is no longer available."
            lists = []
            return
        }
        guard let client = model.authorizedService(for: accountID) else {
            lists = []
            return
        }
        let access = model.accountVersions[accountID, default: 0]
        do {
            let fetched = try await client.allTaskLists()
            guard checkAuthorization(), !Task.isCancelled,
                  model.validAccount(accountID, access: access) else { return }
            lists = fetched
            let preferred = selectedListID ?? model.defaults.string(forKey: model.listKey(accountID))
            selectedListID = fetched.first(where: { $0.id == preferred })?.id ?? fetched.first?.id
            if fetched.isEmpty { error = "Create a list in Google Tasks, then try again." }
        } catch {
            guard checkAuthorization(), !Task.isCancelled else { return }
            loadIssue = GoogleTasksIssue(error)
            self.error = loadIssue?.message
        }
    }

    func connect() async {
        guard !isLoading, !isSaving, !model.isConnecting, checkAuthorization(),
              let accountID, account != nil else { return }
        model.selectAccount(accountID)
        await model.connect()
        guard checkAuthorization(), !Task.isCancelled else { return }
        await load()
        if needsConnection { error = model.errorMessage ?? "Allow Google Tasks access, then try again." }
    }

    var editedRequest: TaskCreationRequest {
        var request = original
        request.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        request.notes = notes
        request.dueDate = hasDueDate ? GoogleTaskDateCoding.string(dueDate) : nil
        request.accountID = accountID
        request.listID = selectedListID
        return request
    }

    @discardableResult
    func save(retryAfterReview: Bool = false) async -> Bool {
        guard checkAuthorization(), canSave else { return false }
        let request = editedRequest
        guard request.title.count <= 1024, request.notes.count <= 8192 else {
            error = "Use a title under 1,024 characters and notes under 8,192 characters."
            return false
        }
        isSaving = true
        error = nil
        defer { isSaving = false }
        let saved = await model.add(request, retryAfterReview: retryAfterReview, isAuthorized: isAuthorized)
        if !saved {
            error = model.errorMessage ?? "The task couldn't be saved. Try again."
        }
        return saved
    }

    private func checkAuthorization() -> Bool {
        guard hasAccess else {
            error = "Assistant access changed. Close this review and start again."
            return false
        }
        return true
    }
}

struct AssistantTaskReview: View {
    @State private var session: AssistantTaskReviewSession
    @State private var confirmsRetry = false
    @Environment(\.dismiss) private var dismiss
    @FocusState private var titleFocused: Bool

    init(request: TaskCreationRequest, model: GoogleTasksModel,
         isAuthorized: @escaping @MainActor () -> Bool) {
        _session = State(initialValue: AssistantTaskReviewSession(
            request: request, model: model, isAuthorized: isAuthorized))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s4) {
            Label("Add to Tasks", systemImage: "checklist")
                .font(.title3.weight(.semibold))
            Text("Review the task and choose a list.")
                .font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                TextField("Task title", text: $session.title, axis: .vertical)
                    .font(.title3.weight(.medium)).textFieldStyle(.plain)
                    .lineLimit(2...4).focused($titleFocused)
                    .accessibilityLabel("Task title")
                Divider()
                TextField("Add details", text: $session.notes, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(3...8)
                    .accessibilityLabel("Task notes")
            }
            .padding(Tokens.Space.s4).ternSurface(style: .grouped)
            .disabled(session.isSaving || !session.hasAccess)
            HStack(spacing: Tokens.Space.s2) {
                Toggle("Due date", isOn: $session.hasDueDate).toggleStyle(.checkbox)
                Spacer(minLength: Tokens.Space.s2)
                if session.hasDueDate {
                    DatePicker("Due date", selection: $session.dueDate, displayedComponents: .date)
                        .datePickerStyle(.field).labelsHidden()
                        .accessibilityLabel("Task due date")
                }
            }
            .disabled(session.isSaving || !session.hasAccess)
            destination
            if let source = session.original.source {
                Label(source.subject.isEmpty ? "Source email" : source.subject, systemImage: "envelope")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).help(source.subject)
            }
            if !session.hasAccess {
                notice("Assistant access changed. Close this review and start again.")
            } else if let error = session.error {
                notice(error)
            }
            if session.isUncertain {
                Text("Google hasn't confirmed this save. Check again to look for the task before trying another addition.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Add Again…") { confirmsRetry = true }
                    .disabled(!session.canSave)
            }
            HStack {
                if session.isSaving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(session.isSaving)
                Button(session.isUncertain ? "Check again" : "Add Task") {
                    Task { if await session.save() { dismiss() } }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(!session.canSave)
                .accessibilityIdentifier("assistant-task-save")
            }
        }
        .padding(Tokens.Space.s5)
        .frame(width: Tokens.Sheet.smallWidth)
        .background(Tokens.Surface.primary)
        .interactiveDismissDisabled(session.isSaving)
        .confirmationDialog("Add the task again?", isPresented: $confirmsRetry, titleVisibility: .visible) {
            Button("Add Again") {
                Task { if await session.save(retryAfterReview: true) { dismiss() } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The previous request may have succeeded. Check Google Tasks first to avoid a duplicate.")
        }
        .task {
            titleFocused = true
            await session.load()
        }
    }

    private var destination: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            Text(session.account?.email ?? "Email account")
                .font(.callout.weight(.medium)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if session.isLoading {
                ProgressView("Loading lists…").controlSize(.small)
            } else if session.needsConnection {
                Button(session.model.isConnecting ? "Connecting…" : "Connect Google Tasks") {
                    Task { await session.connect() }
                }
                .disabled(session.model.isConnecting || !session.hasAccess)
            } else {
                if !session.lists.isEmpty {
                    Picker("List", selection: $session.selectedListID) {
                        ForEach(session.lists) { list in
                            Text(list.title).tag(Optional(list.id))
                        }
                    }
                    .disabled(session.isSaving || !session.hasAccess)
                }
                if session.error != nil || session.lists.isEmpty {
                    Button("Reload lists") { Task { await session.load() } }
                        .disabled(session.isSaving || !session.hasAccess)
                }
            }
        }
        .padding(Tokens.Space.s3).ternSurface(style: .grouped)
    }

    private func notice(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.callout).foregroundStyle(Tokens.Status.error)
            .fixedSize(horizontal: false, vertical: true)
    }
}
