import MailStore
import SwiftUI

struct FailedChangesView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var rows: [FailedChangePresentation] = []
    @State private var busy: Set<Int64> = []
    @State private var error: String?
    @State private var discarding: PendingAction?

    var body: some View {
        Group {
            if rows.isEmpty {
                ContentUnavailableView {
                    Label(error == nil ? "No Failed Changes" : "Couldn't Load Changes",
                          systemImage: error == nil ? "checkmark.circle" : "exclamationmark.circle")
                } description: {
                    Text(error == nil ? "Changes that Gmail can't save will appear here." : "Check your account's connection and reopen this pane.")
                }
            } else {
                SettingsPage {
                    Section {
                        ForEach(rows) { row in
                            failedRow(row)
                        }
                    } header: {
                        Text("\(rows.count) failed \(rows.count == 1 ? "change" : "changes")")
                    } footer: {
                        Text("Retry asks Gmail to save the change again. Discard removes the failed change from this Mac.")
                    }
                    if let error {
                        Section {
                            SettingsErrorLabel(error)
                        }
                    }
                }
            }
        }
        .task(id: app.mailbox?.accounts.map(\.account.id) ?? []) {
            guard let mailbox = app.mailbox else { rows = []; return }
            do {
                for try await actions in mailbox.cache.failedActions(accountIDs: mailbox.accounts.map(\.account.id)) {
                    let resolved = try await mailbox.cache.read { transaction in
                        try actions.map { try FailedChangePresentation.resolve($0, in: transaction) }
                    }
                    guard !Task.isCancelled, app.mailbox === mailbox else { return }
                    self.rows = resolved
                    self.error = nil
                }
            } catch { self.error = "Couldn't read failed changes." }
        }
        .ternConfirm("Discard this failed change?", item: $discarding, actionTitle: "Discard",
                     message: discardMessage) { row in
            Task { await discard(row) }
        }
    }

    private func failedRow(_ failure: FailedChangePresentation) -> some View {
        let row = failure.action
        return VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            HStack(alignment: .top, spacing: Tokens.Space.s2) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(Tokens.Status.warning)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text(title(row.kind)).font(.body.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(failure.targetDescription)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if let intent = failure.intentDescription {
                        Text(intent).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(row.createdAt, format: .dateTime.year().month().day().hour().minute().second())
                        .font(.caption).foregroundStyle(.secondary)
                    Text(app.mailbox?.account(id: row.accountID)?.account.email ?? "Account removed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(app.mailbox?.account(id: row.accountID)?.account.email ?? "Account removed")
                }
            }
            Text(row.lastError ?? "Gmail refused this change.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: Tokens.Space.s2) {
                sourceActions(failure)
                Spacer(minLength: 0)
                if row.id.map(busy.contains) == true {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Updating failed change")
                }
                Button("Retry", systemImage: "arrow.clockwise") { Task { await retry(row) } }
                    .accessibilityLabel("Retry \(title(row.kind)): \(failure.targetDescription)")
                Button("Discard…", role: .destructive) { discarding = row }
                    .accessibilityLabel("Discard \(title(row.kind)): \(failure.targetDescription)")
            }
            .controlSize(.small)
        }
        .disabled(row.id.map(busy.contains) == true)
        .padding(.vertical, Tokens.Space.s1)
    }

    private var discardMessage: String {
        let target = rows.first { $0.id == discarding?.id }?.targetDescription
        let description = target.map { "For “\($0)”. " } ?? ""
        return description + "The change is removed from this Mac and never reaches Gmail."
    }

    @ViewBuilder private func sourceActions(_ failure: FailedChangePresentation) -> some View {
        if let draftID = failure.draftID {
            Button("Open Draft") { Task { await openDraft(draftID, accountID: failure.action.accountID) } }
        } else if failure.sources.count == 1, let source = failure.sources.first {
            Button("Show Affected Mail") { app.mailURLs.openConversation(source.link) }
        } else if !failure.sources.isEmpty {
            Menu("Show Affected Mail") {
                ForEach(failure.sources) { source in
                    Button(source.title) { app.mailURLs.openConversation(source.link) }
                }
            }
            .help("Shows up to five cached sources for this change.")
        }
    }

    private func openDraft(_ id: String, accountID: String) async {
        guard let mailbox = app.mailbox, mailbox.account(id: accountID) != nil else { return }
        do {
            let draft = try await mailbox.cache.read { try $0.localDraft(id: id) }
            guard app.mailbox === mailbox, mailbox.account(id: accountID) != nil,
                  draft?.accountID == accountID else {
                error = "This draft is no longer available."
                return
            }
            openWindow(id: ComposeWindow.sceneID, value: id)
        } catch { self.error = "Couldn't open this draft. Try again." }
    }

    private func retry(_ row: PendingAction) async {
        guard let id = row.id, let owner = app.mailbox?.account(id: row.accountID), busy.insert(id).inserted else { return }
        defer { busy.remove(id) }
        do { _ = try await owner.engine.retryFailedAction(id: id); error = nil }
        catch { self.error = "Couldn't retry this change. Finish related pending changes, check the account's connection and try again." }
    }

    private func discard(_ row: PendingAction) async {
        guard let id = row.id, let owner = app.mailbox?.account(id: row.accountID), busy.insert(id).inserted else { return }
        defer { busy.remove(id) }
        do { try await owner.engine.discardFailedAction(id: id); error = nil }
        catch { self.error = "Couldn't discard this failed change. Try again." }
    }

    private func title(_ kind: PendingAction.Kind) -> String {
        switch kind {
        case .modifyThreads, .modifyMessages: "Change message labels"
        case .trashThreads, .trashMessages: "Move to Trash"
        case .untrashThreads, .untrashMessages: "Restore from Trash"
        case .deleteMessages: "Permanently delete messages"
        case .saveDraft: "Save draft"
        case .sendDraft: "Send draft"
        case .discardDraft: "Discard draft"
        case .createLabel: "Create label"
        case .updateLabel: "Edit label"
        case .deleteLabel: "Delete label"
        case .createFilter: "Create filter"
        case .deleteFilter: "Delete filter"
        case .replaceFilter: "Edit filter"
        case .updateVacation: "Change vacation responder"
        case .updateSignature: "Change signature"
        }
    }
}
