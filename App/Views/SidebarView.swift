import MailStore
import GmailAPI
import SwiftUI

struct SidebarView: View {
    @Bindable var mailbox: MailboxModel
    @AppStorage(AccountAppearance.storageKey) private var storedColors = Data()
    @AppStorage(SidebarExpansion.storageKey) private var expanded = SidebarExpansion.initial
    @AppStorage("sidebarFavoritesCollapsed") private var favoritesCollapsed = false
    @State private var isAddingFavorite = false
    @State private var preferredSelection: SidebarRowSelection?
    @State private var expandedLabels: Set<MailboxID> = []
    @State private var expandedMore: Set<String> = []

    var body: some View {
        // Calendar and Attachments live in the toolbar's section switcher, so
        // the sidebar starts with Favorites. During a search it shows no
        // selection, since results can come from outside the selected mailbox.
        List(selection: selection) {
            FavoritesView(mailbox: mailbox, isCollapsed: $favoritesCollapsed, isAddingFavorite: $isAddingFavorite)
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
                                .accessibilityValue(mailbox.sidebarBadgeDescription(boxID))
                                .conversationDropTarget(boxID, mailbox: mailbox)
                                .sidebarHover(SidebarRowSelection(mailbox: boxID))
                                .tag(SidebarRowSelection(mailbox: boxID))
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
        .environment(\.selectedSidebarRow, selection.wrappedValue)
        .contentMargins(.horizontal, 0, for: .scrollContent)
        // A Section can apply its sheet to every row, queuing repeated presentations.
        .sheet(isPresented: $isAddingFavorite) {
            AddFavoriteView(mailbox: mailbox) { favoritesCollapsed = false }
        }
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
        .onChange(of: revealTarget, initial: true) { _, _ in
            revealSelection()
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

    private var selection: Binding<SidebarRowSelection?> {
        Binding {
            mailbox.sidebarRowSelection(preferred: preferredSelection, favoritesCollapsed: favoritesCollapsed,
                expandedMailboxIDs: expanded.ids)
        } set: { row in
            // List can clear its selection when a section closes or rows move.
            guard let row else { return }
            preferredSelection = row
            mailbox.sidebarSelection = row.mailbox
        }
    }

    private struct RevealTarget: Equatable {
        let row: SidebarRowSelection?
        let ancestors: [MailboxID]
    }

    private var revealTarget: RevealTarget {
        let row = mailbox.sidebarRowForNavigation(preferred: preferredSelection)
        let ancestors = row.flatMap { $0.source == .mailboxes ? mailbox.sidebarLabelAncestors(of: $0.mailbox) : nil } ?? []
        return RevealTarget(row: row, ancestors: ancestors)
    }

    private func revealSelection() {
        guard let row = mailbox.sidebarRowForNavigation(preferred: preferredSelection) else { return }
        preferredSelection = row
        if case .favorite = row.source { favoritesCollapsed = false }
        if row.source == .mailboxes, case .account(let accountID, let labelID) = row.mailbox,
           let owner = mailbox.account(id: accountID) {
            expandedLabels.formUnion(mailbox.sidebarLabelAncestors(of: row.mailbox))
            if moreBoxes(owner).contains(where: { $0.id == labelID })
                || owner.labels.contains(where: { $0.id == labelID && !$0.isSystem && !mailbox.isVisibleInSidebar($0) }) {
                expandedMore.insert(accountID)
            }
        }
        var ancestor = mailbox.sidebarParent(of: row)
        while let parent = ancestor {
            if mailbox.sidebarCanExpand(parent) { expanded.ids.insert(parent.mailbox.id) }
            ancestor = mailbox.sidebarParent(of: parent)
        }
    }

    /// Right Arrow shows a mailbox's account rows and Left Arrow hides them,
    /// or moves from an account row up to its mailbox, as in an outline.
    private func expandOrCollapse(_ key: KeyEquivalent) -> KeyPress.Result {
        guard let selected = selection.wrappedValue else { return .ignored }
        if mailbox.sidebarCanExpand(selected) {
            if key == .rightArrow { expanded.ids.insert(selected.mailbox.id) }
            else { expanded.ids.remove(selected.mailbox.id) }
        } else if selected.source == .mailboxes, mailbox.sidebarLabelHasChildren(box: selected.mailbox),
                  key == .rightArrow || expandedLabels.contains(selected.mailbox) {
            if key == .rightArrow { expandedLabels.insert(selected.mailbox) }
            else { expandedLabels.remove(selected.mailbox) }
        } else if key == .leftArrow, let parent = mailbox.sidebarParent(of: selected) {
            selection.wrappedValue = parent
        } else {
            return .ignored
        }
        return .handled
    }

    private func expansion(of id: String) -> Binding<Bool> {
        $expanded.ids.contains(id)
    }

    private func labelOutline(_ owner: AccountMailbox) -> some View {
        ForEach(mailbox.sidebarLabelRows(for: owner, expandedLabels: expandedLabels)) { item in
            let box = MailboxID.account(owner.account.id, item.node.id)
            LabelRow(mailbox: mailbox, node: item.node,
                isExpanded: item.node.children == nil ? nil : expandedLabels.contains(box),
                onToggleExpansion: {
                    if expandedLabels.contains(box) { expandedLabels.remove(box) } else { expandedLabels.insert(box) }
                })
                .padding(.leading, CGFloat(item.depth) * Tokens.Space.s4)
        }
    }

    @ViewBuilder private func moreMailboxes(_ owner: AccountMailbox) -> some View {
        if mailbox.listPreferences.showsMore {
            DisclosureGroup("More", isExpanded: $expandedMore.contains(owner.account.id)) {
                ForEach(moreBoxes(owner), id: \.id) { box in
                    Label(box.title, systemImage: box.systemImage)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .sidebarHover(SidebarRowSelection(mailbox: .account(owner.account.id, box.id)))
                        .tag(SidebarRowSelection(mailbox: .account(owner.account.id, box.id)))
                        .badge(mailbox.sidebarBadgeCount(.account(owner.account.id, box.id)))
                        .accessibilityValue(mailbox.sidebarBadgeDescription(.account(owner.account.id, box.id)))
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

/// Resolve inside the row so the native selection controls foreground contrast.
struct SidebarSymbolStyle: ShapeStyle {
    let color: Color

    func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        environment.backgroundProminence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(color)
    }
}

extension EnvironmentValues {
    @Entry var selectedSidebarRow: SidebarRowSelection?
}

private struct SidebarHover: ViewModifier {
    @Environment(\.selectedSidebarRow) private var selection
    let row: SidebarRowSelection
    let isEnabled: Bool

    func body(content: Content) -> some View {
        content.ternHover(isEnabled: isEnabled && selection != row)
    }
}

extension View {
    func sidebarHover(_ row: SidebarRowSelection, isEnabled: Bool = true) -> some View {
        modifier(SidebarHover(row: row, isEnabled: isEnabled))
    }
}

struct SidebarDisclosureAccessibility: ViewModifier {
    let isExpanded: Bool?
    var childrenTitle = "Accounts"
    var badgeDescription = ""
    let toggle: () -> Void

    static func value(badgeDescription: String, isExpanded: Bool?) -> String {
        [badgeDescription, isExpanded.map { $0 ? "Expanded" : "Collapsed" }]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    @ViewBuilder func body(content: Content) -> some View {
        if let isExpanded {
            content
                .accessibilityValue(Self.value(badgeDescription: badgeDescription, isExpanded: isExpanded))
                .accessibilityAction(named: Text("\(isExpanded ? "Hide" : "Show") \(childrenTitle)"), toggle)
        } else {
            content.accessibilityValue(badgeDescription)
        }
    }
}

/// Disclosure changes the outline without changing the current mailbox.
struct SidebarDisclosureButton: View {
    let title: String
    let isExpanded: Bool
    let isHovered: Bool
    var childrenTitle = "Accounts"
    let toggle: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: toggle) {
            SidebarDisclosureChevron(isExpanded: isExpanded, isHovered: isHovered || isFocused)
                .frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .focused($isFocused)
        .accessibilityLabel("\(isExpanded ? "Hide" : "Show") \(childrenTitle.lowercased()) in \(title)")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .help("\(isExpanded ? "Hide" : "Show") \(childrenTitle)")
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
    var onToggleExpansion: (() -> Void)?
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
                    .foregroundStyle(SidebarSymbolStyle(color: color))
                    .frame(width: Tokens.Space.s5 * scale)
            }
            Spacer(minLength: Tokens.Space.s1)
            if let isExpanded, let onToggleExpansion {
                SidebarDisclosureButton(title: box.title, isExpanded: isExpanded, isHovered: isHovered, toggle: onToggleExpansion)
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
            count: isExpanded ? 0 : mailbox.sidebarBadgeCount(combinedID), isExpanded: isExpanded,
            onToggleExpansion: { isExpanded.toggle() }
        )
        .conversationDropTarget(combinedID, mailbox: mailbox)
        .sidebarHover(SidebarRowSelection(mailbox: combinedID))
        .tag(SidebarRowSelection(mailbox: combinedID))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(box.title)
        .modifier(SidebarDisclosureAccessibility(isExpanded: isExpanded,
            badgeDescription: isExpanded ? "" : mailbox.sidebarBadgeDescription(combinedID), toggle: { isExpanded.toggle() }))
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
                    .accessibilityValue(mailbox.sidebarBadgeDescription(boxID))
                    .conversationDropTarget(boxID, mailbox: mailbox)
                    .sidebarHover(SidebarRowSelection(mailbox: boxID))
                    .tag(SidebarRowSelection(mailbox: boxID))
                    .contextMenu {
                        MailboxContextMenu(mailbox: mailbox, box: boxID,
                            favoriteTarget: .mailbox(labelID: box.id, scope: .accounts([owner.account.id])))
                    }
                    if box.id == SystemLabel.inbox { InboxCategoryRows(mailbox: mailbox, accountID: owner.account.id) }
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
    var isExpanded: Bool?
    var onToggleExpansion: (() -> Void)?
    @State private var isHovered = false

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
                Spacer(minLength: Tokens.Space.s1)
                if let isExpanded, let onToggleExpansion {
                    SidebarDisclosureButton(title: label.name, isExpanded: isExpanded, isHovered: isHovered,
                        childrenTitle: "Labels", toggle: onToggleExpansion)
                }
            }
        } icon: {
            let color = Color(gmailHex: label.backgroundColor)
            let icon = LabelAppearance.shared.icon(for: label)
            let scale = Tokens.Control.sidebarIconScale(sidebarRowSize)
            Image(systemName: icon == "tag" && color != nil ? "tag.fill" : icon)
                .font(.system(size: Tokens.Control.icon * scale))
                .imageScale(.medium)
                .foregroundStyle(SidebarSymbolStyle(color: color ?? .secondary))
                .frame(width: Tokens.Space.s5 * scale)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .badge(label.threadsUnread ?? 0)
        .selectionDisabled(isPending)
        .conversationDropTarget(.account(label.accountID, label.id), mailbox: mailbox)
        .onHover { isHovered = $0 }
        .sidebarHover(SidebarRowSelection(mailbox: .account(label.accountID, label.id)), isEnabled: !isPending)
        .tag(SidebarRowSelection(mailbox: .account(label.accountID, label.id)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isPending ? "\(label.name), waiting for Gmail" : label.name)
        .modifier(SidebarDisclosureAccessibility(isExpanded: isExpanded, childrenTitle: "Labels",
            badgeDescription: (label.threadsUnread ?? 0) > 0 ? "\(label.threadsUnread ?? 0) unread" : "",
            toggle: { onToggleExpansion?() }))
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
        SidebarFooter {
            status
        } details: {
            if case .failed(let message) = mailbox.syncStatus {
                VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                    Text(message)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(message)
                    Button("Try Again", systemImage: "arrow.clockwise") { mailbox.syncNow() }
                        .buttonStyle(.link)
                        .foregroundStyle(Color.accentColor)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(Tokens.Space.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tokens.Status.warning.opacity(Tokens.Opacity.wash), in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                .ternOutline(radius: Tokens.Radius.sm, style: .contrastOnly)
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch mailbox.syncStatus {
        case .syncing:
            HStack(spacing: Tokens.Space.s1_5) {
                ProgressView().controlSize(.mini)
                    .frame(width: Tokens.Control.icon, height: Tokens.Control.icon)
                    .accessibilityHidden(true)
                Text("Updating…")
            }
            .accessibilityElement(children: .combine)
        case .failed:
            statusLabel("Update failed", symbol: "exclamationmark.triangle.fill", tint: Tokens.Status.warning)
        case .idle:
            if let date = mailbox.lastSyncedAt {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    let relativeDate = date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
                    ViewThatFits(in: .horizontal) {
                        statusLabel("Updated \(relativeDate)", symbol: "checkmark.circle", tint: Tokens.Status.success)
                            .fixedSize(horizontal: true, vertical: false)
                        statusLabel(relativeDate, symbol: "checkmark.circle", tint: Tokens.Status.success)
                    }
                    .help("Last updated \(date.formatted(date: .abbreviated, time: .shortened))")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Updated \(date.formatted(.relative(presentation: .named)))")
                }
            } else {
                statusLabel("Not updated yet", symbol: "circle.dashed")
            }
        }
    }

    private func statusLabel(_ title: String, symbol: String, tint: Color = .secondary) -> some View {
        HStack(spacing: Tokens.Space.s1_5) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: Tokens.Control.icon)
                .accessibilityHidden(true)
            Text(title)
        }
        .accessibilityElement(children: .combine)
    }
}

extension SystemMailbox {
    /// The sidebar symbol's color, the same in every account.
    var color: Color {
        switch id {
        case SystemLabel.inbox, SystemLabel.unread: .blue
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
