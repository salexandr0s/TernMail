import MailStore
import GmailAPI
import SwiftUI

struct SidebarView: View {
    /// The `UserDefaults` key listing the mailboxes expanded to show each account.
    static let expandedKey = "sidebarExpandedMailboxes"

    @Bindable var mailbox: MailboxModel
    @AppStorage(AccountAppearance.storageKey) private var storedColors = Data()
    @AppStorage(Self.expandedKey) private var expandedIDs = SystemLabel.inbox

    var body: some View {
        List(selection: $mailbox.selectedMailbox) {
            Section("Library") {
                Label("Attachments", systemImage: "paperclip")
                    .tag(MailboxID.combined(AttachmentLibraryModel.mailboxID))
            }
            FavoritesView(mailbox: mailbox)
            SavedSearchRows(mailbox: mailbox)
            if mailbox.presentedAccounts.count > 1 {
                let colors = accountColors
                let names = sidebarNames
                Section("Mailboxes") {
                    ForEach(boxes(showingOutbox: mailbox.showsOutbox(.combined(MailboxModel.outboxID)))) { box in
                        CombinedMailboxRows(
                            mailbox: mailbox, box: box, colors: colors, names: names, isExpanded: expansion(of: box.id)
                        )
                    }
                }
                ForEach(mailbox.presentedAccounts, id: \.account.id) { owner in
                    Section {
                        labelOutline(owner)
                        moreMailboxes(owner)
                    } header: {
                        AccountHeader(mailbox: mailbox, owner: owner, color: colors[owner.account.id] ?? .secondary)
                    }
                }
            } else {
                if let owner = mailbox.presentedAccounts.first {
                Section("Mailboxes") {
                    let outboxID = MailboxID.account(owner.account.id, MailboxModel.outboxID)
                    ForEach(boxes(showingOutbox: mailbox.showsOutbox(outboxID))) { box in
                        let boxID = MailboxID.account(owner.account.id, box.id)
                        MailboxRow(box: box, title: box.title, color: box.color, count: mailbox.sidebarCount(boxID))
                            .tag(boxID)
                        if box.id == SystemLabel.inbox { InboxCategoryRows(mailbox: mailbox, accountID: owner.account.id) }
                    }
                }
                Section {
                    labelOutline(owner)
                    moreMailboxes(owner)
                } header: {
                    HStack {
                        Text("Labels")
                        Spacer()
                        Button {
                            mailbox.showNewLabel(in: owner.account.id)
                        } label: {
                            Image(systemName: "plus")
                                .frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .help("New Label")
                        .accessibilityLabel("New Label")
                    }
                }
                }
            }
        }
        .listStyle(.sidebar)
        .sheet(isPresented: Binding(get: { mailbox.navigation.isCreatingSearch }, set: { mailbox.navigation.isCreatingSearch = $0 })) {
            SavedSearchEditor(mailbox: mailbox, existing: nil)
        }
        .sheet(item: Binding(get: { mailbox.navigation.searchToEdit }, set: { mailbox.navigation.searchToEdit = $0 })) { search in
            SavedSearchEditor(mailbox: mailbox, existing: search)
        }
        .sheet(isPresented: Binding(get: { mailbox.navigation.isShowingSwitcher }, set: { mailbox.navigation.isShowingSwitcher = $0 })) {
            MailboxSwitcher(mailbox: mailbox)
        }
        .onChange(of: mailbox.navigation.searches) { _, _ in mailbox.refreshSavedSearch() }
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
        .task(id: mailbox.accounts.flatMap(\.labels)) {
            await LabelAppearance.shared.reconcile(using: mailbox.cache)
        }
        .onChange(of: mailbox.selectedMailbox) { _, selected in
            // An account's mailbox chosen elsewhere shows under its expanded row.
            if mailbox.presentedAccounts.count > 1, case .account(_, let id)? = selected,
               (SystemMailbox.all + [.outbox]).contains(where: { $0.id == id }) {
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
            Text("Conversations keep their other labels. This can't be undone.")
        }
    }

    /// System mailboxes in sidebar order, with the Outbox after Drafts.
    private func boxes(showingOutbox: Bool) -> [SystemMailbox] {
        let favorites = Set(mailbox.navigation.favorites.compactMap { favorite -> String? in
            if case .mailbox(let id, .allAccounts) = favorite.target { return id }
            return nil
        })
        return SystemMailbox.all.flatMap { box in
            box.id == SystemLabel.draft && showingOutbox ? [box, .outbox] : [box]
        }.filter { !favorites.contains($0.id) }
    }

    private var accountColors: [String: Color] {
        let ids = mailbox.accounts.map(\.account.id)
        return AccountAppearance.colorIndexes(for: ids, stored: AccountAppearance.decode(storedColors))
            .mapValues { AccountAppearance.color(at: $0) }
    }

    /// Right Arrow shows a mailbox's account rows and Left Arrow hides them,
    /// or moves from an account row up to its mailbox, as in an outline.
    private func expandOrCollapse(_ key: KeyEquivalent) -> KeyPress.Result {
        guard mailbox.presentedAccounts.count > 1, let selected = mailbox.selectedMailbox,
              (SystemMailbox.all + [.outbox]).contains(where: { $0.id == selected.id })
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
        OutlineGroup(LabelNode.outline(owner.labels.filter { !$0.isSystem && mailbox.isVisibleInSidebar($0) }), children: \.children) { node in
            LabelRow(mailbox: mailbox, node: node)
        }
    }

    @ViewBuilder private func moreMailboxes(_ owner: AccountMailbox) -> some View {
        if mailbox.listPreferences.showsMore {
            DisclosureGroup("More") {
                let primary = Set(SystemMailbox.all.map(\.id) + [SystemLabel.unread])
                ForEach(owner.labels.filter { label in
                    label.isSystem && !primary.contains(label.id)
                        && !(mailbox.accountPresentation[owner.account.id]?.inboxCategories.map(\.labelID).contains(label.id) ?? false)
                }, id: \.id) { label in
                    Label(label.name, systemImage: "tray").tag(MailboxID.account(owner.account.id, label.id))
                        .badge(mailbox.sidebarBadgeCount(.account(owner.account.id, label.id)))
                }
                ForEach(owner.labels.filter { !$0.isSystem && !mailbox.isVisibleInSidebar($0) }, id: \.id) { label in
                    LabelRow(mailbox: mailbox, node: LabelNode(label: label, title: label.name))
                }
            }
        }
    }

    private var sidebarNames: [String: String] {
        var names = AccountAppearance.shortNames(mailbox.accounts.map(\.account))
        for owner in mailbox.accounts {
            if let nickname = mailbox.accountPresentation[owner.account.id]?.nickname, !nickname.isEmpty { names[owner.account.id] = nickname }
        }
        return names
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let box: SystemMailbox
    let title: String
    let color: Color
    /// Unread conversations, or the Outbox's messages. Zero shows no badge.
    let count: Int
    /// Set on a row listing every account to show its disclosure state.
    var isExpanded: Bool?
    var isAccount = false

    var body: some View {
        HStack(spacing: Tokens.Space.s1) {
            if let isExpanded {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(reduceMotion ? nil : Tokens.Motion.standard(duration: Tokens.Motion.fast), value: isExpanded)
                    .frame(width: Tokens.Space.s3, height: Tokens.Space.s5)
                    .accessibilityHidden(true)
            }
            Label {
                Text(title)
                    .lineLimit(1)
            } icon: {
                Image(systemName: box.systemImage)
                    .font(.system(size: isAccount ? Tokens.Space.s3 : Tokens.Control.icon))
                    .imageScale(.medium)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(color)
                    .frame(width: Tokens.Space.s5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
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
            count: isExpanded ? 0 : mailbox.sidebarCount(combinedID), isExpanded: isExpanded
        )
        .tag(combinedID)
        .onTapGesture(perform: selectAndToggle)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint(isExpanded ? "Hides accounts" : "Shows accounts")
        .accessibilityAction(.default, selectAndToggle)
        if isExpanded {
            ForEach(mailbox.presentedAccounts, id: \.account.id) { owner in
                let boxID = MailboxID.account(owner.account.id, box.id)
                if box.id != MailboxModel.outboxID || mailbox.showsOutbox(boxID) {
                    let name = names[owner.account.id] ?? owner.account.email
                    MailboxRow(
                        box: box, title: name, color: colors[owner.account.id] ?? .secondary,
                        count: mailbox.sidebarCount(boxID), isAccount: true
                    )
                    .padding(.leading, Tokens.Space.s8)
                    .help(owner.account.email)
                    .accessibilityLabel("\(box.title), \(name)")
                    .tag(boxID)
                    if box.id == SystemLabel.inbox { InboxCategoryRows(mailbox: mailbox, accountID: owner.account.id) }
                }
            }
        }
    }

    private func selectAndToggle() {
        mailbox.selectedMailbox = .combined(box.id)
        // Keep the disclosure animation local to the chevron, outside List layout.
        isExpanded.toggle()
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
                Text(mailbox.accountTitle(owner.account))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(email)
                if !needsSignIn, case .failed(let message) = owner.syncStatus {
                    Image(systemName: "exclamationmark.triangle")
                        .help(message)
                        .accessibilityLabel(message)
                }
                Spacer(minLength: Tokens.Space.s1)
                Button {
                    mailbox.showNewLabel(in: owner.account.id)
                } label: {
                    Image(systemName: "plus")
                        .frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("New Label")
                .accessibilityLabel("New label for \(email)")
            }
            if needsSignIn {
                Button("Sign In Again") {
                    Task { await app.signInAgain(to: owner.account.id) }
                }
                .buttonStyle(.link)
                .disabled(app.isSigningIn || !app.auth.isConfigured)
                .help("Google ended this session. Sign in again to sync mail.")
                .accessibilityLabel("Sign in again to \(email)")
            }
        }
        .contextMenu {
            Button("New Label…", systemImage: "tag") { mailbox.showNewLabel(in: owner.account.id) }
                .labelStyle(.titleAndIcon)
            Divider()
            Button("Sign Out…", systemImage: "rectangle.portrait.and.arrow.right") { app.accountToSignOut = owner.account }
                .labelStyle(.titleAndIcon)
        }
    }
}

/// A user label in the sidebar outline. Its tag is filled with Gmail's color
/// and outlined when the label has none. A label Gmail hasn't created yet is
/// marked as pending and can't be selected.
private struct LabelRow: View {
    let mailbox: MailboxModel
    let node: LabelNode

    var body: some View {
        let label = node.label
        let isPending = LabelRules.isTemporary(label.id)
        Label {
            HStack(spacing: Tokens.Space.s1) {
                Text(node.title)
                    .lineLimit(1)
                    .help(label.name)
                if isPending {
                    Image(systemName: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Waiting for Gmail")
                }
            }
        } icon: {
            let color = Color(gmailHex: label.backgroundColor)
            let icon = LabelAppearance.shared.icon(for: label)
            Image(systemName: icon == "tag" && color != nil ? "tag.fill" : icon)
                .font(.system(size: Tokens.Control.icon))
                .imageScale(.medium)
                .foregroundStyle(color ?? .secondary)
                .frame(width: Tokens.Space.s5)
        }
        .badge(label.threadsUnread ?? 0)
        .selectionDisabled(isPending)
        .tag(MailboxID.account(label.accountID, label.id))
        .accessibilityLabel(isPending ? "\(label.name), waiting for Gmail" : label.name)
        .contextMenu {
            Button("Add to Favorites", systemImage: "star") {
                Task { await mailbox.navigation.addFavorite(.label(accountID: label.accountID, labelID: label.id)) }
            }
            Menu("Show in Sidebar") {
                ForEach(LabelListVisibility.allCases, id: \.rawValue) { visibility in
                    Button(visibility.sidebarTitle) { mailbox.setLabelVisibility(label, to: visibility) }
                }
            }
            Button("Edit Label…", systemImage: "pencil") { mailbox.showEditLabel(label) }
                .labelStyle(.titleAndIcon)
            Button("Delete Label…", systemImage: "trash") { mailbox.labelToDelete = label }
                .labelStyle(.titleAndIcon)
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
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            switch mailbox.syncStatus {
            case .syncing:
                HStack(spacing: Tokens.Space.s2) {
                    ProgressView().controlSize(.mini)
                    Text("Checking for mail…")
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .fixedSize(horizontal: false, vertical: true)
                    .help(message)
                Button("Try Again") { mailbox.syncNow() }
                    .buttonStyle(.link)
            case .idle:
                if let date = mailbox.lastSyncedAt {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Label("Updated \(date.formatted(.relative(presentation: .named)))", systemImage: "checkmark.circle")
                            .lineLimit(2)
                    }
                }
            }
            // With several accounts, the section titles name them.
            if !mailbox.hasSeveralAccounts {
                Label(mailbox.account.email, systemImage: "person.crop.circle")
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
        sidebarBadgeCount(box)
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
