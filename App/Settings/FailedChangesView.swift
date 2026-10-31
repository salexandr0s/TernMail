import MailStore
import SwiftUI

struct FailedChangesView: View {
    @Environment(AppModel.self) private var app
    @State private var rows: [PendingAction] = []
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
                for try await rows in mailbox.cache.failedActions(accountIDs: mailbox.accounts.map(\.account.id)) {
                    guard !Task.isCancelled else { return }
                    self.rows = rows
                }
            } catch { self.error = "Couldn't read failed changes." }
        }
        .ternConfirm("Discard this failed change?", item: $discarding, actionTitle: "Discard",
                     message: "The change is removed from this Mac and never reaches Gmail.") { row in
            Task { await discard(row) }
        }
    }

    private func failedRow(_ row: PendingAction) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s3) {
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text(title(row.kind)).font(.body.weight(.semibold))
                    Text(app.mailbox?.account(id: row.accountID)?.account.email ?? "Account removed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if row.id.map(busy.contains) == true {
                    ProgressView().controlSize(.small)
                }
                Button("Retry", systemImage: "arrow.clockwise") { Task { await retry(row) } }
                Button("Discard…", role: .destructive) { discarding = row }
            }
            .controlSize(.small)
            Text(row.lastError ?? "Gmail refused this change.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .disabled(row.id.map(busy.contains) == true)
        .padding(.vertical, Tokens.Space.s1)
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
