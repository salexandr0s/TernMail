import MailStore
import SwiftUI

struct FailedChangesView: View {
    @Environment(AppModel.self) private var app
    @State private var rows: [PendingAction] = []
    @State private var busy: Set<Int64> = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            Text("Gmail couldn't save these changes. Retry keeps the same queued intent; Discard removes the failed change from this Mac.")
                .font(.callout).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            if rows.isEmpty {
                ContentUnavailableView("No failed changes", systemImage: "checkmark.circle")
            } else {
                List(rows) { row in
                    VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                        HStack {
                            Text(title(row.kind)).font(.headline)
                            Spacer()
                            Button("Retry") { Task { await retry(row) } }
                            Button("Discard", role: .destructive) { Task { await discard(row) } }
                        }
                        Text(app.mailbox?.account(id: row.accountID)?.account.email ?? "Account removed")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(row.lastError ?? "Gmail refused this change.").font(.callout).textSelection(.enabled)
                    }
                    .disabled(row.id.map(busy.contains) == true)
                    .padding(.vertical, Tokens.Space.s2)
                }
            }
        }
        .padding(Tokens.Space.s4)
        .task(id: app.mailbox?.accounts.map(\.account.id) ?? []) {
            guard let mailbox = app.mailbox else { rows = []; return }
            do {
                for try await rows in mailbox.cache.failedActions(accountIDs: mailbox.accounts.map(\.account.id)) {
                    guard !Task.isCancelled else { return }
                    self.rows = rows
                }
            } catch { self.error = "Couldn't read failed changes." }
        }
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
