import MailStore
import SwiftUI

struct SidebarView: View {
    @Bindable var mailbox: MailboxModel

    var body: some View {
        List(selection: $mailbox.selectedMailbox) {
            if mailbox.hasSeveralAccounts {
                Section("All Accounts") {
                    MailboxRows(mailbox: mailbox, boxes: SystemMailbox.combined, accountID: nil)
                }
                ForEach(mailbox.accounts, id: \.account.id) { owner in
                    Section {
                        MailboxRows(mailbox: mailbox, boxes: SystemMailbox.all, accountID: owner.account.id)
                        labelOutline(owner)
                    } header: {
                        AccountHeader(mailbox: mailbox, owner: owner)
                    }
                }
            } else {
                let owner = mailbox.defaultAccount
                Section("Mailboxes") {
                    MailboxRows(mailbox: mailbox, boxes: SystemMailbox.all, accountID: owner.account.id)
                }
                Section {
                    labelOutline(owner)
                } header: {
                    HStack {
                        Text("Labels")
                        Spacer()
                        Button {
                            mailbox.showNewLabel(in: owner.account.id)
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderless)
                        .help("New Label")
                        .accessibilityLabel("New Label")
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            SyncStatusView(mailbox: mailbox)
        }
        .sheet(item: $mailbox.labelEditor) { request in
            LabelEditorSheet(
                title: Self.editorTitle(request),
                saveTitle: Self.editorSaveTitle(request),
                draft: request.draft,
                parentChoices: mailbox.parentChoices(for: Self.editedLabel(request)),
                validate: { mailbox.labelNameProblem($0, renaming: Self.editedLabel(request)?.id) },
                onSave: { mailbox.saveLabel($0, for: request) },
                onCancel: { mailbox.labelEditor = nil }
            )
        }
        .confirmationDialog(
            "Delete the label “\(mailbox.labelToDelete?.name ?? "")”?",
            isPresented: Binding(
                get: { mailbox.labelToDelete != nil },
                set: { if !$0 { mailbox.labelToDelete = nil } }
            )
        ) {
            Button("Delete Label", role: .destructive) { mailbox.deleteConfirmedLabel() }
        } message: {
            Text("Conversations keep their other labels. Gmail can't restore a deleted label, so this can't be undone.")
        }
    }

    private func labelOutline(_ owner: AccountMailbox) -> some View {
        OutlineGroup(LabelNode.outline(owner.labels.filter { !$0.isSystem }), children: \.children) { node in
            LabelRow(mailbox: mailbox, node: node)
        }
    }

    private static func editedLabel(_ request: MailboxModel.LabelEditorRequest) -> LabelRecord? {
        if case .edit(let label) = request.kind { return label }
        return nil
    }

    private static func editorTitle(_ request: MailboxModel.LabelEditorRequest) -> String {
        editedLabel(request) == nil ? "New Label" : "Edit Label"
    }

    private static func editorSaveTitle(_ request: MailboxModel.LabelEditorRequest) -> String {
        editedLabel(request) == nil ? "Create" : "Save"
    }
}

/// System mailboxes, with the Outbox after Drafts while it has items. A nil
/// `accountID` lists them across every account.
private struct MailboxRows: View {
    let mailbox: MailboxModel
    let boxes: [SystemMailbox]
    let accountID: String?

    var body: some View {
        ForEach(boxes) { box in
            let boxID = mailboxID(box.id)
            Label(box.title, systemImage: box.systemImage)
                .badge(mailbox.unreadCount(boxID))
                .tag(boxID as MailboxID?)
            if box.id == SystemLabel.draft, mailbox.showsOutbox(mailboxID(MailboxModel.outboxID)) {
                let outboxID = mailboxID(MailboxModel.outboxID)
                Label("Outbox", systemImage: "tray.and.arrow.up")
                    .badge(mailbox.outbox(in: outboxID).count)
                    .tag(outboxID as MailboxID?)
            }
        }
    }

    private func mailboxID(_ id: String) -> MailboxID {
        accountID.map { .account($0, id) } ?? .combined(id)
    }
}

/// An account's section title. It offers sign-in when Google ended the
/// account's session, and otherwise warns when its mail can't sync.
private struct AccountHeader: View {
    @Environment(AppModel.self) private var app
    let mailbox: MailboxModel
    let owner: AccountMailbox

    var body: some View {
        let email = owner.account.email
        let needsSignIn = app.accountsNeedingSignIn.contains(owner.account.id)
        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
            HStack(spacing: Tokens.Space.s1) {
                Text(email)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(email)
                if !needsSignIn, case .failed(let message) = owner.syncStatus {
                    Image(systemName: "exclamationmark.triangle")
                        .help(message)
                        .accessibilityLabel(message)
                }
            }
            if needsSignIn {
                Button("Sign In Again") {
                    Task { await app.signInAgain(to: owner.account.id) }
                }
                .buttonStyle(.link)
                .disabled(app.isSigningIn)
                .help("Google ended this account's session. Sign in to keep its mail up to date.")
                .accessibilityLabel("Sign in again to \(email)")
            }
        }
        .contextMenu {
            Button("New Label…") { mailbox.showNewLabel(in: owner.account.id) }
            Divider()
            Button("Sign Out…") { app.accountToSignOut = owner.account }
        }
    }
}

/// A user label in the sidebar outline. A label Gmail hasn't created yet is
/// dimmed and can't be selected.
private struct LabelRow: View {
    let mailbox: MailboxModel
    let node: LabelNode

    var body: some View {
        let label = node.label
        let isPending = LabelRules.isTemporary(label.id)
        Label {
            Text(node.title)
                .help(label.name)
        } icon: {
            Image(systemName: "tag")
                .foregroundStyle(Color(gmailHex: label.backgroundColor) ?? .secondary)
        }
        .badge(label.threadsUnread ?? 0)
        .opacity(isPending ? 0.5 : 1)
        .selectionDisabled(isPending)
        .tag(MailboxID.account(label.accountID, label.id) as MailboxID?)
        .accessibilityLabel(isPending ? "\(label.name), waiting for Gmail" : label.name)
        .contextMenu {
            Button("Edit Label…") { mailbox.showEditLabel(label) }
            Button("Delete Label…") { mailbox.labelToDelete = label }
        }
    }
}

/// User labels as an outline. Gmail stores nesting in the name, so
/// "Work/Clients" sits under "Work" when that label exists. A label whose
/// parent doesn't exist shows at the top level under its full name.
struct LabelNode: Identifiable, Equatable {
    let label: LabelRecord
    /// The name below the parent, or the full name at the top level.
    let title: String
    /// Nil for a label with nothing nested under it, as `OutlineGroup` expects.
    var children: [LabelNode]?

    var id: String { label.id }

    static func outline(_ labels: [LabelRecord]) -> [LabelNode] {
        let sorted = labels.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let names = Set(sorted.map(\.name))
        // The nearest existing ancestor of each label, by full name.
        func parent(of name: String) -> String? {
            var path = name
            while let slash = path.lastIndex(of: "/") {
                path = String(path[..<slash])
                if names.contains(path) { return path }
            }
            return nil
        }
        let children = Dictionary(grouping: sorted) { parent(of: $0.name) ?? "" }
        func nodes(under parentName: String?) -> [LabelNode] {
            (children[parentName ?? ""] ?? []).map { label in
                let title = parentName.map { String(label.name.dropFirst($0.count + 1)) } ?? label.name
                let nested = nodes(under: label.name)
                return LabelNode(label: label, title: title, children: nested.isEmpty ? nil : nested)
            }
        }
        return nodes(under: nil)
    }
}

private struct SyncStatusView: View {
    let mailbox: MailboxModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
            switch mailbox.syncStatus {
            case .syncing:
                HStack(spacing: Tokens.Space.s2) {
                    ProgressView().controlSize(.mini)
                    Text("Checking for mail…")
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { mailbox.syncNow() }
                    .buttonStyle(.link)
            case .idle:
                if let date = mailbox.lastSyncedAt {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text("Updated \(date.formatted(.relative(presentation: .named)))")
                    }
                }
            }
            // With several accounts, the section titles name them.
            if !mailbox.hasSeveralAccounts {
                Text(mailbox.account.email)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(mailbox.account.email)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Space.s3)
    }
}

extension Color {
    /// Gmail label colors arrive as "#rrggbb".
    init?(gmailHex hex: String?) {
        guard let hex, hex.hasPrefix("#"), hex.count == 7, let value = UInt32(hex.dropFirst(), radix: 16) else {
            return nil
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
