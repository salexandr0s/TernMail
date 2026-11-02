import MailStore
import SwiftUI

struct MailboxSwitchOption: Identifiable, Equatable {
    let title: String
    let detail: String
    let mailbox: MailboxID
    let symbol: String
    var id: String { String(describing: mailbox) }
}

struct MailboxSwitcher: View {
    let mailbox: MailboxModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected: String?
    @FocusState private var searchFocused: Bool
    private var choices: [MailboxSwitchOption] {
        mailbox.mailboxSwitchOptions.filter { query.isEmpty || ($0.title + " " + $0.detail).localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        SettingsEditorSheet(title: "Go to Mailbox", width: Tokens.Settings.editorWideWidth, scrolls: false) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Tokens.Space.s3) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("Mailbox, label or saved search", text: $query)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($searchFocused)
                        .onSubmit(openSelected)
                        .accessibilityLabel("Find a mailbox, label or saved search")
                        .accessibilityIdentifier("mail.switcher.search")
                    if !query.isEmpty {
                        Button("Clear Search", systemImage: "xmark.circle.fill", action: clearSearch)
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(Tokens.Space.s4)
                .ternSurface(style: .grouped)
                .ternOutline(radius: Tokens.Radius.lg, focus: searchFocused ? .accentColor : nil)
                .padding(.horizontal, Tokens.Workspace.pageGutter)
                .padding(.top, Tokens.Space.s4)
                .padding(.bottom, Tokens.Space.s3)

                List(choices, selection: $selected) { choice in
                    HStack(spacing: Tokens.Space.s3) {
                        Image(systemName: choice.symbol)
                            .font(.title3)
                            .foregroundStyle(SidebarSymbolStyle(color: .accentColor))
                            .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                            Text(choice.title).font(.body.weight(.medium)).lineLimit(1)
                            Text(choice.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, Tokens.Space.s1)
                    .contentShape(Rectangle())
                    .tag(choice.id)
                    .help("\(choice.title), \(choice.detail)")
                    .accessibilityElement(children: .combine)
                    .onTapGesture(count: 2) { open(choice) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .accessibilityLabel("Mailbox results")
                .overlay {
                    if choices.isEmpty {
                        ContentUnavailableView("No Matching Mailboxes", systemImage: "magnifyingglass",
                            description: Text("Try another mailbox, label or account name."))
                    }
                }
            }
        } actions: {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Open", action: openSelected)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(choices.isEmpty)
        }
        .onAppear { searchFocused = true; selected = choices.first?.id }
        .onChange(of: query) { _, _ in selected = choices.first?.id }
    }

    private func clearSearch() { query = ""; searchFocused = true }
    private func openSelected() { if let option = choices.first(where: { $0.id == selected }) ?? choices.first { open(option) } }
    private func open(_ option: MailboxSwitchOption) { mailbox.selectedMailbox = option.mailbox; dismiss() }
}

extension MailboxModel {
    var mailboxSwitchOptions: [MailboxSwitchOption] {
        var options = [MailboxSwitchOption(title: "Attachments", detail: "Library", mailbox: .combined(AttachmentLibraryModel.mailboxID), symbol: "paperclip")]
        let primaryIDs = Set(SystemMailbox.all.map(\.id))
        if presentedAccounts.count > 1 {
            options += SystemMailbox.all.map { .init(title: $0.title, detail: "All Accounts", mailbox: .combined($0.id), symbol: $0.systemImage) }
            if showsOutbox(.combined(Self.outboxID)) {
                options.append(.init(title: "Outbox", detail: "All Accounts", mailbox: .combined(Self.outboxID), symbol: SystemMailbox.outbox.systemImage))
            }
        }
        for owner in presentedAccounts {
            let detail = accountTitle(owner.account)
            options += SystemMailbox.all.map { .init(title: $0.title, detail: detail, mailbox: .account(owner.account.id, $0.id), symbol: $0.systemImage) }
            options += owner.labels.filter { !primaryIDs.contains($0.id) && !LabelRules.isTemporary($0.id) }
                .map { .init(title: $0.title, detail: detail, mailbox: .account(owner.account.id, $0.id),
                             symbol: $0.isSystem ? SystemMailbox(labelID: $0.id).systemImage : "tag") }
            if showsOutbox(.account(owner.account.id, Self.outboxID)) {
                options.append(.init(title: "Outbox", detail: detail, mailbox: .account(owner.account.id, Self.outboxID), symbol: SystemMailbox.outbox.systemImage))
            }
        }
        for saved in navigation.searches {
            if let target = favoriteMailboxID(.savedSearch(id: saved.id)) {
                options.append(.init(title: saved.name, detail: "Saved Search", mailbox: target, symbol: "magnifyingglass"))
            }
        }
        return options
    }
}
