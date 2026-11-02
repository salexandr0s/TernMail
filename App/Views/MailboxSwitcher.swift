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
        VStack(spacing: Tokens.Space.s3) {
            TextField("Go to mailbox, label or saved search", text: $query)
                .textFieldStyle(.roundedBorder).focused($searchFocused)
                .onSubmit { openSelected() }
            List(choices, selection: $selected) { choice in
                HStack {
                    Label(choice.title, systemImage: choice.symbol).lineLimit(1)
                    Spacer()
                    Text(choice.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .tag(choice.id)
                .onTapGesture(count: 2) { open(choice) }
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Open") { openSelected() }.keyboardShortcut(.defaultAction).disabled(choices.isEmpty)
            }
        }
        .padding(Tokens.Space.s4)
        .frame(width: Tokens.Layout.shortcutsWidth, height: Tokens.Layout.shortcutsHeight)
        .onAppear { searchFocused = true; selected = choices.first?.id }
        .onChange(of: query) { _, _ in selected = choices.first?.id }
    }

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
