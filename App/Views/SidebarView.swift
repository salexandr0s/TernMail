import MailStore
import GmailAPI
import SwiftUI

struct SidebarView: View {
    @Bindable var mailbox: MailboxModel
    @AppStorage(AccountAppearance.storageKey) private var storedColors = Data()
    @AppStorage(SidebarExpansion.storageKey) private var expanded = SidebarExpansion.initial

    var body: some View {
        // Calendar and Attachments live in the toolbar's section switcher, so
        // the sidebar starts with Favorites. During a search it shows no
        // selection, since results can come from outside the selected mailbox.
        List(selection: $mailbox.sidebarSelection) {
            FavoritesView(mailbox: mailbox)
            SavedSearchRows(mailbox: mailbox)
            if mailbox.presentedAccounts.count > 1 {
                let colors = accountColors
                let names = mailbox.sidebarAccountNames
                let combined = boxes(showingOutbox: mailbox.showsOutbox(.combined(MailboxModel.outboxID)))
                // Favorites can hold every system mailbox, which leaves no rows here.
                if !combined.isEmpty {
                    Section("Mailboxes") {
                        ForEach(combined) { box in
                            CombinedMailboxRows(
                                mailbox: mailbox, box: box, colors: colors, names: names, isExpanded: expansion(of: box.id)
                            )
                        }
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
            } else if let owner = mailbox.presentedAccounts.first {
                let outboxID = MailboxID.account(owner.account.id, MailboxModel.outboxID)
                let accountBoxes = boxes(showingOutbox: mailbox.showsOutbox(outboxID))
                if !accountBoxes.isEmpty {
                    Section("Mailboxes") {
                        ForEach(accountBoxes) { box in
                            let boxID = MailboxID.account(owner.account.id, box.id)
                            MailboxRow(box: box, title: box.title, color: box.color, count: mailbox.sidebarBadgeCount(boxID))
                                .conversationDropTarget(boxID, mailbox: mailbox)
                                .tag(boxID)
                            if box.id == SystemLabel.inbox { InboxCategoryRows(mailbox: mailbox, accountID: owner.account.id) }
                        }
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
        .listStyle(.sidebar)
        .contentMargins(.horizontal, 0, for: .scrollContent)
        .sheet(isPresented: Bindable(mailbox.navigation).isShowingSwitcher) {
            MailboxSwitcher(mailbox: mailbox)
        }
        // The File menu, the Favorites menu and the Saved Searches header
        // open this. Search results pop the same editor over their Save button.
        .sheet(isPresented: Bindable(mailbox.navigation).isCreatingSearch) {
            SavedSearchEditor(mailbox: mailbox, existing: nil)
        }
        .onChange(of: mailbox.navigation.searches) { _, _ in mailbox.refreshSavedSearch() }
        // Rows scroll under the status line; the bar's hard edge effect keeps
        // the status readable over them.
        .safeAreaBar(edge: .bottom) {
            SyncStatusView(mailbox: mailbox)
        }
        .scrollEdgeEffectStyle(.hard, for: .bottom)
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
        .ternConfirm(
            "Delete the label “\(mailbox.labelToDelete?.name ?? "")”?",
            item: $mailbox.labelToDelete,
            actionTitle: "Delete Label",
            message: "Conversations keep their other labels. This can't be undone."
        ) { _ in
            mailbox.deleteConfirmedLabel()
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
        guard mailbox.presentedAccounts.count > 1, let selected = mailbox.sidebarSelection,
              (SystemMailbox.all + [.outbox]).contains(where: { $0.id == selected.id })
        else { return .ignored }
        switch (selected, key) {
        case (.combined(let id), .rightArrow): expansion(of: id).wrappedValue = true
        case (.combined(let id), .leftArrow): expansion(of: id).wrappedValue = false
        case (.account(_, let id), .leftArrow): mailbox.sidebarSelection = .combined(id)
        default: return .ignored
        }
        return .handled
    }

    private func expansion(of id: String) -> Binding<Bool> {
        $expanded.ids.contains(id)
    }

    private func labelOutline(_ owner: AccountMailbox) -> some View {
        OutlineGroup(LabelNode.outline(owner.labels.filter { !$0.isSystem && mailbox.isVisibleInSidebar($0) }), children: \.children) { node in
            LabelRow(mailbox: mailbox, node: node)
        }
    }

    @ViewBuilder private func moreMailboxes(_ owner: AccountMailbox) -> some View {
        if mailbox.listPreferences.showsMore {
            DisclosureGroup("More") {
                ForEach(moreBoxes(owner), id: \.id) { box in
                    Label(box.title, systemImage: box.systemImage)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .ternHover(isEnabled: mailbox.sidebarSelection != .account(owner.account.id, box.id))
                        .tag(MailboxID.account(owner.account.id, box.id))
                        .badge(mailbox.sidebarBadgeCount(.account(owner.account.id, box.id)))
                }
                ForEach(owner.labels.filter { !$0.isSystem && !mailbox.isVisibleInSidebar($0) }, id: \.id) { label in
                    LabelRow(mailbox: mailbox, node: LabelNode(label: label, title: label.name))
                }
            }
        }
    }

    /// The account's system labels that no other sidebar row shows, in
    /// `SystemMailbox.more` order, then any others by title. UNREAD is left
    /// out, and so are the inbox categories listed under the Inbox.
    private func moreBoxes(_ owner: AccountMailbox) -> [SystemMailbox] {
        let excluded = Set(SystemMailbox.all.map(\.id) + [SystemLabel.unread]
            + (mailbox.accountPresentation[owner.account.id]?.inboxCategories.map(\.labelID) ?? []))
        let ids = Set(owner.labels.filter { $0.isSystem && !excluded.contains($0.id) }.map(\.id))
        let known = SystemMailbox.more.filter { ids.contains($0.id) }
        let others = ids.subtracting(known.map(\.id)).map(SystemMailbox.init(labelID:))
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return known + others
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

/// Names for account rows in the sidebar: the nickname the user set, then
/// the account's own name while no other row would show it, then the part of
/// its address before the @ (the whole address when that part repeats).
enum SidebarAccountNames {
    static func names(for accounts: [AccountRecord], nicknames: [String: String] = [:]) -> [String: String] {
        let addressNames = AccountAppearance.shortNames(accounts)
        let setNames = accounts.reduce(into: [String: String]()) { names, account in
            if let nickname = trimmed(nicknames[account.id]) { names[account.id] = nickname }
        }
        // One person's accounts often share a name, so a shared name falls back to the address.
        let ownNames = accounts.reduce(into: [String: String]()) { names, account in
            if setNames[account.id] == nil, let name = trimmed(account.displayName) { names[account.id] = name }
        }
        let uses = Dictionary(ownNames.values.map { ($0.lowercased(), 1) }, uniquingKeysWith: +)
        return accounts.reduce(into: [:]) { names, account in
            names[account.id] = setNames[account.id]
                ?? ownNames[account.id].flatMap { uses[$0.lowercased()] == 1 ? $0 : nil }
                ?? addressNames[account.id] ?? account.email
        }
    }

    private static func trimmed(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

extension MailboxModel {
    /// Account row names for the sidebar, keyed by account ID.
    var sidebarAccountNames: [String: String] {
        let records = accounts.map(\.account)
        let nicknames = records.reduce(into: [String: String]()) { names, account in
            names[account.id] = accountPresentation[account.id]?.nickname
        }
        return SidebarAccountNames.names(for: records, nicknames: nicknames)
    }
}

/// The disclosure chevron of a row that lists every account. As in Finder,
/// it shows while the row is expanded or under the pointer, and keeps its
/// width otherwise so titles stay aligned.
struct SidebarDisclosureChevron: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isExpanded: Bool
    let isHovered: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .animation(reduceMotion ? nil : Tokens.Motion.standard(duration: Tokens.Motion.fast), value: isExpanded)
            .frame(width: Tokens.Space.s3, height: Tokens.Space.s5)
            .opacity(isExpanded || isHovered ? 1 : 0)
            .accessibilityHidden(true)
    }
}

/// A system mailbox's row, its symbol in `color`.
private struct MailboxRow: View {
    @Environment(\.sidebarRowSize) private var sidebarRowSize
    let box: SystemMailbox
    let title: String
    let color: Color
    /// Unread conversations, or the Outbox's messages. Zero shows no badge.
    let count: Int
    /// Set on a row listing every account to show its disclosure state.
    var isExpanded: Bool?
    var isAccount = false
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Tokens.Space.s1) {
            Label {
                Text(title)
                    .lineLimit(1)
            } icon: {
                let scale = Tokens.Control.sidebarIconScale(sidebarRowSize)
                Image(systemName: box.systemImage)
                    .font(.system(size: (isAccount ? Tokens.Space.s3 : Tokens.Control.icon) * scale))
                    .imageScale(.medium)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(color)
                    .frame(width: Tokens.Space.s5 * scale)
            }
            Spacer(minLength: Tokens.Space.s1)
            if let isExpanded {
                SidebarDisclosureChevron(isExpanded: isExpanded, isHovered: isHovered)
                    .padding(.trailing, Tokens.Space.s2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
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
            count: isExpanded ? 0 : mailbox.sidebarBadgeCount(combinedID), isExpanded: isExpanded
        )
        .conversationDropTarget(combinedID, mailbox: mailbox)
        .tag(combinedID)
        .onTapGesture(perform: selectAndToggle)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint(isExpanded ? "Hides accounts" : "Shows accounts")
        .accessibilityAction(.default, selectAndToggle)
        .contextMenu {
            MailboxContextMenu(mailbox: mailbox, box: combinedID, favoriteTarget: .mailbox(labelID: box.id, scope: .allAccounts))
        }
        if isExpanded {
            ForEach(mailbox.presentedAccounts, id: \.account.id) { owner in
                let boxID = MailboxID.account(owner.account.id, box.id)
                if box.id != MailboxModel.outboxID || mailbox.showsOutbox(boxID) {
                    let name = names[owner.account.id] ?? owner.account.email
                    MailboxRow(
                        box: box, title: name, color: colors[owner.account.id] ?? .secondary,
                        count: mailbox.sidebarBadgeCount(boxID), isAccount: true
                    )
                    .padding(.leading, Tokens.Space.s4)
                    .help(owner.account.email)
                    .accessibilityLabel("\(box.title), \(name)")
                    .conversationDropTarget(boxID, mailbox: mailbox)
                    .tag(boxID)
                    .contextMenu {
                        MailboxContextMenu(mailbox: mailbox, box: boxID,
                            favoriteTarget: .mailbox(labelID: box.id, scope: .accounts([owner.account.id])))
                    }
                    if box.id == SystemLabel.inbox { InboxCategoryRows(mailbox: mailbox, accountID: owner.account.id) }
                }
            }
        }
    }

    private func selectAndToggle() {
        mailbox.sidebarSelection = .combined(box.id)
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
                // The start of an address tells accounts apart, so a narrow sidebar cuts the end.
                Text(mailbox.accountTitle(owner.account))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
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
    @Environment(\.sidebarRowSize) private var sidebarRowSize
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
            let scale = Tokens.Control.sidebarIconScale(sidebarRowSize)
            Image(systemName: icon == "tag" && color != nil ? "tag.fill" : icon)
                .font(.system(size: Tokens.Control.icon * scale))
                .imageScale(.medium)
                .foregroundStyle(color ?? .secondary)
                .frame(width: Tokens.Space.s5 * scale)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .badge(label.threadsUnread ?? 0)
        .selectionDisabled(isPending)
        .conversationDropTarget(.account(label.accountID, label.id), mailbox: mailbox)
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
