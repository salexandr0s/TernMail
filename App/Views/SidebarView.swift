import MailStore
import SwiftUI

struct SidebarView: View {
    /// The `UserDefaults` key listing the mailboxes expanded to show each account.
    static let expandedKey = "sidebarExpandedMailboxes"

    @Bindable var mailbox: MailboxModel
    @AppStorage(AccountAppearance.storageKey) private var storedColors = Data()
    @AppStorage(Self.expandedKey) private var expandedIDs = SystemLabel.inbox

    var body: some View {
        List(selection: $mailbox.selectedMailbox) {
            if mailbox.hasSeveralAccounts {
                let colors = accountColors
                let names = AccountAppearance.shortNames(mailbox.accounts.map(\.account))
                Section("Mailboxes") {
                    ForEach(boxes(showingOutbox: mailbox.showsOutbox(.combined(MailboxModel.outboxID)))) { box in
                        CombinedMailboxRows(
                            mailbox: mailbox, box: box, colors: colors, names: names, isExpanded: expansion(of: box.id)
                        )
                    }
                }
                ForEach(mailbox.accounts, id: \.account.id) { owner in
                    Section {
                        labelOutline(owner)
                    } header: {
                        AccountHeader(mailbox: mailbox, owner: owner, color: colors[owner.account.id] ?? .secondary)
                    }
                }
            } else {
                let owner = mailbox.defaultAccount
                Section("Mailboxes") {
                    let outboxID = MailboxID.account(owner.account.id, MailboxModel.outboxID)
                    ForEach(boxes(showingOutbox: mailbox.showsOutbox(outboxID))) { box in
                        let boxID = MailboxID.account(owner.account.id, box.id)
                        MailboxRow(box: box, title: box.title, color: box.color, count: mailbox.sidebarCount(boxID))
                            .tag(boxID as MailboxID?)
                    }
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
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            expandOrCollapse(press.key)
        }
        .onChange(of: mailbox.accounts.map(\.account.id), initial: true) { _, ids in
            let stored = AccountAppearance.decode(storedColors)
            let indexes = AccountAppearance.colorIndexes(for: ids, stored: stored)
            if indexes != stored { storedColors = AccountAppearance.encode(indexes) }
        }
        .onChange(of: mailbox.selectedMailbox) { _, selected in
            // An account's mailbox chosen elsewhere shows under its expanded row.
            if mailbox.hasSeveralAccounts, case .account(_, let id)? = selected,
               boxes(showingOutbox: true).contains(where: { $0.id == id }) {
                expansion(of: id).wrappedValue = true
            }
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

    /// System mailboxes in sidebar order, with the Outbox after Drafts.
    private func boxes(showingOutbox: Bool) -> [SystemMailbox] {
        SystemMailbox.all.flatMap { box in
            box.id == SystemLabel.draft && showingOutbox ? [box, .outbox] : [box]
        }
    }

    private var accountColors: [String: Color] {
        let ids = mailbox.accounts.map(\.account.id)
        return AccountAppearance.colorIndexes(for: ids, stored: AccountAppearance.decode(storedColors))
            .mapValues { AccountAppearance.color(at: $0) }
    }

    /// Right Arrow shows a mailbox's account rows and Left Arrow hides them,
    /// or moves from an account row up to its mailbox, as in an outline.
    private func expandOrCollapse(_ key: KeyEquivalent) -> KeyPress.Result {
        guard mailbox.hasSeveralAccounts, let selected = mailbox.selectedMailbox,
              boxes(showingOutbox: true).contains(where: { $0.id == selected.id })
        else { return .ignored }
        switch (selected, key) {
        case (.combined(let id), .rightArrow): expansion(of: id).wrappedValue = true
        case (.combined(let id), .leftArrow): expansion(of: id).wrappedValue = false
        case (.account(_, let id), .leftArrow): mailbox.selectedMailbox = .combined(id)
        default: return .ignored
        }
        return .handled
    }

    private func expansion(of id: String) -> Binding<Bool> {
        Binding(
            get: { expandedIDs.split(separator: ",").contains { $0 == id } },
            set: { isExpanded in
                var ids = Set(expandedIDs.split(separator: ",").map(String.init))
                if isExpanded { ids.insert(id) } else { ids.remove(id) }
                expandedIDs = ids.sorted().joined(separator: ",")
            }
        )
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

/// A system mailbox's row, its symbol in `color`.
private struct MailboxRow: View {
    let box: SystemMailbox
    let title: String
    let color: Color
    /// Unread conversations, or the Outbox's messages. Zero shows no badge.
    let count: Int
    /// Set on a row listing every account, for its button that shows a row per account.
    var isExpanded: Binding<Bool>?

    var body: some View {
        HStack(spacing: Tokens.Space.s1) {
            if let isExpanded {
                Button {
                    withAnimation(.easeOut(duration: Tokens.Motion.fast)) { isExpanded.wrappedValue.toggle() }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                }
                .buttonStyle(.borderless)
                .help(isExpanded.wrappedValue ? "Hide Accounts" : "Show Accounts")
                .accessibilityLabel(isExpanded.wrappedValue ? "Collapse \(box.title)" : "Expand \(box.title)")
            }
            Label {
                Text(title)
            } icon: {
                Image(systemName: box.systemImage)
                    .foregroundStyle(color)
            }
        }
        .badge(count)
    }
}

/// A system mailbox across accounts, with a row per account below it while
/// it's expanded. The total moves to the account rows then. These are plain
/// rows because a disclosure group's own row can't be selected on macOS.
private struct CombinedMailboxRows: View {
    let mailbox: MailboxModel
    let box: SystemMailbox
    let colors: [String: Color]
    let names: [String: String]
    @Binding var isExpanded: Bool

    var body: some View {
        let combinedID = MailboxID.combined(box.id)
        MailboxRow(
            box: box, title: box.title, color: box.color,
            count: isExpanded ? 0 : mailbox.sidebarCount(combinedID), isExpanded: $isExpanded
        )
        .tag(combinedID as MailboxID?)
        if isExpanded {
            ForEach(mailbox.accounts, id: \.account.id) { owner in
                let boxID = MailboxID.account(owner.account.id, box.id)
                if box.id != MailboxModel.outboxID || mailbox.showsOutbox(boxID) {
                    let name = names[owner.account.id] ?? owner.account.email
                    MailboxRow(
                        box: box, title: name, color: colors[owner.account.id] ?? .secondary,
                        count: mailbox.sidebarCount(boxID)
                    )
                    .padding(.leading, Tokens.Space.s6)
                    .help(owner.account.email)
                    .accessibilityLabel("\(box.title), \(name)")
                    .tag(boxID as MailboxID?)
                }
            }
        }
    }
}

/// An account's section title. It offers sign-in when Google ended the
/// account's session, and otherwise warns when its mail can't sync.
private struct AccountHeader: View {
    @Environment(AppModel.self) private var app
    let mailbox: MailboxModel
    let owner: AccountMailbox
    /// The account's color on its mailbox rows.
    let color: Color

    var body: some View {
        let email = owner.account.email
        let needsSignIn = app.accountsNeedingSignIn.contains(owner.account.id)
        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
            HStack(spacing: Tokens.Space.s1) {
                Image(systemName: "circle.fill")
                    .imageScale(.small)
                    .foregroundStyle(color)
                    .accessibilityHidden(true)
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

/// A user label in the sidebar outline. Its tag is filled with Gmail's color
/// and outlined when the label has none. A label Gmail hasn't created yet is
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
            let color = Color(gmailHex: label.backgroundColor)
            Image(systemName: color == nil ? "tag" : "tag.fill")
                .foregroundStyle(color ?? .secondary)
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

extension SystemMailbox {
    /// The sidebar symbol's color, the same in every account.
    var color: Color {
        switch id {
        case SystemLabel.inbox: .blue
        case SystemLabel.starred: .yellow
        case MailboxModel.snoozedID: .purple
        case SystemLabel.sent: .green
        case SystemLabel.draft: .teal
        case MailboxModel.outboxID: .mint
        case SystemLabel.allMail: .indigo
        case SystemLabel.spam: .orange
        case SystemLabel.trash: .red
        default: .secondary
        }
    }
}

private extension MailboxModel {
    /// A sidebar row's number: the Outbox's messages, otherwise unread conversations.
    func sidebarCount(_ box: MailboxID) -> Int {
        box.id == Self.outboxID ? outbox(in: box).count : unreadCount(box)
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
